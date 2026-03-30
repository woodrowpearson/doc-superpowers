# doc-superpowers

Documentation orchestrator skill for Claude Code. Generates, audits, and maintains project docs through parallel agent dispatch and agentic workflow discovery.

## Directory Structure

```
doc-superpowers/
├── .gitignore            # Git ignore rules
├── .worktrees/           # Parallel agent dispatch worktrees (gitignored)
├── .claude-plugin/       # Claude Code plugin manifest + marketplace
│   ├── plugin.json
│   └── marketplace.json
├── .cursor-plugin/       # Cursor plugin manifest
│   └── plugin.json
├── .codex/               # Codex installation guide
│   └── INSTALL.md
├── .opencode/            # OpenCode plugin + installation guide
│   ├── INSTALL.md
│   └── plugins/
│       └── doc-superpowers.js
├── SKILL.md              # Main skill definition — action routing, discovery, verification
├── AGENTS.md             # Cross-client agent instructions
├── GEMINI.md             # Gemini CLI context redirect
├── gemini-extension.json # Gemini CLI extension manifest
├── package.json          # npm/OpenCode package metadata
├── scripts/
│   ├── doc-tools.sh      # Bundled freshness tooling (build-index, check-freshness, update-index, add-entry, remove-entry, deprecate-entry, status, bump-version, check-version)
│   ├── test-doc-tools.sh # Test suite for doc-tools.sh
│   ├── test-helpers.sh   # Shared test utilities
│   ├── test-hooks.sh     # Test suite for hooks installer and hook scripts
│   └── hooks/
│       ├── install.sh        # Hook installer engine
│       ├── git/              # Git hook scripts
│       ├── claude/           # Claude Code hook scripts
│       └── ci/               # GitHub Actions workflow templates
├── references/
│   ├── doc-spec.md       # Templates for generated docs (C4, ERD, workflows, agentic, specs, ADRs)
│   ├── agent-prompt-template.md   # Review agent prompt template + scope focus areas
│   ├── output-templates.md        # Audit report format + plan template
│   ├── spec-lifecycle-actions.md  # Detailed procedures for spec-generate/inject/verify
│   ├── spec-lifecycle-protocol.md  # Wrapper author integration guide
│   ├── integration-patterns.md    # How other skills integrate with doc-superpowers
│   └── tool-mappings.md           # Cross-framework tool name mappings
├── docs/                 # Documentation about this skill itself
│   ├── architecture/
│   │   ├── system-overview.md  # C4 diagrams, tech stack, key decisions
│   │   └── diagrams/           # Architecture PNGs
│   ├── workflows/
│   │   ├── doc-superpowers.md  # Action flows, sequence diagrams, agentic docs
│   │   └── diagrams/           # Workflow PNGs
│   ├── guides/
│   │   └── getting-started.md  # Installation, first run, verification
│   ├── superpowers/      # Design docs and plans (created by superpowers framework)
│   │   ├── specs/              # Design specs from brainstorming
│   │   └── plans/              # Implementation plans from writing-plans
│   ├── .doc-index.json   # Machine-readable freshness index (generated)
│   ├── plans/            # Audit reports and update plans
│   ├── archive/          # Archived docs (created on demand by `update` when superseding)
│   │   └── plans/              # Archived audit plans
│   ├── codebase-guide.md # Directory map, key files, code flow
│   ├── conventions.md    # Naming, versioning, skill structure
├── evals/                # Evaluation test cases for skill testing
│   └── evals.json        # Test prompts and assertions
├── README.md             # Installation, usage, examples
├── LICENSE               # MIT
├── RELEASE-NOTES.md      # Semantic versioned changelog
└── CLAUDE.md             # This file
```

## Key Files

| File | Purpose | When to Modify |
|------|---------|---------------|
| `SKILL.md` | Skill logic — discovery, action routing, agent prompts, verification | Adding actions, changing workflow |
| `scripts/doc-tools.sh` | Bundled freshness tooling — 9 subcommands for index and version management | Changing staleness detection, index schema, version sync |
| `scripts/test-doc-tools.sh` | Test suite for doc-tools.sh | Adding tests for new doc-tools features |
| `scripts/test-hooks.sh` | Test suite for hooks installer and hook scripts | Adding tests for new hooks or installer features |
| `scripts/hooks/install.sh` | Hook installer — install/uninstall/status for all tiers | Adding hook tiers, changing installer logic |
| `references/doc-spec.md` | Doc templates, Mermaid syntax, naming conventions, schema reference | Adding doc types, changing templates |
| `references/agent-prompt-template.md` | Review agent prompt template + scope-specific focus areas | Changing agent review instructions or adding project signals |
| `references/output-templates.md` | Audit report format + plan template | Changing report structure or plan format |
| `references/spec-lifecycle-actions.md` | Detailed procedures for spec-generate, spec-inject, spec-verify | Changing spec action steps or adding new spec actions |
| `references/spec-lifecycle-protocol.md` | Wrapper author integration guide — input/output contracts, integration patterns | Adding integration patterns, changing action contracts |
| `references/integration-patterns.md` | How other skills integrate with doc-superpowers (code review, commit review, wrapper skills) | Adding integration patterns |
| `docs/codebase-guide.md` | Directory map, key files, code flow for this skill | Structural changes to the skill |
| `docs/conventions.md` | Naming, versioning, skill structure conventions | Convention changes |
| `references/tool-mappings.md` | Cross-framework tool name translations | Adding framework support, tool name changes |
| `AGENTS.md` | Cross-client agent instructions | Adding commands, changing project orientation |
| `.opencode/plugins/doc-superpowers.js` | OpenCode ESM plugin | Changing skill registration or tool mapping injection |
| `RELEASE-NOTES.md` | Version history | Every release |
| `README.md` | User-facing docs | Feature changes |

## Commands

- `/doc-superpowers init` — Generate docs from scratch
- `/doc-superpowers audit` — Full documentation health check
- `/doc-superpowers review-pr` — PR-scoped doc review
- `/doc-superpowers update` — Execute doc updates from audit
- `/doc-superpowers diagram` — Regenerate diagrams
- `/doc-superpowers sync` — Sync doc index with filesystem
- `/doc-superpowers hooks install [--git] [--claude] [--ci] [--all]` — Install workflow hooks
- `/doc-superpowers hooks status` — Show installed hooks
- `/doc-superpowers hooks uninstall` — Remove installed hooks
- `/doc-superpowers release` — Draft release notes entry from git history
- `/doc-superpowers spec-generate --design-doc=<path>` — Generate formal specs from design doc
- `/doc-superpowers spec-inject --phase=plan|execute` — Inject spec tasks or track drift
- `/doc-superpowers spec-verify --mode=post-execute|review` — Verify spec compliance

## Conventions

- **Versioning**: Semantic versioning (MAJOR.MINOR.PATCH) in RELEASE-NOTES.md
- **Skill structure**: Follows obra/superpowers SKILL.md conventions (YAML frontmatter with `name` + `description`)
- **Templates**: All doc templates live in `references/doc-spec.md`, not inline in SKILL.md
- **Diagrams**: Mermaid source in docs, PNGs committed for GitHub rendering
- **Testing**: Test skill changes by running `/doc-superpowers init` on a sample project
