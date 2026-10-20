# doc-search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `doc-search`, an opt-in MCP server (MCP Python SDK v2) in doc-superpowers. It answers questions about docs, code, or both in one call, over two per-worktree semble indexes, and can add an abundance-compatible Vertex/Firestore docs leg. Results are fused with RRF and cross-linked through the doc-index.

**Architecture:** A uv-managed Python package under `search/`. Pieces:
- semble 0.7 through its Python API: a docs index and a code index per worktree.
- A thin join layer: enrichment, pre-filtering, RRF, cross-links.
- An `MCPServer` with four tools, and a CLI.
- An optional `cloud` extra for Vertex + Firestore, covering both the read leg and a guarded write path.

On the shell side: a POSIX launcher, an opt-in `install.sh --search` set, and a `search` check in `check-ci.sh` / `tests.yml`.

**Tech Stack:** Python 3.12 (uv), `semble>=0.7,<0.8`, `mcp>=2.3,<3` (`mcp.server.mcpserver.MCPServer`), `pathspec`, stdlib. Extra `cloud`: `google-genai`, `google-cloud-firestore`. pytest. bash 3.2 / POSIX sh.

**Spec:** `docs/superpowers/specs/2026-10-19-doc-search-design.md` (rev 2). §n below refers to it.

## Global Constraints

**Opt-in contract**
- Without `docs/search/config.json`, every tool answers exactly `doc-search: not enabled (no docs/search/config.json)`. Every CLI verb except `init` prints that line and exits 0.
- With an invalid config, tools answer `doc-search: invalid config: <message>` and the CLI exits 2.

**CLI exit codes**
- `0` ok (inert included), `1` findings, `2` could not run, `3` usage.
- When several apply, `1` wins over `2`, and `2` over `0`.

**Dependencies**
- Runtime: exactly `semble>=0.7,<0.8`, `mcp>=2.3,<3`, `pathspec`.
- Extra `cloud`: `google-genai`, `google-cloud-firestore`.
- Dev group: `pytest`.
- No torch, no onnxruntime. `uv tree --project search --all-extras | rg -i 'torch|onnxruntime'` prints nothing.
- `search/.python-version` is `3.12`; `requires-python = ">=3.11"`.

**Names**
- Server `doc-search`.
- Tools `search`, `fetch`, `related`, `status`.
- CLI `doc-search` with the verbs `serve init index query status eval`.

**Config**
- `docs/search/config.json`, holding the §9 defaults exactly.
- Deep merge: objects merge, arrays and scalars replace.
- `cloud` is `null` or an object.
- `DOC_SEARCH_CLOUD=0` disables the cloud leg. No environment variable enables it.

**semble usage**
- Indexes:
  - docs: `SembleIndex.from_path(worktree, content=[ContentType.DOCS], model_path=cfg.docs.model)`
  - code: `content=[ContentType(c) for c in cfg.code.content]`, `model_path=cfg.code.model`
- Load or validate with `semble.cache.get_validated_cache(path, model_path, content)`, then `SembleIndex.load_from_disk`.
- Save with `semble.cache.save_index_to_cache(index, path)`.
- Revalidate after `max(rescan_seconds, 3 × last build seconds)`.

**Search sizing and output**
- RRF `k = 60`.
- The docs leg fetches `limit × 3`, code `limit × 2`, cloud `limit × 3`.
- Per-kind floor `ceil(limit/3)`.
- `limit` defaults to 10 and is clamped to 1–50.
- Snippets are at most 6 lines.
- A response is at most 8,000 characters.
- `fetch` returns at most 400 lines, with 20 lines of context by default.
- At most 2 worktrees' index pairs in memory.
- A first-build wait is at most 20 s.

**Doc metadata**
- Terminal statuses default to `["deprecated", "superseded", "archived"]`. A path under `docs/archive/` is also terminal.
- Built-in `doc_type` rules are per §5.

**Cloud leg**
- Fields: `path, chunkIndex, text, embedding, headingPath, lastIndexedAt, fileSha256, docType, startLine, endLine`.
- Meta document `corpus_meta/index` `{built_from_commit, built_at, mode, embedder_id}`.
- Lease `corpus_meta/catch_up_lease` `{holder, expires_at}`, TTL 1800 s.
- Vertex `gemini-embedding-001`, 768-d, `RETRIEVAL_QUERY` / `RETRIEVAL_DOCUMENT`.
- Writes in batches of 200, with 3 retries and exponential backoff plus jitter.
- Vectors are L2-normalized.

**Tests and shell**
- Tests never touch the network. semble runs on a tiny test-built Model2Vec model (Task 1's fixture), and live tests run only under `DOC_SEARCH_LIVE=1`.
- The launcher is POSIX sh. Installer edits are bash 3.2-safe. Both pass shellcheck at warning severity.

**Hands-off files**
- Nothing writes `docs/.doc-index.json` or a doc.
- Commits stay free of `RELEASE-NOTES.md`, version strings and tags.

## Review Focus

1. **An empty allowed set.** semble's `filter_paths` silently stops filtering when none of the given paths are indexed: its selector comes back `None`. Example: `doc_type=adr` in a repo with no ADRs. That must return zero docs hits, not unfiltered ones. Test in Task 4: `test_empty_allowed_set_returns_no_docs`.
2. **Unreadable or odd corpus files.** Non-UTF-8 files, files over 1 MiB, binary `.md`, files deleted between discovery and enrichment, and files semble did not index (`.sembleignore`) are all skipped. A doc missing from the index is counted in `status`, and nothing raises. Test in Task 2: `test_enrichment_tolerates_bad_files`. Test in Task 6: `test_status_reports_unindexed_corpus`.
3. **A call during a first build.** It waits at most 20 s, then answers the "index building" line. It never hangs the stdio loop or raises. Test in Task 5: `test_first_build_bounded_wait`.
4. **A cloud leg with no credentials, or a stamp commit that hasn't been fetched.** The search still answers from the local legs, and the header and `status` give the reason. Test in Task 7: `test_cloud_failure_degrades_to_local`.
5. **Path confinement.** `fetch` and `related` refuse absolute paths, `..`, `.git/…`, and symlinks that leave the worktree. The `worktree` parameter refuses non-worktrees. Test in Task 6: `test_fetch_and_related_confined`.

---

## File Structure

```
search/
├── pyproject.toml, uv.lock, .python-version
├── src/doc_search/
│   ├── __init__.py        # __version__ via importlib.metadata
│   ├── types.py           # Hit, DocMeta, SearchRequest, SearchResponse, HeaderInfo
│   ├── config.py          # load_config, Config, ConfigError, INERT_LINE
│   ├── repo.py            # RepoInfo, worktrees, resolve_worktree, confine, git helpers
│   ├── docindex.py        # DocIndex (mtime-cached), docs_covering
│   ├── corpus.py          # Corpus (discovery + enrichment cache), DocMeta resolution, heading_path_at
│   ├── engines.py         # WorktreeIndexes (docs+code SembleIndex pair), IndexPool (LRU 2, background builds)
│   ├── fusion.py          # rrf, collapse_by_file, interleave_with_floor
│   ├── searcher.py        # Searcher.search/fetch/related/status
│   ├── render.py          # render_search/fetch/related/status
│   ├── chunker.py         # heading-bounded chunker (cloud write path only)
│   ├── cloud/
│   │   ├── __init__.py
│   │   ├── vertex.py      # VertexEmbedder
│   │   ├── read.py        # CloudLeg (Firestore kNN, stamp, branch-changed suppression)
│   │   └── write.py       # CloudIndexer (guards, lease, catch-up, orphans, stamp)
│   ├── evaluate.py        # run_eval (legs incl. semble-single)
│   ├── server.py          # build_server (MCPServer), serve
│   └── cli.py             # main
└── tests/
    ├── conftest.py        # tiny_model, git_repo, add_worktree, semble cache isolation
    ├── fakes.py           # FakeFirestore, FakeGenai
    └── test_*.py
scripts/search/launch.sh
scripts/hooks/install.sh, scripts/test-hooks.sh, scripts/check-ci.sh, .github/workflows/tests.yml
references/search.md, SKILL.md, references/{hooks,tool-mappings}.md, README.md, AGENTS.md, CLAUDE.md, docs/codebase-guide.md
.gitignore
```

---

### Task 1: Scaffold, config, and the test fixtures

**Files:**
- Create: `search/pyproject.toml`, `search/.python-version`, `search/uv.lock`, `search/src/doc_search/{__init__,types,config}.py`, `search/tests/conftest.py`, `search/tests/test_config.py`, `search/tests/test_fixtures.py`
- Modify: `.gitignore` (add `search/.venv/`, `search/**/__pycache__/`, `search/.pytest_cache/`)

**Interfaces:**
- Produces:
  - `load_config(top: Path, env: Mapping[str, str] = os.environ) -> Config | None`. Returns `None` when inert; raises `ConfigError` (whose message names the key) when the config is invalid.
  - `Config`, a frozen dataclass:
    - `docs: DocsCfg(include, exclude, types: tuple[tuple[str, str], ...], model: str | None)`
    - `code: CodeCfg(enabled: bool, content: tuple[str, ...], model: str | None)`
    - `cloud: CloudCfg | None`, where `CloudCfg(vertex: VertexCfg(project, location, model, dimensions), firestore: FirestoreCfg(project, database, collection, meta_collection, base_ref))`
    - `search: SearchCfg(default_limit, terminal_statuses, rescan_seconds)`
  - `cloud` is `None` when the config's `cloud` is null or `DOC_SEARCH_CLOUD=0`. `GOOGLE_CLOUD_PROJECT` fills a null `project`.
  - `INERT_LINE = "doc-search: not enabled (no docs/search/config.json)"`.
  - `types.py`:
    - `Hit(kind: Literal["doc","code"], path, start_line, end_line, snippet, heading_path: tuple[str, ...] = (), doc_type: str | None = None, status: str | None = None, links: tuple[str, ...] = (), more_in_file: int = 0, legs: tuple[str, ...] = ())`
    - `DocMeta(path, title, doc_type, status, code_refs: tuple[str, ...], replaces, superseded_by)`
    - `SearchRequest(query, scope="all", limit=10, doc_type: tuple[str, ...] = (), path_prefix=None, include_terminal=False)`
    - `HeaderInfo(docs_model: str, code: str, cloud: str | None, notes: tuple[str, ...], truncated: bool)`
    - `SearchResponse(hits: list[Hit], header: HeaderInfo)`
  - conftest fixtures:
    - `tiny_model(tmp_path_factory) -> str` builds a model2vec `StaticModel` from a WordLevel `tokenizers.Tokenizer` over a fixed ~200-word vocabulary covering the test texts, with lowercase normalizer and whitespace pre-tokenizer, seeded random 16-d vectors and `normalize=True`. It is saved with `save_pretrained` and the directory path returned.
    - `semble_cache` (autouse) sets `SEMBLE_CACHE_LOCATION` to a tmp dir and `HF_HUB_OFFLINE=1`.
    - `git_repo` is a factory: `git init` with `GIT_CONFIG_GLOBAL=/dev/null` and a private `HOME`, plus `write(rel, text)`, `commit(msg)` and `add_worktree(name, branch) -> Path`.

- [ ] **Step 1: Write the failing tests.**
  - `test_config.py`:
    - `test_absent_config_is_inert`.
    - `test_empty_object_gets_defaults`, which asserts every §9 default value:
      - `docs.include == ("docs/**/*.md", "*.md")`
      - `docs.exclude == ("docs/archive/**", "docs/.doc-index.json")`
      - `docs.model is None`, `code.enabled is True`, `code.content == ("code",)`, `cloud is None`
      - `search.default_limit == 10`, `search.terminal_statuses == ("deprecated", "superseded", "archived")`, `search.rescan_seconds == 5`
    - `test_arrays_replace_objects_merge`.
    - `test_cloud_defaults_fill`: `{"cloud": {"vertex": {"project": "p"}, "firestore": {}}}` gives location `us-central1`, model `gemini-embedding-001`, dimensions `768`, database `(default)`, collection `doc_chunks`, meta collection `corpus_meta`, base_ref `None`.
    - `test_cloud_disabled_by_env`: `DOC_SEARCH_CLOUD=0` makes `cloud is None`.
    - `test_env_cannot_enable_cloud`: `DOC_SEARCH_CLOUD=1` with `{}` leaves `cloud is None`.
    - `test_google_cloud_project_fallback`.
    - `test_invalid_values_raise`, parametrized:
      - an unknown `code.content` value (allowed: `code`, `config`, `docs`, `all`)
      - a non-integer `default_limit`
      - a `cloud` that isn't an object
      - a malformed `docs.types` entry
      - a non-object top level
      - malformed JSON
  - `test_fixtures.py`:
    - `test_tiny_model_drives_semble`: a repo with `docs/refunds.md` and `src/refund.py`. The docs index search `"refund rounding"` returns `docs/refunds.md`, and the code index returns `src/refund.py`, offline.

- [ ] **Step 2: Run them to see them fail.** `uv run --project search pytest search/tests -q` errors on import.
- [ ] **Step 3: Implement** the scaffold, `config.py` and `types.py`.
- [ ] **Step 4: Lock and run.**
  - `uv lock --project search && uv run --project search --frozen pytest search/tests -q`: expected PASS.
  - `uv tree --project search --all-extras | rg -i 'torch|onnxruntime'`: expected no output.
- [ ] **Step 5: Commit.** `git add search .gitignore && git commit -m "feat(search): package scaffold, config, offline semble test fixture"`

---

### Task 2: Repository helpers, doc-index, corpus and enrichment

**Files:**
- Create: `search/src/doc_search/{repo,docindex,corpus}.py`, `search/tests/{test_repo,test_docindex,test_corpus}.py`

**Interfaces:**
- Consumes: `Config`, `DocMeta` (Task 1).
- Produces:
  - `RepoInfo.from_cwd(cwd: Path) -> RepoInfo(top, common_dir)`; raises `NotARepo`.
  - `worktrees(repo) -> list[Path]` (real paths from `git worktree list --porcelain`).
  - `resolve_worktree(repo, requested: str | None) -> Path`: `None` means the launch top. Anything not in `worktrees(repo)` raises `ValueError("not a worktree of this repository: …")`.
  - `confine(top: Path, rel: str) -> Path`: raises `ValueError` for absolute paths, `..` escapes, any `.git` component, or a symlink whose resolved path leaves `top`.
  - `git(top, *args) -> str` (argv, never a shell), `diff_names(top, commit) -> set[str] | None` (`None` when the commit is missing locally), `ls_files(top) -> set[str]`, `is_ancestor(top, a, b) -> bool`, `rev_parse(top, ref) -> str | None`.
  - `DocIndex(top)`:
    - `.present: bool`, `.entry(path) -> dict | None`
    - `.docs_covering(code_path) -> list[str]`: docs naming the file, an ancestor directory, or `.`. Most specific first, then by path.
    - Reloads when the file's mtime changes.
  - `Corpus(top: Path, cfg: Config, docindex: DocIndex)`:
    - `.files() -> list[str]`: include minus exclude via `pathspec` gitwildmatch, ∩ `git ls-files --cached --others --exclude-standard`, sorted. Cached for `rescan_seconds`.
    - `.contains(path) -> bool`
    - `.meta(path) -> DocMeta | None`, per the §5 resolution order. Reads at most the first 64 KiB. Cached by `(size, mtime_ns)`. `None` for unreadable files.
    - `.heading_path_at(path, line) -> tuple[str, ...]`: the heading stack above `line`, ignoring fenced blocks, with the title first.
    - `.allowed(doc_types: tuple[str, ...], path_prefix: str | None, include_terminal: bool) -> list[str]`.
    - `.skipped() -> dict[str, str]`: path → reason (`not-utf8`, `too-large`, `vanished`).
  - `is_terminal(meta, cfg) -> bool`.

- [ ] **Step 1: Write the failing tests.**
  - `test_repo.py`:
    - `test_from_cwd_in_worktree`: the common dir is shared.
    - `test_resolve_worktree_rejects_foreign_path`.
    - `test_confine_rejects`, parametrized: `"/etc/passwd"`, `"../x"`, `"docs/../../x"`, `".git/config"`, and a symlink to an outside dir.
    - `test_diff_names_non_ancestor` (the stamp is on a sibling branch).
    - `test_diff_names_missing_commit_is_none`.
  - `test_docindex.py`:
    - `test_docs_covering_specificity`: refs `src/a.py`, `src/` and `.` yield `[file_doc, dir_doc, root_doc]` for `src/a.py`.
    - `test_absent_index`.
    - `test_reload_on_mtime`.
  - `test_corpus.py`:
    - `test_discovery_defaults`: includes `docs/a.md`, `README.md` and an untracked `docs/new.md`. Excludes `docs/archive/old.md`, a gitignored `docs/tmp.md` and `src/x.py`.
    - `test_doc_type_resolution_order`: one doc per tier, plus `other`.
    - `test_status_sources`: doc-index `deprecated`; `superseded_by` → `superseded`; front matter `status: Accepted` → `accepted`; `**Status:** Draft — 2026-10-19` → `draft`.
    - `test_heading_path_at`: nested H1/H2/H3, a `#` line inside a fence that is ignored, and a line before any heading giving `(title,)`.
    - `test_allowed_filters`: type, prefix, and terminal included vs excluded.
    - `test_enrichment_tolerates_bad_files` *(Review Focus 2)*: Latin-1 text, a 2 MiB `.md`, a binary `.md`, and a file removed after `files()`. `meta()` returns `None` for each, `skipped()` names all four, and nothing raises.
- [ ] **Step 2: Run them to see them fail.** `uv run --project search --frozen pytest search/tests/test_repo.py search/tests/test_docindex.py search/tests/test_corpus.py -q`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(search): repo helpers, doc-index reader, corpus discovery and enrichment"`

---

### Task 3: semble engines — per-worktree index pairs

**Files:**
- Create: `search/src/doc_search/engines.py`, `search/tests/test_engines.py`

**Interfaces:**
- Consumes: `Config`, `RepoInfo` (Tasks 1–2).
- Produces:
  - `WorktreeIndexes`: `docs: SembleIndex | None`, `code: SembleIndex | None`, `built_at: dict[str, float]`, `build_seconds: dict[str, float]`, `error: dict[str, str]`.
  - `IndexPool(cfg: Config, max_worktrees: int = 2, clock=time.monotonic)`:
    - `.get(worktree: Path, wait_s: float = 20.0) -> WorktreeIndexes | Building`
      - Starts a background build on first use and waits up to `wait_s`.
      - Returns `Building(worktree, docs_ready: bool, code_ready: bool)` when that time runs out.
      - Revalidates per the Global Constraints cooldown.
      - LRU-evicts beyond `max_worktrees`.
    - `.indexed_files(worktree, kind) -> set[str]` (from `index.chunks`).
    - `.semble_version() -> str`.
  - Load path: `get_validated_cache` → `SembleIndex.load_from_disk`. Otherwise `SembleIndex.from_path` → `save_index_to_cache`. A `code.enabled == False` config never builds the code index. Build exceptions are caught into `error[kind]` and never raised to callers.

- [ ] **Step 1: Write the failing tests** (`tiny_model` and `git_repo`):
  - `test_builds_both_and_reuses_cache`: the second `IndexPool` on the same worktree loads from disk. Assert it by monkeypatching `SembleIndex.from_path` to count calls: 0 the second time.
  - `test_revalidate_after_edit`: edit a doc and advance the injected clock past the cooldown → the new text is searchable.
  - `test_lru_two_worktrees`.
  - `test_code_disabled`.
  - `test_build_error_captured`: a `model_path` that doesn't exist → `error["docs"]` set, and no exception.
  - `test_get_returns_building_after_wait`: `from_path` monkeypatched to sleep 1 s, `wait_s=0.1` → `Building`.
- [ ] **Step 2: Run them to see them fail.** `uv run --project search --frozen pytest search/tests/test_engines.py -q`.
- [ ] **Step 3: Implement** with a `threading.Thread` per build and a `threading.Event` per kind.
- [ ] **Step 4: Run them to see them pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(search): per-worktree semble index pool"`

---

### Task 4: Fusion, searcher and rendering

**Files:**
- Create: `search/src/doc_search/{fusion,searcher,render}.py`, `search/tests/{test_fusion,test_searcher,test_render}.py`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `rrf(lists: Sequence[Sequence[K]], k: int = 60) -> list[tuple[K, float]]`
  - `collapse_by_file(hits: list[Hit]) -> list[Hit]` (best per path; sets `more_in_file`)
  - `interleave_with_floor(docs: list[Hit], code: list[Hit], limit: int) -> list[Hit]`
  - `Searcher(cfg: Config, repo: RepoInfo, pool: IndexPool, corpus_for: Callable[[Path], Corpus], cloud: CloudLeg | None = None)`:
    - `.search(req: SearchRequest, worktree: Path) -> SearchResponse | str`
    - The `str` return is a one-line answer: inert, building, invalid, or code off for `scope=code`.
    - `CloudLeg` is defined in Task 7. Type it as a Protocol here: `.hits(query, allowed: set[str], worktree: Path, limit: int) -> tuple[list[Hit], str | None]`.
  - `render_search(resp: SearchResponse, cap: int = 8000) -> str`. Format per spec §6:
    - The header line: `doc-search · docs: semble <model> [(+cloud: <model>)] · code: semble <ver>|off · <n> hits`, plus a `note:` line per header note.
    - Hit lines: `N. [doc|code] path:start-end[ · Heading › Path][ · type][ · status][ (+N more in this file)]`.
    - Snippets: 3-space indented, ≤ 6 lines.
    - Link lines: `code: a, b, c (+N)` / `documented by: …`.
    - When truncated, the last line is `(truncated at 8000 chars)`.
- Behavior:
  - `allowed = corpus.allowed(...)`. If `allowed` ∩ `pool.indexed_files(worktree, "docs")` is empty, the docs leg returns `[]` **without calling semble** (Review Focus 1).
  - The docs leg is `docs.search(q, top_k=limit*3, filter_paths=sorted(allowed ∩ indexed))`. Hits whose path is not in `allowed` are dropped as a second guard.
  - Code-leg hits with `corpus.contains(path)` become doc hits when the path is in `allowed`, and are dropped otherwise.
  - Every doc hit is enriched with `heading_path_at`, `meta`, and `links = meta.code_refs`. Code hits get `links = docindex.docs_covering(path)`.
  - Docs fused = `collapse_by_file(rrf([docs_leg, cloud_leg]))`. With `scope=all`, the result is `interleave_with_floor` over that and the code leg.

- [ ] **Step 1: Write the failing tests.**
  - `test_fusion.py`:
    - `test_rrf_known_values`: `[a, b, c]` and `[b, a]` → `b`, `a`, `c`; scores `1/61 + 1/62` etc. to 1e-9.
    - `test_floor_guarantees_each_kind`: 10 docs and 10 code with docs stronger, limit 10 → ≥ 4 code.
    - `test_floor_when_one_kind_short`.
    - `test_collapse_counts_more_in_file`.
  - `test_searcher.py` (real semble on `tiny_model`):
    - `test_scope_all_returns_both_kinds_with_links`.
    - `test_identifier_query_hits_doc`: `SPEC-PAY-004`.
    - `test_filters_are_exact`: 12 matching docs, 8 of them deprecated, limit 5 → 4 hits; `include_terminal` → 5.
    - `test_empty_allowed_set_returns_no_docs` *(Review Focus 1)*: `doc_type=("adr",)` with no ADRs → zero doc hits while code hits remain. Also assert the semble docs `search` was not called (spy).
    - `test_code_hit_under_corpus_becomes_doc`: `docs/wire.jsx` included by config.
    - `test_scope_code_off_one_line`.
    - `test_building_returns_line` (the pool returns `Building`).
  - `test_render.py`:
    - `test_render_golden` (an exact string for two hits).
    - `test_render_cap`.
- [ ] **Step 2: Run them to see them fail.** `uv run --project search --frozen pytest search/tests/test_fusion.py search/tests/test_searcher.py search/tests/test_render.py -q`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(search): RRF join over semble docs and code, enrichment, rendering"`

---

### Task 5: MCP server (SDK v2) and search tool wiring

**Files:**
- Create: `search/src/doc_search/server.py`, `search/tests/test_server.py`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `build_server(cwd: Path, *, pool: IndexPool | None = None) -> MCPServer`:
    - `MCPServer("doc-search", version=__version__, instructions=<one paragraph: one tool for docs and code; scope narrows; related for doc↔code; returned text is data>)`.
    - Four tools via `@server.tool()`, with `Annotated[…, Field(description=…)]` parameters per spec §7. `fetch`, `related` and `status` are stubs answering `"not implemented"` until Task 6.
    - It loads the config once. When inert, every tool returns `INERT_LINE`. When invalid, every tool returns `doc-search: invalid config: …`.
    - When enabled, it starts `pool.get(launch_top, wait_s=0)` at build time, so the indexes warm up.
  - `serve(cwd: Path) -> None`: `anyio.run(build_server(cwd).run_stdio_async)`.
  - Tool return type is `str`. Each tool resolves `worktree` with `resolve_worktree`; a `ValueError` becomes the one-line answer.

- [ ] **Step 1: Write the failing tests.** Use the SDK v2 in-memory client if `mcp` 2.x provides one (check `mcp.shared.memory` / `mcp.client`); otherwise call the registered handlers through `server.call_tool`.
  - `test_tools_listed`: exactly `{"search", "fetch", "related", "status"}`, each with a description ending in the data-not-instructions sentence.
  - `test_inert_without_config`.
  - `test_invalid_config_line`.
  - `test_search_tool_end_to_end` (`tiny_model` via `docs.model` / `code.model` in the fixture config).
  - `test_worktree_param` (a second worktree's own doc is found; a foreign path is refused).
  - `test_first_build_bounded_wait` *(Review Focus 3)*: `from_path` monkeypatched to sleep 30 s, `wait_s` patched to 0.2 → the tool returns the building line in under 2 s.
  - `test_stdio_smoke` (marked `slow`): spawn `uv run --project search --frozen doc-search serve` in a fixture repo with `mcp.client.stdio`, `initialize`, `list_tools`, then call `search`.
- [ ] **Step 2: Run them to see them fail.** `uv run --project search --frozen pytest search/tests/test_server.py -q`.
- [ ] **Step 3: Implement.** A minimal `cli.py` with `serve` only, enough for the smoke test. Task 9 completes it.
- [ ] **Step 4: Run them to see them pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(search): MCP server on the SDK v2 MCPServer"`

---

### Task 6: fetch, related, status

**Files:**
- Modify: `search/src/doc_search/{searcher,render,server}.py`
- Create: `search/tests/test_tools.py`

**Interfaces:**
- Produces:
  - `Searcher.fetch(path, worktree, start_line=None, end_line=None, line=None, context=20) -> str`: rendered output, at most 400 lines, confined. Corpus docs get the header `<title> · <type>[ · <status>] · code: …`.
  - `Searcher.related(path, worktree, line=None, limit=10) -> str`:
    - **Doc:** metadata, `code_refs`, `replaces` / `superseded_by`, and "see also" from `docs.find_related(chunk)`. The chunk is the one containing `line`, or the file's first chunk. Results are restricted to corpus paths.
    - **Code:** `docs_covering`, plus `code.find_related(chunk)` when `line` is given.
  - `Searcher.status(worktree) -> str`, with these fields:
    - `config`, `docs model`, `code model`, `semble <version>`
    - per kind: `chunks`, `files`, `last build`, `build seconds`, `error`
    - `corpus files: N; not in semble's docs index: M` (first 5 listed, with `check .sembleignore` when M > 0)
    - `skipped: …`
    - `doc-index: present|absent`
    - the cloud lines (Task 7)

- [ ] **Step 1: Write the failing tests:**
  - `test_fetch_ranges_and_cap`.
  - `test_fetch_and_related_confined` *(Review Focus 5)*: `"../x"`, `"/etc/passwd"`, `".git/config"`, an outward symlink, and a foreign worktree all get one-line refusals.
  - `test_related_doc_see_also_and_refs`.
  - `test_related_code_documented_by`.
  - `test_status_reports_unindexed_corpus` *(Review Focus 2)*: a `.sembleignore` excluding `docs/b.md` → `not in semble's docs index: 1` and the hint.
  - `test_status_fields`.
- [ ] **Step 2: Run them to see them fail.** `uv run --project search --frozen pytest search/tests/test_tools.py -q`.
- [ ] **Step 3: Implement**, and wire the three tools in `server.py`.
- [ ] **Step 4: Run them to see them pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(search): fetch, related and status tools"`

---

### Task 7: Cloud read leg (Vertex + Firestore)

**Files:**
- Create: `search/src/doc_search/cloud/{__init__,vertex,read}.py`, `search/tests/fakes.py`, `search/tests/test_cloud_read.py`
- Modify: `search/src/doc_search/{searcher,server}.py` (build a `CloudLeg` when `cfg.cloud`)

**Interfaces:**
- Produces:
  - `VertexEmbedder(cfg: CloudCfg, client=None)`:
    - `.embed_query(text) -> np.ndarray` and `.embed_documents(texts) -> np.ndarray` (unit rows, batches of 200, retry policy per Global Constraints).
    - `.id = f"vertex:{model}/{dimensions}"`.
    - Raises `CloudUnavailable(reason)` when `google-genai` is not importable or the project is missing.
  - `CloudLeg(cfg: CloudCfg, embedder: VertexEmbedder, client=None)`:
    - `.stamp() -> CorpusStamp | None`, cached for 60 s.
    - `.hits(query, allowed: set[str], worktree: Path, limit: int) -> tuple[list[Hit], str | None]`. The second item is a note for the header, e.g. `cloud skipped: stamp <sha> not fetched` or `cloud failed: <reason>`.
    - Remote hits for paths in `diff_names(worktree, stamp)` or outside `allowed` are dropped.
    - Line ranges come from `startLine` / `endLine` when present. Otherwise they come from locating the chunk text in the working-tree file, falling back to `1-1`.
    - `.status_lines(worktree) -> list[str]`: stamp, `base_ref` relation (`current` / `behind N` / `not an ancestor`), branch-changed count. It never streams the collection.
  - `fakes.py`:
    - `FakeFirestore`: `collection().where().find_nearest()` computing cosine `vector_distance` over stored vectors, plus `document().get()`, `transaction`, `batch`, `stream`, with call counters.
    - `FakeGenai`: records `embed_content` calls and returns deterministic vectors.

- [ ] **Step 1: Write the failing tests:**
  - `test_vertex_batches_retries_normalizes`: 450 texts → `[200, 200, 50]`; a first 429 is retried; outputs are unit vectors.
  - `test_cloud_hits_and_doc_type_prefilter`.
  - `test_branch_changed_paths_suppressed`: a doc edited on the branch → only the local leg's hit appears for it.
  - `test_status_never_streams_collection`.
  - `test_cloud_failure_degrades_to_local` *(Review Focus 4)*: the embedder raises `CloudUnavailable("no credentials")` → search returns the local hits and the header note `cloud failed: no credentials`. Repeat with a stamp commit that isn't fetched → `cloud skipped: stamp … not fetched`.
  - `test_cloud_leg_fused_in_docs`: one doc hit only from cloud, another only from the local leg → both are present, and a doc found by both ranks first.
- [ ] **Step 2: Run them to see them fail.** `uv run --project search --frozen --all-extras pytest search/tests/test_cloud_read.py -q`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(search): optional Vertex/Firestore docs leg with branch suppression"`

---

### Task 8: Cloud write path and its chunker

**Files:**
- Create: `search/src/doc_search/chunker.py`, `search/src/doc_search/cloud/write.py`, `search/tests/{test_chunker,test_cloud_write}.py`

**Interfaces:**
- Produces:
  - `chunk_markdown(path, text, title, heading_level=3, target=1600) -> list[CloudChunk]`, where `CloudChunk(ordinal, start_line, end_line, heading_path, text)`. Behavior:
    - Front matter is stripped, and line numbers stay true to the file.
    - Sections are bounded at headings ≤ `heading_level`, and headings inside fences are ignored.
    - A section under 25% of `target` merges with its next sibling.
    - A large section splits at blank lines, then at lines, with about 15% line overlap.
    - Fences stay whole up to 6,000 characters.
  - `chunk_lines(path, text, title, target=1600) -> list[CloudChunk]` for non-markdown files.
  - `CloudIndexer(cfg: Config, top: Path, embedder: VertexEmbedder, client=None, clock=time.time, holder: str | None = None)`:
    - `.run(mode: Literal["catch-up", "full", "prune-orphans"], allow_off_base=False) -> IndexReport(mode, files_written, files_deleted, orphans_removed, files_failed: dict[str, str], stamped: bool, stamp: str | None)`.
  - Exceptions `BaseRefError`, `LeaseHeld(holder, expires_at)`.
  - The steps, in order, per spec §8:
    1. Resolve `base_ref`: config value, else `origin/` + `git symbolic-ref --short refs/remotes/origin/HEAD` minus `origin/`.
    2. Base guard.
    3. Transactional lease (TTL 1800 s), released in `finally`.
    4. Build the file set (catch-up falls back to full).
    5. Per-file sha256 check against the stored chunk 0's `fileSha256`, then delete-then-write in batches of ≤ 500 ops. `docType` comes from `Corpus.meta`.
    6. Deletes confirmed by `git ls-tree HEAD -- <path>` being empty.
    7. Orphans (on `full` and `prune-orphans`).
    8. Stamp only when `files_failed` is empty.

- [ ] **Step 1: Write the failing tests.**
  - `test_chunker.py`:
    - `test_sections_bound_chunks_and_small_merge`.
    - `test_large_section_overlap`.
    - `test_fence_whole_until_cap`.
    - `test_line_ranges_true_to_file` (4 lines of front matter → the first chunk starts at line 5; each chunk's text equals the file lines in its range).
    - `test_level4_not_split`.
    - `test_chunk_lines_windows`.
  - `test_cloud_write.py`:
    - `test_refuses_off_base` (and `allow_off_base` runs).
    - `test_lease_held_and_expired`.
    - `test_full_then_catch_up_only_changed`.
    - `test_catch_up_falls_back_without_stamp`.
    - `test_same_sha_skipped`.
    - `test_delete_requires_ls_tree`.
    - `test_orphans_reconciled`.
    - `test_no_stamp_on_failure`.
    - `test_schema_fields_exact`: exactly the 10 fields, with `embedding` 768-d.
- [ ] **Step 2: Run them to see them fail.** `uv run --project search --frozen --all-extras pytest search/tests/test_chunker.py search/tests/test_cloud_write.py -q`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(search): guarded cloud indexer and heading-bounded chunker"`

---

### Task 9: CLI and eval

**Files:**
- Create: `search/src/doc_search/evaluate.py`, `search/tests/test_cli.py`
- Modify: `search/src/doc_search/cli.py`

**Interfaces:**
- Produces:
  - `main(argv: list[str] | None = None) -> int`, an argparse subclass whose `error()` exits 3. Error mapping:
    - `ConfigError`, `NotARepo`, `CloudUnavailable` (on `index --cloud`), `BaseRefError` and `LeaseHeld` → one stderr line, exit 2.
    - `index --cloud` exits 1 when `files_failed` is non-empty.
  - **`init`:** writes the defaults (2-space JSON, trailing newline), with `docs.include` widened by `"<dir>/**/*.md"` for each top-level directory except `docs/` that holds tracked markdown. Prints its choices. If the file exists, prints `doc-search: docs/search/config.json exists; not changed` and exits 0.
  - **`index`:** without `--cloud`, builds both indexes in the foreground through `IndexPool.get(wait_s=inf)` and prints the chunks and seconds per kind. With `--cloud`, runs `CloudIndexer`.
  - **`query`:** prints `render_search`, or `{"header": …, "hits": [asdict…]}` with `--format json`.
  - **`status [--format json]`:** JSON is `{"enabled": bool, …}`.
  - **`eval`:** `run_eval(searcher, pool, path, k, worktree) -> EvalReport`.
    - Legs `docs`, `code`, `cloud` (when on), `all`, `semble-single`. `semble-single` is built by `SembleIndex.from_path(worktree, content=[DOCS, CODE], model_path=cfg.docs.model)`, queried at top k×3 and deduplicated per file.
    - Reports recall@k and MRR per leg. Expected paths are compared per file.
    - A malformed line exits 3 and names the line number.
    - `--min-recall` exits 1 when the `all` leg's recall@k is below it.
    - The last line reads `semble-single within 0.02 of joined (recall@k and MRR): yes|no`.

- [ ] **Step 1: Write the failing tests:**
  - `test_exit_codes` (unknown verb 3; outside a repo 2; inert status 0 with `INERT_LINE`; invalid config 2).
  - `test_init_writes_once_and_widens`.
  - `test_query_json_shape`.
  - `test_index_local_builds`.
  - `test_eval_legs_and_decision_line`.
  - `test_eval_malformed_line_exit_3`.
  - `test_eval_min_recall_exit_1`.
- [ ] **Step 2: Run them to see them fail.** `uv run --project search --frozen --all-extras pytest search/tests/test_cli.py -q`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass,** then the whole suite: `uv run --project search --frozen --all-extras pytest search/tests -q`.
- [ ] **Step 5: Commit.** `git commit -m "feat(search): CLI — init, index, query, status, eval"`

---

### Task 10: Launcher and the installer's `--search` set

**Files:**
- Create: `scripts/search/launch.sh`
- Modify: `scripts/hooks/install.sh` (usage, flags, `preflight_search` / `install_search` / `uninstall_search` / `status_search`, the `status --json` member `"search"`), `scripts/test-hooks.sh`, and the shellcheck / bash-4 guard file lists in `scripts/test-doc-tools.sh` if they are explicit.

**Interfaces:**
- **Launcher** (spec §10):
  - Root resolution, in order:
    1. `$DOC_SUPERPOWERS_ROOT` when `$DOC_SUPERPOWERS_ROOT/search/pyproject.toml` exists.
    2. `git rev-parse --show-toplevel` when it has `search/pyproject.toml` and `scripts/doc-tools.sh`.
    3. The newest numeric `X.Y.Z` directory under `${CLAUDE_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}/*/doc-superpowers/` that has `search/pyproject.toml`. Order with `grep -Ex "[0-9]+[.][0-9]+[.][0-9]+" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1`.
  - Failures, each exit 2:
    - no root: `doc-search: cannot find doc-superpowers (set DOC_SUPERPOWERS_ROOT)`
    - no uv: `doc-search: uv not found (https://docs.astral.sh/uv/)`
  - Extras: `--extra cloud` when `jq -e '.cloud != null' docs/search/config.json` succeeds; `--all-extras` when `jq` is absent.
  - It ends with `exec uv run --project "$ROOT/search" --frozen $EXTRAS doc-search "$@"`.
- **Installer:**
  - `--search` is never part of `--all`.
  - Install without the config prints `ERROR: install --search needs docs/search/config.json, which this repository does not have: doc-search is not enabled here (doc-search init sets it up). Nothing was changed.` and exits 1.
  - Install copies the launcher to `.claude/doc-superpowers/search-mcp.sh` (755) and, via jq, sets `.mcpServers["doc-search"] = {"command":"sh","args":[".claude/doc-superpowers/search-mcp.sh","serve"]}`, preserving everything else. It creates `.mcp.json` if absent. A non-object `.mcp.json` → exit 1 with nothing changed.
  - Install is idempotent, byte for byte.
  - Uninstall removes the key and the launcher, and deletes `.mcp.json` if it becomes exactly `{"mcpServers":{}}`.
  - Status header: `doc-search MCP (the opt-in --search set):`.
    - launcher: `installed` / `outdated: differs from the plugin's scripts/search/launch.sh` / `not installed`
    - entry: `registered` / `registered with a different command` / `not registered`
  - JSON: `"search": {"launcher": "...", "mcp_entry": "..."}`.

- [ ] **Step 1: Write the failing shell tests** in `scripts/test-hooks.sh`, in its existing fixture and assert style:
  - `test_search_install_refused_without_config`
  - `test_search_install_writes_launcher_and_entry` (another server survives)
  - `test_search_install_idempotent`
  - `test_search_install_refuses_non_object_mcp_json`
  - `test_search_not_in_all`
  - `test_search_uninstall_removes_only_ours`
  - `test_search_status_and_json`
  - `test_launcher_resolution_order` (a fake `uv` echoing its args; env root wins; dogfood; the plugin cache picks `10.0.0` over `9.9.9`; none → exit 2 with the message)
  - `test_launcher_cloud_extra`
  - `test_launcher_without_uv`
- [ ] **Step 2: Run them to see them fail.** `bash scripts/check-ci.sh --bash /bin/bash hooks`.
- [ ] **Step 3: Implement.** Mirror `preflight_ledger_config` and the `--ledger` plumbing, and write through `tmp_beside` / `commit_tmp`.
- [ ] **Step 4: Run them to see them pass.** `bash scripts/check-ci.sh hooks doc-tools`: PASS under both interpreters.
- [ ] **Step 5: Commit.** `git commit -m "feat(hooks): opt-in --search set — doc-search launcher and .mcp.json entry"`

---

### Task 11: CI wiring

**Files:**
- Modify: `scripts/check-ci.sh`, `.github/workflows/tests.yml`, `scripts/test-hooks.sh` (the check-ci stub tests learn `search`)

**Interfaces:**
- `check-ci.sh search` runs `uv run --project "$ROOT/search" --frozen --all-extras pytest -q` once.
  - It is in the default run, not in `--fast`.
  - `DOC_SP_REQUIRE_UV` defaults to 1: a missing `uv` FAILs, and `0` turns that into a loud SKIP.
  - Summary line: `search (pytest): PASS|FAIL|SKIP`.
- `tests.yml`: an `astral-sh/setup-uv` step pinned by commit sha with a version comment, then `"$BASH_BIN" scripts/check-ci.sh --bash "$BASH_BIN" --verbose search`, on both legs.

- [ ] **Step 1: Write the failing test.** `check-ci.sh --list` names `search`, and `DOC_SP_REQUIRE_UV=0` with no `uv` on PATH gives the SKIP line.
- [ ] **Step 2: Run it to see it fail.** `bash scripts/check-ci.sh hooks`.
- [ ] **Step 3: Implement.** Get the sha via `gh api repos/astral-sh/setup-uv/releases/latest --jq .tag_name`, then `gh api repos/astral-sh/setup-uv/git/ref/tags/<tag> --jq .object.sha`.
- [ ] **Step 4: Run it to see it pass.** `bash scripts/check-ci.sh search hooks`.
- [ ] **Step 5: Commit.** `git commit -m "ci: run the doc-search pytest suite (check-ci.sh search)"`

---

### Task 12: Documentation and pins

**Files:**
- Create: `references/search.md`
- Modify:
  - `skills/doc-superpowers/SKILL.md`: references row; quick-reference `hooks` mention of `--search`; one advisory sentence in `audit` and `review-pr`
  - `references/hooks.md`
  - `references/tool-mappings.md`
  - `README.md`, `AGENTS.md`
  - `CLAUDE.md`: tree, key-files rows, commands, Testing with the pytest count and the `search` check
  - `docs/codebase-guide.md`
  - `docs/.doc-index.json`, via `scripts/doc-tools.sh add-entry` (the spec as `design-spec`, the plan as `plan`) and `update-index` for touched living docs
  - `scripts/test-spec-status-model.sh`

`references/search.md` has these sections, in order:
1. `## Turning it on`: `doc-search init`, then `install.sh install --search`; the inert contract.
2. `## Modes`: local, plus the optional cloud leg, and when to add it.
3. `## Configuration`: the keys table and the environment.
4. `## CLI`: verbs and exit codes.
5. `## Tools`: the four tools and `worktree`.
6. `## Cloud leg`. It covers:
   - the setup, with the gcloud vector-index command:

     ```
     gcloud firestore indexes composite create --collection-group=doc_chunks --query-scope=COLLECTION --field-config=field-path=embedding,vector-config='{"dimension":"768","flat":"{}"}' --database=<db>
     ```

     plus a `docType`-prefixed variant
   - the named-database recommendation
   - the write path's guards
7. `## Other clients`: Cursor, Codex, Gemini and OpenCode snippets running `sh .claude/doc-superpowers/search-mcp.sh serve`, each marked *unverified* where not checked.
8. `## Hardware and performance`: M-series minimum; Intel slower; Docker when a wheel is missing; §4's measured numbers.
9. `## Privacy`.
10. `## Troubleshooting`: `status`, and `.sembleignore` excluding docs.

- [ ] **Step 1: Write the failing pins** in `test-spec-status-model.sh`: the file exists, SKILL.md names it, and the ten headings above are present.
- [ ] **Step 2: Run them to see them fail.** `bash scripts/check-ci.sh spec-status-model`.
- [ ] **Step 3: Write the docs.** The SKILL.md description stays ≤ 1,536 characters.
- [ ] **Step 4: Run the full gate.** `bash scripts/check-ci.sh`: every check passes (`tag` WARN locally), and the leak scan is clean.
- [ ] **Step 5: Commit.** `git commit -m "docs: doc-search reference, skill wiring and index entries"`

---

### Task 13: Tonight's eval (scratchpad only, no commits unless it finds a defect)

- [ ] **Step 1: Build the eval set.** `eval.jsonl` combines abundance's five `test_known_answers.py` pairs with about 50 authored paraphrase queries and about 10 identifier queries over a stratified sample of abundance's docs. It lives in the scratchpad.
- [ ] **Step 2: Run doc-search against abundance.** In a scratch `git worktree add` of abundance `origin/main` (never the live checkout):
  - write a temporary `docs/search/config.json` (§11 step 2, with `cloud` pointing at the existing corpus, read-only)
  - drop the `docs/` lines from that worktree's `.sembleignore`
  - run `doc-search index`, then `doc-search eval eval.jsonl` twice: `docs.model` null, then `minishlab/potion-retrieval-32M`
- [ ] **Step 3: Run the gte spike.** Take a docs subset (every expected doc plus 450 seeded random distractors) copied into a scratch repo. Index it with semble, using the §4 encoder adapter for gte-modernbert int8 ONNX injected at `semble.index.dense._load_cached`. Score the same queries, and score the other legs on the same subset.
- [ ] **Step 4: Report.** Put the per-leg recall@10 and MRR, the build times, the query p50, and the §3(b) and §4 decision-rule outcomes in the PR description. If gte clears its rule, propose the follow-up as its own task.
