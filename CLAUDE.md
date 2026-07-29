# doc-superpowers

Documentation orchestrator skill for Claude Code. Generates, audits, and maintains project docs through parallel agent dispatch and agentic workflow discovery.

## Directory Structure

```
doc-superpowers/
├── .gitignore            # Git ignore rules
├── .worktrees/           # Parallel agent dispatch worktrees (gitignored)
├── .claude/              # Self-installed Claude Code hook tier
│   ├── settings.local.json   # Hook wiring (PreToolUse, PostToolUse, Stop)
│   └── hooks/
│       └── doc-superpowers/  # pre-commit-gate.sh, post-commit-sync.sh, session-summary.sh
├── .claude-plugin/       # Claude Code plugin manifest + marketplace
│   ├── plugin.json
│   └── marketplace.json
├── .cursor-plugin/       # Cursor plugin manifest + installation guide
│   ├── plugin.json
│   └── INSTALL.md
├── .codex/               # Codex installation guide
│   └── INSTALL.md
├── .github/              # Self-installed CI tier — 3 of the 9 workflow templates,
│   └── workflows/        # plus tests.yml (this repo only, not a template)
│       ├── doc-freshness-pr.yml
│       ├── doc-freshness-schedule.yml
│       ├── doc-index-update.yml
│       └── tests.yml     # Runs the five shell suites + check-version (bash 5.x / 3.2 matrix)
├── .opencode/            # OpenCode plugin + installation guide
│   ├── INSTALL.md
│   └── plugins/
│       └── doc-superpowers.js
├── skills/
│   └── doc-superpowers/
│       └── SKILL.md      # Main skill definition — action routing, discovery, verification
├── AGENTS.md             # Cross-client agent instructions
├── GEMINI.md             # Gemini CLI context redirect
├── claude-code.json      # Claude Code skill manifest (bump-version target)
├── gemini-extension.json # Gemini CLI extension manifest
├── package.json          # npm/OpenCode package metadata
├── scripts/
│   ├── doc-tools.sh      # Bundled freshness tooling (build-index, check-freshness, update-index, add-entry, remove-entry, deprecate-entry, status, bump-version, check-version, implementation-status, set-implementation, fragments, tools)
│   ├── test-doc-tools.sh # Test suite for doc-tools.sh
│   ├── test-doc-pr-release.sh # Test suite for doc-pr-release helpers
│   ├── test-helpers.sh   # Shared test utilities
│   ├── test-hooks.sh     # Test suite for hooks installer and hook scripts
│   ├── test-spec-status-model.sh # Test suite for the canonical Spec Status Model + call sites
│   ├── merge-doc-index.sh  # Custom git merge driver for .doc-index.json
│   ├── test-merge-driver.sh # Test suite for merge driver
│   └── hooks/
│       ├── install.sh        # Hook installer engine
│       ├── state.sh          # Install-state tracking — .claude/doc-superpowers/installed.json
│       ├── git/              # Git hook scripts
│       ├── claude/           # Claude Code hook scripts
│       └── ci/               # GitHub Actions workflow templates
│           ├── doc-freshness-pr.yml      # PR freshness check (shell-based)
│           ├── doc-freshness-schedule.yml # Weekly audit cron (shell-based)
│           ├── doc-index-update.yml      # Auto-index update on push (shell-based)
│           ├── doc-audit-update.yml      # AI audit+update on feature branches
│           ├── doc-review-pr.yml         # AI PR doc review + @claude interactive
│           ├── doc-release.yml           # AI release notes drafting (consumer)
│           ├── doc-spec-verify.yml       # AI spec compliance on PRs
│           ├── doc-pr-full-cycle.yml     # AI PR full cycle: review, update, diagram, sync
│           ├── doc-pr-release.yml        # AI per-PR release-notes fragment producer
│           └── doc-pr-release/           # Helper scripts + fragment-format spec
│               ├── extract-context.sh    # Build context.json for the agent
│               ├── update-pr-body.sh     # Idempotent PR-body managed-section editor
│               ├── commit-and-push.sh    # FF-safe fragment commit + push (rebase retry)
│               └── RELEASE-NOTES.next.README.md # Fragment-format spec (producer/consumer contract)
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
│   ├── issues/           # Bug reports and enhancement requests
│   ├── plans/            # Audit reports and update plans
│   ├── archive/          # Archived docs (created on demand by `update` when superseding)
│   │   └── plans/              # Archived audit plans
│   ├── codebase-guide.md # Directory map, key files, code flow
│   └── conventions.md    # Naming, versioning, skill structure
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
| `skills/doc-superpowers/SKILL.md` | Skill logic — discovery, action routing, agent prompts, verification | Adding actions, changing workflow |
| `scripts/doc-tools.sh` | Bundled freshness tooling — 13 subcommands for index management, version sync, ADR/SPEC implementation status, release-notes fragments, and CLI vendoring | Changing staleness detection, index schema, version sync, implementation status, fragment merge, or vendoring |
| `scripts/test-doc-tools.sh` | Test suite for doc-tools.sh | Adding tests for new doc-tools features |
| `scripts/test-hooks.sh` | Test suite for hooks installer and hook scripts | Adding tests for new hooks or installer features |
| `scripts/test-spec-status-model.sh` | Test suite pinning the canonical Spec Status Model wording and its call sites | Changing spec status transition rules, roles, or vocabulary |
| `scripts/test-doc-pr-release.sh` | Test suite for doc-pr-release helpers (extract-context, update-pr-body, commit-and-push) + YAML placeholder substitution | Adding tests for fragment-producer features |
| `scripts/hooks/ci/doc-pr-release.yml` | AI per-PR release-notes fragment producer — drafts `RELEASE-NOTES.next/PR-<N>.md` on every push | Changing the producer workflow, prompt, or post-Claude verification |
| `scripts/hooks/ci/doc-pr-release/*.sh` | Producer helpers: extract-context, update-pr-body, commit-and-push | Changing fragment context schema, PR-body editing, or push logic |
| `scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md` | Fragment-format spec — producer/consumer contract for `RELEASE-NOTES.next/PR-*.md` | Changing fragment markers, hash protocol, or consumer rules |
| `scripts/merge-doc-index.sh` | Custom git merge driver for .doc-index.json — auto-resolves timestamp/entry conflicts during merge/rebase | Changing merge conflict resolution logic |
| `scripts/test-merge-driver.sh` | Test suite for merge-doc-index.sh | Adding tests for merge driver features |
| `scripts/hooks/install.sh` | Hook installer — install/uninstall/status for all tiers (including merge driver registration) | Adding hook tiers, changing installer logic |
| `scripts/hooks/state.sh` | Install-state tracking shared by install.sh — reads/writes `.claude/doc-superpowers/installed.json` (committed, so install choices persist across contributors) | Changing state schema, the known-workflow list, or state-respect rules |
| `references/doc-spec.md` | Doc templates, Mermaid syntax, naming conventions, schema reference | Adding doc types, changing templates |
| `references/agent-prompt-template.md` | Review agent prompt template + scope-specific focus areas | Changing agent review instructions or adding project signals |
| `references/output-templates.md` | Audit report format + plan template | Changing report structure or plan format |
| `references/spec-lifecycle-actions.md` | Detailed procedures for spec-generate (incl. Step 5b stale content scan), spec-inject, spec-verify; defines the canonical **Spec Status Model** (ladder, exempt class, rules R1-R4, evaluation order) | Changing spec action steps or adding new spec actions; changing status transition rules, roles, or vocabulary |
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
- `/doc-superpowers spec-inject --phase=plan|execute --specs=<paths>` — Inject spec tasks or track drift
- `/doc-superpowers spec-verify --mode=post-execute|review --specs=<paths>` — Verify spec compliance

Each `--specs` path may carry an optional role suffix — `<path>:target` or `<path>:constraint`. Unsuffixed paths stay valid and are role-inferred at execution time.

## Conventions

- **Versioning**: Semantic versioning (MAJOR.MINOR.PATCH). RELEASE-NOTES.md is the canonical source — `check-version` reads it, `bump-version` never writes it. Run `scripts/doc-tools.sh bump-version X.Y.Z` to update the 6 manifest files, then `check-version` to verify. This step is **mandatory** — never manually edit version strings in individual files
- **Skill structure**: Follows obra/superpowers SKILL.md conventions (YAML frontmatter with `name` + `description`)
- **Templates**: All doc templates live in `references/doc-spec.md`, not inline in SKILL.md
- **Diagrams**: Mermaid source in docs, PNGs committed for GitHub rendering
- **Testing**: Five shell suites gate changes — `test-doc-tools.sh` (209 assertions), `test-hooks.sh` (308), `test-spec-status-model.sh` (68), `test-doc-pr-release.sh` (32), `test-merge-driver.sh` (19), 636 total, all sharing the `test-helpers.sh` harness. All five run in CI via `.github/workflows/tests.yml` on push to `main` and on every PR, matrixed over `ubuntu-latest` (bash 5.x) and `macos-latest` (`/bin/bash` 3.2.57). The interpreter is passed explicitly at both levels: CI runs each suite under `$BASH_BIN`, and `test-helpers.sh`'s `bash_bin_shim()` wraps every script under test so it `exec`s under the same interpreter instead of re-resolving bash from its own `#!/usr/bin/env bash`. Without the shim the 3.2 leg silently tests whatever bash the runner image puts first on `PATH` — bash 3.2 is a real support target (it is what macOS ships, so it is what a consuming project's git hooks run under), and `test-doc-tools.sh` carries a static guard that fails on any bash-4-only construct in the shipped scripts. Test skill changes by running `/doc-superpowers init` on a sample project
