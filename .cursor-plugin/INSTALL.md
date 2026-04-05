# Installing doc-superpowers for Cursor

## Quick Install

Install from the Cursor plugin marketplace, or clone manually:

```bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.cursor/plugins/doc-superpowers
```

The `.cursor-plugin/plugin.json` manifest declares the skill path. Cursor discovers `skills/doc-superpowers/SKILL.md` automatically.

## Verify

Start a new Cursor session. Try:

```
audit my project's documentation
```

## Tool Compatibility

Cursor uses the same tool names as Claude Code (both are Anthropic-ecosystem). No translation is needed — all skill instructions work as-is.

## Feature Parity

Cursor has **full feature parity** with Claude Code:

- All 11 commands (init, audit, review-pr, update, diagram, sync, hooks, release, spec-generate, spec-inject, spec-verify)
- Parallel agent dispatch (up to 3 agents for init/audit)
- All 3 hook tiers (git, Claude Code, CI/CD)
- Mermaid MCP diagram generation (if MCP configured)
- WebSearch / WebFetch
- Spec lifecycle tracking

## Usage

See the project [README.md](../README.md) for command reference and examples.
