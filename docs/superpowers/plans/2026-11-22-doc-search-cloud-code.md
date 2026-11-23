# doc-search cloud code leg — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in cloud leg over code (Vertex embeddings in a Firestore collection), chosen per corpus (docs, code, both), fused into code results by shaped weighted RRF; a search the cloud did not answer says which kinds are local-only, and the agent asks the user before relying on it. Ships as v3.21.0.

**Architecture:** The cloud writer and reader are generalised over a *corpus description* (`cloud/corpora.py`): the docs corpus is today's behaviour, the code corpus is semble's chunks of the code index's files. The searcher runs a second cloud leg for `scope=code|all` and fuses it with the local code leg before the existing docs/code join. uv's offline setting stays the host's; the launcher only names the warm-up when an offline start lacks packages.

**Tech Stack:** Python ≥ 3.11 (uv project `search/`), semble 0.7.x, google-genai, google-cloud-firestore; POSIX sh (the launcher); bash test harness (`scripts/test-hooks.sh`).

**Spec:** `docs/superpowers/specs/2026-11-22-doc-search-cloud-code-design.md`

**Review record:** the consumer coordinator's review A (spec and plan) was folded in on 2026-11-22: all 12 Important and 10 Minor findings accepted, none rejected. One was resolved differently from its suggested fix: finding 3 (a note suffix breaks exact-match tests) — the notes keep their text and `local_only` is shown in the header line instead, so no existing note assertion changes. Review B (the design against the consumer as it runs) was folded in on 2026-11-23: the Critical and the doc-superpowers-side Important and Minor findings accepted (C1, I1, I3–I6, I8, M1, M5); the rest are the consumer's own changes. Two resolved differently: I3's first half (derive the chunker id from how chunks are cut) — the id stays `semble-<major>.<minor>`, which no semble patch changes under the `<0.8` pin, and a boundary-pin test catches a patch that moves cuts; its second half (resumable rewrites) is taken. I5 (skip the code cloud leg on identifier-shaped queries) is taken after re-scoring the spike's vectors: overall MRR 0.882 → 0.873, identifier MRR 0.983 → 0.967, recall unchanged.

## Global Constraints

- Config: `cloud.docs` boolean, default `true`; `cloud.code` object or `null`, default `null`; under `cloud.code`: `collection` (default `"code_chunks"`), `exclude` (glob list, default `[]`), `timeout_s` (number > 0, default `10`); unknown keys under `cloud.code` are errors; `cloud.docs: false` with `cloud.code: null` is an error; `cloud.code` with `code.enabled: false` is an error. The cross-checks run before the `DOC_SEARCH_CLOUD=0` override, so a bad config is reported whatever the environment.
- `check` reports the `requires` floor before parsing the rest of the config when the raw text's floor is above the running version.
- Code stamp document `<meta_collection>/code-index`; code lease `<meta_collection>/code_catch_up_lease`.
- Code query task `CODE_RETRIEVAL_QUERY`; document task `RETRIEVAL_DOCUMENT`; at most 6,000 characters of a chunk embedded.
- Code chunker id `semble-<major>.<minor>` (from `semble.__version__`) in the stamp field `chunker_id`; raised by hand (`semble-0.7.r2`) only when the boundary-pin test shows a lock bump moved cuts.
- Code scope (`CodeCloudCorpus.in_scope`, a path test only): what semble's walker would yield over HEAD (an extension in `get_extensions(content_types(cfg.code.content))`, not under semble's `_DEFAULT_IGNORED_DIRS`, not matched by any directory's `.gitignore` / `.sembleignore` blob at HEAD, with semble's matching semantics), not in the docs corpus (`Corpus.in_scope`), file name not matched (case-insensitive) by the deny list `*.pem *.key *.p12 *.pfx *.jks *.keystore *.tfvars *.tfvars.json .env .env.* *.env id_rsa* id_ed25519* id_ecdsa* *secret* *secrets* *credential* *credentials* .npmrc .pypirc .netrc`, path not matched by `cloud.code.exclude`. Read-time: over 1,000,000 bytes (`CODE_MAX_FILE_BYTES`, a fixed constant: never semble's env-overridable `MAX_FILE_BYTES`), binary or not UTF-8 → the file's chunks are purged.
- Code fields: `path`, `chunkIndex`, `text`, `startLine`, `endLine`, `fileSha256`, `chunkerId`, `embedderId`, `embedding`, `language`, `headingPath` (`[]`), `lastIndexedAt`; no `docType`. A rewrite skips a file whose chunk 0 has this run's sha, chunker and embedder.
- Fusion: RRF k = 60, cloud 10, local 1 (`CODE_CLOUD_WEIGHT = 10.0`); identifier-shaped queries never reach it.
- `index --cloud` output: one corpus run → byte-identical to today (no prefix, same exits). Two → report lines prefixed `docs: ` / `code: `; error lines at column 0, `doc-search: …`, ending ` (docs)` / ` (code)`; the lease refusal keeps `doc-search: the corpus lease is held by …`; exit = the highest non-lease-refusal exit, else 2 if a lease refused, else 0.
- Identifier-shaped: a whitespace word, stripped of `` `'"()[]{},:;?! `` and a final `.`, of ≥ 4 characters containing `_`, `.`, `/`, a digit, a lowercase-or-digit followed by an uppercase letter, or two uppercase letters followed by a lowercase one (so `APIs`, `URLs`, `HTTPServer` count; `CTA`, `end-to-end` do not).
- The code cloud leg: not run when the search has a `path_prefix` or the query is identifier-shaped; deadline `cloud.code.timeout_s + 5 + 1` s; allowed set = `pool.indexed_files(worktree, "code")` minus the docs corpus's files.
- Lease refusal text unchanged: `the corpus lease is held by …`.
- Notes: the docs leg's text unchanged; the code leg's read `cloud code failed: …` / `cloud code skipped: …`. `HeaderInfo.local_only: tuple[tuple[str, str], ...] = ()`, `(kind, reason)` pairs, docs before code, reason ∈ {`failed`, `timeout`, `no-stamp`, `building`}; the header line renders `local-only: code (failed)`, pairs joined by `, `.
- Launcher: `UV_OFFLINE` passed through, never set or cleared; on uv's `Network connectivity is disabled`, print spec §9's warm-up as one line (`doc-search: uv is offline and this release's packages are not cached; ask the user to run, with the network on: …`), with `UV_PROJECT_ENVIRONMENT` and `UV_CACHE_DIR` when set; `check` and `gate` answer through `answer_unrunnable`.
- Every existing test passes unchanged except where a task names the change. bash 3.2 for the launcher and its tests; no bash-4 construct.
- Leak rule: no machine paths, emails or consumer names in committed text (`scripts/leak-scan.sh`), and the hand check of Task 13.

## Review Focus

1. A repository on a pre-3.21 config (`cloud` set, no `docs` / `code` keys) behaves exactly as today: docs leg on, no code leg, same stamp, same lease, same notes, and `index --cloud` output byte-identical (a driver greps `^stamped: yes` and `^doc-search: the corpus lease is held by`) — pinned in Tasks 1, 4, 5 and 10.
2. Code a repository keeps out of its local index (`.sembleignore`, a nested `.gitignore`, `dist/`) or a secret-bearing file (`prod.tfvars`, `deploy/key.pem`, `.env.local`, `aws_credentials.json`) is never sent — pinned in Task 3.
3. A code file edited on the branch is never served from the cloud (its stale chunk would point at wrong lines) — pinned in Task 6.
4. With both corpora, a docs failure beside a code lease refusal exits 1, not 2, so a driver never reads it as "someone else is doing it" — pinned in Task 5.
5. A cold or slow code cloud leg (reason `timeout`) or a corpus not yet written (`no-stamp`) never asks the user, and never empties or delays code results past the code budget — pinned in Tasks 7 and 10.

---

### Task 1: Config keys `cloud.docs` and `cloud.code`

**Files:**
- Modify: `search/src/doc_search/config.py` (`CLOUD_DEFAULTS`, `CloudCfg`, `_cloud`, `load_config`), `search/src/doc_search/check.py` (the floor first)
- Leave: `scripts/setup/search-config.json` (`"cloud": null`)
- Test: `search/tests/test_config.py`, `search/tests/test_check.py`

**Interfaces:**
- Produces: `@dataclass(frozen=True) class CloudCodeCfg: collection: str; exclude: tuple[str, ...]; timeout_s: float`; `CloudCfg` gains `docs: bool = True` and `code: CloudCodeCfg | None = None` (defaults keep every existing constructor call valid); constants `CODE_STAMP_DOC = "code-index"`, `CODE_LEASE_DOC = "code_catch_up_lease"`, `DEFAULT_CODE_COLLECTION = "code_chunks"`, `DEFAULT_CODE_TIMEOUT_S = 10.0` in `config.py`.

- [ ] **Step 1: Write the failing tests** — `test_cloud_docs_defaults_true_and_code_off` (today's `cloud` object → `docs is True`, `code is None`); `test_cloud_code_empty_object_takes_defaults` (`"code": {}` → `("code_chunks", (), 10.0)`); `test_cloud_code_keys` (collection, exclude, timeout_s set); `test_cloud_nothing_on_is_an_error` (names `cloud.docs`); `test_cloud_code_needs_the_code_leg` (names `cloud.code`); `test_cloud_code_unknown_key` (`unknown key cloud.code.colection`); `test_cloud_docs_must_be_boolean`; `test_cloud_code_timeout_must_be_positive`; `test_cross_checks_run_with_cloud_off_by_env` (`DOC_SEARCH_CLOUD=0` + `docs:false`, no code → still `ConfigError`). check: `test_check_reports_the_floor_before_unknown_keys` (raw `requires: ">=99.0.0"` with an unknown key → the "plugin too old" verdict, not "invalid config").
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest tests/test_config.py tests/test_check.py -q` — the new tests FAIL.
- [ ] **Step 3: Implement** in `config.py`: `CLOUD_DEFAULTS` gains `"docs": True`, `"code": None`; `_reject_unknown` recurses into `cloud.code` when it is an object; `_cloud` parses both; the cross-checks run in `load_config` after `_code` and before the env override. In `check.py`, read `requires` from the raw JSON before `load_config`.
- [ ] **Step 4: Run** — PASS; then the whole suite `uv run --frozen --all-extras pytest -q` — PASS.
- [ ] **Step 5: Commit** `feat(doc-search): config keys cloud.docs and cloud.code`

### Task 2: Query task on the embedder

**Files:**
- Modify: `search/src/doc_search/cloud/vertex.py`
- Test: `search/tests/test_cloud_read.py` (where the embedder's query tests live; else a new `search/tests/test_vertex.py`)

**Interfaces:**
- Produces: `CODE_QUERY_TASK = "CODE_RETRIEVAL_QUERY"`; `VertexEmbedder.embed_query(self, text: str, task: str = QUERY_TASK) -> np.ndarray`.

- [ ] **Step 1: Test** `test_embed_query_passes_the_task` — with `FakeGenai`, `embed_query("q", CODE_QUERY_TASK)` records `task_type == "CODE_RETRIEVAL_QUERY"`; the default records `"RETRIEVAL_QUERY"`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** the parameter. **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(doc-search): the embedder takes the query task`

### Task 3: Corpus descriptions

**Files:**
- Create: `search/src/doc_search/cloud/corpora.py`
- Modify: `search/src/doc_search/engines.py` (rename `_content_types` → `content_types`, keep the old name as an alias)
- Modify: `search/src/doc_search/cloud/read.py` (`CorpusStamp` gains `chunker_id: str | None = None`; `_parse_stamp` reads it)
- Test: `search/tests/test_cloud_corpora.py`, `search/tests/test_semble_seam.py` (add `semble.chunking.chunking.chunk_source`, `semble.index.files.detect_language`, `get_extensions`, `semble.__version__`)

**Interfaces:**
- Produces, in `corpora.py`:
  - `class CloudCorpus(Protocol)`: attributes `name: Literal["docs", "code"]`, `collection: str`, `stamp_doc: str`, `lease_doc: str`, `query_task: str`, `hit_kind: Literal["doc", "code"]`, `note_prefix: str` (`"cloud"` / `"cloud code"`); methods `in_scope(self, path: str) -> bool` (path only), `readable(self, path: str, data: bytes) -> str | None` (the text, or `None` to purge), `chunks(self, path: str, text: str) -> list[CloudChunk]`, `fields(self, path: str, chunk: CloudChunk) -> dict[str, Any]` (beyond the common ones), `chunker_stamp(self) -> dict[str, Any]`, `chunker_matches(self, stamp: CorpusStamp) -> bool`, `resumable_current(self, chunk0: Mapping[str, Any] | None, sha: str) -> bool` (used by Task 4's rewrite).
  - `DocsCloudCorpus(cfg: Config, top: Path)`: today's behaviour — `collection = cfg.cloud.firestore.collection`, `stamp_doc = "index"`, `lease_doc = "catch_up_lease"`, `query_task = QUERY_TASK`, `hit_kind = "doc"`, scope `Corpus.in_scope`, `readable` = today's `_decode` with the 1 MiB limit, chunks by `chunk_markdown` / `chunk_lines` (moved from `CloudIndexer._chunks`), fields `docType` and `headingPath`, stamp `{"chunker_version": CHUNKER_VERSION}`, matches as `_plan` decides today.
  - `CodeCloudCorpus(cfg: Config, top: Path)`: `collection = cfg.cloud.code.collection`, `stamp_doc = CODE_STAMP_DOC`, `lease_doc = CODE_LEASE_DOC`, `query_task = CODE_QUERY_TASK`, `hit_kind = "code"`; scope and read-time rules per Global Constraints (`CODE_DENY: tuple[str, ...]`, `CODE_MAX_FILE_BYTES = 1_000_000`); `chunks` from `chunk_source(text, path, detect_language(PurePosixPath(path)))` mapped to `CloudChunk(ordinal, start_line, end_line, (), content[:6000])`; fields `{"language": …, "headingPath": []}`; stamp `{"chunker_id": "semble-<major>.<minor>"}`; matches when equal.
  - `corpora_for(cfg: Config, top: Path, only: str | None = None) -> list[CloudCorpus]`: the enabled corpora, docs first, `only` ∈ {`"docs"`, `"code"`, None}.

- [ ] **Step 1: Tests** — `test_docs_corpus_matches_todays_chunks`; `test_code_corpus_scope` (a `.py`, a `.swift` in; a `.md` in the docs corpus out even with `code.content: ["all"]`; a `.png` out; a deleted path answers without reading the file); `test_code_corpus_follows_sembleignore` (a root `.sembleignore` with `docs/archive/`, a nested `tools/.gitignore` with `gen/`, a `dist/app.js`, and a `.sembleignore` changed in the working tree but not committed → only HEAD's blobs count); `test_code_corpus_parity_with_semble_walker` (on a fixture repo with ignores at three depths and a negation `!keep.py`: the set equals `{p for p in semble.index.file_walker.walk_files(checkout, exts)}` minus the docs corpus); `test_code_corpus_deny_list` (`prod.tfvars`, `deploy/key.pem`, `.env.local`, `cfg/aws_credentials.json`, `Secrets.swift`, `ID_RSA.pub` out; `app/secretary.py` out too: `*secret*` is deliberately broad, and the test pins that); `test_code_corpus_exclude_globs`; `test_code_readable_limits` (1,000,000 bytes in, 1,000,001 → `None`, a NUL byte → `None`, invalid UTF-8 → `None`); `test_code_corpus_chunks_are_sembles` (line ranges equal `chunk_source`'s for a 3-function Python file); `test_code_chunk_boundaries_pinned` (fixture files in Python, Swift, TypeScript, Go, Kotlin and shell, each one's `(start, end)` list written out literally, so a semble patch that moves cuts fails here); `test_code_chunk_text_is_capped_at_6000`; `test_corpora_for_order_and_only`; `test_code_stamp_is_major_minor` (`semble-0.7`; a stamp `semble-0.8` does not match).
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest tests/test_cloud_corpora.py tests/test_semble_seam.py -q` — FAIL.
- [ ] **Step 3: Implement** `corpora.py`.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(doc-search): cloud corpus descriptions for docs and code`

### Task 4: The writer over a corpus

**Files:**
- Modify: `search/src/doc_search/cloud/write.py`
- Test: `search/tests/test_cloud_write.py`

**Interfaces:**
- Consumes: `CloudCorpus`, `DocsCloudCorpus`, `CodeCloudCorpus` (Task 3).
- Produces: `CloudIndexer(cfg, top, embedder, client=None, clock=time.time, holder=None, *, corpus: CloudCorpus | None = None)`; `None` means `DocsCloudCorpus(cfg, top)`. Every collection, stamp and lease name, the scope test, the read-time test, the chunking, the extra fields and the chunker check go through `corpus`.

- [ ] **Step 1: Tests** (existing tests unchanged) — `test_code_run_writes_code_fields` (a repo with `app.py` and `docs/guide.md`, code corpus → `code_chunks` holds only `app.py`, fields exactly the Global Constraints set); `test_code_run_stamps_code_index` (stamp at `corpus_meta/code-index` with `chunker_id`; `corpus_meta/index` untouched); `test_code_lease_is_its_own`; `test_code_catch_up_rewrites_only_changed_files`; `test_another_semble_makes_a_full_run`; `test_code_file_grown_past_limit_is_purged` (catch-up after `app.py` grows to 1,000,001 bytes → its chunks gone, stamp advanced); `test_code_file_turned_binary_is_purged`; `test_code_rewrite_resumes` (a rewrite for another embedder raises `LeaseLost` after 2 of 4 files; the next rewrite embeds only the other 2, and the stamp is written once, at the end); `test_code_rewrite_redoes_a_file_of_the_old_chunker` (chunk 0 with the old `chunkerId` and this sha → re-embedded); `test_docs_run_unchanged_by_code_config` (the docs documents have exactly today's fields: no `chunkerId`, no `embedderId`).
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest tests/test_cloud_write.py -q` — new ones FAIL, old ones PASS.
- [ ] **Step 3: Implement** the refactor: `_collection`, `_read_stamp`, `_write_stamp`, `_lease_ref`, `_work`'s scope test, `_decode` → `corpus.readable`, `_chunks`, `_replace`'s field dict and `_plan`'s chunker test read `self._corpus`; `_index_file`'s `rewrite` branch asks `corpus.resumable_current(chunk0, sha) -> bool` (code: sha, `chunkerId` and `embedderId` all match; docs: always `False`, today's behaviour).
- [ ] **Step 4: Run** — all PASS.
- [ ] **Step 5: Commit** `refactor(doc-search): the cloud writer writes any corpus; the code corpus`

### Task 5: `index --cloud --corpus`

**Files:**
- Modify: `search/src/doc_search/cli.py` (`index` parser, `make_indexer`, `_index_cloud`)
- Test: `search/tests/test_cli.py`

**Interfaces:**
- Consumes: `corpora_for` (Task 3), `CloudIndexer(..., corpus=)` (Task 4).
- Produces: `--corpus {docs,code}` on `index` (only with `--cloud`; usage error 3 otherwise); `make_indexer(cfg: Config, top: Path, corpus: CloudCorpus | None = None) -> CloudIndexer` (the seam keeps its name; `_index_cloud` passes `corpus` only for the code corpus, so the existing `lambda cfg, top` stubs at `test_cli.py:648,764`, which run docs-only configs, are called with two arguments and keep working); output and exit per Global Constraints (`index --cloud` output); `--corpus code` without `cloud.code` → exit 2 `doc-search: cloud code is not configured (set cloud.code)`.

- [ ] **Step 1: Tests** — `test_cloud_index_runs_docs_then_code` (every report line starts `docs: ` or `code: `, docs first); `test_cloud_index_corpus_code_only` (no prefix); `test_cloud_index_exit_is_the_worst` (docs 0, code 1 → 1); `test_cloud_index_lease_refusal_never_outranks_a_failure` (docs 1, code lease → exit 1, and a line matching `^doc-search: the corpus lease is held by .* \(code\)$`); `test_cloud_index_only_lease_refusals_exit_2`; `test_cloud_index_corpus_needs_cloud` (exit 3); `test_cloud_index_corpus_code_unconfigured` (exit 2, the message); `test_cloud_index_pre_320_config_is_todays_output` (stdout, stderr and exit byte-identical to a recorded fixture of today's output, for a written run, a no-op and a lease refusal).
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest tests/test_cli.py -q -k cloud_index` — FAIL (and the existing `test_cloud_index_*` PASS).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; then `tests/test_cli.py` whole — PASS.
- [ ] **Step 5: Commit** `feat(doc-search): index --cloud writes each configured corpus; --corpus picks one`

### Task 6: The reader over a corpus

**Files:**
- Modify: `search/src/doc_search/cloud/read.py` (`CloudLeg`, `DegradedLeg`, `build_cloud_leg`, `_git_lines`)
- Test: `search/tests/test_cloud_read.py`

**Interfaces:**
- Consumes: `CloudCorpus` (Task 3), `embed_query(text, task)` (Task 2).
- Produces: `CloudLeg(cfg, embedder, client=None, *, corpus: CloudCorpus | None = None, corpus_for=None, clock=..., deadline_s=None)`; for the code corpus `deadline_s` defaults to `cfg.cloud.code.timeout_s + 5`; hits carry `kind = corpus.hit_kind` and `legs=("cloud",)` for docs, `("cloud-code",)` for code; notes start with `corpus.note_prefix`; the code leg never sends a `docType` filter; `status_lines` prefix `cloud:` / `cloud code:`, with the stamp's `chunker_id` when set, and the branch-changed count filtered by `corpus.in_scope` (not the docs corpus); `build_cloud_legs(cfg: Config, top: Path, *, corpus_for=None) -> tuple[CloudLeg | DegradedLeg | None, CloudLeg | DegradedLeg | None]` (docs, code; `None` for a corpus not configured; a `DegradedLeg` for code words its notes `cloud code failed: …`). `build_cloud_leg` stays as the docs-only wrapper.

- [ ] **Step 1: Tests** — `test_code_leg_queries_the_code_collection_with_the_code_task`; `test_code_leg_drops_branch_changed_files`; `test_code_leg_hits_are_code_kind`; `test_code_leg_without_stamp_notes_code_index` (`cloud code skipped: no corpus stamp (corpus_meta/code-index)`); `test_code_degraded_leg_notes_say_cloud_code`; `test_status_lines_for_code` (the count is of changed code files, a changed `.md` not counted); `test_build_cloud_legs_per_config` (docs only / code only / both / neither). Existing note tests unchanged.
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest tests/test_cloud_read.py tests/test_cloud_unavailable.py -q` — new ones FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(doc-search): the cloud reader reads any corpus; the code leg`

### Task 7: Fusion and the searcher

**Files:**
- Modify: `search/src/doc_search/fusion.py`, `search/src/doc_search/searcher.py`
- Test: `search/tests/test_fusion.py`, `search/tests/test_searcher.py`

**Interfaces:**
- Consumes: the code `CloudLeg` (Task 6).
- Produces: `fusion.weighted_rrf(lists: Sequence[Sequence[K]], weights: Sequence[float], k: int = RRF_K) -> list[tuple[K, float]]` (`rrf` = `weighted_rrf` with weights 1); `fusion.identifier_shaped(query: str) -> bool`; `fusion.fuse_code(local: Sequence[Hit], cloud: Sequence[Hit]) -> list[Hit]` (each leg collapsed to its best chunk per file, the rest counted in `more_in_file`; local's chunk represents a file both found, `legs` naming both, `more_in_file` the sum; cloud 10 : local 1); `Searcher(..., cloud=None, code_cloud=None, ...)`; `Searcher.code_cloud_wait_s`.
- In `_search`: the code cloud leg starts on a `_Background` beside the docs one when `scope != "docs"`, `code.usable`, `code_cloud` is set, there is no `path_prefix` and `not identifier_shaped(query)`; allowed per Global Constraints; waited for at most `code_cloud_wait_s`. In the local code list, doc-kind hits keep their positions and `fuse_code(code-kind hits, cloud hits)` fills the other positions in order; the result joins the docs list by `interleave_with_floor` unchanged.

- [ ] **Step 1: Tests** — fusion: `test_identifier_shaped` (`ItemDetailSheet`, `make_index`, `a/b.py`, `v3.20`, `HTTPServer`, `getURL`, `APIs`, `` `make_index`, `` → True; `where is the refund rounded`, `end-to-end`, `CTA` → False); `test_weighted_rrf_weights`; `test_fuse_code_leans_on_cloud` (cloud's #1 above local's #1); `test_fuse_code_more_in_file_sums`. Searcher: `test_scope_code_fuses_the_code_cloud_leg`; `test_identifier_query_skips_the_code_cloud` (`make_index` → the leg is never called, hits = today's local code list); `test_scope_docs_never_asks_the_code_cloud`; `test_scope_all_doc_kind_code_hits_keep_their_place`; `test_code_cloud_failure_keeps_local_code`; `test_code_cloud_timeout_is_its_own_budget` (a leg sleeping past `code_cloud_wait_s` but within `cloud_wait_s` → local code hits, returned within `code_cloud_wait_s` + 1 s); `test_path_prefix_skips_the_code_cloud` (the leg is never called); `test_code_cloud_allowed_set_excludes_docs_corpus`; `test_no_code_cloud_is_todays_code_list`.
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest tests/test_fusion.py tests/test_searcher.py -q` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS, and the whole suite.
- [ ] **Step 5: Commit** `feat(doc-search): fuse the code cloud leg into code results`

### Task 8: Server, status and tools wiring

**Files:**
- Modify: `search/src/doc_search/server.py`, `search/src/doc_search/tools.py`, `search/src/doc_search/cli.py` (`status`)
- Test: `search/tests/test_tools.py`, `search/tests/test_cli.py`, `search/tests/test_server.py`

**Interfaces:**
- Consumes: `build_cloud_legs` (Task 6), `Searcher(code_cloud=)` (Task 7).
- Produces: `rt.code_cloud` beside `rt.cloud`; `status` (tool and CLI) prints the code cloud lines after the docs ones, within the same `STATUS_CLOUD_BUDGET_S`.

- [ ] **Step 1: Tests** — `test_status_shows_cloud_code_lines`; `test_server_builds_both_legs`; `test_status_without_cloud_code_is_unchanged`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(doc-search): status and the server know the code cloud leg`

### Task 9: Eval's `cloud-code` leg

**Files:**
- Modify: `search/src/doc_search/evaluate.py`, `search/src/doc_search/cli.py` (`eval`)
- Test: `search/tests/test_cli.py`

**Interfaces:**
- Produces: `LEG_ORDER = ("docs", "code", "cloud", "cloud-code", "all", "semble-single")`; `run_eval(..., cloud=None, code_cloud=None, corpus_for=None)`; the `cloud-code` ranker asks the code leg with the code index's files minus the docs corpus's at `k × SINGLE_FETCH`; the leg is absent from the report when `code_cloud` is `None` (so `test_cli.py:1221`'s list is unchanged).

- [ ] **Step 1: Tests** — `test_eval_reports_cloud_code_leg`; `test_eval_without_code_cloud_has_no_leg`; `test_eval_code_leg_is_fused_when_on`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** (and the module docstring's leg list). **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(doc-search): eval's cloud-code leg`

### Task 10: Local-only answers, the rule, and the offline warm-up message

**Files:**
- Modify: `search/src/doc_search/types.py` (`HeaderInfo.local_only: tuple[tuple[str, str], ...] = ()`), `search/src/doc_search/searcher.py` (set it; the legs return their reason beside the note, `CloudLeg.hits` gaining a third value only through a new method `hits_with_reason`, so existing two-value tests hold), `search/src/doc_search/render.py` (the header line; the structured output carries it)
- Modify: `references/search-rule.md` (widen the block's "use when"; spec §9 point 3's table, in as few words as the block's budget allows)
- Modify: `scripts/search/launch.sh` (only when `UV_OFFLINE` is set: an offline `uv sync` preflight before the final exec)
- Test: `search/tests/test_searcher.py`, `search/tests/test_render.py`, `scripts/test-hooks.sh` (new `test_launcher_names_the_offline_warm_up`, registered after `test_launcher_heals_half_installed_packages`), `scripts/test-spec-status-model.sh` if it pins the rule's lines

**Interfaces:**
- Consumes: the docs and code cloud legs' outcomes (Tasks 6, 7).
- Produces: `local_only` per spec §9 point 1 — `(kind, reason)` when its configured leg failed (`failed`), overran or is held back after an overrun (`timeout`), has no stamp (`no-stamp`), or (docs) was not started because the docs index is building (`building`); nothing when unconfigured, off by `DOC_SEARCH_CLOUD=0`, skipped for a `path_prefix`, an identifier-shaped query or an empty allowed set, or answered with zero hits and no note. Notes are not changed. The header line renders `local-only: docs (timeout), code (failed)` after the model labels.
- Launcher: with `UV_OFFLINE` set, `uv sync --project "$ROOT/search" --frozen --no-dev --inexact $EXTRAS` runs first, its stderr captured to a `mktemp` file removed on exit. On failure with `Network connectivity is disabled` in it: for `check` and `gate`, `answer_unrunnable` with the warm-up as the fix (gate exits 0 with hook JSON); for every other verb, print spec §9's one line (the root quoted with `pf_squote`; `UV_PROJECT_ENVIRONMENT='…'` and `UV_CACHE_DIR='…'` included only when set) first, then uv's own lines, exit 1. On another failure: uv's lines, the same exits, no warm-up line. On success `exec uv run … --no-sync`. Without `UV_OFFLINE` nothing changes.

- [ ] **Step 1: Tests** — searcher: `test_docs_cloud_failure_marks_docs_failed`; `test_code_cloud_timeout_marks_code_timeout`; `test_timeout_memory_keeps_reason_timeout` (the next search within 60 s, held back → still `timeout`, not `failed`); `test_code_cloud_without_stamp_marks_no_stamp`; `test_scope_all_partial_cloud` (docs answers, code fails → `(("code", "failed"),)`); `test_docs_index_building_marks_docs_building`; `test_no_cloud_is_not_local_only`; `test_cloud_off_by_env_is_not_local_only`; `test_cloud_answered_nothing_is_not_local_only`; `test_path_prefix_code_skip_is_not_local_only`; `test_identifier_query_is_not_local_only`; `test_scope_docs_ignores_code_cloud_failure`; the existing exact-notes test at `test_searcher.py:736` unchanged. Render: `test_header_shows_local_only`; `test_header_without_local_only_is_unchanged`. Launcher (the fake uv of `test_launcher_heals_half_installed_packages`, its sync exit code and stderr scripted): `UV_OFFLINE=1` + sync ok → one sync, then `uv run --no-sync`; + connectivity failure, `query` → exit 1, the first stderr line is the whole warm-up (`^doc-search: uv is offline .*ask the user to run, with the network on: env -u UV_OFFLINE .*uv sync --project '.*/search' --frozen --no-dev --inexact`) with the extras; + connectivity failure with `UV_PROJECT_ENVIRONMENT` and `UV_CACHE_DIR` set → both in the line; + connectivity failure, `check` → a not-ready verdict naming the warm-up; + connectivity failure, `gate` → exit 0, valid hook JSON; + another failure → uv's lines, no warm-up line; no `UV_OFFLINE` → no preflight, `uv run` as today; the launcher never sets or unsets `UV_OFFLINE` (the fake uv records the value it saw).
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest tests/test_searcher.py tests/test_render.py -q` and `bash scripts/check-ci.sh --bash /bin/bash hooks` — FAIL.
- [ ] **Step 3: Implement** (the launcher in POSIX sh; no bash-isms, the static gate checks).
- [ ] **Step 4: Run** under `/bin/bash` 3.2 and Homebrew bash — PASS.
- [ ] **Step 5: Commit** `feat(doc-search): say which results are local-only; name the offline warm-up`

### Task 11: Docs

**Files:**
- Modify: `references/search.md` (Configuration: the keys, the update order of spec §4; CLI: `--corpus`; Tools: the `local_only` field and the ask-before-relying rule, for every repository; Cloud leg: the code corpus, the index command of spec §5, fusion; Privacy: §10's text with the deny list and `exclude`; Hardware and performance: the spike's numbers, the flat-index caveat (the measured numbers come in Task 12); Troubleshooting: the offline warm-up line, `cloud code skipped: no corpus stamp`), `scripts/help/search.txt` (≤ 50 lines, ≤ 80 columns), `docs/codebase-guide.md` (`cloud/corpora.py`, the launcher preflight), `CLAUDE.md` (key-files rows for `search/` and the launcher; test counts)
- Not here: `RELEASE-NOTES.md` (Task 13: `check-ci.sh --fast` runs `check-version`, which an unreleased entry fails)
- Test: `bash scripts/check-ci.sh --fast`

- [ ] **Step 1: Write** the docs. **Step 2: Run** `bash scripts/check-ci.sh --fast` — PASS. **Step 3: Commit** `docs(doc-search): the cloud code leg and local-only answers`

### Task 12: Measure on the consumer's corpus

Owner-approved (2026-11-22): sending the consumer's code to Vertex and Firestore, `terraform apply` of the code index, the first code upload (about $5). Run in a scratch worktree of the consumer at its base branch; nothing is committed there in this task, and `cloud.code` stays out of the base branch's config throughout (the scratch config is an uncommitted edit of `docs/search/config.json` in the scratch worktree only).

**Who runs the writes.** The consumer's cloud corpus has one writer (its driver, which runs the pinned release), and its write guard denies any agent's `index --cloud`; only the owner lifts that guard. So the owner runs Steps 1 and 2 himself in his own terminal, from commands this task prints for him (the guard covers agent Bash calls, not his shell). The agent never runs a cloud write here and never asks for the guard to be lifted; if the owner prefers to lift it for one run, he says so in words in the session that runs it.

- [ ] **Step 1 (owner):** `terraform apply` in the consumer's `terraform/firestore` of the `code_chunks` vector index resource (added plan-only by the consumer's prep PR); wait for it to read `READY`.
- [ ] **Step 2 (owner):** in the scratch worktree, with `DOC_SUPERPOWERS_ROOT` at this branch's checkout and the scratch config adding `cloud.code`, `doc-search index --cloud --corpus code --full`; the agent records from its output and timing the wall time, the document count and the `_indexed_paths` scan time (against `SCAN_TIMEOUT_S` = 300).
- [ ] **Step 3:** A timing run of the 30 paraphrased code questions through `query --scope code` (the identifier ones skip the leg): the first search after a 30 min idle (cold) and the rest (warm); p50 and p95 of the code leg warm, the cold time, the end-to-end time, and Firestore reads per search from the project's usage metrics; plus `eval` recall@10 / MRR for `code`, `cloud-code` and `all` on all 60.
- [ ] **Step 4:** Gate: warm p95 of the code leg < `cloud.code.timeout_s` (10 s) and fused recall@10 ≥ 0.96 (the spike's 0.983, less one question). A cold time over the budget does not fail the gate (it is a `timeout`, which asks no one) but is reported. If the gate fails, stop and bring the numbers to the owner before Task 13. Reads (Step 3) need no guard lift.
- [ ] **Step 4b (owner, only if the gate fails and he decides not to ship the code leg):** remove what Steps 1–2 made: `gcloud firestore bulk-delete --collection-ids=code_chunks --database=<db>`, delete `<meta>/code-index` and `<meta>/code_catch_up_lease`, and revert the index resource (`terraform apply` without it). The docs collection and its stamp are never touched.
- [ ] **Step 5:** Put the numbers (no consumer name, no paths) into `references/search.md` → *Hardware and performance*; commit `docs(doc-search): measured code-leg latency and recall`.

### Task 13: Release v3.21.0

- [ ] **Step 1:** Add the v3.21.0 section to `RELEASE-NOTES.md` (Features, Fixes; not `### Security`), including that projects which copied the search-rule block must copy it again.
- [ ] **Step 2:** `bash scripts/doc-tools.sh bump-version 3.21.0 && bash scripts/doc-tools.sh check-version`, then `bash scripts/doc-tools.sh update-index` for the docs the stamps changed; commit `release: v3.21.0`, then `docs: re-baseline … after the v3.21.0 version stamps`.
- [ ] **Step 3:** `bash scripts/check-ci.sh` — every check PASS (the full gate; dep-audit needs the network).
- [ ] **Step 4:** Leak check by hand (the leak guard is off): `git diff main... | rg -i -n "<consumer and sibling-project names>"` and the same over `git log main..` messages → nothing; `bash scripts/leak-scan.sh` → clean.
- [ ] **Step 5:** PR to `main` (merge commit), the lightweight tag `v3.21.0` on the release commit, a GitHub release with the v3.21.0 notes section.
- [ ] **Step 6:** Tell the consumer coordinator: the tag, its peeled sha, the update order of spec §4, and the names that changed from its prep checklist (`HeaderInfo.local_only` is `(kind, reason)` pairs; `cloud.code.exclude`, `cloud.code.timeout_s`; the code index has no `__name__` field in the gcloud form; the two-corpus output prefixes and the ` (code)` suffix on error lines; the one-line warm-up).
