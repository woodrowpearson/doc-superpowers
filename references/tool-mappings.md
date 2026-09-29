# Tool Mappings

This skill is written with Claude Code's tool names. This file is the **one** place that maps them to other clients and says what each client supports: the INSTALL files, `AGENTS.md` and `GEMINI.md` link here instead of repeating it. Where a client's documentation is silent, the cell says *unverified* — treat it as untested, not as supported.

> Last verified: 2026-09-28, against each client's current documentation or source (see *Sources*). Re-verify a column before relying on it after a client release.

## Tool names

Use the tool that does the same job in your client. Only the skill's own references to these tools need translating; shell commands in the skill's `bash` blocks run as written through the client's shell tool.

| Claude Code | Cursor | Codex | OpenCode | Gemini CLI |
|-------------|--------|-------|----------|------------|
| `Read` | read files ¹ | `exec_command` (`cat`, `sed -n`) | `read` | `read_file` |
| `Write` | edit files ¹ | `apply_patch` | `write` | `write_file` |
| `Edit` | edit files ¹ | `apply_patch` | `edit` | `replace` |
| `Bash` | run shell commands ¹ | `exec_command` | `bash` | `run_shell_command` |
| `Grep` | search ¹ | `exec_command` (`rg`, `grep`) | `grep` | `grep_search` |
| `Glob` | search ¹ | `exec_command` (`rg --files`, `find`) | `glob` | `glob` |
| `Agent` | subagents: the built-in Explore subagent, or custom ones in `.cursor/agents/` | `spawn_agent`, then `wait_agent` | `task` | `invoke_agent` |
| `Skill` | loads plugin skills itself (mechanism and tool id unverified) | none: skills are listed at startup and read on use | `skill` | `activate_skill` |
| `AskUserQuestion` | ask questions ¹ | `request_user_input` (experimental; otherwise ask in the reply) | `question` | `ask_user` |
| `TodoWrite` | unverified | `update_plan` (current source registers it only with `[tools.update_plan] enabled = true`) | `todowrite` | `write_todos` |
| `WebSearch` | web ¹ | `web_search` (when the model supports it) | `websearch` | `google_web_search` |
| `WebFetch` | web ¹ | none | `webfetch` | `web_fetch` |
| `mcp__mermaid__generate_mermaid_diagram` | the Mermaid MCP server, if configured | the Mermaid MCP server, if configured | the Mermaid MCP server, if configured | the Mermaid MCP server, if configured |

¹ Cursor documents its agent tools by what they do, not by an id; use the tool that does that.

`Agent` was called `Task` in older Claude Code releases; the row covers both. The skill dispatches `Agent` with `subagent_type: "Explore"` (read-only exploration) or `"general-purpose"`; pick the client's closest subagent.

## Capabilities

| Capability | Claude Code | Cursor | Codex | OpenCode | Gemini CLI |
|------------|-------------|--------|-------|----------|------------|
| How this mapping reaches the model | not needed | not delivered: SKILL.md's references table points here | not delivered: SKILL.md's references table points here | the plugin adds this file to the system prompt | `GEMINI.md` imports this file |
| Subagent dispatch (`init`, `audit`, `review-pr`, `update`) | `Agent`, in parallel | subagents; parallel dispatch unverified | `spawn_agent` (`[features] multi_agent`, on by default) | `task`; parallel dispatch unverified | `invoke_agent`; parallel dispatch unverified |
| Git hook tier (`--git`) | yes | yes | yes | yes | yes |
| Claude hook tier (`--claude`) | yes | unverified: Cursor runs Claude Code hooks from `.claude/settings.json` when *Include Third-Party Plugins, Skills, and Other Configs* is on; this tier writes `.claude/settings.local.json`, which Cursor's docs do not name | no | no | no |
| CI tier (`--ci`) | yes | yes | yes | yes | yes |
| Web search / fetch | yes | yes | search only, model-dependent | yes | yes |
| Diagram PNGs (`diagram`) | with a Mermaid MCP server | with a Mermaid MCP server | with a Mermaid MCP server | with a Mermaid MCP server | with a Mermaid MCP server |

- **Git hooks** are run by git, whatever client made the commit. **CI workflows** run on GitHub Actions; the AI workflows run Claude Code there with the repository's Anthropic secret, whatever client you use locally.
- **Claude hooks** are Claude Code's `PreToolUse` / `PostToolUse` / `Stop` hooks. Cursor maps those three events to its own; whether it also reads `.claude/settings.local.json` is not documented, so install the tier under Cursor only after checking that the hooks fire.
- **Without subagents** — or when a client runs them one at a time — do each scope's work inline, in turn (gather, analyze, report or execute), then merge the results. Slower; same result.
- **Without a Mermaid MCP server** the `diagram` action writes the Mermaid source in place of the PNG.
- The skill's core workflows do not depend on web search or fetch.

## Tool resolution

Every client finds the bundled tooling the same way: from the skill's own directory, never from a client-specific install location. SKILL.md's *Detect Bundled Tooling* block sets `ROOT="${CLAUDE_SKILL_DIR}/../.."` — the plugin root, two levels above the directory holding `SKILL.md` — and takes `$ROOT/scripts/doc-tools.sh`, `$ROOT/scripts/hooks/install.sh` and `$ROOT/references/` from it.

- **Claude Code** substitutes `${CLAUDE_SKILL_DIR}` when it loads the skill, so the block runs as written.
- **Any other client** leaves it literal: put in the path of the directory the client loaded `SKILL.md` from (the skill path it reports, or the path you read the file at).
- The Claude Code plugin cache (`~/.claude/plugins/cache/doc-superpowers/doc-superpowers/<version>/`) is only a fallback, tried when `$ROOT` holds no executable `doc-tools.sh`; with neither, the block stops rather than run a tool that is not there.
- CI workflows do not resolve at all: they call the vendored `.github/scripts/doc-tools.sh` by that literal path, the one their `--allowedTools` grants.

## Client notes

### Cursor
- `.cursor-plugin/plugin.json` sets `"skills": "./skills/"`, the directory holding `doc-superpowers/SKILL.md`.
- A manual install lives in `~/.cursor/plugins/local/doc-superpowers` — a real directory: Cursor skips a symlink there whose target is outside that folder. See `.cursor-plugin/INSTALL.md`.

### Codex
- Subagents need `[features] multi_agent`, which is on by default; set `multi_agent = true` under `[features]` in `~/.codex/config.toml` only if it was turned off. A top-level `multi_agent` key is ignored.
- Codex has no separate read, search or list tools: it runs `cat`, `rg`, `sed` and the like through `exec_command`.

### OpenCode
- `.opencode/plugins/doc-superpowers.js` registers the plugin root as a skills path and adds this file to the system prompt (`experimental.chat.system.transform`, appending one entry to the `output.system` array).

### Gemini CLI
- The extension's `GEMINI.md` is loaded into every session, so it imports only this file; the skill itself is loaded on demand from the extension's `skills/doc-superpowers/`.
- `activate_skill` grants file access to the skill's own directory. Whether `read_file` then reaches `$ROOT/references/`, two levels up, is unverified; if it is refused, read the file with `run_shell_command` (`cat`).

## Sources

Checked 2026-09-28. The Context7 library id each fact was fetched through is given in brackets.

- **OpenCode** — `Hooks` interface: `experimental.chat.system.transform(input, output: { system: string[] })` — github.com/anomalyco/opencode `packages/plugin/src/index.ts`; tool ids and permission keys `read`, `write`, `edit`, `apply_patch`, `bash`, `grep`, `glob`, `list`, `task`, `todowrite`, `question`, `webfetch`, `websearch`, `skill` — `packages/web/src/content/docs/permissions.mdx`, `agents.mdx`, `packages/opencode/src/cli/cmd/run/tool.ts`; `skills.paths`, the `plugin` array and `.opencode/plugins/` auto-loading — `packages/core/src/plugin/skill/customize-opencode.md` [`/anomalyco/opencode`].
- **Codex** — `features.multi_agent` (stable, on by default; `spawn_agent`, `send_input`, `resume_agent`, `wait_agent`, `close_agent`) — learn.chatgpt.com/docs/config-file/config-reference; skill locations (`$HOME/.agents/skills`, repo `.agents/skills`; symlinks followed) — learn.chatgpt.com/docs/build-skills [`/llmstxt/learn_chatgpt_llms-full_txt`]; recursive `SKILL.md` discovery (depth 6, hidden directories skipped) — `codex-rs/ext/skills/src/loader/discovery.rs`; `exec_command`, `apply_patch` — `codex-rs/core/src/tools/spec_plan.rs`, `handlers/apply_patch_spec.rs`; `update_plan` behind `[tools.update_plan]`, `web_search` by model support, `experimental_request_user_input` — `codex-rs/config/src/config_toml.rs`, `core/src/config/mod.rs` [`/openai/codex`].
- **Cursor** — plugin manifest, `skills` field ("path(s) to skill directories"), local plugins in `~/.cursor/plugins/local/<name>` and the symlink rule — cursor.com/docs/plugins, cursor.com/docs/reference/plugins; Claude Code hooks from `.claude/settings.json` behind *Include Third-Party Plugins, Skills, and Other Configs*, event mapping — cursor.com/docs/reference/third-party-hooks; subagents (Explore, `.cursor/agents/`) — cursor.com/docs/subagents; tools described by function — cursor.com/docs/agent/overview [`/websites/cursor`].
- **Gemini CLI** — tool names `read_file`, `write_file`, `replace`, `glob`, `grep_search`, `list_directory` — `docs/reference/tools.md`; `run_shell_command`, `google_web_search`, `web_fetch`, `ask_user`, `activate_skill` — `docs/cli/plan-mode.md`, `docs/hooks/reference.md`; `write_todos` — `docs/tools/todos.md`; `invoke_agent` — `docs/reference/policy-engine.md`; skill discovery tiers (extension skills; `~/.gemini/skills/` or `~/.agents/skills/`) and `activate_skill` access — `docs/cli/skills.md`; `contextFileName` loaded every session, `@file` imports — `docs/extensions/writing-extensions.md`, `docs/cli/gemini-md.md` [`/google-gemini/gemini-cli`].
- **Claude Code** — `/plugin marketplace add owner/repo`, `plugin install <plugin>@<marketplace>`, skills-directory plugins — code.claude.com/docs/en/plugin-marketplaces, code.claude.com/docs/en/plugins-reference [`/websites/code_claude`].
