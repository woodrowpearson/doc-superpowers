# GitHub Pages Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a VitePress documentation site at `woodrowpearson.github.io/doc-superpowers` with 6 nav sections, dark/light mode, and GitHub Actions deployment.

**Architecture:** A `site/` directory at the repo root contains the VitePress project. Content is a hybrid of adapted existing docs and fresh action reference pages. GitHub Actions deploys on push to `main` when `site/**` changes.

**Tech Stack:** VitePress 2.x, Node 20, GitHub Actions (`actions/deploy-pages`), GitHub Pages

---

### Task 1: Scaffold VitePress project

**Files:**
- Create: `site/package.json`
- Create: `site/.vitepress/config.ts`
- Create: `site/.vitepress/theme/index.ts`
- Create: `site/.vitepress/theme/style.css`
- Create: `site/index.md`
- Modify: `.gitignore`

- [ ] **Step 1: Create `site/package.json`**

```json
{
  "name": "doc-superpowers-site",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vitepress dev",
    "build": "vitepress build",
    "preview": "vitepress preview"
  },
  "devDependencies": {
    "vitepress": "^2.0.0"
  }
}
```

- [ ] **Step 2: Create `site/.vitepress/config.ts`**

```ts
import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'doc-superpowers',
  description: 'Documentation orchestrator for AI-assisted development',
  base: '/doc-superpowers/',

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/doc-superpowers/logo.svg' }],
  ],

  themeConfig: {
    logo: '/logo.svg',

    nav: [
      { text: 'Get Started', link: '/get-started/installation' },
      { text: 'Actions', link: '/actions/' },
      { text: 'Hooks', link: '/hooks/' },
      { text: 'Spec Lifecycle', link: '/spec-lifecycle/' },
      { text: 'Reference', link: '/reference/doc-templates' },
      { text: 'Architecture', link: '/architecture/overview' },
      { text: 'Releases', link: 'https://github.com/woodrowpearson/doc-superpowers/releases' },
    ],

    sidebar: {
      '/get-started/': [
        {
          text: 'Get Started',
          items: [
            { text: 'Installation', link: '/get-started/installation' },
            { text: 'Quick Start', link: '/get-started/quick-start' },
            { text: 'Verification', link: '/get-started/verification' },
          ],
        },
      ],
      '/actions/': [
        {
          text: 'Actions',
          items: [
            { text: 'Overview', link: '/actions/' },
            { text: 'init', link: '/actions/init' },
            { text: 'audit', link: '/actions/audit' },
            { text: 'review-pr', link: '/actions/review-pr' },
            { text: 'update', link: '/actions/update' },
            { text: 'diagram', link: '/actions/diagram' },
            { text: 'sync', link: '/actions/sync' },
            { text: 'hooks', link: '/actions/hooks' },
            { text: 'release', link: '/actions/release' },
            { text: 'spec-generate', link: '/actions/spec-generate' },
            { text: 'spec-inject', link: '/actions/spec-inject' },
            { text: 'spec-verify', link: '/actions/spec-verify' },
          ],
        },
      ],
      '/hooks/': [
        {
          text: 'Hooks',
          items: [
            { text: 'Overview', link: '/hooks/' },
            { text: 'Git Hooks', link: '/hooks/git' },
            { text: 'Claude Code Hooks', link: '/hooks/claude' },
            { text: 'CI/CD Hooks', link: '/hooks/ci' },
            { text: 'Configuration', link: '/hooks/configuration' },
          ],
        },
      ],
      '/spec-lifecycle/': [
        {
          text: 'Spec Lifecycle',
          items: [
            { text: 'Overview', link: '/spec-lifecycle/' },
            { text: 'Generate', link: '/spec-lifecycle/generate' },
            { text: 'Inject', link: '/spec-lifecycle/inject' },
            { text: 'Verify', link: '/spec-lifecycle/verify' },
          ],
        },
      ],
      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'Doc Templates', link: '/reference/doc-templates' },
            { text: 'Agent Prompts', link: '/reference/agent-prompts' },
            { text: 'Output Formats', link: '/reference/output-formats' },
            { text: 'Tool Mappings', link: '/reference/tool-mappings' },
            { text: 'Integration Patterns', link: '/reference/integration' },
          ],
        },
      ],
      '/architecture/': [
        {
          text: 'Architecture',
          items: [
            { text: 'System Overview', link: '/architecture/overview' },
            { text: 'Workflows', link: '/architecture/workflows' },
            { text: 'Diagrams', link: '/architecture/diagrams' },
          ],
        },
      ],
    },

    socialLinks: [
      { icon: 'github', link: 'https://github.com/woodrowpearson/doc-superpowers' },
    ],

    search: {
      provider: 'local',
    },

    editLink: {
      pattern: 'https://github.com/woodrowpearson/doc-superpowers/edit/main/site/:path',
    },

    footer: {
      message: 'Released under the MIT License.',
    },
  },
})
```

- [ ] **Step 3: Create `site/.vitepress/theme/style.css`**

```css
:root {
  --vp-c-brand-1: #7c5cfc;
  --vp-c-brand-2: #6a4de6;
  --vp-c-brand-3: #5a3ed0;
  --vp-c-brand-soft: rgba(124, 92, 252, 0.14);
}

.dark {
  --vp-c-brand-1: #9b82fc;
  --vp-c-brand-2: #7c5cfc;
  --vp-c-brand-3: #6a4de6;
  --vp-c-brand-soft: rgba(124, 92, 252, 0.16);
}
```

- [ ] **Step 4: Create `site/.vitepress/theme/index.ts`**

```ts
import DefaultTheme from 'vitepress/theme'
import './style.css'

export default DefaultTheme
```

- [ ] **Step 5: Create `site/index.md`**

```markdown
---
layout: home

hero:
  name: doc-superpowers
  text: Documentation orchestrator for AI-assisted development
  tagline: Discover, generate, audit, and maintain project docs — automatically
  actions:
    - theme: brand
      text: Get Started
      link: /get-started/installation
    - theme: alt
      text: View on GitHub
      link: https://github.com/woodrowpearson/doc-superpowers

features:
  - icon: 🔍
    title: Zero-Config Discovery
    details: Automatically discovers your project's doc tooling, directory structure, and agentic workflows
  - icon: 🤖
    title: Parallel Agent Auditing
    details: Scope-isolated review agents verify docs against code with evidence-backed findings
  - icon: 📦
    title: Multi-Platform Support
    details: Claude Code, Cursor, Codex, OpenCode, Gemini CLI, and skills.sh
---
```

- [ ] **Step 6: Add `site/` build artifacts to `.gitignore`**

Append to the existing `.gitignore`:

```
# VitePress site build
site/.vitepress/dist
site/.vitepress/cache
site/node_modules
```

- [ ] **Step 7: Install dependencies and verify dev server starts**

Run:
```bash
cd site && npm install
```
Expected: `node_modules/` created, `package-lock.json` generated.

Run:
```bash
cd site && npx vitepress dev --port 5173 &
sleep 3 && curl -s http://localhost:5173/doc-superpowers/ | head -20
kill %1
```
Expected: HTML output containing "doc-superpowers".

- [ ] **Step 8: Commit**

```bash
git add site/package.json site/package-lock.json site/.vitepress/ site/index.md .gitignore
git commit -m "feat(site): scaffold VitePress project with config, theme, and landing page"
```

---

### Task 2: Create placeholder logo

**Files:**
- Create: `site/public/logo.svg`

- [ ] **Step 1: Create `site/public/logo.svg`**

A simple text-based SVG placeholder:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" fill="none">
  <rect width="32" height="32" rx="6" fill="#7c5cfc"/>
  <text x="16" y="22" text-anchor="middle" font-family="system-ui, sans-serif" font-weight="700" font-size="18" fill="white">d</text>
</svg>
```

- [ ] **Step 2: Commit**

```bash
git add site/public/logo.svg
git commit -m "feat(site): add placeholder logo SVG"
```

---

### Task 3: Get Started section

**Files:**
- Create: `site/get-started/installation.md`
- Create: `site/get-started/quick-start.md`
- Create: `site/get-started/verification.md`

- [ ] **Step 1: Create `site/get-started/installation.md`**

Fresh content consolidating all 6 platform install methods from the README. Format:

```markdown
# Installation

Install doc-superpowers in your preferred AI coding agent.

## Claude Code (Recommended)

\`\`\`bash
git clone git@github.com:woodrowpearson/doc-superpowers.git ~/code/doc-superpowers
ln -s ~/code/doc-superpowers ~/.claude/skills/doc-superpowers
\`\`\`

## Cursor

\`\`\`
/add-plugin doc-superpowers
\`\`\`

Or clone and point `.cursor-plugin/plugin.json` at the repo.

## Codex

\`\`\`bash
git clone https://github.com/woodrowpearson/doc-superpowers.git ~/.codex/doc-superpowers
mkdir -p ~/.agents/skills
ln -s ~/.codex/doc-superpowers ~/.agents/skills/doc-superpowers
\`\`\`

## OpenCode

Add to your `opencode.json`:

\`\`\`json
{
  "plugin": ["doc-superpowers@git+https://github.com/woodrowpearson/doc-superpowers.git"]
}
\`\`\`

## Gemini CLI

\`\`\`bash
gemini extensions install https://github.com/woodrowpearson/doc-superpowers
\`\`\`

## skills.sh (Any Agent)

\`\`\`bash
npx skills add woodrowpearson/doc-superpowers
\`\`\`

Works with 40+ supported agents. See [skills.sh](https://skills.sh) for details.

## Dependencies

The skill itself has zero dependencies. The bundled tooling in `scripts/` requires:

| Dependency | Required | Notes |
|-----------|----------|-------|
| `git` | Yes | Already required by doc-superpowers |
| `jq` | Yes | `brew install jq` / `apt install jq` |
| `sha256sum` or `shasum` | Yes | Standard on Linux/macOS |
```

- [ ] **Step 2: Adapt `site/get-started/quick-start.md`**

Adapt from `docs/guides/getting-started.md` with VitePress frontmatter. Rewrite the content to flow as a tutorial: prerequisites, first run with `init`, what to expect.

- [ ] **Step 3: Create `site/get-started/verification.md`**

Fresh content:

```markdown
# Verification

Confirm doc-superpowers is installed and working correctly.

## Check Skill Loading

Start a Claude Code session in any project:

\`\`\`
/doc-superpowers init
\`\`\`

You should see the discovery phase begin, scanning your project structure.

## Expected Output

A successful `init` creates a `docs/` directory with:

- `architecture/system-overview.md` — C4 diagrams and tech stack
- `workflows/` — Process flows and sequence diagrams
- `guides/getting-started.md` — Prerequisites and setup
- `codebase-guide.md` — Directory map and key files
- `conventions.md` — Code style and naming conventions
- `.doc-index.json` — Machine-readable freshness index

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Skill not found | Verify symlink: `ls -la ~/.claude/skills/doc-superpowers` |
| `jq` not found | Install: `brew install jq` or `apt install jq` |
| No docs generated | Check you're in a project with source code |
```

- [ ] **Step 4: Verify pages render**

Run:
```bash
cd site && npx vitepress dev --port 5173 &
sleep 3 && curl -s http://localhost:5173/doc-superpowers/get-started/installation.html | grep -c '<h1'
kill %1
```
Expected: `1` (the page renders with a heading).

- [ ] **Step 5: Commit**

```bash
git add site/get-started/
git commit -m "feat(site): add Get Started section — installation, quick-start, verification"
```

---

### Task 4: Actions section

**Files:**
- Create: `site/actions/index.md`
- Create: `site/actions/init.md`
- Create: `site/actions/audit.md`
- Create: `site/actions/review-pr.md`
- Create: `site/actions/update.md`
- Create: `site/actions/diagram.md`
- Create: `site/actions/sync.md`
- Create: `site/actions/hooks.md`
- Create: `site/actions/release.md`
- Create: `site/actions/spec-generate.md`
- Create: `site/actions/spec-inject.md`
- Create: `site/actions/spec-verify.md`

Each action page follows a consistent format:

```markdown
# <action-name>

<One-line description>

## Usage

\`\`\`
/doc-superpowers <action> [options]
\`\`\`

## Options

| Option | Description |
|--------|-------------|
| ... | ... |

## What It Does

<2-3 paragraphs explaining the action's behavior>

## Examples

<Real usage examples with expected output>

## Related Actions

- [action-name](/actions/action-name) — <how they relate>
```

- [ ] **Step 1: Create `site/actions/index.md`**

Overview page with the quick reference table from SKILL.md (the 11-row action table) and a brief intro paragraph.

- [ ] **Step 2: Create action pages for core actions (init, audit, review-pr, update)**

Write `init.md`, `audit.md`, `review-pr.md`, `update.md` using the format above. Content is derived from SKILL.md descriptions and README examples but written fresh for the site audience.

- [ ] **Step 3: Create action pages for utility actions (diagram, sync, hooks, release)**

Write `diagram.md`, `sync.md`, `hooks.md`, `release.md` using the same format.

- [ ] **Step 4: Create action pages for spec lifecycle actions (spec-generate, spec-inject, spec-verify)**

Write `spec-generate.md`, `spec-inject.md`, `spec-verify.md` using the same format.

- [ ] **Step 5: Commit**

```bash
git add site/actions/
git commit -m "feat(site): add Actions section — 12 action reference pages"
```

---

### Task 5: Hooks section

**Files:**
- Create: `site/hooks/index.md`
- Create: `site/hooks/git.md`
- Create: `site/hooks/claude.md`
- Create: `site/hooks/ci.md`
- Create: `site/hooks/configuration.md`

- [ ] **Step 1: Create `site/hooks/index.md`**

Overview of the three hook tiers (Git, Claude Code, CI/CD), installation command, and a table listing all hooks per tier.

- [ ] **Step 2: Create `site/hooks/git.md`**

Detail page for Git hooks: pre-commit, post-merge, post-checkout, prepare-commit-msg, pre-push. What each does, how to install, example output.

- [ ] **Step 3: Create `site/hooks/claude.md`**

Detail page for Claude Code hooks: pre-commit gate, post-commit sync, session summary. What each does, when it fires, example output.

- [ ] **Step 4: Create `site/hooks/ci.md`**

Detail page for CI/CD hooks: PR freshness check, weekly drift cron, post-merge index update. Workflow file names, trigger conditions, how to customize.

- [ ] **Step 5: Create `site/hooks/configuration.md`**

Environment variables page:

```markdown
# Configuration

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DOC_SUPERPOWERS_STRICT` | `0` | Set to `1` to make pre-commit block instead of warn |
| `DOC_SUPERPOWERS_QUIET` | `0` | Set to `1` to suppress hook output while still enforcing |
| `DOC_SUPERPOWERS_SKIP` | `0` | Set to `1` to bypass all hooks temporarily |
```

- [ ] **Step 6: Commit**

```bash
git add site/hooks/
git commit -m "feat(site): add Hooks section — git, claude, ci, configuration"
```

---

### Task 6: Spec Lifecycle section

**Files:**
- Create: `site/spec-lifecycle/index.md`
- Create: `site/spec-lifecycle/generate.md`
- Create: `site/spec-lifecycle/inject.md`
- Create: `site/spec-lifecycle/verify.md`

- [ ] **Step 1: Create `site/spec-lifecycle/index.md`**

Overview with the workflow diagram (Mermaid source from `docs/workflows/doc-superpowers.md` spec-lifecycle section). Explain the three phases and how they connect to the brainstorming → planning → execution pipeline.

- [ ] **Step 2: Create `site/spec-lifecycle/generate.md`**

Deep dive on spec-generate: inputs (design doc path), outputs (formal spec files), process, example invocation and output.

- [ ] **Step 3: Create `site/spec-lifecycle/inject.md`**

Deep dive on spec-inject: plan phase vs execute phase, how tasks are injected, drift tracking, example invocations.

- [ ] **Step 4: Create `site/spec-lifecycle/verify.md`**

Deep dive on spec-verify: post-execute mode vs review mode, compliance checks, coverage reports, example invocations.

- [ ] **Step 5: Commit**

```bash
git add site/spec-lifecycle/
git commit -m "feat(site): add Spec Lifecycle section — overview, generate, inject, verify"
```

---

### Task 7: Reference section

**Files:**
- Create: `site/reference/doc-templates.md`
- Create: `site/reference/agent-prompts.md`
- Create: `site/reference/output-formats.md`
- Create: `site/reference/tool-mappings.md`
- Create: `site/reference/integration.md`

Content is adapted from the `references/` directory files. Each page is restructured for site readability (proper headings, introductory context, clean tables) but preserves the technical content.

- [ ] **Step 1: Create all 5 reference pages**

For each reference file:
1. Read the source in `references/`
2. Add VitePress frontmatter
3. Add an introductory paragraph explaining the purpose
4. Restructure content with proper heading hierarchy
5. Fix any relative links to work in the site context

Source → destination mapping:
- `references/doc-spec.md` → `site/reference/doc-templates.md`
- `references/agent-prompt-template.md` → `site/reference/agent-prompts.md`
- `references/output-templates.md` → `site/reference/output-formats.md`
- `references/tool-mappings.md` → `site/reference/tool-mappings.md`
- `references/integration-patterns.md` → `site/reference/integration.md`

- [ ] **Step 2: Commit**

```bash
git add site/reference/
git commit -m "feat(site): add Reference section — adapted from references/ directory"
```

---

### Task 8: Architecture section

**Files:**
- Create: `site/architecture/overview.md`
- Create: `site/architecture/workflows.md`
- Create: `site/architecture/diagrams.md`
- Copy: diagram PNGs → `site/public/diagrams/`

- [ ] **Step 1: Copy diagram PNGs to `site/public/diagrams/`**

```bash
mkdir -p site/public/diagrams
cp docs/architecture/diagrams/*.png site/public/diagrams/
cp docs/workflows/diagrams/*.png site/public/diagrams/
```

- [ ] **Step 2: Create `site/architecture/overview.md`**

Adapted from `docs/architecture/system-overview.md`. Update image paths from relative (`diagrams/c4-context.png`) to absolute (`/doc-superpowers/diagrams/c4-context.png`). Add introductory context for site visitors who may not be familiar with C4 diagrams.

- [ ] **Step 3: Create `site/architecture/workflows.md`**

Adapted from `docs/workflows/doc-superpowers.md`. Update image paths the same way. Ensure Mermaid source blocks remain in `<details>` sections.

- [ ] **Step 4: Create `site/architecture/diagrams.md`**

Gallery page listing all diagrams with thumbnail images and captions:

```markdown
# Diagrams

## Architecture

![C4 Context](/diagrams/c4-context.png)
*System context — doc-superpowers in its operating environment*

![C4 Container](/diagrams/c4-container.png)
*Internal components — discovery, routing, agents, templates, hooks*

## Workflows

![Primary Workflow](/diagrams/workflow-primary.png)
*Action routing from discovery to verification*

<!-- ... remaining diagrams ... -->
```

- [ ] **Step 5: Commit**

```bash
git add site/public/diagrams/ site/architecture/
git commit -m "feat(site): add Architecture section — reused docs with diagram gallery"
```

---

### Task 9: Build verification

**Files:** None (verification only)

- [ ] **Step 1: Run the full build**

```bash
cd site && npm run build
```
Expected: Build completes without errors. Output in `site/.vitepress/dist/`.

- [ ] **Step 2: Preview the built site**

```bash
cd site && npm run preview -- --port 4173 &
sleep 3 && curl -s http://localhost:4173/doc-superpowers/ | grep -c 'doc-superpowers'
kill %1
```
Expected: `1` or more (site renders correctly).

- [ ] **Step 3: Verify all nav links resolve**

```bash
cd site && find .vitepress/dist -name '*.html' | wc -l
```
Expected: ~35 HTML files (index + 12 actions + 5 hooks + 4 spec-lifecycle + 5 reference + 3 architecture + 3 get-started).

- [ ] **Step 4: Fix any broken links or build warnings**

Address any warnings from the build output. Common issues: broken relative links, missing images, frontmatter errors.

- [ ] **Step 5: Commit any fixes**

```bash
git add site/
git commit -m "fix(site): resolve build warnings and broken links"
```

---

### Task 10: GitHub Actions deployment workflow

**Files:**
- Create: `.github/workflows/deploy-site.yml`

- [ ] **Step 1: Create `.github/workflows/deploy-site.yml`**

```yaml
name: Deploy Site

on:
  push:
    branches: [main]
    paths: ['site/**']
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
          cache-dependency-path: site/package-lock.json

      - name: Install dependencies
        working-directory: site
        run: npm ci

      - name: Build site
        working-directory: site
        run: npm run build

      - uses: actions/configure-pages@v5

      - uses: actions/upload-pages-artifact@v3
        with:
          path: site/.vitepress/dist

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

- [ ] **Step 2: Verify workflow syntax**

```bash
cat .github/workflows/deploy-site.yml | python3 -c "import sys, yaml; yaml.safe_load(sys.stdin.read()); print('valid')"
```
Expected: `valid`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-site.yml
git commit -m "ci: add GitHub Actions workflow for VitePress site deployment"
```

---

### Task 11: Enable GitHub Pages

**Files:** None (GitHub settings)

- [ ] **Step 1: Enable GitHub Pages via API**

```bash
gh api repos/woodrowpearson/doc-superpowers/pages \
  --method POST \
  --field build_type=workflow \
  2>/dev/null || echo "Pages may already be enabled"
```

If this fails with a 409 (already exists), update instead:

```bash
gh api repos/woodrowpearson/doc-superpowers/pages \
  --method PUT \
  --field build_type=workflow
```

- [ ] **Step 2: Push and verify deployment**

After pushing to `main`, check the Actions run:

```bash
gh run list --workflow=deploy-site.yml --limit 1
```

Wait for it to complete, then verify the site is live:

```bash
curl -s -o /dev/null -w '%{http_code}' https://woodrowpearson.github.io/doc-superpowers/
```
Expected: `200`

- [ ] **Step 3: Verify key pages load**

```bash
curl -s -o /dev/null -w '%{http_code}' https://woodrowpearson.github.io/doc-superpowers/get-started/installation.html
curl -s -o /dev/null -w '%{http_code}' https://woodrowpearson.github.io/doc-superpowers/actions/
curl -s -o /dev/null -w '%{http_code}' https://woodrowpearson.github.io/doc-superpowers/architecture/overview.html
```
Expected: All `200`.
