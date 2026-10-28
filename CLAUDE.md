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
│   │                     #   (no ledger/ or adapters/: the ledger helper set ships only with docs/ledger/config.json)
│   └── workflows/
│       ├── doc-freshness-pr.yml       # The 2 default templates, rendered with the recorded choices
│       ├── doc-freshness-schedule.yml
│       └── tests.yml     # This repo only (not a template): every step is scripts/check-ci.sh — the seven suites (bash 5.x / 3.2 matrix), the doc-search pytest suite, self-install drift, check-version, the release tag (main)
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
├── search/               # doc-search: the opt-in MCP server over docs and code (uv project; inert without docs/search/config.json)
│   ├── pyproject.toml    # semble>=0.7,<0.8, mcp>=2.3,<3, pathspec; extras cloud (google-genai, google-cloud-firestore) and local-transformer (onnxruntime, flatbuffers, protobuf); dev pytest
│   ├── uv.lock           # Locked; run with --frozen (no torch; onnxruntime only in the local-transformer extra)
│   ├── src/doc_search/   # server.py (4 tools), cli.py (serve init index query status eval), searcher.py + fusion.py (legs, RRF),
│   │                     #   engines.py (semble index pairs), corpus.py, docindex.py, repo.py, tools.py, render.py, evaluate.py,
│   │                     #   transformer.py (the opt-in local docs embedder: registry, ONNX encoder), encode_cache.py (per-host vector cache, host lock),
│   │                     #   progress.py (transformer build progress and ETA), chunker.py, buildlock.py (cross-process build lock), cloud/ (read.py, write.py, vertex.py)
│   └── tests/            # pytest suite (no network: a test-built model, a fake transformer, fake Firestore/Vertex; DOC_SEARCH_LIVE=1 for live)
├── scripts/
│   ├── doc-superpowers   # The dispatcher (bash; every client runs "$ROOT/scripts/doc-superpowers"): help|-h|--help [topic], setup,
│   │                     #   version, and the hooks / tools / search pass-throughs; the ~/.local/bin shim runs it as the terminal command
│   ├── help/             # The help text, one plain-text file per topic (overview setup search hooks ci ledger claims release):
│   │                     #   one source for the terminal and the skill's `help` action (overview ≤ 24 lines, topics ≤ 50, ≤ 80 columns)
│   ├── setup/            # setup's engine (bash 3.2 + jq): setup.sh (flags, modes), catalog.json (the items), lib-model.sh (selection,
│   │                     #   base, --set, requires), lib-probe.sh (status --json, records, host checks, hints), lib-plan.sh (the steps,
│   │                     #   summary, review), lib-exec.sh (running them; records, exclude block, env hook, shim), lib-harness.sh (the
│   │                     #   per-harness doc-search entries), lib-prompt.sh (prompt UI), lib-tui.sh (TUI), search-config.json, shim.sh
│   ├── doc-tools.sh      # Bundled freshness tooling (build-index, check-freshness, update-index, add-entry, remove-entry, move-entry, set-code-refs, set-doc-type, upgrade-entries, deprecate-entry, status, audit-merges, bump-version, check-version, implementation-status, set-implementation, fragments, tools, claims, ledger)
│   ├── test-doc-tools.sh # Test suite for doc-tools.sh
│   ├── test-doc-pr-release.sh # Test suite for doc-pr-release helpers
│   ├── test-helpers.sh   # Shared test utilities
│   ├── test-hooks.sh     # Test suite for hooks installer and hook scripts
│   ├── test-spec-status-model.sh # Test suite for the canonical Spec Status Model + call sites
│   ├── test-spec-claims.sh # Test suite for the `claims` verb group (spec claims)
│   ├── test-ledger.sh    # Test suite for the `ledger` verb group (work ledger), its adapters and hook modes
│   ├── bench-ledger.sh   # Work-ledger performance check on a synthetic corpus (`bench-ledger.sh 3000`; not in CI)
│   ├── check-ci.sh       # Maintainer: runs locally exactly what tests.yml runs (tests.yml calls it); --fast, --bash, a check name
│   ├── check-self-install.sh # Maintainer: the self-installed CI tier + .gitattributes block match the installer (check-ci.sh self-install)
│   ├── install-maintainer-hooks.sh # Maintainer: opt-in pre-push hook running check-ci.sh --fast (not the hooks installer's)
│   ├── leak-scan.sh      # Leak scan over tracked files (machine paths, emails, tokens; records allowlisted), run by test-spec-status-model.sh
│   ├── ledger/           # The work ledger, sourced by doc-tools.sh with docs/ledger/config.json (and for ledger init, and claims V5 on a ledger host): lib.sh + 13 modules
│   │                     #   (parse glob validate index keys query views adapters relations upkeep inflight init hooks .sh),
│   │                     #   config.jq defs.jq render-md.jq render-html.jq, frontmatter.awk fm-write.awk
│   ├── adapters/         # Reference ledger adapters, `doc-superpowers:<name>`: ledger-pr-gh.sh, ledger-items-gh.sh (GitHub, via gh)
│   ├── search/
│   │   └── launch.sh     # doc-search's launcher (POSIX sh); install --search copies it to .claude/doc-superpowers/search-mcp.sh
│   ├── merge-doc-index.sh  # Custom git merge driver for .doc-index.json
│   ├── test-merge-driver.sh # Test suite for merge driver
│   └── hooks/
│       ├── install.sh        # Hook installer engine
│       ├── state.sh          # Install-state tracking — .claude/doc-superpowers/installed.json
│       ├── git/              # Git hook scripts (the --git tier's 5) + ledger-{pre-commit,pre-push,post-commit} (--ledger blocks)
│       ├── claude/           # Claude Code hook scripts (the --claude tier's 3) + ledger-{session-notices,state-watch}.sh (--ledger-claude),
│       │                     #   and hook-lib.sh, which the 3 tier scripts and ledger-session-notices.sh source
│       │                     #   (its "shared hook settings" region — budget watchdog, hooks.conf reader, advice — is copied byte for byte into each git hook)
│       └── ci/               # GitHub Actions workflow templates
│           ├── doc-freshness-pr.yml      # PR freshness check (shell-based; fails closed)
│           ├── doc-freshness-schedule.yml # Weekly audit cron (shell-based; fails closed)
│           ├── doc-audit-update.yml      # AI audit+update on feature branches
│           ├── doc-review-pr.yml         # AI PR doc review + @claude interactive
│           ├── doc-release.yml           # AI release notes drafting (consumer)
│           ├── doc-spec-verify.yml       # AI spec compliance on PRs
│           ├── doc-pr-full-cycle.yml     # AI PR full cycle: review, update, diagram, sync
│           ├── doc-pr-release.yml        # AI per-PR release-notes fragment producer
│           ├── doc-ledger-publish.yml    # Work-ledger views publisher (every 30 min; vendors the ledger helper set on a ledger host)
│           ├── doc-pr-release/           # Helper scripts + fragment-format spec
│           │   ├── extract-context.sh    # Build context.json for the agent
│           │   ├── update-pr-body.sh     # Idempotent PR-body managed-section editor
│           │   ├── commit-and-push.sh    # Seal + commit the fragment; push only while the branch is at the checkout
│           │   ├── fragment-lib.sh       # Sourced fragment line rules (markers, hash line, sha256) the helpers share
│           │   └── RELEASE-NOTES.next.README.md # Fragment-format spec (producer/consumer contract)
│           └── doc-superpowers-steps/    # run: step bodies of every template (freshness-check, resolve-auth, prepare-agent, commit-changes, pr-guard, sentinel-check, write-context, verify-fragment, precheck, claims-check, ledger-publish)
├── references/
│   ├── doc-spec.md       # Templates for generated docs (C4, ERD, workflows, agentic, specs, ADRs)
│   ├── agent-prompt-template.md   # Review agent prompt template + scope focus areas
│   ├── output-templates.md        # Audit report format (+ its Update Tasks) + spec compliance report
│   ├── release.md                 # `release` action steps 1–12 (REQUIRED pointer from SKILL.md)
│   ├── setup.md                   # `setup` and `help` actions: defaults, flow, items, flags + exit codes, records, env hook, harness entries, terminal command (REQUIRED pointer from SKILL.md)
│   ├── hooks.md                   # `hooks` action: tiers, consent table, CI templates (REQUIRED pointer from SKILL.md)
│   ├── spec-lifecycle-actions.md  # Detailed procedures for spec-generate/inject/verify
│   ├── spec-lifecycle-protocol.md  # Wrapper author integration guide; the claims direction protocol
│   ├── spec-claims.md             # Spec claims (opt-in): claim schema, checks V1–V12, adapters, gates, direction policy keys (config `policy`)
│   ├── ledger.md                  # Work ledger (opt-in): config, verbs + exit codes, keys, adapters, in-flight, hooks, init (REQUIRED pointer from SKILL.md)
│   ├── ledger-index.schema.json   # The work-ledger index shape (ledger-index/1), read by scripts/ledger/index.sh
│   ├── search.md                  # doc-search (opt-in): turning it on, config, CLI + exit codes, tools, cloud leg, other clients (REQUIRED pointer from SKILL.md)
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
| `scripts/doc-superpowers` | The dispatcher: `help [topic]` (prints `scripts/help/<topic>.txt`), `setup` (`scripts/setup/setup.sh`), `version`, and the `hooks` / `tools` / `search` pass-throughs to `install.sh`, `doc-tools.sh` and doc-search's launcher; every sub-script under `"$BASH"`; `$ROOT` its directory's parent, symlinks of the file resolved | Adding a command (with `scripts/help/overview.txt`; tests in `test-spec-status-model.sh`) |
| `scripts/help/*.txt` | The help text: the one source for `doc-superpowers help` and the skill's `help` action, which shows it verbatim. Limits pinned by `test-spec-status-model.sh`: overview ≤ 24 lines, each topic ≤ 50 with its Default / Terminal / Skill / Committed / Local / Undo / Reference lines, every line ≤ 80 columns | Changing what a feature does, its defaults or its commands |
| `scripts/setup/` | `setup`'s engine (`references/setup.md`): the catalog (`catalog.json`: ids, kinds, defaults, scopes, details, writes, undo), the model, the read-only probe (installer status, the records, host checks, hints), the plan (the selection against what is installed: steps, summary, review), the executor (installer steps; the files setup owns: switches, harness entries, the env hook block, its exclude block, the `~/.local/bin` shim, the team record `.setup` in `installed.json` and `installed.local.json`), the prompt UI and the TUI. bash 3.2 + jq ≥ 1.6, no other dependency | Changing an item, a default, a flag, a record or a UI (tests in `test-hooks.sh`, the flags and ids pinned against `references/setup.md` by `test-spec-status-model.sh`) |
| `references/setup.md` | `setup` and `help` reference — ten sections (What setup does, The defaults, The flow, Items, Flags and exit codes, The records, The env hook, Harness entries, The terminal command, Help); the flags and catalog ids are read from the code by `test-spec-status-model.sh` | Changing anything `setup` or `help` users or agents act on |
| `scripts/doc-tools.sh` | Bundled freshness tooling — 20 subcommands (`fragments list\|validate\|merge`, `tools install\|uninstall\|status\|version`, `claims validate\|run\|promote\|render\|gate\|attest\|rulings` and `ledger show\|ls\|find\|related\|suggest\|sweep\|recheck\|upkeep\|inflight\|notices\|state-watch\|new\|assign\|link\|note\|view\|validate\|publish\|finalize\|init` take sub-verbs; `--help` lists them all) for index management (the batch forms included: `move-entry`, `set-code-refs` and `set-doc-type --stdin`, and `upgrade-entries`, which fills pre-v3 entries' `code_oids` without a baseline reset), version sync, ADR/SPEC implementation status, release-notes fragments, CLI vendoring, executable spec claims and the work ledger (its dispatch, inert check and verdict helpers; the verbs themselves are in `scripts/ledger/`) | Changing staleness detection, index schema, version sync, implementation status, fragment merge, vendoring, spec claims, or the ledger's dispatch and help |
| `scripts/test-doc-tools.sh` | Test suite for doc-tools.sh, with the static gates on the shipped scripts (no bash-4-only construct, no jq-1.7-only form, shellcheck at warning severity) | Adding tests for new doc-tools features |
| `scripts/test-hooks.sh` | Test suite for hooks installer and hook scripts, the work ledger's two sets and their legs included, and the maintainer tooling (`check-ci.sh` against stub suites, `install-maintainer-hooks.sh` against real pushes) | Adding tests for new hooks or installer features |
| `scripts/test-spec-claims.sh` | Test suite for the `claims` verb group: one fixture per check (V1–V12), the run / promote / gate / attest / rulings flows and the inert (no `docs/spec-claims/`) contract, driven through `/bin/sh` stub adapters in throwaway fixture repos | Changing any `claims` verb, check, adapter contract or gate record |
| `scripts/ledger/` | The work ledger (`doc-tools.sh ledger`, opt-in with `docs/ledger/config.json`): `lib.sh` (config merge, verdict helpers) sources the modules — parse cache, globs, validate, index build and caches, keys (counter-ref CAS, provisional, finalize), queries, views and publish, adapters and the remote cache, relations, upkeep (merge-time proposals), in-flight and notices, init, hook modes — over the `*.jq` / `*.awk` programs. bash 3.2 + jq ≥ 1.6, no other dependency | Changing any ledger verb, the index, keys, adapters, in-flight or init (tests in `test-ledger.sh`; budgets with `bench-ledger.sh 3000`, recorded in the commit body) |
| `scripts/adapters/` | Reference ledger adapters (`ledger-pr-gh.sh`: `pr list`; `ledger-items-gh.sh`: hosted items as GitHub issues), resolved as `doc-superpowers:<name>`; shipped in the ledger helper set | Changing an adapter contract (`references/ledger.md` → *Adapters*) |
| `scripts/test-ledger.sh` | Test suite for the `ledger` verb group: every verb, the inert contract, keys racing against a local bare remote, in-flight fixtures across worktrees and fake hosts, adapters against a fake `gh`, the two hook modes, and a 300-item smoke of the budgets (×3) | Adding tests for ledger features |
| `scripts/bench-ledger.sh` | The ledger's full performance check on a synthetic corpus (`bench-ledger.sh 3000`) against the design budgets; not run in CI | Changing index, parse or query cost |
| `references/ledger.md` | Work-ledger reference: config keys and defaults, registry, item fields, legacy and finalized maps, verbs and exit codes, keys, adapter contracts, in-flight privacy, merge-time upkeep, views, validation, hooks, `ledger init`, building on the ledger (the filing and declare procedures), V5 | Changing a ledger verb, config key, adapter contract or hook (with the help text) |
| `search/` | doc-search, the opt-in MCP server (`doc-search`: tools `search`, `fetch`, `related`, `status`; CLI `serve init index query status eval`) over two semble indexes per worktree, docs and code, fused with the doc-index's cross-links, plus the optional cloud docs leg (Vertex + Firestore, its guarded writer `index --cloud`) and the opt-in local transformer docs model (`docs.model: "transformer:gte-modernbert-base"`: the `local-transformer` extra, a per-host encode cache and encoder lock, a static docs index serving while the first build runs). A uv package: Python ≥ 3.11 (`.python-version` 3.12), runtime `semble`, `mcp` (SDK v2), `pathspec`; inert without `docs/search/config.json`; the rest of doc-superpowers never needs Python | Changing the server, a tool, the CLI, the config, the cloud leg or the transformer (with `references/search.md`; tests `bash scripts/check-ci.sh search`) |
| `scripts/search/launch.sh` | doc-search's POSIX-sh launcher: finds doc-superpowers at run time (`$DOC_SUPERPOWERS_ROOT`, this checkout, the newest plugin-cache version), then `uv run --project <root>/search --frozen --no-dev [--extra cloud] [--extra local-transformer] doc-search` (the second extra when `docs.model` starts `transformer:`; without `jq`, `--all-extras --no-extra local-transformer`, or `--all-extras` when `grep` finds a `transformer:` model); for `serve`, exports the parent process's cwd as `DOC_SEARCH_CLIENT_CWD` (the server's default worktree); vendored byte for byte to `.claude/doc-superpowers/search-mcp.sh` by `install --search` | Changing how the server is found or started (installed copies then read `outdated`) |
| `references/search.md` | doc-search's reference — ten sections (Turning it on, Modes, Configuration, CLI, Tools, Cloud leg, Other clients, Hardware and performance, Privacy, Troubleshooting), pinned by `test-spec-status-model.sh` with the inert line and the CLI verbs read from the code | Changing anything doc-search's users or agents act on |
| `references/ledger-index.schema.json` | The ledger index's JSON Schema (`ledger-index/1`; derived, never committed) | Changing an index field (with `index.sh`) |
| `scripts/test-spec-status-model.sh` | Test suite pinning the canonical Spec Status Model wording and its call sites, and the skill prompt ↔ tool contract: tool resolution, index-write routing, review-pr base, safety rules, templates, the prompts' `--allowedTools`, and `evals/evals.json` (fields, regexes, fixtures run); also the cross-client packaging (manifests, INSTALL pins) and the OpenCode plugin, run under `node` (a loud SKIP without node locally; `DOC_SP_REQUIRE_NODE=1`, set by tests.yml, makes it a FAIL), with a 12,000-char ceiling on the text its transform emits; the `SKILL.md` frontmatter (description ≤ 1,536 chars, no block scalar) and every `references/` / `scripts/` path it names; the help text and the dispatcher's routes; the `setup` and `help` actions and `references/setup.md` (its sections, every flag `setup.sh` parses, every catalog id); and the leak scan (`leak-scan.sh`) on a fixture and on this checkout | Changing spec status transition rules, roles, or vocabulary; changing what SKILL.md / references tell an agent to run; adding an eval; changing a manifest or the OpenCode plugin; growing `references/tool-mappings.md` past the ceiling |
| `scripts/test-doc-pr-release.sh` | Test suite for the CI workflow helpers (extract-context, update-pr-body, commit-and-push, the `run:` step scripts in doc-superpowers-steps/) + YAML placeholder substitution, template structure/wiring, and the installed templates' fail-closed / least-privilege properties | Adding tests for fragment-producer, CI-step or template features |
| `scripts/hooks/ci/doc-pr-release.yml` | AI per-PR release-notes fragment producer — drafts `RELEASE-NOTES.next/PR-<N>.md` on every push | Changing the producer workflow, prompt, or post-Claude verification |
| `scripts/hooks/ci/doc-pr-release/*.sh`, `scripts/hooks/ci/doc-superpowers-steps/*.sh` | Producer helpers (extract-context, update-pr-body, commit-and-push, and `fragment-lib.sh`, the fragment line rules they source; shipped to `.github/scripts/doc-pr-release/` while `doc-pr-release` is installed) and every template's `run:` step bodies (each shipped to `.github/scripts/doc-superpowers-steps/` while an installed workflow runs it, or runs a step script that runs it; `prepare-agent.sh` has no marketplace-URL default: the AI templates' env carries the installer-rendered `DOC_SUPERPOWERS_MARKETPLACE_URL`) | Changing fragment context schema, PR-body editing, push logic, or any workflow step body |
| `scripts/hooks/ci/doc-pr-release/RELEASE-NOTES.next.README.md` | Fragment-format spec — producer/consumer contract for `RELEASE-NOTES.next/PR-*.md` | Changing fragment markers, hash protocol, or consumer rules |
| `scripts/merge-doc-index.sh` | Custom git merge driver for .doc-index.json — base-aware per-key three-way merge during merge/rebase/revert; conflict markers + exit 1 when it cannot decide | Changing merge conflict resolution logic |
| `scripts/test-merge-driver.sh` | Test suite for merge-doc-index.sh | Adding tests for merge driver features |
| `scripts/hooks/install.sh` | Hook installer — install/uninstall/status for all tiers (including merge driver registration), and the work ledger's two opt-in sets (`--ledger`: marked blocks in pre-commit, pre-push, post-commit; `--ledger-claude`: SessionStart and PostToolUse `Write\|Edit\|MultiEdit`; never in `--all`, refused without `docs/ledger/config.json`, never recorded in `installed.json`; `uninstall --claude` keeps `hook-lib.sh` while a ledger script needs it), and doc-search's opt-in `--search` set (the launcher `.claude/doc-superpowers/search-mcp.sh` and the `.mcp.json` `doc-search` entry, both committed; never in `--all`, refused without `docs/search/config.json`, not recorded in `installed.json`; `status --json --search` → `.tiers.search`); ships the ledger helper set with `doc-ledger-publish` and every claims-running workflow; `--merge-driver-only` (the git tier's driver registration and `.gitattributes` block alone), `status --json` (schema `doc-superpowers-hooks-status/1`) and `print-merge-driver` | Adding hook tiers or sets, changing installer logic or the JSON status shape (with `references/hooks.md`) |
| `scripts/hooks/state.sh` | Install-state tracking shared by install.sh — reads/writes `.claude/doc-superpowers/installed.json` (committed, so install choices persist across contributors); keeps setup's top-level `setup` object (the team's choice of tiers), which it never reads | Changing state schema, the known-workflow list, or state-respect rules |
| `references/doc-spec.md` | Doc templates, Mermaid syntax, naming conventions, schema reference | Adding doc types, changing templates |
| `references/agent-prompt-template.md` | Review agent prompt template + scope-specific focus areas | Changing agent review instructions or adding project signals |
| `references/output-templates.md` | Audit report format (with its Update Tasks, the handoff to `update`) + spec compliance report | Changing report structure |
| `references/spec-lifecycle-actions.md` | Detailed procedures for spec-generate (incl. Step 5b stale content scan), spec-inject, spec-verify; defines the canonical **Spec Status Model** (ladder, exempt class, rules R1-R5 — R5 for claims-enabled projects only — evaluation order) | Changing spec action steps or adding new spec actions; changing status transition rules, roles, or vocabulary |
| `references/spec-claims.md` | Spec claims (opt-in, enabled by `docs/spec-claims/`): sidecar and claim schema, `config.json`, checks V1–V12, exit codes, adapter contracts, gates and records, the direction policy keys (config `policy`), reference pytest/jest helpers | Changing a `claims` verb, check, adapter contract or the claims policy |
| `references/spec-lifecycle-protocol.md` | Wrapper author integration guide — input/output contracts, integration patterns; defines the claims **Direction protocol** (directions, rulings, policy defaults) | Adding integration patterns, changing action contracts or the direction protocol |
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
| `.github/workflows/tests.yml` | This repo's CI: the seven suites under bash 5.x (ubuntu) and `/bin/bash` 3.2 (macOS), the doc-search pytest suite on both legs (after `astral-sh/setup-uv`, pinned by sha), the self-install drift check, `check-version`, and on pushes to `main` the release tag on origin (`check-version --tag`) — every step a `scripts/check-ci.sh <check>` call, so it carries no check body of its own | Adding a suite, a CI requirement, or a self-installed tier (add the check to `check-ci.sh` first) |
| `scripts/check-ci.sh` | Maintainer: runs locally exactly what tests.yml runs — the toolchain check, the seven suites under every bash it detects (5.x and `/bin/bash` 3.2), `search` (the doc-search pytest suite, once: `uv run --project search --frozen --all-extras pytest -q`), `self-install`, `check-version`, `tag` (`--warn` locally), and `claude plugin validate .` when the claude CLI is on PATH (not in CI: no authenticated CLI there); `DOC_SP_REQUIRE_{YAML_PARSER,NODE,SHELLCHECK,UV}` default to 1. `--fast` (no `search`): one interpreter (3.2 when present), the quick suites, self-install, check-version. `--bash PATH` (repeatable), a check name to run just that one, `--verbose` to stream | Adding a CI check (then a tests.yml step naming it) |
| `scripts/check-self-install.sh` | Maintainer: the self-installed CI tier is what `install --ci` writes today, and `.gitattributes` routes the index to the merge driver (was tests.yml's inline drift step) | Changing what the installer vendors or renders |
| `scripts/install-maintainer-hooks.sh` | Maintainer: `install \| uninstall \| status` of an opt-in pre-push block running `check-ci.sh --fast` (stdin untouched; after a shell hook's `#!`; refuses the git tier's whole-file hook — uninstall `--git`, install this, re-install `--git`); `DOC_SP_SKIP_CHECK_CI=1` skips it | Changing the maintainer hook |
| `scripts/leak-scan.sh` | Leak scan over `git ls-files`: home-dir paths, `/Volumes/…`, emails (example / test / noreply domains allowed), token-shaped strings; dated `docs/plans/` and `docs/issues/` records, `docs/archive/`, `docs/superpowers/` are allowlisted for paths only; a `leak-scan:allow` marker skips a line. Run by `test-spec-status-model.sh` | Changing a leak class or the allowlist |
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
- `/doc-superpowers setup` — Set this repository up in one pass: fixed safe defaults (the merge driver, the 5 report-only git hooks, the 3 Claude hooks; no CI, no download), every write shown first, the team's choice recorded in `installed.json`'s `setup` object (`references/setup.md`). The skill drives `setup --dry-run`, `--list`, `--dry-run --set …`, then `--yes --set … [--for-team] [--build] [--link-bin]`; in a terminal, `doc-superpowers setup` is the full-screen version, and `setup --apply` reproduces the recorded setup in a teammate's clone
- `/doc-superpowers help [topic]` — One-screen help, or one topic (`setup search hooks ci ledger claims release`): `scripts/doc-superpowers help [topic]`'s output, verbatim
- `/doc-superpowers hooks install [--git [--merge-driver-only]] [--claude] [--ci] [--all] [--ledger] [--ledger-claude] [--search]` — Install workflow hooks (`--ledger` / `--ledger-claude`: the work ledger's opt-in sets, never in `--all`; `--search`: doc-search's MCP server — the launcher and the `.mcp.json` entry — opt-in the same way, needs `docs/search/config.json`; `--merge-driver-only`: the git tier's merge driver alone, no hook)
- `/doc-superpowers hooks status [--git [--merge-driver-only]] [--claude] [--ci] [--all] [--ledger] [--ledger-claude] [--search] [--json]` — Show installed hooks (`--json`: the git, Claude and CI tiers as one JSON object, plus `.tiers.search` when `--search` is named, `references/hooks.md` → *Machine-readable status*)
- `/doc-superpowers hooks uninstall [--git [--merge-driver-only]] [--claude] [--ci] [--all] [--ledger] [--ledger-claude] [--search]` — Remove installed hooks
- `/doc-superpowers release [--from=<ref>]` — Draft release notes entry from git history (`--from` overrides the range start)
- `/doc-superpowers spec-generate --design-doc=<path>` — Generate formal specs from design doc
- `/doc-superpowers spec-inject --phase=plan|execute --specs=<paths> [--plan=<path>]` — Inject spec tasks into the plan (`--plan` required) or track drift after a chunk
- `/doc-superpowers spec-verify --mode=post-execute|review --specs=<paths> [--plan=<path>]` — Verify spec compliance (`post-execute` also takes `--design-doc=<path>`; `review` takes `--changed-files=<paths>`, with `--specs` optional)
- `/doc-superpowers ledger <verb> [args]` — The work ledger (`scripts/doc-tools.sh ledger <verb>`; inert without `docs/ledger/config.json`, except `init`; `references/ledger.md`). `ledger upkeep --range <base>...HEAD` (or `--pr <n>`) proposes the `changes` / `consumes` a range's items are missing, never writing them; `review-pr` runs it read-only on a ledger host
- `/doc-superpowers ledger file [<title>]` — File a work item: duplicates first, one question round, `ledger new --create`, then the confirmed relations through `ledger link` (a skill flow, not a verb; `references/ledger.md` → *Filing an item*)
- `/doc-superpowers ledger declare [--range <a>..<b> | --range <a>...<b> | --pr <n>] [--items <item>…]` — Confirm and link what a change's items are missing: `ledger upkeep` over the range (default `"$BASE...HEAD"`), one question round, then one `ledger link` per item with what was confirmed; attended only, never in a CI run (a skill flow, not a verb; `references/ledger.md` → *Declaring after a change*; `review-pr` step 9 names it)
- `scripts/doc-superpowers <help [topic]|setup [flags]|version|hooks …|tools …|search …>` — the same from a terminal (`doc-superpowers …` once `setup --link-bin` wrote `~/.local/bin/doc-superpowers`)
- `sh .claude/doc-superpowers/search-mcp.sh <serve|init|index|query|status|eval>` — doc-search's CLI in a project that installed `--search` (before that: `uv run --project <plugin>/search --frozen doc-search init`); inert without `docs/search/config.json`, except `init`; `references/search.md`

`[scope]` is read by `audit`, `update` and `diagram` only (default `all`). The CI options of `hooks install` (with `--ci` or `--all`) are `--workflows=<csv|all|none>`, `--force`, `--base-branch NAME`, `--cron EXPR`, `--ci-strict[=true|false]` and `--marketplace-url URL` (where the AI workflows fetch the plugin: default the plugin's own repository, recorded only when given), recorded in `.claude/doc-superpowers/installed.json`; `hooks uninstall` takes `--workflows=<csv|all|none>` and `--transient`.

Each `--specs` path may carry an optional role suffix — `<path>:target`, `<path>:constraint` or `<path>:amends`. Unsuffixed paths stay valid and are role-inferred at execution time; inference never yields `:amends` (an amendment corrects what a spec *says* without building its surface: it writes no `Status`, and is verified as landed). Pass `--plan=<path>` to `spec-verify` so an `:amends` spec's landed-check can confirm the `AMENDED` block cites that plan; without it the check degrades to block-present and warns.

## Conventions

- **Versioning**: Semantic versioning (MAJOR.MINOR.PATCH). RELEASE-NOTES.md is the canonical source — `check-version` reads it, `bump-version` never writes it. Run `scripts/doc-tools.sh bump-version X.Y.Z` to update the 5 manifest files, then `check-version` to verify. This step is **mandatory** — never manually edit version strings in individual files
- **Skill structure**: Follows obra/superpowers SKILL.md conventions (YAML frontmatter with `name` + `description`)
- **Templates**: All doc templates live in `references/doc-spec.md`, not inline in SKILL.md
- **Diagrams**: Mermaid source in docs, PNGs committed for GitHub rendering
- **Testing**: Seven shell suites gate changes — `test-doc-tools.sh` (1579 assertions), `test-hooks.sh` (3698), `test-spec-status-model.sh` (1043), `test-doc-pr-release.sh` (630), `test-merge-driver.sh` (844), `test-spec-claims.sh` (3269), `test-ledger.sh` (3841), 14904 total (no XFAIL left: the harness's known-bug markers, reported on every run and turned into a FAIL the moment the bug is fixed, have all been resolved), all sharing the `test-helpers.sh` harness — and beside them doc-search's pytest suite (`search/tests/`, 769 tests, the 2 live tests (semble's default model, and the gte-modernbert docs model) skipped unless `DOC_SEARCH_LIVE=1`; the `search` check, `uv run --project search --frozen --all-extras pytest -q`, run once whatever the interpreters, never touching the network). These counts are kept **only here** — every other doc links to this section. Before a PR, run what CI runs: `bash scripts/check-ci.sh` — all seven under both interpreters it detects (a bash 5.x: Homebrew's `/opt/homebrew/bin/bash` or `/usr/local/bin/bash` on macOS, Linux's own `bash`; and macOS's `/bin/bash` 3.2 — a host without one says so), then the doc-search pytest suite (`search`; it needs `uv`), the self-install drift check, `check-version`, the release tag (`--warn` locally) and `claude plugin validate .`; it ends with a summary line per suite per interpreter. `--bash PATH` picks the interpreters, a check name runs one (`bash scripts/check-ci.sh --bash /bin/bash ledger`), `--fast` runs the quick part, and `bash scripts/install-maintainer-hooks.sh` installs an opt-in pre-push hook that runs `--fast`. The harness isolates every fixture from the contributor's git config (`GIT_CONFIG_GLOBAL=/dev/null`, private `HOME`), keeps all scratch files under one private root removed on EXIT/INT/TERM, and never runs with the checkout as cwd. All seven run in CI via `.github/workflows/tests.yml` on push to `main` and on every PR targeting `main`, matrixed over `ubuntu-latest` (bash 5.x) and `macos-latest` (`/bin/bash` 3.2.57), and the pytest suite runs on both legs after `astral-sh/setup-uv` (pinned by sha). The interpreter is passed explicitly at both levels: CI runs each suite under `$BASH_BIN`, and `test-helpers.sh`'s `bash_bin_shim()` wraps every script under test so it `exec`s under the same interpreter instead of re-resolving bash from its own `#!/usr/bin/env bash`. Without the shim the 3.2 leg silently tests whatever bash the runner image puts first on `PATH` — bash 3.2 is a real support target (it is what macOS ships, so it is what a consuming project's git hooks run under), and `test-doc-tools.sh` carries a static guard that fails on any bash-4-only construct in the shipped scripts, and another that fails on any jq-1.7-only form in their jq programs (the jq floor is 1.6). Run directly, a suite turns a missing YAML parser (PyYAML or ruby's psych), `node` or `shellcheck` into a loud SKIP for the cases that need it; CI and `check-ci.sh` set `DOC_SP_REQUIRE_YAML_PARSER=1`, `DOC_SP_REQUIRE_NODE=1` and `DOC_SP_REQUIRE_SHELLCHECK=1`, which make them FAILs (export one as 0 to accept the SKIP in `check-ci.sh`); `DOC_SP_REQUIRE_UV=1` (the default) makes a missing `uv` fail the `search` check the same way. The suites also hold four static gates: shellcheck at warning severity over the shipped and maintainer scripts (`test-doc-tools.sh`; a finding is fixed or disabled on its own line with a reason), the leak scan over tracked files (`scripts/leak-scan.sh`), the `SKILL.md` frontmatter (description ≤ 1,536 chars, no block scalar) and the paths it names, and the OpenCode plugin's emitted always-on text ≤ 12,000 chars (the last three in `test-spec-status-model.sh`). Test skill changes by running `/doc-superpowers init` on a sample project
- **Self-installed tiers (dogfood)**: this repo runs its own tiers. The CI tier is committed: `.github/workflows/doc-freshness-{pr,schedule}.yml` rendered with the choices recorded in `.claude/doc-superpowers/installed.json` (strict), and `.github/scripts/` vendored. The git tier's merge-driver attribute is in `.gitattributes`; its hooks and the Claude tier are per-clone / per-user (`bash scripts/hooks/install.sh install --git --claude`; the Claude tier's files are gitignored). After changing a CI template, `scripts/doc-tools.sh` or a CI helper script, run `bash scripts/hooks/install.sh install --ci` and commit what it writes: tests.yml's *Self-installed CI tier matches its templates* step fails on any drift
