# doc-search readiness gate — design

**Status:** approved 2026-10-27 · **Release:** 3.11.0 (proposed) · **Parent:** `2026-10-19-doc-search-design.md`

## Problem

A repository that relies on doc-search wants an agent to stop when doc-search cannot answer, but
only for a developer who has doc-search installed. 3.9.0 cannot express that:

- `status` always exits 0.
- The launcher's exit 2 means several different things. "No doc-superpowers here" (not opted in) and
  "no `uv`" (installed but broken) share it.
- Opt-in exists only per repository (`docs/search/config.json`), not per developer.
- Codex has no supported install path. The launcher finds doc-superpowers only through
  `$DOC_SUPERPOWERS_ROOT` or the Claude plugin cache.
- No agent-facing rule ships, so projects hand-write their own.

**Baseline.** Fresh agents ran under deadline pressure with a hand-written "search first" rule:
- With the MCP tools missing, 2 of 2 used the command line and finished.
- With a stale docs cache and an outdated launcher, 2 of 2 carried on ("a stale cache isn't one of the
  listed outages").
- With doc-superpowers not installed, 1 of 1 used `rg` with a one-line reason, which is correct.

The failures follow the rule text, so the decision has to be mechanical.

**What the clients can do** (their hook documentation, 2026-10-27):
- **Claude Code `SessionStart`** cannot block. It can only add context.
- **`UserPromptSubmit`** blocks a prompt in both Claude Code and Codex. The user sees the reason and the
  agent never gets the prompt.
- **`PreToolUse`** denies a tool call in both. The agent sees the reason. In Claude Code it also fires
  inside subagents.
- **Codex** runs project hooks from `.codex/hooks.json` once the project and the hook are trusted.

## Design

### Policy: two config keys

- `"required": true` makes doc-search a gate in this repository. The default `false` keeps 3.9.0's
  soft behavior.
- `"requires": ">=X.Y.Z"` is the version floor for the plugin and for the committed launcher copy.
  The default `null` sets none.

A plugin older than 3.11.0 rejects both as unknown keys, so every verb says `invalid config: unknown
key required`. That message is the cue to update.

### Per-developer opt-in

- **Opted in** means the launcher finds a doc-superpowers root for this developer. It looks in this
  order:
  1. `$DOC_SUPERPOWERS_ROOT`;
  2. this repository, when it is doc-superpowers itself;
  3. **(new)** `${CODEX_HOME:-$HOME/.codex}/doc-superpowers`, the Codex install path;
  4. the Claude plugin cache.
- **Two per-developer variables.** They are usually set in the env hook the launcher sources.
  - `DOC_SEARCH_MCP=0`: this developer's client cannot run the MCP server (an organization policy, for
    example), so the command line is their search.
  - `DOC_SEARCH_GATE=0`: the hooks allow everything. This is the developer's escape hatch.

### `doc-search check`: the probe

`check [--format text|json] [--budget SECONDS]` exits:

| Exit | Verdict | Meaning |
|---|---|---|
| `0` | `ready` / `degraded` | doc-search answers for this worktree's current tree |
| `1` | `not-ready` | Required here, installed for this developer, and it cannot answer now: halt |
| `3` | usage | |
| `4` | `not-in-force` | No doc-superpowers for this developer, no config, or not required (then the reason says whether it is ready). Never halts |

**Ready** means all of these hold:
1. The config is valid.
2. The plugin version meets `requires`.
3. The committed launcher copy carries a stamp (`# doc-search launcher vX.Y.Z`) that meets `requires`.
4. Both indexes match the tree.

**Index refresh.** Where the config requires doc-search, `check` first runs the incremental refresh
that `query` would run, bounded by `--budget` (default 20 s). Without it, an agent's own edits would
read as stale at the next prompt. Where it does not, `check` refreshes nothing (no index write, no
wait): it reports the would-be state from the cache states alone, so a repository that never opted in
never pays the budget at a prompt.

**Degraded** covers two cases:
- The transformer docs index is absent or building, and the static fallback matches the tree.
- The launcher copy differs from the plugin's but meets the floor.

A saved transformer index that is stale is refreshed incrementally; a refresh that overruns the budget
is `not-ready`, not `degraded`: once a transformer index serves, no static fallback stands beside it.

**Fixes.** Every not-ready verdict names one fix command. `check` never starts a first transformer
build, and `status` is unchanged.

**The launcher answers when Python cannot run:**
- No root: `4`.
- A root that predates the gate (doc-superpowers 3.10.0 or older, whose CLI has neither `check` nor
  `gate`): `1` when the raw config says `"required": true`, fix the plugin update, else `4`.
- No `uv`: `1` when the raw config says `"required": true`, else `4`.
- Not in a git work tree: `4`.

### `gate`: the hooks

The hooks call the committed launcher, so a project commits no other script:
`sh "$(git rev-parse --show-toplevel)/.claude/doc-superpowers/search-mcp.sh" gate <event>`.

| Event | Gate |
|---|---|
| `session-start` | Runs `check` and adds its verdict as context. A not-ready verdict says to do no work until it is ready |
| `prompt` | Runs `check`. When not ready it blocks the prompt with the reason and the fix |
| `tool` | Shell only, no `uv`. It reads the verdict file and, while that says not-ready, denies every tool except the exact fix commands (`search-mcp.sh index`, `status`, `check`) |

- **The verdict file** is `$(git rev-parse --git-path doc-search-gate)`, one per worktree and shared
  by that worktree's sessions. `session-start`, `prompt` and `check` write it atomically (not with
  `DOC_SEARCH_GATE=0`), so the halt's own fix followed by `check` lifts the tool gate.
- **The client.** `install.sh` registers `gate session-start --client claude` for Claude Code and
  `--client codex` for Codex. The `mcp:` line then reports that client's registration (`.mcp.json` for
  Claude Code, Codex's `config.toml` for Codex); `check` run by itself reports each client's.
- **When `gate` stays silent:** with no root, no config, or `DOC_SEARCH_GATE=0`, it prints nothing
  and allows.
- **Failure handling:**
  - A `check` that raises is treated as not ready when the config is required.
  - A hook that times out lets the prompt through, which is the client's behavior. The verdict file
    keeps its last value.
  - The command finds the launcher through `git rev-parse --show-toplevel`, so it needs the hook's
    working directory inside the repository. Outside it the command fails, and the client lets the
    call through (fails open).

`install.sh install --search-gate` merges the three entries into `.claude/settings.json` and
`.codex/hooks.json`. The repository commits them. It needs the committed launcher to be the plugin's
own copy, since an older copy cannot answer the hooks, and `uninstall --search` alone is refused while
the entries run that launcher. Because the probe's exit `4` gives the
per-developer opt-in, committed hooks are inert for everyone else.

### The rule template

`references/search-rule.md` is the agent-facing section. A project copies it between markers:
`<!-- doc-superpowers:search-rule vX.Y.Z -->` … `<!-- /doc-superpowers:search-rule -->`.

- **Keyed to `check`.** `0` means use doc-search, and `degraded` is said once. `4` keeps the soft rule:
  `rg` with a one-line reason. `1` means halt and report.
- **Two agent-observable predicates:**
  - The MCP tools are missing while the `mcp:` line says `expected` for your client: halt (not in a
    Claude Code subagent whose definition lists no MCP tools).
  - `status`'s `worktree:` line is not your top-level directory: pass `worktree:`.
- **Wording.** It carries a rationalization table and red flags from the baseline, and is tested
  RED and then GREEN.
- **Drift check.** `install.sh status --search-gate` says whether a project's marked copy is current.

## Out of scope

- Detecting a client's MCP approval state from its internal files.
- A server-side worktree check. The template's `worktree:` predicate covers that case.
