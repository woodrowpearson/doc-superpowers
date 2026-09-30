# doc-superpowers

Documentation orchestrator skill for Claude Code. Generates, audits, and maintains project docs through parallel agent dispatch and agentic workflow discovery.

## Directory Structure

```
doc-superpowers/
├── .gitignore            # Git ignore rules (incl. the per-user Claude tier and index lock/temp files)
├── .gitattributes        # Self-installed git tier: docs/.doc-index.json → the doc-index merge driver
├── .worktrees/           # Parallel-agent worktree location (gitignored; not created by the skill)
├── .claude/
│   └── doc-superpowers/
│       └── installed.json    # The self-installed CI tier's record (committed): workflow set, base branch, cron, strict
│                             # (the Claude tier — settings.local.json, hooks/doc-superpowers/ — is per-user and gitignored)
├── .claude-plugin/       # Claude Code plugin manifest + marketplace
│   ├── plugin.json
│   └── marketplace.json
├── .cursor-plugin/       # Cursor plugin manifest + installation guide
│   ├── plugin.json
│   └── INSTALL.md
├── .codex/               # Codex installation guide
│   └── INSTALL.md
├── .github/              # Self-installed CI tier (install.sh install --ci: installer output, never hand-edited)
│   ├── scripts/          # Vendored byte copies: doc-tools.sh + doc-superpowers-steps/ (the step scripts the workflows run)
│   └── workflows/
│       ├── doc-freshness-pr.yml       # The 2 default templates, rendered with the recorded choices
│       ├── doc-freshness-schedule.yml
│       └── tests.yml     # This repo only (not a template): the five suites (bash 5.x / 3.2 matrix), check-version, self-install drift check
├── .opencode/            # OpenCode plugin + installation guide
│   ├── INSTALL.md
│   └── plugins/
│       └── doc-superpowers.js
├── skills/
│   └── doc-superpowers/
│       └── SKILL.md      # Main skill definition — action routing, discovery, verification
├── AGENTS.md             # Cross-client agent instructions
├── GEMINI.md             # Gemini CLI context redirect
├── gemini-extension.json # Gemini CLI extension manifest
├── package.json          # npm/OpenCode package metadata
├── scripts/
│   ├── doc-tools.sh      # Bundled freshness tooling (build-index, check-freshness, update-index, add-entry, remove-entry, move-entry, set-code-refs, set-doc-type, deprecate-entry, status, audit-merges, bump-version, check-version, implementation-status, set-implementation, fragments, tools)
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
│       ├── claude/           # Claude Code hook scripts (and hook-lib.sh, which all three source)
│       └── ci/               # GitHub Actions workflow templates
│           ├── doc-freshness-pr.yml      # PR freshness check (shell-based; fails closed)
│           ├── doc-freshness-schedule.yml # Weekly audit cron (shell-based; fails closed)
│           ├── doc-audit-update.yml      # AI audit+update on feature branches
│           ├── doc-review-pr.yml         # AI PR doc review + @claude interactive
│           ├── doc-release.yml           # AI release notes drafting (consumer)
│           ├── doc-spec-verify.yml       # AI spec compliance on PRs
│           ├── doc-pr-full-cycle.yml     # AI PR full cycle: review, update, diagram, sync
│           ├── doc-pr-release.yml        # AI per-PR release-notes fragment producer
│           ├── doc-pr-release/           # Helper scripts + fragment-format spec
│           │   ├── extract-context.sh    # Build context.json for the agent
│           │   ├── update-pr-body.sh     # Idempotent PR-body managed-section editor
│           │   ├── commit-and-push.sh    # Seal + commit the fragment; push only while the branch is at the checkout
│           │   ├── fragment-lib.sh       # Sourced fragment line rules (markers, hash line, sha256) the helpers share
│           │   └── RELEASE-NOTES.next.README.md # Fragment-format spec (producer/consumer contract)
│           └── doc-superpowers-steps/    # run: step bodies of every template (freshness-check, resolve-auth, prepare-agent, commit-changes, pr-guard, sentinel-check, write-context, verify-fragment, precheck)
├── references/
│   ├── doc-spec.md       # Templates for generated docs (C4, ERD, workflows, agentic, specs, ADRs)
│   ├── agent-prompt-template.md   # Review agent prompt template + scope focus areas
│   ├── output-templates.md        # Audit report format (+ its Update Tasks) + spec compliance report
│   ├── release.md                 # `release` action steps 1–12 (REQUIRED pointer from SKILL.md)
│   ├── hooks.md                   # `hooks` action: tiers, consent table, CI templates (REQUIRED pointer from SKILL.md)
│   ├── spec-lifecycle-actions.md  # Detailed procedures for spec-generate/inject/verify
│   ├── spec-lifecycle-protocol.md  # Wrapper author integration guide
│   ├── integration-patterns.md    # How other skills integrate with doc-superpowers
│   └── tool-mappings.md           # The one capability matrix: per-client tool names + capabilities, tool resolution ($ROOT)
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
│   ├── evals.json        # Test prompts and machine-checkable assertions (path / pattern / command)
│   └── fixtures/         # lib.sh + <eval>/setup.sh — builds each eval's scenario in an empty dir, self-checked
├── README.md             # Installation, usage, examples
├── LICENSE               # MIT
├── RELEASE-NOTES.md      # Semantic versioned changelog
└── CLAUDE.md             # This file
```

## Key Files

| File | Purpose | When to Modify |
|------|---------|---------------|
| `skills/doc-superpowers/SKILL.md` | Skill logic — discovery, action routing, agent prompts, verification | Adding actions, changing workflow |
| `scripts/doc-tools.sh` | Bundled freshness tooling — 17 subcommands (`fragments list\|validate\|merge` and `tools install\|uninstall\|status\|version` take sub-verbs; `--help` lists them all) for index management, version sync, ADR/SPEC implementation status, release-notes fragments, and CLI vendoring | Changing staleness detection, index schema, version sync, implementation status, fragment merge, or vendoring |
| `scripts/test-doc-tools.sh` | Test suite for doc-tools.sh | Adding tests for new doc-tools features |
| `scripts/test-hooks.sh` | Test suite for hooks installer and hook scripts | Adding tests for new hooks or installer features |
| `scripts/test-spec-status-model.sh` | Test suite pinning the canonical Spec Status Model wording and its call sites, and the skill prompt ↔ tool contract: tool resolution, index-write routing, review-pr base, safety rules, templates, the prompts' `--allowedTools`, and `evals/evals.json` (fields, regexes, fixtures run); also the cross-client packaging (manifests, INSTALL pins) and the OpenCode plugin, run under `node` (a loud SKIP without node locally; `DOC_SP_REQUIRE_NODE=1`, set by tests.yml, makes it a FAIL) | Changing spec status transition rules, roles, or vocabulary; changing what SKILL.md / references tell an agent to run; adding an eval; changing a manifest or the OpenCode plugin |
| `scripts/test-doc-pr-release.sh` | Test suite for the CI workflow helpers (extract-context, update-pr-body, commit-and-push, the `run:` step scripts in doc-superpowers-steps/) + YAML placeholder substitution, template structure/wiring, and the installed templates' fail-closed / least-privilege properties | Adding tests for fragment-producer, CI-step or template features |
| `scripts/hooks/ci/doc-pr-release.yml` | AI per-PR release-notes fragment producer — drafts `RELEASE-NOTES.next/PR-<N>.md` on every push | Changing the producer workflow, prompt, or post-Claude verification |
| `scripts/hooks/ci/doc-pr-release/*.sh`, `scripts/hooks/ci/doc-superpowers-steps/*.sh` | Producer helpers (extract-context, update-pr-body, commit-and-push, and `fragment-lib.sh`, the fragment line rules they source; shipped to `.github/scripts/doc-pr-release/` while `doc-pr-release` is installed) and every template's `run:` step bodies (shipped to `.github/scripts/doc-superpowers-steps/` while any workflow is installed) | Changing fragment context schema, PR-body editing, push logic, or any workflow step body |
| `scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md` | Fragment-format spec — producer/consumer contract for `RELEASE-NOTES.next/PR-*.md` | Changing fragment markers, hash protocol, or consumer rules |
| `scripts/merge-doc-index.sh` | Custom git merge driver for .doc-index.json — base-aware per-key three-way merge during merge/rebase/revert; conflict markers + exit 1 when it cannot decide | Changing merge conflict resolution logic |
| `scripts/test-merge-driver.sh` | Test suite for merge-doc-index.sh | Adding tests for merge driver features |
| `scripts/hooks/install.sh` | Hook installer — install/uninstall/status for all tiers (including merge driver registration) | Adding hook tiers, changing installer logic |
| `scripts/hooks/state.sh` | Install-state tracking shared by install.sh — reads/writes `.claude/doc-superpowers/installed.json` (committed, so install choices persist across contributors) | Changing state schema, the known-workflow list, or state-respect rules |
| `references/doc-spec.md` | Doc templates, Mermaid syntax, naming conventions, schema reference | Adding doc types, changing templates |
| `references/agent-prompt-template.md` | Review agent prompt template + scope-specific focus areas | Changing agent review instructions or adding project signals |
| `references/output-templates.md` | Audit report format (with its Update Tasks, the handoff to `update`) + spec compliance report | Changing report structure |
| `references/spec-lifecycle-actions.md` | Detailed procedures for spec-generate (incl. Step 5b stale content scan), spec-inject, spec-verify; defines the canonical **Spec Status Model** (ladder, exempt class, rules R1-R4, evaluation order) | Changing spec action steps or adding new spec actions; changing status transition rules, roles, or vocabulary |
| `references/spec-lifecycle-protocol.md` | Wrapper author integration guide — input/output contracts, integration patterns | Adding integration patterns, changing action contracts |
| `references/release.md` | `release` action procedure (steps 1–12); its `$DOC_TOOLS fragments merge … --remove` forms are pinned to `doc-release.yml`'s `--allowedTools` | Changing the release flow (change the template and its test in the same commit) |
| `references/hooks.md` | `hooks` action: installer routing, per-user Claude tier, `--ci` consent table, CI templates and helpers | Changing installer flags, tiers, or workflow templates |
| `evals/evals.json`, `evals/fixtures/` | Skill evals with machine-checkable fields; per-eval `setup.sh` fixtures | Adding or changing an eval (the spec-status-model suite validates both) |
| `references/integration-patterns.md` | How other skills integrate with doc-superpowers (code review, commit review, wrapper skills) | Adding integration patterns |
| `docs/codebase-guide.md` | Directory map, key files, code flow for this skill | Structural changes to the skill |
| `docs/conventions.md` | Naming, versioning, skill structure conventions | Convention changes |
| `references/tool-mappings.md` | The one capability matrix — per-client tool names and capabilities (INSTALL files, AGENTS.md and GEMINI.md link here), tool resolution | Adding framework support, tool name or capability changes |
| `AGENTS.md` | Cross-client agent instructions | Adding commands, changing project orientation |
| `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `gemini-extension.json` | The 5 version manifests — `bump-version` writes their `version`, `check-version` compares them with RELEASE-NOTES.md | Version strings: never by hand, run `bump-version`. Otherwise only when a client's packaging changes (pinned by `test-spec-status-model.sh`) |
| `GEMINI.md`, `.cursor-plugin/INSTALL.md`, `.codex/INSTALL.md`, `.opencode/INSTALL.md` | Per-client install guides, and Gemini CLI's context file (`gemini-extension.json` loads `GEMINI.md`); each links to `references/tool-mappings.md` instead of copying it | Adding or changing a client's install steps (pinned by `test-spec-status-model.sh`) |
| `.opencode/plugins/doc-superpowers.js` | OpenCode ESM plugin | Changing skill registration or tool mapping injection |
| `.github/workflows/tests.yml` | This repo's CI: the five suites under bash 5.x (ubuntu) and `/bin/bash` 3.2 (macOS), `check-version`, and the self-install drift check | Adding a suite, a CI requirement, or a self-installed tier |
| `.github/workflows/doc-freshness-*.yml`, `.github/scripts/`, `.claude/doc-superpowers/installed.json` | This repo's own installed CI tier — installer output | Never by hand: after changing a CI template, `doc-tools.sh` or a CI helper script, run `bash scripts/hooks/install.sh install --ci` and commit what it writes (tests.yml fails on drift) |
| `.gitattributes` | The git tier's one committed piece: the `docs/.doc-index.json` merge-driver block — installer output | Never by hand: `bash scripts/hooks/install.sh install --git` writes it (tests.yml's drift step fails without it, and names `install --git`) |
| `RELEASE-NOTES.md` | Version history | Every release |
| `README.md` | User-facing docs | Feature changes |

## Commands

- `/doc-superpowers init` — Generate docs from scratch
- `/doc-superpowers audit [scope]` — Full documentation health check
- `/doc-superpowers review-pr` — PR-scoped doc review
- `/doc-superpowers update [scope] [--report=<path>]` — Execute doc updates from an audit report (default: this session's audit, else `check-freshness`)
- `/doc-superpowers diagram [scope]` — Regenerate diagrams
- `/doc-superpowers sync` — Sync doc index with filesystem
- `/doc-superpowers hooks install [--git] [--claude] [--ci] [--all]` — Install workflow hooks
- `/doc-superpowers hooks status` — Show installed hooks
- `/doc-superpowers hooks uninstall` — Remove installed hooks
- `/doc-superpowers release [--from=<ref>]` — Draft release notes entry from git history (`--from` overrides the range start)
- `/doc-superpowers spec-generate --design-doc=<path>` — Generate formal specs from design doc
- `/doc-superpowers spec-inject --phase=plan|execute --specs=<paths> [--plan=<path>]` — Inject spec tasks into the plan (`--plan` required) or track drift after a chunk
- `/doc-superpowers spec-verify --mode=post-execute|review --specs=<paths> [--plan=<path>]` — Verify spec compliance (`post-execute` also takes `--design-doc=<path>`; `review` takes `--changed-files=<paths>`, with `--specs` optional)

`[scope]` is read by `audit`, `update` and `diagram` only (default `all`). The CI options of `hooks install` (with `--ci` or `--all`) are `--workflows=<csv|all|none>`, `--force`, `--base-branch NAME`, `--cron EXPR` and `--ci-strict[=true|false]`, recorded in `.claude/doc-superpowers/installed.json`; `hooks uninstall` takes `--workflows=<csv|all|none>` and `--transient`.

Each `--specs` path may carry an optional role suffix — `<path>:target`, `<path>:constraint` or `<path>:amends`. Unsuffixed paths stay valid and are role-inferred at execution time; inference never yields `:amends` (an amendment corrects what a spec *says* without building its surface: it writes no `Status`, and is verified as landed). Pass `--plan=<path>` to `spec-verify` so an `:amends` spec's landed-check can confirm the `AMENDED` block cites that plan; without it the check degrades to block-present and warns.

## Conventions

- **Versioning**: Semantic versioning (MAJOR.MINOR.PATCH). RELEASE-NOTES.md is the canonical source — `check-version` reads it, `bump-version` never writes it. Run `scripts/doc-tools.sh bump-version X.Y.Z` to update the 5 manifest files, then `check-version` to verify. This step is **mandatory** — never manually edit version strings in individual files
- **Skill structure**: Follows obra/superpowers SKILL.md conventions (YAML frontmatter with `name` + `description`)
- **Templates**: All doc templates live in `references/doc-spec.md`, not inline in SKILL.md
- **Diagrams**: Mermaid source in docs, PNGs committed for GitHub rendering
- **Testing**: Five shell suites gate changes — `test-doc-tools.sh` (1350 assertions), `test-hooks.sh` (1015), `test-spec-status-model.sh` (516), `test-doc-pr-release.sh` (453), `test-merge-driver.sh` (560), 3894 total (no XFAIL left: the harness's known-bug markers, reported on every run and turned into a FAIL the moment the bug is fixed, have all been resolved), all sharing the `test-helpers.sh` harness. These counts are kept **only here** — every other doc links to this section. Before a PR, run all five under both interpreters: `for B in /opt/homebrew/bin/bash /bin/bash; do "$B" --version | head -n 1; for s in doc-tools hooks spec-status-model doc-pr-release merge-driver; do BASH_BIN=$B $B scripts/test-$s.sh || echo "FAIL: $B $s"; done; done` — the first a bash 5.x (Homebrew's on macOS; Linux's own `bash`), the second macOS's 3.2 (bare `bash` may resolve to `/bin/bash`, testing one interpreter twice; the `--version` line shows which ran). The harness isolates every fixture from the contributor's git config (`GIT_CONFIG_GLOBAL=/dev/null`, private `HOME`), keeps all scratch files under one private root removed on EXIT/INT/TERM, and never runs with the checkout as cwd. All five run in CI via `.github/workflows/tests.yml` on push to `main` and on every PR targeting `main`, matrixed over `ubuntu-latest` (bash 5.x) and `macos-latest` (`/bin/bash` 3.2.57). The interpreter is passed explicitly at both levels: CI runs each suite under `$BASH_BIN`, and `test-helpers.sh`'s `bash_bin_shim()` wraps every script under test so it `exec`s under the same interpreter instead of re-resolving bash from its own `#!/usr/bin/env bash`. Without the shim the 3.2 leg silently tests whatever bash the runner image puts first on `PATH` — bash 3.2 is a real support target (it is what macOS ships, so it is what a consuming project's git hooks run under), and `test-doc-tools.sh` carries a static guard that fails on any bash-4-only construct in the shipped scripts. Locally, a missing YAML parser (PyYAML or ruby's psych) or `node` turns the cases that need it into a loud SKIP; CI sets `DOC_SP_REQUIRE_YAML_PARSER=1` and `DOC_SP_REQUIRE_NODE=1`, which make them FAILs. Test skill changes by running `/doc-superpowers init` on a sample project
- **Self-installed tiers (dogfood)**: this repo runs its own tiers. The CI tier is committed: `.github/workflows/doc-freshness-{pr,schedule}.yml` rendered with the choices recorded in `.claude/doc-superpowers/installed.json` (strict), and `.github/scripts/` vendored. The git tier's merge-driver attribute is in `.gitattributes`; its hooks and the Claude tier are per-clone / per-user (`bash scripts/hooks/install.sh install --git --claude`; the Claude tier's files are gitignored). After changing a CI template, `scripts/doc-tools.sh` or a CI helper script, run `bash scripts/hooks/install.sh install --ci` and commit what it writes: tests.yml's *Self-installed CI tier matches its templates* step fails on any drift
