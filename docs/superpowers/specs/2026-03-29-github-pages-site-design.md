# GitHub Pages Site Design

**Date:** 2026-03-29
**Status:** Approved
**Scope:** VitePress documentation site for doc-superpowers, deployed to GitHub Pages

## Summary

Create a VitePress-powered documentation site at `woodrowpearson.github.io/doc-superpowers` that mirrors the structure and polish of [Axiom](https://charleswiltgen.github.io/Axiom/). The site lives in a `site/` directory within the existing repo, uses a hybrid content strategy (reuse existing docs where solid, write fresh content for action references), and deploys via GitHub Actions.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Repo location | Same repo, `site/` directory | Keeps docs next to code, single PR for changes |
| Framework | VitePress | Markdown-first, what Axiom uses, minimal config, dark/light mode built-in |
| Content approach | Hybrid | Reuse architecture/workflow docs, write fresh action reference pages |
| Landing page | Minimal | Hero + 3 feature cards + CTA, expandable later |
| Deployment | GitHub Actions → GitHub Pages | Standard, triggers on `site/**` changes to `main` |

## Directory Structure

```
site/
├── package.json              # VitePress + dev dependencies
├── .vitepress/
│   ├── config.ts             # Nav, sidebar, theme, site metadata
│   └── theme/
│       ├── index.ts          # Custom theme extensions
│       └── style.css         # Custom CSS overrides
├── public/
│   └── logo.svg              # Site logo/favicon
├── index.md                  # Landing page (hero + feature cards)
├── get-started/
│   ├── installation.md       # All 6 platform install methods
│   ├── quick-start.md        # First run walkthrough
│   └── verification.md       # How to verify it's working
├── actions/
│   ├── index.md              # Actions overview
│   ├── init.md               # One page per action (fresh content)
│   ├── audit.md
│   ├── review-pr.md
│   ├── update.md
│   ├── diagram.md
│   ├── sync.md
│   ├── hooks.md
│   ├── release.md
│   ├── spec-generate.md
│   ├── spec-inject.md
│   └── spec-verify.md
├── hooks/
│   ├── index.md              # Hooks overview
│   ├── git.md                # Git hooks detail
│   ├── claude.md             # Claude Code hooks detail
│   ├── ci.md                 # CI/CD hooks detail
│   └── configuration.md      # Env vars, strict mode, etc.
├── spec-lifecycle/
│   ├── index.md              # Overview + workflow diagram
│   ├── generate.md           # Deep dive on spec-generate
│   ├── inject.md             # Deep dive on spec-inject
│   └── verify.md             # Deep dive on spec-verify
├── reference/
│   ├── doc-templates.md      # From references/doc-spec.md (adapted)
│   ├── agent-prompts.md      # From references/agent-prompt-template.md
│   ├── output-formats.md     # From references/output-templates.md
│   ├── tool-mappings.md      # From references/tool-mappings.md
│   └── integration.md        # From references/integration-patterns.md
└── architecture/
    ├── overview.md            # From docs/architecture/system-overview.md (reused)
    ├── workflows.md           # From docs/workflows/ (reused)
    └── diagrams.md            # Gallery of architecture/workflow diagrams
```

## Navigation

### Top Nav (6 items)

| Item | Link |
|------|------|
| Get Started | `/get-started/installation` |
| Actions | `/actions/` |
| Hooks | `/hooks/` |
| Spec Lifecycle | `/spec-lifecycle/` |
| Reference | `/reference/doc-templates` |
| Architecture | `/architecture/overview` |

Plus a GitHub icon link to the repo and a "Releases" nav link pointing to `https://github.com/woodrowpearson/doc-superpowers/releases`.

### Sidebar

Each section gets its own sidebar group. Pages listed in logical order (not alphabetical). Sidebar auto-collapses when navigating between sections.

## VitePress Configuration

```ts
// site/.vitepress/config.ts
export default defineConfig({
  title: 'doc-superpowers',
  description: 'Documentation orchestrator for AI-assisted development',
  base: '/doc-superpowers/',

  themeConfig: {
    logo: '/logo.svg',
    nav: [/* 6 section items + Releases external link */],
    sidebar: {/* per-section groups */},
    socialLinks: [
      { icon: 'github', link: 'https://github.com/woodrowpearson/doc-superpowers' }
    ],
    nav: [/* 6 section items + Releases external link */],
    search: { provider: 'local' },
    darkModeSwitchLabel: 'Theme',
  }
})
```

**Theme customization:**
- Dark/light mode toggle (VitePress built-in)
- Blue-purple brand accent color
- Text-only logo initially, SVG later
- Local search (no Algolia)

## Landing Page

```yaml
# site/index.md frontmatter
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
```

## Deployment

### GitHub Actions Workflow

`.github/workflows/deploy-site.yml`:
- **Trigger:** Push to `main` when `site/**` files change
- **Steps:** Checkout → Setup Node → `npm ci` in `site/` → `npm run build` → Deploy to GitHub Pages via `actions/deploy-pages`
- **Pages config:** Deploy from GitHub Actions (not branch-based)

### Local Dev

```bash
cd site && npm run dev
# Preview at localhost:5173
```

## Content Strategy

### Reused from existing docs (adapted with frontmatter)

| Source | Destination |
|--------|-------------|
| `docs/architecture/system-overview.md` | `site/architecture/overview.md` |
| `docs/workflows/doc-superpowers.md` | `site/architecture/workflows.md` |
| `docs/guides/getting-started.md` | `site/get-started/quick-start.md` |
| `docs/architecture/diagrams/*.png` | `site/public/diagrams/` |

### Written fresh

| Section | Format |
|---------|--------|
| Action pages (12) | Description, Usage, Options/Flags, Examples, Related Actions |
| Hooks pages (4) | What it does, Installation, Configuration, Env vars |
| Spec lifecycle pages (3) | Workflow diagram, Step-by-step, Integration |
| Reference pages (5) | Adapted from `references/`, restructured for readability |
| Installation page | All 6 platforms consolidated |
| Verification page | How to confirm it's working |

### Included (linked from nav)

| Page | Source | Notes |
|------|--------|-------|
| Release Notes | `RELEASE-NOTES.md` (reused) | Nav bar link pointing to GitHub releases page (`https://github.com/woodrowpearson/doc-superpowers/releases`) |

### Deferred (add as project grows)

- Blog/announcements
- Community/contributing guide
- API reference (if programmatic API is added)

## Out of Scope

- Custom domain (use `woodrowpearson.github.io/doc-superpowers`)
- Algolia search (local search sufficient)
- i18n / translations
- Analytics
