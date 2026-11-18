# Local diagram rendering — design

**Status:** approved by the developer 2026-11-17 · **Scope:** a new `diagram` verb in
`doc-tools.sh`, its Node renderer under `scripts/diagram/`, the `diagram` and `init` actions, the
tool mappings, the tests and the docs · **Release:** one minor release, 3.16.0, after 3.15.0.

## What this decides

doc-superpowers renders every Mermaid diagram on the machine it runs on, with a renderer it ships
and pins. Diagram source never leaves that machine. The `diagram` action stops naming the Mermaid
MCP tool. Any agent, in any client with a shell, renders the same way:
`doc-tools.sh diagram render`.

## Why

The `diagram` action told agents to use `mcp__mermaid__generate_mermaid_diagram`. In the common
server that provides it, two output types (`svg_url`, `png_url`) return a `mermaid.ink` link that
carries the diagram source in its URL. Whoever opens that link sends the source to an outside
service. A doc's diagrams describe its system, which a project may treat as confidential. The
tool's local outputs depend on which server a client has configured, and clients without it had
no renderer at all. Diagrams laid out with ELK (the Eclipse Layout Kernel, Mermaid's optional
layered-layout plugin) could not be rendered by `mmdc`, which does not load layout plugins.

## Requirements

**R1. One verb.** `doc-tools.sh diagram list [<doc>…]` prints, as JSON, each Mermaid source block
in the given docs (default: every Markdown file under `docs/` holding a
`<details><summary>Mermaid source</summary>` block): the doc, the block's line, the PNG it renders
to (the image link directly above the block), and whether it asks for ELK.
`doc-tools.sh diagram render [<doc>…]` renders each block to that PNG. Exit codes: 0 rendered (or
listed), 1 a diagram failed to render (its source is invalid), 2 the renderer could not run (no
Node, no browser, dependencies missing), 3 usage.

**R2. Nothing leaves the machine.** The renderer loads Mermaid and the ELK plugin from its own
installed `node_modules`, in a headless Chrome page. Every request the page makes to anything but a
`file:`, `data:` or `about:` URL is aborted. A render that made such a request fails (exit 1) and
names the URL. No renderer service, CDN or URL output is used anywhere.

**R3. Pinned.** `scripts/diagram/package.json` and its `package-lock.json` pin `mermaid` 11.17.2,
`@mermaid-js/layout-elk` 0.2.3 and `puppeteer-core` 24.43.1, exactly. Node 18 or later. They are
installed once per lockfile, with `npm ci --ignore-scripts`, into a cache directory outside the
repository (`${XDG_CACHE_HOME:-$HOME/.cache}/doc-superpowers/diagram/<lockfile hash>`). Installing
fetches packages from the npm registry; it sends no diagram.

**R4. The browser.** `puppeteer-core` downloads no browser. The renderer uses, in order:
`DOC_SUPERPOWERS_CHROME`; a system Chrome or Chromium at the usual paths for macOS and Linux; a
`chrome-headless-shell` already in the cache. With none, it exits 2 and names
`doc-tools.sh diagram install-browser`, which installs the `chrome-headless-shell` build that
`puppeteer-core` 24.43.1 pins into the cache. That command runs only when someone asks for it.

**R5. ELK.** A block whose front matter or init directive sets `layout: elk` renders with the ELK
plugin registered. Every other block renders with Mermaid's default layout.

**R6. Output.** PNGs render at width 1248 and device scale 2 on a white background, the settings
earlier releases recorded for their hand renders. A render writes the PNG only when it succeeds; a
failed render leaves the old PNG as it was.

**R7. The actions.** The `diagram` action renders with `doc-tools.sh diagram render`. Where the
renderer cannot run (exit 2), it keeps the source current in the doc and reports the PNGs it could
not render, as its step 7 does today. The skill names no renderer service and no MCP rendering
tool. `init`'s diagram step follows the `diagram` action.

**R8. A guard.** A test fails when a tracked file outside dated records and release history names
`mermaid.ink`, `kroki`, or `mcp__mermaid`.

**R9. Redrawn.** Every diagram in this repository is re-rendered with the new verb before the
release, and each PNG is checked by eye against its source.

## The design

- **Bash side** (`doc-tools.sh diagram`): finds the blocks and their targets with awk, resolves the
  cache and the browser, installs the dependencies when the lockfile's directory is missing, and
  calls the renderer with a JSON job list. bash 3.2 and jq 1.6, like the rest of `doc-tools.sh`.
- **Node side** (`scripts/diagram/render.mjs`): one browser, one page per job, request
  interception as in R2, `mermaid.render` then a screenshot of the SVG at R6's settings. It prints
  one JSON result per job.
- **Tests** (`scripts/test-doc-tools.sh`):
  - `diagram list`: block discovery, the target PNG, the ELK flag, usage errors.
  - `diagram render` with a stub renderer: the cache path, the install step, the exit codes, and
    the old PNG kept on failure.
  - One real render, a default diagram and an ELK diagram, plus a diagram that requests an outside
    URL and must fail. These run when Node and a browser are present and are reported as skipped
    otherwise.
  - The R8 guard.

## Not in this release

- **SVG output.** Docs embed PNGs; an SVG option can follow.
- **Removing the Mermaid MCP server from a user's setup.** That is the user's configuration. The
  docs say its URL outputs send the source out, and the skill no longer uses it.
