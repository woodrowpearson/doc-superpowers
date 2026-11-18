# Local diagram rendering — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan
> task-by-task, test first (superpowers:test-driven-development). Steps use checkbox (`- [ ]`) syntax.

**Goal:** `doc-tools.sh diagram list|render|install-browser`, which renders every Mermaid source
block to its PNG in local headless Chrome, with a renderer this plugin pins. The design is
`docs/superpowers/specs/2026-11-17-local-diagram-rendering-design.md`; its requirements (R1–R9) bind every task.

**Architecture:** The bash side (`cmd_diagram` in `scripts/doc-tools.sh`) finds the blocks with awk,
installs the pinned packages into a cache once per lockfile, finds a browser, and hands the renderer
a JSON job file. The Node side (`scripts/diagram/render.mjs`) opens one browser, one page per job,
aborts every request that is not `file:`, `data:` or `about:`, renders with Mermaid, and screenshots
the SVG into a temporary file. The bash side moves each temporary file onto its PNG only when that
job succeeded. `scripts/diagram/browser.mjs` finds or installs the pinned `chrome-headless-shell`.

**Tech stack:** bash ≥ 3.2, jq ≥ 1.6, Node ≥ 18, `mermaid` 11.17.2, `@mermaid-js/layout-elk` 0.2.3,
`puppeteer-core` 24.43.1 (with `@puppeteer/browsers` 2.13.2).

## Global constraints

- Exit codes for every `diagram` verb: 0 rendered or listed, 1 a diagram failed, 2 the renderer
  could not run, 3 usage.
- The cache: `${XDG_CACHE_HOME:-$HOME/.cache}/doc-superpowers/diagram/<sha256 of package-lock.json>`,
  installed with `npm ci --ignore-scripts`; browsers under `…/diagram/browsers`.
- No diagram source reaches a network. Installing packages reaches the npm registry only.
- Never commit `node_modules`. The leak scan stays clean.
- The tests that render for real run when Node 18+, a browser and the registry are present, and
  print a SKIP line with the reason otherwise.
- After a change to `scripts/doc-tools.sh`, run `bash scripts/hooks/install.sh install --ci` and
  commit the vendored copy with it (`check-self-install.sh`).

---

### Task 1: Pin the renderer's packages

**Files:**
- Create: `scripts/diagram/package.json`, `scripts/diagram/package-lock.json`
- Modify: `.gitignore` (already ignores `node_modules/` everywhere; check), `.github/dependabot.yml`
- Test: `scripts/test-doc-tools.sh` (`test_diagram_packages_are_pinned`)

- [ ] Write the test: package.json and the lockfile pin the three versions exactly, the lock's
      `@puppeteer/browsers` is 2.13.2, `engines.node` is `>=18`, and git tracks no `node_modules`.
- [ ] Run it; it fails (no `scripts/diagram/`).
- [ ] Write package.json; generate the lock with `npm install --ignore-scripts --package-lock-only`.
- [ ] Run it; it passes. Run `scripts/leak-scan.sh`.
- [ ] Commit: `feat(diagram): pin the renderer's packages`.

### Task 2: `diagram list`

**Files:**
- Modify: `scripts/doc-tools.sh` (verb rows `diagram list|render|install-browser`, `_main`'s usage
  exit 3 for `diagram`, `cmd_diagram_list`, `_dg_blocks`)
- Test: `scripts/test-doc-tools.sh` (`test_diagram_list_*`)

- [ ] Write the tests. Default discovery is under `docs/`; a block inside another fence is not one.
      Named docs, the line and the PNG from the image link above come next.
- [ ] Then the ELK flag (front matter, init directive), a block with no image link (`png: null`),
      and usage errors (exit 3).
- [ ] Run them; they fail (unknown subcommand).
- [ ] Implement; run them; they pass. Re-vendor; run `check-self-install.sh`.
- [ ] Commit: `feat(diagram): diagram list finds every Mermaid source block and its PNG`.

### Task 3: `diagram render` and `install-browser`, bash side

**Files:**
- Modify: `scripts/doc-tools.sh` (`cmd_diagram_render`, `cmd_diagram_install_browser`,
  `_dg_node`, `_dg_install`, `_dg_browser`)
- Test: `scripts/test-doc-tools.sh` (`test_diagram_render_*`, with stub `node` and `npm` on `PATH`)

- [ ] Write the tests. No Node exits 2. The install runs once per lockfile, into the cache path,
      with `ci --ignore-scripts`; a failed one exits 2 and leaves no cache directory.
- [ ] The browser order: `DOC_SUPERPOWERS_CHROME`, system paths, the cache. None exits 2 and names
      `install-browser`.
- [ ] A failed job exits 1 and keeps the old PNG. A renderer that cannot run exits 2. Success moves
      the new PNG in. No blocks exits 0, and a vendored copy exits 2.
- [ ] Run them; they fail. Implement; they pass. Re-vendor.
- [ ] Commit: `feat(diagram): diagram render and install-browser, with the cache and the browser search`.

### Task 4: The Node renderer

**Files:**
- Create: `scripts/diagram/render.mjs`, `scripts/diagram/browser.mjs`
- Test: `scripts/test-doc-tools.sh` (`test_diagram_render_for_real`)

- [ ] Write the test. A default and an ELK flowchart render on white, at device scale 2, at most
      1248 CSS pixels wide.
- [ ] The ELK result says ELK was registered, and differs from the same graph without it.
- [ ] A node whose image is an outside URL fails with exit 1, names the URL and keeps the old PNG.
- [ ] Run it; it fails (no renderer). Implement; it passes against system Chrome.
- [ ] Commit: `feat(diagram): the pinned Node renderer, local-only, with ELK on request`.

### Task 5: The skill, the docs and the guard

**Files:**
- Modify: `skills/doc-superpowers/SKILL.md` (the `diagram` action, `init` step 10, error table),
  `references/tool-mappings.md`, `references/doc-spec.md`, `docs/workflows/doc-superpowers.md`,
  `docs/architecture/system-overview.md`, `docs/codebase-guide.md`, `docs/conventions.md`,
  `docs/guides/getting-started.md`, `README.md`, `CLAUDE.md`, `SECURITY.md` if it lists tools
- Test: `scripts/test-doc-tools.sh` (`test_diagram_no_renderer_service_is_named`),
  `scripts/test-spec-status-model.sh` (SKILL.md's diagram steps)

- [ ] Write the guard: tracked files outside `docs/plans/`, `docs/issues/`, `docs/archive/`,
      `docs/superpowers/` and `RELEASE-NOTES.md` name no `mermaid.ink`, `kroki` or the Mermaid MCP
      tool prefix. Its needles are built from parts, so the test file does not name them.
- [ ] Run it; it fails on SKILL.md, tool-mappings.md and doc-superpowers.md.
- [ ] Rewrite those, and every place that lists or counts doc-tools.sh subcommands (21 → 22).
- [ ] Run it; it passes. Run the writing lint on the changed prose.
- [ ] Commit: `docs: render diagrams with doc-tools.sh diagram everywhere the skill and docs say how`.

### Task 6: CI and counts

**Files:**
- Modify: `.github/dependabot.yml`, `CLAUDE.md` (suite counts)

- [ ] Add `scripts/diagram` as an npm entry in dependabot. CI needs no new step: GitHub's runners
      have Node and Chrome, so the real-render test runs in the existing doc-tools step.
- [ ] Run the suites; record the counts in CLAUDE.md.
- [ ] Commit: `chore(diagram): dependabot for the renderer's lock, and the suite counts`.

### Task 7: Redraw this repository's diagrams (R9)

**Files:**
- Modify: the 13 PNGs under `docs/architecture/diagrams/` and `docs/workflows/diagrams/`

- [ ] `bash scripts/doc-tools.sh diagram render` with system Chrome.
- [ ] Open every PNG and compare it with its source: every node and edge label present and legible,
      nothing clipped, no blank or error image. Fix the renderer, not the sources, until all 13 pass.
- [ ] `bash scripts/doc-tools.sh check-freshness`; re-baseline only docs read against their code.
- [ ] Commit: `docs: redraw every diagram with the local renderer`.
