# The search rule — the block a project copies

This is the rule that tells an agent what to do with a doc-search verdict when a repository requires doc-search (`"required": true` in `docs/search/config.json`). A project copies everything from the opening marker line to the closing marker line, both included, into its `AGENTS.md` or `CLAUDE.md`, unchanged.

`install.sh status --search-gate` reports whether that copy is current: it compares the lines between the markers with this file's.

<!-- doc-superpowers:search-rule v3.11.0 -->
## When doc-search is required

**Use when** your session shows a doc-search verdict: the context your session started with, a blocked
prompt, a denied tool call, or the output of `sh .claude/doc-superpowers/search-mcp.sh check`.

`check` decides whether doc-search can answer; you do not. Its exit code:

| `check` exits | Verdict | Do |
|---|---|---|
| `0` | `ready`, or `degraded` | Search with doc-search first. If degraded, say so once, in one line. |
| `1` | `not-ready` | Halt (below). |
| `4` | `not-in-force` | The gate does not apply to you here. Follow this repository's search rule: doc-search first where it answers, otherwise `rg` with a one-line reason. |

Two things `check` cannot see. Check them yourself:

- **Tools missing.** The verdict's `mcp:` line says `expected` for your client (`claude=` or `codex=`;
  the session-start line names yours), and your tool list has no doc-search
  tools (`mcp__doc-search__*` in Claude Code). The server did not start or was not approved: halt.
  In a Claude Code subagent whose definition lists no MCP tools this is not a halt: use `rg` with a
  one-line reason (the tool gate still applies).
- **Wrong worktree.** doc-search `status` reports a `worktree:` that is not your top-level directory
  (`git rev-parse --show-toplevel`). Pass `worktree: "<your top-level directory>"` on every call.
  This is not a halt.

### Halt

1. Tell the user the verdict line and its fix, word for word. For missing tools the fix is the
   user's: approve or restart the doc-search server, then start a new session.
2. If the fix is `sh .claude/doc-superpowers/search-mcp.sh index`, `status` or `check`, and the verdict does
   not say only the user can run it, you may run it
   from your top-level directory (or by the launcher's absolute path), then run `check`. Exit `0`: carry on.
3. Otherwise stop. No other tool call, no search by other means, no edits, until the user tells you
   doc-search is ready.

| Excuse | Reality |
|---|---|
| "The command line works, so it is the search, not a fallback." | Only where `mcp:` is not `expected`. Expected tools that are missing mean a broken session: halt. |
| "A stale cache or an outdated launcher isn't one of the listed outages." | `check` lists the outages. Exit `1` is a halt, whatever the reason. |
| "The coordinator is waiting; it must land today." | The halt report is one message. Work done on a stale index is done twice. |
| "I'll mention it and carry on." | Mentioning is not halting. Stop after the report. |
| "`rg` is good enough for one lookup." | Not while doc-search is required and not ready. |

**Red flags — stop:** you are about to search with `rg`, grep or the command line after a not-ready
verdict; you are about to edit a file after one; you wrote "carry on" or "proceed" next to "not ready".
<!-- /doc-superpowers:search-rule -->
