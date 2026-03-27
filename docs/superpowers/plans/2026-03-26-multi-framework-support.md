# Multi-Framework Agent Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make doc-superpowers installable and functional in Cursor, Codex, OpenCode, and Gemini CLI — not just Claude Code.

**Architecture:** Follow the pattern established by obra/superpowers v5.0.6, which ships integration files for 5 frameworks. Each framework needs its own discovery mechanism: Cursor uses `.cursor-plugin/plugin.json` with a `skills` path field; Codex uses `.codex/INSTALL.md` with symlink instructions; OpenCode uses `package.json` + `.opencode/plugins/` JS plugin; Gemini CLI uses `gemini-extension.json` + `GEMINI.md` redirect. Additionally, create an `AGENTS.md` for cross-client interop and a tool-mapping reference for frameworks whose tools differ from Claude Code's.

**Tech Stack:** JSON manifests, Markdown, JavaScript (ESM for OpenCode plugin), shell scripts (hooks)

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Already exists | `.claude-plugin/plugin.json` | Claude Code plugin manifest |
| Already exists | `.claude-plugin/marketplace.json` | Self-hosted marketplace registry |
| Create | `.cursor-plugin/plugin.json` | Cursor plugin manifest (explicit path fields) |
| Create | `.codex/INSTALL.md` | Codex installation instructions (symlink-based) |
| Create | `.opencode/INSTALL.md` | OpenCode installation instructions |
| Create | `.opencode/plugins/doc-superpowers.js` | OpenCode ESM plugin (injects skill path + system context) |
| Create | `package.json` | npm/OpenCode package metadata |
| Create | `gemini-extension.json` | Gemini CLI extension manifest |
| Create | `GEMINI.md` | Gemini CLI context redirect (@ includes) |
| Create | `AGENTS.md` | Cross-client instructions (OpenCode, Codex, `.agents/` convention) |
| Create | `references/tool-mappings.md` | Tool name mappings for Codex, OpenCode, Gemini CLI |
| Modify | `README.md` | Add multi-framework installation section |
| Modify | `CLAUDE.md` | Add new files to directory structure table |

---

### Task 1: Cursor Plugin Manifest

**Files:**
- Create: `.cursor-plugin/plugin.json`

Cursor's plugin.json is similar to Claude Code's but adds `displayName` and explicit path fields for skills, agents, commands, and hooks.

- [ ] **Step 1: Create `.cursor-plugin/plugin.json`**

```json
{
  "name": "doc-superpowers",
  "displayName": "Doc Superpowers",
  "description": "Documentation orchestrator: generates, audits, and maintains project docs through parallel agent dispatch, agentic workflow discovery, diagram generation, and spec lifecycle tracking",
  "version": "2.4.0",
  "author": {
    "name": "Woodrow Pearson"
  },
  "homepage": "https://github.com/woodrowpearson/doc-superpowers",
  "repository": "https://github.com/woodrowpearson/doc-superpowers",
  "license": "MIT",
  "keywords": [
    "documentation",
    "audit",
    "freshness",
    "diagrams",
    "mermaid",
    "specs",
    "adr",
    "release-notes",
    "hooks",
    "skills"
  ],
  "skills": "./"
}
```

Note: doc-superpowers is a single-skill plugin with SKILL.md at root, so `skills` points to `"./"`. No separate agents/commands/hooks paths needed since the skill self-contains its hook installer.

- [ ] **Step 2: Verify JSON is valid**

Run: `jq . .cursor-plugin/plugin.json`
Expected: Pretty-printed JSON without errors

- [ ] **Step 3: Commit**

```bash
git add .cursor-plugin/plugin.json
git commit -m "feat: add Cursor plugin manifest"
```

---

### Task 2: Codex Installation Guide

**Files:**
- Create: `.codex/INSTALL.md`

Codex doesn't use a plugin.json — it discovers skills by scanning `~/.agents/skills/` at startup and parsing SKILL.md frontmatter. Installation is clone + symlink. Codex App has sandbox constraints (detached HEAD, blocked git push) that don't affect a documentation skill.

- [ ] **Step 1: Create `.codex/INSTALL.md`**

```markdown
# Installing doc-superpowers for Codex

## Quick Install

```bash
# Clone the repo
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.codex/doc-superpowers

# Create the cross-client skills directory if it doesn't exist
mkdir -p ~/.agents/skills

# Symlink the skill (Codex scans ~/.agents/skills/ at startup)
ln -s ~/.codex/doc-superpowers ~/.agents/skills/doc-superpowers
```

## Verify

Start a new Codex session. The skill should appear in the available skills list. Try:

```
audit my project's documentation
```

## Tool Differences

Codex uses different tool names than Claude Code. See `references/tool-mappings.md` for the full mapping. Key differences:

| Claude Code | Codex |
|-------------|-------|
| `Task` (subagent dispatch) | `spawn_agent` (requires `multi_agent = true`) |
| `TodoWrite` | `update_plan` |
| `Skill` | Skills load natively via SKILL.md discovery |

## Codex App Notes

The Codex App runs in a sandbox with a detached HEAD and blocked `git push`/`git checkout -b`. doc-superpowers works fine in this mode — it reads code and writes documentation files, neither of which require git write operations.
```

- [ ] **Step 2: Commit**

```bash
git add .codex/INSTALL.md
git commit -m "feat: add Codex installation guide"
```

---

### Task 3: OpenCode Plugin

**Files:**
- Create: `package.json`
- Create: `.opencode/INSTALL.md`
- Create: `.opencode/plugins/doc-superpowers.js`

OpenCode loads plugins as ESM JavaScript modules. The plugin hooks into OpenCode's config system to register the skill path and injects bootstrap context into the system prompt. OpenCode also reads `package.json` for the plugin's entry point.

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "doc-superpowers",
  "version": "2.4.0",
  "description": "Documentation orchestrator skill for AI coding agents",
  "type": "module",
  "main": ".opencode/plugins/doc-superpowers.js",
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "https://github.com/woodrowpearson/doc-superpowers.git"
  }
}
```

- [ ] **Step 2: Create `.opencode/plugins/doc-superpowers.js`**

```javascript
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..", "..");

export const DocSuperpowersPlugin = async ({ directory }) => {
  return {
    config: async (config) => {
      // Register the skill root so OpenCode discovers SKILL.md
      config.skills = config.skills || {};
      config.skills.paths = config.skills.paths || [];
      if (!config.skills.paths.includes(ROOT)) {
        config.skills.paths.push(ROOT);
      }
    },

    "experimental.chat.system.transform": async (input, output) => {
      // Inject tool mapping context so the skill's Claude Code
      // tool references get translated to OpenCode equivalents
      const toolMappingNote = [
        "## Tool Mapping (OpenCode)",
        "This skill was written for Claude Code. In OpenCode:",
        "- `TodoWrite` → `todowrite`",
        "- `Task` with subagents → `@mention` syntax",
        "- `Skill` tool → OpenCode's native `skill` tool",
        "- `Read`, `Write`, `Edit`, `Bash`, `Grep`, `Glob` → same names",
      ].join("\n");

      output.system = output.system || "";
      output.system += "\n\n" + toolMappingNote;
    },
  };
};
```

- [ ] **Step 3: Create `.opencode/INSTALL.md`**

```markdown
# Installing doc-superpowers for OpenCode

## Quick Install

Add to your project's `opencode.json`:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git"]
}
```

Or for a specific version:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git#v2.4.0"]
}
```

## Alternative: Local Install

```bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.config/opencode/plugins/doc-superpowers
```

Then add to `opencode.json`:

```json
{
  "skills": {
    "paths": ["~/.config/opencode/plugins/doc-superpowers"]
  }
}
```

## Verify

Start a new OpenCode session. Try:

```
audit my project's documentation
```
```

- [ ] **Step 4: Verify JS syntax**

Run: `node --check .opencode/plugins/doc-superpowers.js`
Expected: No output (clean parse)

- [ ] **Step 5: Commit**

```bash
git add package.json .opencode/
git commit -m "feat: add OpenCode plugin and installation guide"
```

---

### Task 4: Gemini CLI Extension

**Files:**
- Create: `gemini-extension.json`
- Create: `GEMINI.md`

Gemini CLI uses `gemini-extension.json` for metadata and `GEMINI.md` as a context redirect file using `@` include syntax. Gemini has no subagent support, so the skill falls back to sequential execution.

- [ ] **Step 1: Create `gemini-extension.json`**

```json
{
  "name": "doc-superpowers",
  "description": "Documentation orchestrator: generates, audits, and maintains project docs through parallel agent dispatch, agentic workflow discovery, diagram generation, and spec lifecycle tracking",
  "version": "2.4.0",
  "contextFileName": "GEMINI.md"
}
```

- [ ] **Step 2: Create `GEMINI.md`**

```markdown
@./SKILL.md
@./references/tool-mappings.md

# Gemini CLI Notes

This skill was written for Claude Code. Key differences in Gemini CLI:

- **No subagent dispatch**: Where the skill references `Task` tool for parallel agents, use sequential execution instead. Work through audit scopes one at a time.
- **Tool names differ**: See the tool mappings loaded above. Use `read_file` instead of `Read`, `write_file` instead of `Write`, etc.
- **Skill activation**: Skills activate via `activate_skill` tool, not `Skill` tool.
- **No TodoWrite**: Use `write_todos` instead.
```

- [ ] **Step 3: Verify JSON**

Run: `jq . gemini-extension.json`
Expected: Pretty-printed JSON without errors

- [ ] **Step 4: Commit**

```bash
git add gemini-extension.json GEMINI.md
git commit -m "feat: add Gemini CLI extension manifest and context file"
```

---

### Task 5: Cross-Client AGENTS.md

**Files:**
- Create: `AGENTS.md`

`AGENTS.md` is the cross-client convention (used by OpenCode, Codex, and the `.agents/skills/` discovery path). It serves the same role as `CLAUDE.md` but for non-Claude agents. Keep it focused — it should orient an unfamiliar agent to the project without duplicating CLAUDE.md.

- [ ] **Step 1: Create `AGENTS.md`**

```markdown
# doc-superpowers

Documentation orchestrator skill for AI coding agents. Generates, audits, and maintains project documentation.

## Skill Location

The main skill definition is `SKILL.md` at the repository root. Activate it when the user asks about documentation quality, auditing, freshness, diagrams, specs, ADRs, or release notes.

## Key Commands

| Command | Purpose |
|---------|---------|
| `init` | Generate docs from scratch |
| `audit` | Full documentation health check |
| `review-pr` | PR-scoped doc review |
| `update` | Execute doc updates from audit |
| `diagram` | Regenerate diagrams |
| `sync` | Sync doc index with filesystem |
| `hooks` | Install/manage workflow hooks |
| `release` | Draft release notes |
| `spec-generate` | Generate formal specs from design doc |
| `spec-inject` | Inject spec tasks or track drift |
| `spec-verify` | Verify spec compliance |

## Tool Mapping

This skill was written for Claude Code. If your agent uses different tool names, see `references/tool-mappings.md` for the translation table.

## Directory Structure

See `CLAUDE.md` for the full directory map, key files table, and conventions.
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "feat: add cross-client AGENTS.md for non-Claude agents"
```

---

### Task 6: Tool Mappings Reference

**Files:**
- Create: `references/tool-mappings.md`

A single reference file mapping Claude Code tool names to their equivalents in each supported framework. The skill's instructions reference Claude Code tools — agents on other frameworks need this translation table.

- [ ] **Step 1: Create `references/tool-mappings.md`**

```markdown
# Tool Mappings

This skill was written for Claude Code. The table below maps Claude Code tool names to their equivalents in other agent frameworks.

## Quick Reference

| Claude Code | Codex | OpenCode | Gemini CLI |
|-------------|-------|----------|------------|
| `Read` | `read_file` | `read_file` | `read_file` |
| `Write` | `write_file` | `write_file` | `write_file` |
| `Edit` | `edit_file` | `edit_file` | `replace` |
| `Bash` | `shell` | `shell` | `run_shell_command` |
| `Grep` | `grep_search` | `grep_search` | `grep_search` |
| `Glob` | `glob` | `glob` | `glob` |
| `WebSearch` | N/A | N/A | `google_web_search` |
| `WebFetch` | N/A | N/A | `web_fetch` |
| `Skill` | Native (auto-discovered) | `skill` | `activate_skill` |
| `TodoWrite` | `update_plan` | `todowrite` | `write_todos` |
| `Task` (subagent) | `spawn_agent` | `@mention` syntax | **Not available** — use sequential execution |
| `Agent` (subagent) | `spawn_agent` | `@mention` syntax | **Not available** — use sequential execution |

## Framework-Specific Notes

### Codex
- Subagent dispatch via `spawn_agent` requires `multi_agent = true` in config
- Codex App runs in a sandbox (detached HEAD, no `git push`) — doc-superpowers works fine since it only reads code and writes doc files

### OpenCode
- Subagents use `@mention` syntax rather than explicit tool calls
- Plugin at `.opencode/plugins/doc-superpowers.js` auto-registers the skill path

### Gemini CLI
- No subagent support — parallel audit dispatch falls back to sequential scope-by-scope execution
- `GEMINI.md` loads the skill and this mapping file via `@` includes

### Cursor
- Tool names match Claude Code (both are Anthropic-ecosystem)
- Plugin manifest at `.cursor-plugin/plugin.json` declares skill paths explicitly
```

- [ ] **Step 2: Commit**

```bash
git add references/tool-mappings.md
git commit -m "feat: add cross-framework tool mapping reference"
```

---

### Task 7: Update README.md with Multi-Framework Installation

**Files:**
- Modify: `README.md` (installation section)

Add a framework-selection section so users can find installation instructions for their agent.

- [ ] **Step 1: Read current README.md installation section**

Run: `grep -n "## Installation" README.md` to find the section location

- [ ] **Step 2: Add multi-framework installation section**

After the existing Claude Code installation instructions, add:

```markdown
### Cursor

Use Cursor's plugin system:

```
/add-plugin doc-superpowers
```

Or clone and point `.cursor-plugin/plugin.json` at the repo.

### Codex

```bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.codex/doc-superpowers
mkdir -p ~/.agents/skills
ln -s ~/.codex/doc-superpowers ~/.agents/skills/doc-superpowers
```

See `.codex/INSTALL.md` for details.

### OpenCode

Add to your `opencode.json`:

```json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git"]
}
```

See `.opencode/INSTALL.md` for details.

### Gemini CLI

```bash
gemini extensions install https://github.com/woodrowpearson/doc-superpowers
```

### skills.sh (Any Agent)

```bash
npx skills add woodrowpearson/doc-superpowers
```

This works with 40+ supported agents. See [skills.sh](https://skills.sh) for details.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add multi-framework installation instructions to README"
```

---

### Task 8: Update CLAUDE.md Directory Structure

**Files:**
- Modify: `CLAUDE.md` (directory structure section)

Add the new framework integration files to the directory structure table so future agents working on this codebase know about them.

- [ ] **Step 1: Add new entries to the directory structure**

Add these to the tree in CLAUDE.md under the root level:

```
├── .cursor-plugin/
│   └── plugin.json       # Cursor plugin manifest
├── .codex/
│   └── INSTALL.md        # Codex installation guide
├── .opencode/
│   ├── INSTALL.md        # OpenCode installation guide
│   └── plugins/
│       └── doc-superpowers.js  # OpenCode ESM plugin
├── AGENTS.md             # Cross-client agent instructions
├── GEMINI.md             # Gemini CLI context redirect
├── gemini-extension.json # Gemini CLI extension manifest
├── package.json          # npm/OpenCode package metadata
```

And add to the `references/` section:

```
│   ├── tool-mappings.md          # Cross-framework tool name mappings
```

- [ ] **Step 2: Add new key files to the Key Files table**

| File | Purpose | When to Modify |
|------|---------|---------------|
| `references/tool-mappings.md` | Cross-framework tool name translations | Adding framework support, tool name changes |
| `AGENTS.md` | Cross-client agent instructions | Adding commands, changing project orientation |
| `.opencode/plugins/doc-superpowers.js` | OpenCode ESM plugin | Changing skill registration or tool mapping injection |

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add multi-framework files to CLAUDE.md directory structure"
```

---

## Summary

| Task | Framework | Key Files |
|------|-----------|-----------|
| 1 | Cursor | `.cursor-plugin/plugin.json` |
| 2 | Codex | `.codex/INSTALL.md` |
| 3 | OpenCode | `package.json`, `.opencode/plugins/doc-superpowers.js`, `.opencode/INSTALL.md` |
| 4 | Gemini CLI | `gemini-extension.json`, `GEMINI.md` |
| 5 | Cross-client | `AGENTS.md` |
| 6 | All | `references/tool-mappings.md` |
| 7 | All | `README.md` (installation section) |
| 8 | All | `CLAUDE.md` (directory structure) |

**Task 0 (housekeeping):** Update `.claude-plugin/plugin.json` version from 2.3.0 to 2.4.0 before starting.

All tasks are independent and can be executed in parallel except Tasks 7-8 which should run after Tasks 1-6 so the files they reference exist.
