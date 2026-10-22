# doc-search local-transformer docs embedder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `docs.model: "transformer:gte-modernbert-base"` makes doc-search's docs index embed with gte-modernbert-base int8 ONNX inside semble, behind an opt-in extra, with a per-host content-addressed encode cache and a first build that never blocks search.

**Architecture:** A registry entry names the model; a loader patched in at semble's `semble.index.dense._load_cached` returns an ONNX `Encoder` for `transformer:` model paths, so semble builds, saves and loads the index as it does for its static models. The encoder reads and writes a sqlite (WAL) cache under the user cache directory, per batch. `IndexPool` runs transformer builds in a lane of their own, one encoder per host (an `flock`), and in server mode serves semble's static docs index until the transformer index is built, then swaps.

**Tech Stack:** Python ≥ 3.11, semble 0.7 (pinned `<0.8`), onnxruntime (1.31 on arm64 / Linux, 1.23.2 on Intel macOS), `tokenizers` and `huggingface_hub` (already semble's dependencies), sqlite3, uv, POSIX sh launcher, bash test harness.

**Spec:** `docs/superpowers/specs/2026-10-20-doc-search-local-transformer-design.md` §2 (what to build), §3 (costs), §5 (verification). Parent: `docs/superpowers/specs/2026-10-19-doc-search-design.md` §3(a), §4.

## Global Constraints

- Config value: `docs.model: "transformer:gte-modernbert-base"`. v1 registry: one entry — `Alibaba-NLP/gte-modernbert-base`, `onnx/model_int8.onnx`, CLS pooling, L2-normalized, 768-d, at most 1,024 tokens. Pin revision `e7f32e3c00f91d699e8c43b53106206bcc72bb22`.
- An unknown transformer name is a config error that names the key (`docs.model`). `code.model` refuses the `transformer:` prefix (code stays static).
- Extra `local-transformer` adds exactly `onnxruntime`, `flatbuffers`, `protobuf`. onnxruntime: `>=1.24` everywhere except Intel macOS, `>=1.23.2,<1.24` there.
- Missing extra: the docs leg fails with the line `docs.model transformer:<name> needs the local-transformer extra` (printed with the `doc-search: ` prefix wherever a docs error is a line).
- The launcher adds `--extra local-transformer` when `docs.model` is a string starting `transformer:`, after `--extra cloud` when both apply.
- semble stays pinned `semble>=0.7,<0.8`; a test pins every private semble name this feature uses.
- Threads: default = performance-core count − 2, at least 2 (`hw.perflevel0.physicalcpu` on macOS, `hw.physicalcpu` where that is absent, `os.cpu_count()` elsewhere); `docs.threads` (integer 1–256, or null) overrides. CPU execution provider only; CoreML stays off. Batches of 16, length-sorted.
- Encode cache: `<user cache>/doc-search/encode/<name>.sqlite` (macOS `~/Library/Caches/doc-search`, Linux `${XDG_CACHE_HOME:-~/.cache}/doc-search`; `DOC_SEARCH_CACHE_LOCATION`, an absolute path, overrides, as `SEMBLE_CACHE_LOCATION` does for semble). WAL mode. Key = sha256 of model id (repo@revision), ONNX variant, token limit, onnxruntime version, machine arch and the text. Value = float32 vector. Written per batch. Query strings never stored. No eviction. `status` shows its size.
- Server mode: while the transformer docs index builds, the docs leg serves semble's default docs index; the static index is kept until the transformer index validates, and only then is replaced.
- `status`: `docs: transformer index building, N / M chunks encoded, ETA …`; before encoding starts, an estimate from chunks × a per-arch rate (darwin arm64 16 chunks/s, darwin x86_64 3.6 chunks/s, none elsewhere). Intel macOS is allowed, with a warning.
- No RELEASE-NOTES, version or tag changes. No upstream semble issue (§6) without the owner's OK.
- Tests never touch the network or the user's caches (`HF_HUB_OFFLINE=1`; `SEMBLE_CACHE_LOCATION` and `DOC_SEARCH_CACHE_LOCATION` per test).

## Review Focus

- **Two server processes on one host** (two Claude sessions, two worktrees) both need the first transformer build: one encodes, the other waits for the host lock, serving its static index, and then builds from the cache. Test: Task 6 `test_host_lock_serialises_two_pools`.
- **A process killed mid-build and restarted**: the saved static index loads at once, and the transformer build resumes from the vectors already cached. Tests: Task 4 `test_resume_after_kill`, Task 6 `test_restart_mid_build_serves_static_and_resumes`.
- **Docs edited during the hours-long first build**: the static fallback keeps refreshing, but a fallback save must never overwrite the transformer index once that is saved. Test: Task 6 `test_fallback_save_never_overwrites_transformer`.
- **An unusable encode cache** (corrupt file, read-only directory): the build carries on uncached with one warning. Test: Task 3 `test_unusable_cache_degrades`.
- **The code index and other worktrees' static builds wait behind a 3-hour encode** if the transformer shares the build line: it must not. Test: Task 6 `test_code_build_not_behind_transformer`.

---

### Task 1: Config — the transformer registry, `code.model` refusal, `docs.threads`

**Files:**
- Create: `search/src/doc_search/transformer.py` (registry part only; no onnxruntime import at module level)
- Modify: `search/src/doc_search/config.py` (DEFAULTS `docs.threads: None`; `DocsCfg.threads`, `DocsCfg.transformer`; `_docs`, `_code`)
- Modify: `search/src/doc_search/cli.py` (`_init` prints `docs.threads`)
- Test: `search/tests/test_config.py`, `search/tests/test_cli.py` (init output)

**Interfaces:**
- Produces (`transformer.py`):
  - `PREFIX = "transformer:"`
  - `@dataclass(frozen=True) class TransformerSpec`: `name: str`, `source: str` (HF repo id, or a local directory: tests), `revision: str`, `onnx_file: str`, `variant: str`, `tokenizer_file: str`, `dim: int`, `max_tokens: int`, `pooling: str = "cls"`; properties `model_path -> str` = `f"transformer:{name}@{revision[:12]}"` (what semble records, so a registry change invalidates saved indexes) and `model_id -> str` = `f"{source}@{revision}"`.
  - `REGISTRY: dict[str, TransformerSpec]` = `{"gte-modernbert-base": TransformerSpec("gte-modernbert-base", "Alibaba-NLP/gte-modernbert-base", "e7f32e3c00f91d699e8c43b53106206bcc72bb22", "onnx/model_int8.onnx", "int8", "tokenizer.json", 768, 1024)}`
  - `class UnknownTransformer(ValueError)`; `parse_model(value: str | None) -> TransformerSpec | None` (None for null or a value without the prefix; raises `UnknownTransformer` with the known names otherwise).
  - `spec_for_path(model_path: str) -> TransformerSpec` (a semble model path back to its spec; `ValueError` when it is not a current registry path).
- Produces (`config.py`): `DocsCfg.threads: int | None`, `DocsCfg.transformer: TransformerSpec | None`.

- [ ] **Step 1: Write the failing tests** in `test_config.py`:
  - `test_docs_model_transformer`: `{"docs": {"model": "transformer:gte-modernbert-base"}}` → `cfg.docs.transformer.name == "gte-modernbert-base"`, `.dim == 768`, `.max_tokens == 1024`, `.onnx_file == "onnx/model_int8.onnx"`, `cfg.docs.model == "transformer:gte-modernbert-base"`, `cfg.docs.transformer.model_path == "transformer:gte-modernbert-base@e7f32e3c00f9"`.
  - `test_docs_model_unknown_transformer`: `"transformer:nope"` → `ConfigError` whose message contains `docs.model` and `gte-modernbert-base`.
  - `test_docs_model_static_has_no_transformer`: `"minishlab/potion-base-8M"` and null → `cfg.docs.transformer is None`.
  - `test_code_model_refuses_transformer`: `{"code": {"model": "transformer:gte-modernbert-base"}}` → `ConfigError` containing `code.model`.
  - `test_docs_threads`: default `None`; `4` → 4; `0`, `257`, `true`, `"4"` → `ConfigError` containing `docs.threads`.
  - In `test_cli.py`'s init test: the output has a `docs.threads: auto` line.
- [ ] **Step 2: Run** `cd search && uv run --frozen --all-extras pytest -q tests/test_config.py tests/test_cli.py -k "transformer or threads or init"` — Expected: FAIL.
- [ ] **Step 3: Implement** the registry in `transformer.py`, then in `config.py`: `"threads": None` in `DEFAULTS["docs"]`; `_docs` parses `threads` with `_int(..., minimum=1, maximum=256)` when not null and sets `transformer=parse_model(model)` (an `UnknownTransformer` becomes `ConfigError(f"docs.model: {err}")`); `_code` raises `ConfigError("code.model cannot be a transformer model (transformer:…): the code index stays static")` when the value starts with `PREFIX`. `_init` prints `docs.threads: {cfg.docs.threads or 'auto'}`.
- [ ] **Step 4: Run** the same command — Expected: PASS; then the whole suite `uv run --frozen --all-extras pytest -q` — Expected: PASS (other tests that pin DEFAULTS or init output updated).
- [ ] **Step 5: Commit** `feat(search): docs.model transformer registry, code.model refuses it, docs.threads`

### Task 2: Packaging — the `local-transformer` extra and the launcher

**Files:**
- Modify: `search/pyproject.toml`, `search/uv.lock` (regenerated with `uv lock`)
- Modify: `scripts/search/launch.sh` (header comment and the extras block)
- Test: `scripts/test-hooks.sh` (`test_launcher_cloud_extra`, or a new `test_launcher_transformer_extra` registered beside it in the runner list)

**Interfaces:**
- Produces: extra name `local-transformer`; launcher command lines `uv run --project <root>/search --frozen --no-dev --extra local-transformer doc-search …` and `… --no-dev --extra cloud --extra local-transformer doc-search …`.

- [ ] **Step 1: Write the failing shell test** `test_launcher_transformer_extra` (same fixture helpers as `test_launcher_cloud_extra`): config `{"docs":{"model":"transformer:gte-modernbert-base"}}` → `assert_eq "uv run --project $envroot/search --frozen --no-dev --extra local-transformer doc-search serve"`; config with that and `"cloud":{"project":"p"}` → `… --no-dev --extra cloud --extra local-transformer doc-search serve`; `{"docs":{"model":"minishlab/potion-base-8M"}}` → no `extra`; `{"docs":{"model":7}}` → exit 0 and no `extra`.
- [ ] **Step 2: Run** `bash scripts/check-ci.sh --bash /bin/bash hooks` (or the suite directly) — Expected: the new assertions FAIL.
- [ ] **Step 3: Implement.** pyproject:
  ```toml
  local-transformer = [
      "onnxruntime>=1.23.2,<1.24; sys_platform == 'darwin' and platform_machine == 'x86_64'",
      "onnxruntime>=1.24; sys_platform != 'darwin' or platform_machine != 'x86_64'",
      "flatbuffers",
      "protobuf",
  ]
  ```
  then `cd search && uv lock` (expect onnxruntime 1.31.0 and 1.23.2 forks). Launcher: after the cloud test, `jq -e '(.docs.model | type) == "string" and (.docs.model | startswith("transformer:"))'` appends `--extra local-transformer`; the no-jq branch stays `--all-extras`; update the header comment's *Extras* paragraph. jq 1.6-compatible forms only.
- [ ] **Step 4: Run** the hooks suite under `/bin/bash` and a bash 5 — Expected: PASS; `cd search && uv sync --frozen --all-extras && uv run --frozen --all-extras python -c "import onnxruntime; print(onnxruntime.__version__)"` prints 1.23.2 on w-mm (Intel).
- [ ] **Step 5: Commit** `feat(search): the local-transformer extra; the launcher adds it for a transformer docs.model`

### Task 3: The encode cache and the host lock

**Files:**
- Create: `search/src/doc_search/encode_cache.py`
- Modify: `search/tests/conftest.py` (autouse: `DOC_SEARCH_CACHE_LOCATION` → `tmp_path / "doc-search-cache"`, checked again at teardown like `SEMBLE_CACHE_LOCATION`)
- Test: `search/tests/test_encode_cache.py`

**Interfaces:**
- Consumes: `TransformerSpec` (Task 1).
- Produces:
  - `CACHE_ENV = "DOC_SEARCH_CACHE_LOCATION"`; `cache_root() -> Path` (created on demand); `encode_cache_path(spec: TransformerSpec) -> Path` = `cache_root() / "encode" / f"{spec.name}.sqlite"`; `cache_size(path: Path) -> int | None` (bytes of the db, `-wal` and `-shm`; None when the db is absent).
  - `class EncodeCache`: `__init__(self, path: Path, *, model_id: str, variant: str, max_tokens: int, ort_version: str, arch: str, dim: int)`; `key(self, text: str) -> bytes`; `get_many(self, keys: Sequence[bytes]) -> dict[bytes, np.ndarray]`; `put_many(self, rows: Sequence[tuple[bytes, np.ndarray]]) -> None`; `close(self) -> None`; `usable: bool`. Thread-safe (one connection, a lock, `check_same_thread=False`).
  - `host_lock(spec: TransformerSpec, on_wait: Callable[[int | None], None] | None = None) -> ContextManager[None]`: exclusive `fcntl.flock` on `cache_root()/"encode"/f"{spec.name}.lock"`; tries non-blocking first, and on contention calls `on_wait(<pid read from the file, or None>)` before blocking; writes its own pid once held; a no-op where `fcntl` is missing.

- [ ] **Step 1: Write the failing tests:**
  - `test_cache_root_env_and_default`: env set → that path; unset on darwin → `~/Library/Caches/doc-search` (monkeypatch `sys.platform`, `HOME`); a relative env value is ignored with a warning.
  - `test_round_trip_and_wal`: put two rows, a new `EncodeCache` on the same path gets them back bit-for-bit (`np.array_equal`), `PRAGMA journal_mode` is `wal`.
  - `test_key_material`: same text, same params → same key; a change to any one of model_id, variant, max_tokens, ort_version, arch → a different key; text keyed with `surrogatepass` (a lone surrogate does not raise).
  - `test_wrong_length_blob_is_a_miss`: a row whose blob is not `dim * 4` bytes is not returned.
  - `test_cache_size`: None before the db exists; after writes ≥ the db file's size.
  - `test_unusable_cache_degrades` (Review Focus): the path is a directory, or the file holds garbage → `usable is False`, `get_many` returns `{}`, `put_many` is a no-op, exactly one warning logged (`caplog`).
  - `test_host_lock_contention`: holder A in a thread holds the lock; B's `on_wait` is called with A's pid (the test's own pid) and B acquires only after A exits (an `Event` ordering check).
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest -q tests/test_encode_cache.py` — Expected: FAIL (module missing).
- [ ] **Step 3: Implement.** Table `vectors(key BLOB PRIMARY KEY, vec BLOB NOT NULL)`, a rowid table (as built: `WITHOUT ROWID` was the first design, but ~3 KB vector rows overflow its pages and reading 194,564 keys took 115 to 125 s, against 2.5 to 6 s; see the design note §8); pragmas `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=60000`; `get_many` in chunks of 500 parameters; `put_many` = `INSERT OR REPLACE` + commit. Key = `sha256(b"\0".join([model_id, variant, str(max_tokens), ort_version, arch]).encode-each + b"\0" + text.encode("utf-8", "surrogatepass")).digest()`. Any `sqlite3.Error`/`OSError` sets `usable = False` with one `logger.warning("doc-search: encode cache unusable (%s): encoding without it", ...)`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(search): per-host content-addressed encode cache and the host encoder lock`

### Task 4: The encoder and the semble seam

**Files:**
- Modify: `search/src/doc_search/transformer.py` (add `Encoder`, `default_threads`, `extra_missing`, `MISSING_EXTRA`, `install`, `report_to`)
- Create: `search/tests/onnx_tiny.py` (writes a tiny ONNX model and tokenizer for tests)
- Create: `search/tests/fakes_transformer.py` (`FakeEncoder` and the `fake_transformer` fixture's helpers; the fixture itself goes in `conftest.py`)
- Test: `search/tests/test_transformer.py`, `search/tests/test_semble_seam.py`

**Interfaces:**
- Consumes: `TransformerSpec`, `REGISTRY`, `spec_for_path` (Task 1); `EncodeCache` (Task 3); `BuildProgress.add` (Task 5 — until Task 5 lands, `report_to` accepts any object with `add(n: int, *, cached: bool = False)`).
- Produces:
  - `MISSING_EXTRA = "docs.model transformer:{name} needs the local-transformer extra"`; `extra_missing() -> bool` (`importlib.util.find_spec("onnxruntime") is None`).
  - `default_threads() -> int` (constraint above; macOS via `ctypes` `sysctlbyname`, never a subprocess).
  - `BATCH = 16`; `class Encoder`: `__init__(self, spec: TransformerSpec, threads: int, cache: EncodeCache | None)`; attributes `name` (= `spec.model_path`), `dim`, `threads`; `encode(self, sentences: str | Sequence[str], **kwargs) -> np.ndarray` float32 `(n, dim)`, unit rows. An **indexing** call is one that passes semble's `use_multiprocessing` keyword (`dense.embed_chunks`): it reads the cache, encodes the misses in length-sorted batches of `BATCH`, writes each batch to the cache as it finishes, and reports to the thread's sink (`add(hits, cached=True)` once, then `add(len(batch))` per batch). Any other call is a **query**: no cache read or write, no report.
  - `install(threads: int | None = None) -> None`: idempotent; replaces `semble.index.dense._load_cached` with a loader that returns one cached `Encoder` per transformer model path (built with `threads or default_threads()` and `EncodeCache` for the spec, keyed with `onnxruntime.__version__` and `platform.machine()`) and calls semble's original loader for every other path. `_make_encoder(spec, threads) -> Encoder` is the seam tests patch.
  - `report_to(sink) -> ContextManager[None]`: thread-local sink for indexing encodes.
  - `tests/onnx_tiny.py`: `write_tiny_model(dir: Path, words: list[str], dim: int, seed: int = 0) -> np.ndarray` writes `model.onnx` and `tokenizer.json` and returns the embedding table; `tiny_spec(dir: Path, dim: int) -> TransformerSpec` with `source=str(dir)`, `onnx_file="model.onnx"`, `tokenizer_file="tokenizer.json"`, `max_tokens=32`.
  - `Encoder` is split so a fake can reuse it: `__init__` loads the tokenizer and session, `_forward(self, texts: list[str]) -> np.ndarray` runs one batch, and `encode` holds the cache, sorting and reporting logic.
  - `tests/fakes_transformer.py`: `class FakeEncoder(Encoder)` — its `__init__(self, spec, cache: EncodeCache | None)` loads nothing; its `_forward` returns deterministic hashed-bag-of-words unit vectors (NaN rows when `nan=True`), records each batch in `forwarded: list[list[str]]`, and first waits on `gate: threading.Event` (set by default). Everything else (cache, length sorting, reporting, query detection) is `Encoder`'s own. It also records every `encode` call in `calls: list[tuple[list[str], dict]]`. Fixture `fake_transformer(monkeypatch, tiny_model)` in `conftest.py`: registers `TransformerSpec("test-tiny", ..., dim=16)` in `REGISTRY`, patches `transformer._make_encoder` to return a `FakeEncoder` over a real `EncodeCache` (keyed with ort version `"fake"`), sets `SEMBLE_MODEL_NAME` to `tiny_model` (so the static fallback, semble's default model, resolves offline), clears the encoder cache before and after, yields the spec.

- [ ] **Step 1: Write the tiny-model helper.** The graph is one `Gather(table, input_ids) -> last_hidden_state` with graph inputs `input_ids` and `attention_mask` (int64, dims `b`, `s`) and output float `[b, s, dim]`; hand-encode the protobuf (no `onnx` package: it has no Intel-macOS wheels). Field numbers: ModelProto `ir_version=1, graph=7, opset_import=8`; OperatorSetIdProto `domain=1, version=2` (use opset 13, ir_version 8); GraphProto `node=1, name=2, initializer=5, input=11, output=12`; NodeProto `input=1, output=2, name=3, op_type=4`; TensorProto `dims=1, data_type=2 (FLOAT=1, INT64=7), name=8, raw_data=9`; ValueInfoProto `name=1, type=2`; TypeProto `tensor_type=1`; TypeProto.Tensor `elem_type=1, shape=2`; TensorShapeProto `dim=1`; Dimension `dim_value=1, dim_param=2`. Tokenizer: the `tokenizers` WordLevel model over `["[UNK]", "[PAD]", *words]`, whitespace pre-tokenizer, lowercase. A smoke test `test_tiny_model_loads` runs it in an `onnxruntime.InferenceSession`.
- [ ] **Step 2: Write the failing tests** (`test_transformer.py`):
  - `test_encoder_contract`: `Encoder(tiny_spec, 2, None).encode(["refund total", "tax"], use_multiprocessing=False)` → shape `(2, dim)`, dtype float32, row norms 1 ± 1e-5, row 0 equals the normalized table row of `refund` (CLS = position 0), `encoder.dim == dim`.
  - `test_padding_does_not_change_vectors`: a short text encoded in one batch with a long one equals it encoded alone.
  - `test_length_sorted_batches`: patch `Encoder._forward` to record batch lengths; 40 texts of mixed length → batches of ≤ 16 whose lengths are non-decreasing across calls; output rows still in input order.
  - `test_cache_hits_across_worktrees`: two `Encoder`s on one `EncodeCache` path (two "processes"); the second indexing call on the same texts runs `_forward` zero times; a text that differs runs it once.
  - `test_query_never_stored`: `encode(["refund total"])` (no kwargs) writes nothing to the cache and reports nothing; an indexing call of one text is stored.
  - `test_resume_after_kill` (Review Focus): `_forward` raises after 2 batches of 16 on 40 texts → the cache holds 32 vectors; a new encoder then runs `_forward` only on the 8 remaining.
  - `test_reports_progress`: inside `report_to(sink)`, an indexing call of 20 texts with 4 cached → `sink` got `add(4, cached=True)` then adds summing to 16.
  - `test_session_options`: the session is built with `intra_op_num_threads == threads` and providers `["CPUExecutionProvider"]` (patch `onnxruntime.InferenceSession` to capture).
  - `test_default_threads`: patch the sysctl reader: perflevel0 = 8 → 6; perflevel0 absent, physicalcpu = 6 → 4; 3 → 2; non-darwin → `os.cpu_count()` − 2, at least 2.
  - `test_missing_extra_line`: `MISSING_EXTRA.format(name="gte-modernbert-base") == "docs.model transformer:gte-modernbert-base needs the local-transformer extra"`; with `sys.modules["onnxruntime"] = None` patched, `extra_missing()` is True.
  - `test_semble_seam.py::test_seam_pins` (the §5 seam pin): with `fake_transformer`, `install()`; `SembleIndex.from_path(<tmp docs tree>, content=[ContentType.DOCS], model_path=spec.model_path)` → the `FakeEncoder` got an indexing call (kwargs contain `use_multiprocessing`); `index.search("refund")` → one call with one text and no kwargs; `save_index_to_cache` then `get_validated_cache(path, spec.model_path, (DOCS,))` is not None; `SembleIndex.load_from_disk` returns an index whose `.model` is the same `FakeEncoder`; `index._semantic_index.vectors.shape == (len(index.chunks), 16)`; the saved `metadata.json` has `model_path == spec.model_path` and a `files` map whose entries carry `count`. Also assert the names exist: `semble.index.dense._load_cached`, `semble.index.dense.load_model`, `semble.index.dense.embed_chunks`, `semble.search._search_semantic`, `semble.index.types.PersistencePath`, and that `search/pyproject.toml` pins `semble>=0.7,<0.8`.
  - `test_semble_seam.py::test_other_models_pass_through`: after `install()`, `_load_cached(<tiny_model path>)` returns semble's `StaticModel`.
- [ ] **Step 3: Run** `uv run --frozen --all-extras pytest -q tests/test_transformer.py tests/test_semble_seam.py` — Expected: FAIL.
- [ ] **Step 4: Implement** `Encoder` (port of the eval prototype's `GteEncoder`, without its env knobs and stderr prints): files come from `source` when it is a directory, else `huggingface_hub.hf_hub_download(source, file, revision=revision)`; tokenizer `enable_truncation(max_length=max_tokens)`, `no_padding()`, pad id `token_to_id("[PAD]") or 0`; `SessionOptions` with `intra_op_num_threads=threads`, `inter_op_num_threads=1`, `ORT_ENABLE_ALL`; feed only the inputs the session declares (`token_type_ids` as zeros); CLS = output 0 at position 0; L2 normalize with an epsilon of 1e-12. Then `install`, `report_to`, `default_threads`, `extra_missing`.
- [ ] **Step 5: Run** — Expected: PASS; full suite PASS.
- [ ] **Step 6: Commit** `feat(search): gte-modernbert ONNX encoder at semble's model loader, with a test pinning the seam`

### Task 5: Build progress

**Files:**
- Create: `search/src/doc_search/progress.py`
- Test: `search/tests/test_progress.py`

**Interfaces:**
- Consumes: `cache_root()` (Task 3).
- Produces:
  - `ARCH_RATES: dict[tuple[str, str], float] = {("darwin", "arm64"): 16.0, ("darwin", "x86_64"): 3.6}`; `arch_rate(platform: str = sys.platform, machine: str = platform.machine()) -> float | None`; `RATE_WINDOW_S = 60.0`.
  - `fmt_duration(seconds: float) -> str`: `"55 s"`, `"4 min"`, `"3 h 12 min"`.
  - `@dataclass(frozen=True) class ProgressView`: `phase: str` (`queued | waiting | encoding | saving`), `total: int | None`, `done: int`, `from_cache: int`, `rate: float | None`, `eta_s: float | None`, `estimate_s: float | None`, `holder_pid: int | None`, `pid: int`; `line(self) -> str`; `as_dict(self) -> dict`.
  - `class BuildProgress`: `__init__(self, worktree: Path, model: str, clock: Callable[[], float] = time.monotonic)`; fields `total`, `phase`, `holder_pid`; `add(self, n: int, *, cached: bool = False) -> None`; `view(self) -> ProgressView`; `publish(self, force: bool = False) -> None` (atomic write of `view().as_dict()` plus `worktree`, `model`, `pid` to `progress_path(worktree)`, at most once a second unless forced); `retire(self) -> None`.
  - `progress_path(worktree: Path) -> Path` = `cache_root()/"encode"/"progress"/(sha256(str(resolved worktree))[:16] + ".json")`; `read_progress(worktree: Path) -> ProgressView | None` (None when absent, unreadable, or its pid is not alive).
- Line copy (`ProgressView.line`):
  - encoding: `docs: transformer index building, 12,345 / 194,564 chunks encoded, ETA 2 h 57 min (16.1 chunks/s; 1,203 from the encode cache)` — without `/ M` when total is unknown, without ETA when the rate is unknown.
  - queued: `docs: transformer index queued; estimated 3 h 23 min for 194,564 chunks at ~16 chunks/s on this host` (estimate only when total and `arch_rate()` are known; else `docs: transformer index queued`).
  - waiting: `docs: transformer index waiting for another doc-search process on this host (pid 4242) to finish encoding`.
  - saving: `docs: transformer index saving (194,564 chunks encoded)`.

- [ ] **Step 1: Write the failing tests** with an injected fake clock: rate over the window (`add` 160 over 10 s → 16.0; samples older than 60 s drop out); ETA = (total − done) / rate; estimate = total / `arch_rate`; `arch_rate("linux", "x86_64") is None`; `fmt_duration` cases above (plus `0 s`, `59 min`, `1 h 0 min` → pick and pin `"1 h"` for exact hours); each `line()` form above verbatim; `publish` then `read_progress` round-trips; a file with a dead pid (spawn and reap a child) → None; `publish` throttles (two calls in one clock second write once unless `force`).
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest -q tests/test_progress.py` — Expected: FAIL.
- [ ] **Step 3: Implement**; rate from a deque of `(t, done)` samples kept within `RATE_WINDOW_S`; `publish` writes a temp file and `os.replace`s it; liveness is `os.kill(pid, 0)`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(search): transformer build progress, ETA and the per-arch first-build estimate`

### Task 6: The pool — transformer lane, host lock, static fallback and swap

**Files:**
- Modify: `search/src/doc_search/engines.py`
- Modify: `search/src/doc_search/server.py` (`Runtime(..., fallback: bool = True)` passes it to `IndexPool`)
- Modify: `search/src/doc_search/cli.py` (`_runtime` builds `Runtime(..., fallback=False)`: the command line builds what the config names, in the foreground)
- Test: `search/tests/test_engines_transformer.py`

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 5.
- Produces:
  - `IndexPool(cfg, max_worktrees=2, clock=time.monotonic, *, fallback: bool = True)`. When `cfg.docs.transformer` is set it calls `transformer.install(cfg.docs.threads)`, and when `extra_missing()` the docs state is fatal with `MISSING_EXTRA.format(name=...)` as its error (no build, no fallback).
  - `TRANSFORMER_REFRESH_WAIT_S = 2.0`: how long a `get` waits for a running transformer refresh when an index already serves.
  - `WorktreeIndexes` gains `docs_model: str | None = None` (the semble model path of the docs index served), `docs_fallback: bool = False` (it is the static index, the transformer one still building), `transformer: ProgressView | None = None`.
  - `IndexPool.progress(worktree) -> ProgressView | None` (the docs transformer build in this process: queued, waiting, encoding or saving; None otherwise). `IndexPool.fallback_cache_state(worktree) -> CacheState | None` (the static docs index's disk state; None without a transformer docs model). `cache_state(worktree, "docs")` with a transformer model reads `absent` when the saved docs index is another model's.
- Behaviour (the decisions; the implementer writes the code):
  - Transformer docs builds take places in a second `_BuildLine(1)` (the *transformer lane*), never in the normal line, and inside the slot hold `encode_cache.host_lock(spec, on_wait=...)` (phase `waiting`, `holder_pid`) around `SembleIndex.from_path(...)` run under `transformer.report_to(progress)`.
  - The docs transformer thread first loads a valid transformer cache (no lane, no fallback). Otherwise, with `fallback` on and no transformer index saved for this worktree (absent, or the folder holds another model's index), it starts a hidden static docs state (`_State("docs", (DOCS,), None)`, normal line, kept on the entry as `fallback`), waits for its first build and for the code state's first build to settle, sets `progress.total = len(fallback.index.chunks)` and the docs state's `answerable`, then queues in the transformer lane. A stale saved transformer index (or `fallback` off) refreshes in the lane directly; in that case `progress.total` comes from the saved static metadata when present (a `files` → `count` sum), else stays unknown.
  - While the fallback serves: `get`'s readiness and `_snapshot` take the docs index from the transformer state when it has one, else from the fallback (`docs_fallback=True`, `docs_model=None`→ static); the fallback refreshes on its own cooldown like any state; `building()` counts it.
  - A finished transformer build *validates* before it serves: `len(chunks) > 0`, `index._semantic_index.vectors.shape == (len(chunks), spec.dim)`, all finite. Then, under the entry's `save_lock`, it is saved and `entry.transformer_saved = True`; the swap drops the fallback. A fallback save runs under the same lock and is skipped once `transformer_saved` is set. A failed or invalid build records the error, keeps the fallback serving, and retries on the cooldown.
  - During a transformer refresh with an index serving, `get` waits at most `TRANSFORMER_REFRESH_WAIT_S` for it.
  - Progress is published (`BuildProgress.publish`) while queued/waiting/encoding/saving and retired when the build ends. On darwin x86_64, the first transformer build of a pool logs one warning: `doc-search: the transformer docs model runs ~3.6 chunks/s on Intel (M-series: ~16); this first build may take hours`.

- [ ] **Step 1: Write the failing tests** (all with `fake_transformer`, a small git repo of docs and code, `FakeEncoder.gate` to hold builds):
  - `test_static_serves_while_transformer_builds`: gate cleared; `get(wait_s=10)` → `WorktreeIndexes`, `docs_fallback` True, `docs.model` is not the `FakeEncoder`, `transformer.phase == "encoding"`, `progress(top).total == len(docs.chunks)`.
  - `test_swap_once_built`: then set the gate; within a few seconds `get` → `docs_fallback` False, `docs.model` is the `FakeEncoder`, `docs_model == spec.model_path`, `progress(top) is None`; `cache_state(top, "docs") == "valid"`; a new `IndexPool` loads it with zero indexing calls and no fallback.
  - `test_static_kept_until_validated`: a `FakeEncoder` returning NaN rows → the build fails validation, the error is recorded, the fallback still serves, and the static index is still on disk (`fallback_cache_state(top) == "valid"`).
  - `test_restart_mid_build_serves_static_and_resumes` (Review Focus): pool A builds and saves the fallback, its transformer encodes 2 batches and then its `_forward` raises (the kill: the host lock is released with the failed build). A new pool B, with the encoder cache cleared (a new process) and the encode cache shared, serves the static index loaded from disk (patch `SembleIndex.from_path` to count: no static build), and B's transformer build completes with its first 32 texts read from the encode cache (`forwarded` lacks them).
  - `test_fallback_save_never_overwrites_transformer` (Review Focus): hold a fallback refresh inside `from_path` (patch) while the transformer saves; release → the saved docs index's `model_path` is still `spec.model_path`.
  - `test_code_build_not_behind_transformer` (Review Focus): gate cleared, transformer encoding; touch a code file, wait the cooldown, `get` → the code refresh completes while the transformer is still held.
  - `test_host_lock_serialises_two_pools` (Review Focus): pools A and B over two worktrees; A's transformer is held at the gate; B's `progress()` reaches phase `waiting` with `holder_pid == os.getpid()`, B serves its static index; release A → B's transformer completes and its `FakeEncoder` saw no indexing texts that A had already encoded (encode cache hits).
  - `test_no_fallback_in_foreground`: `IndexPool(cfg, fallback=False)` → `get(wait_s=FOREGROUND_WAIT_S)` returns only after the transformer index is built; no static index is built.
  - `test_missing_extra_is_fatal`: `extra_missing` patched True → docs error equals `MISSING_EXTRA.format(name="test-tiny")`, no build thread runs, the code index still builds.
  - `test_refresh_wait_bounded`: transformer index serving, a doc edited, gate cleared during the refresh → `get(wait_s=20)` returns within ~`TRANSFORMER_REFRESH_WAIT_S` + 1 s with the previous index.
- [ ] **Step 2: Run** `uv run --frozen --all-extras pytest -q tests/test_engines_transformer.py` — Expected: FAIL.
- [ ] **Step 3: Implement** in `engines.py`, keeping the module docstring's account of lanes, fallback and the swap current; `server.Runtime` and `cli._runtime` as above.
- [ ] **Step 4: Run** the new tests, then the full suite (`tests/test_engines.py` unchanged behaviour for static models) — Expected: PASS.
- [ ] **Step 5: Commit** `feat(search): transformer builds in their own lane under a host lock; the static docs index serves until the transformer one validates`

### Task 7: Status, CLI progress, search header, eval

**Files:**
- Modify: `search/src/doc_search/tools.py` (`_status`, `_index_lines`, `_View`)
- Modify: `search/src/doc_search/cli.py` (`_status` text and JSON; progress lines on stderr for foreground builds)
- Modify: `search/src/doc_search/searcher.py` (`model_label`, header model and note)
- Modify: `search/src/doc_search/evaluate.py` (`_single_ranker`)
- Test: `search/tests/test_tools.py`, `search/tests/test_cli.py`, `search/tests/test_searcher.py`, a case in the eval tests

**Interfaces:**
- Consumes: `WorktreeIndexes.docs_model/docs_fallback/transformer`, `IndexPool.progress`, `IndexPool.fallback_cache_state` (Task 6); `ProgressView.line`, `read_progress`, `arch_rate`, `fmt_duration` (Task 5); `encode_cache_path`, `cache_size` (Task 3); `default_threads` (Task 4).
- Produces (copy):
  - `status` header lines with a transformer docs model: `docs model: transformer:gte-modernbert-base (Alibaba-NLP/gte-modernbert-base, int8 ONNX, 768-d, 6 threads)`; on darwin x86_64 the line gains `; Intel: ~3.6 chunks/s against ~16 on M-series`; then `encode cache: <path> (764.1 MB)` or `encode cache: <path> (empty)`.
  - Per worktree, while the fallback serves: `docs index: ready (semble's static index, while the transformer index builds)` with the usual detail lines, then the `ProgressView.line()`; a failed transformer build: `docs: transformer index failed: <error> (the static index serves)`.
  - `doc-search status` (CLI text, a fresh process): after the tool text, `docs cache: <state>` (the transformer's), `docs fallback cache: <state>`, and `read_progress(top).line()` when a live process publishes one.
  - `status --format json`: `docs.transformer` = `null` without a transformer model, else `{"model": spec.model_path, "progress": <ProgressView.as_dict() or null>}`; `cache.docs_fallback`; top-level `encode_cache` = `{"path": str, "bytes": int | null}` or `null`; `ready` counts docs ready when `cache.docs` or `cache.docs_fallback` is `valid`.
  - Foreground verbs (`index`, `query`, `eval`) print, every 30 s while a transformer build runs, `doc-search: <ProgressView.line()>` on stderr.
  - Search header: `model_label` of a transformer path is `transformer:<name>`; while the fallback serves, the header names the static model and adds `note: docs: semble's static index while the transformer index builds (see status)`.
  - Eval: `semble-single` is skipped with `docs.model is a transformer model: the single index would encode the code with it`.

- [ ] **Step 1: Write the failing tests:** tools status with `fake_transformer` and the gate held (fallback line, progress line containing `chunks encoded`, the model line, `encode cache:`); queued line with a patched `arch_rate` containing `estimated`; JSON keys above (`docs.transformer.progress.phase`, `encode_cache.bytes`, `cache.docs_fallback`); CLI `index` with a held gate prints a `doc-search: docs: transformer index` line to stderr (patch the 30 s interval to 0.05 s); searcher header label and note; eval skip reason.
- [ ] **Step 2: Run** the touched test files — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS; full suite PASS.
- [ ] **Step 5: Commit** `feat(search): status shows transformer progress, ETA, estimate and the encode cache; foreground progress lines`

### Task 8: Live test, reference and living docs

**Files:**
- Modify: `search/tests/test_live.py` (a second live case: `docs.model: transformer:gte-modernbert-base` over the fixture docs — downloads ~150 MB; asserts the docs index's `model_path`, dim 768, and the known-answer hit; skipped unless `DOC_SEARCH_LIVE=1`)
- Modify: `references/search.md` — *Turning it on* (the extra is added by the launcher), *Modes* (a **Local transformer (opt-in)** paragraph: what it is, the fallback, the host lock), *Configuration* (`docs.model` row names `transformer:<name>` and the registry entry; new `docs.threads` row; environment table gains `DOC_SEARCH_CACHE_LOCATION`), *CLI* (foreground builds and their progress lines; the status JSON fields), *Tools* (`status` row), *Hardware and performance* (replace *Why no local transformer* with the measured costs from spec §1/§3: +0.154 recall@10 / +0.091 MRR on the local docs leg, 3.2 h first build on an M1 Pro at ~16 chunks/s on 6 threads, 55 s for a second worktree, 4.7 GB peak RSS, 845 MB against 465 MB per worktree, +30 ms p50, 150 MB download, Intel ≈ 14 h, Linux unmeasured, onnxruntime 1.31 needs macOS ≥ 14 on arm64), *Privacy* (the model download; the encode cache holds vectors under hashes of chunk text, never query text), *Troubleshooting* (the missing-extra line; waiting for another process; resetting the cache by deleting `<name>.sqlite*`; Intel). Keep the ten sections and the strings `test-spec-status-model.sh` pins.
- Modify: `docs/superpowers/specs/2026-10-20-doc-search-local-transformer-design.md` (Status → built in this branch; note any decision this plan took beyond §2: the host lock, the transformer lane, the model path's revision tag)
- Modify: `docs/codebase-guide.md`, `docs/architecture/system-overview.md`, `CLAUDE.md` (the `search/` rows: the new modules, the extra; the pytest count in *Testing*), `README.md` if it lists doc-search's extras
- Modify: `docs/.doc-index.json` via `scripts/doc-tools.sh` (`check-freshness`, then `update-index` for each doc re-verified against the changed code; `add-entry` for the plan doc if the index tracks plans)

- [ ] **Step 1:** Write the live case; run it on w-mbp with `DOC_SEARCH_LIVE=1` (Task 9) — locally it SKIPs.
- [ ] **Step 2:** Edit the reference and the living docs; run `bash scripts/check-ci.sh --bash /bin/bash spec-status-model` — Expected: PASS.
- [ ] **Step 3:** `scripts/doc-tools.sh check-freshness` — Expected: no doc stale against this branch's code.
- [ ] **Step 4: Commit** `docs(search): the local transformer in the reference and the living docs` (index re-baseline in its own `docs(index): …` commit, as the repository does).

### Task 9: Verification

- [ ] **Step 1:** `bash scripts/check-ci.sh` (background; ~ several minutes) — Expected: every suite PASS under both interpreters, `search` PASS, self-install, check-version.
- [ ] **Step 2 (w-mbp, M1 Pro):** sync the branch's `search/` to a scratch directory, `uv sync --frozen --extra local-transformer`; with fresh `SEMBLE_CACHE_LOCATION` and `DOC_SEARCH_CACHE_LOCATION`, in abundance's eval clone (`~/scratch/doc-search-gte-eval/corpus-gte`, code off, `docs.model: transformer:gte-modernbert-base`) run `/usr/bin/time -l doc-search index` — record wall time, chunks/s, peak memory.
- [ ] **Step 3 (w-mbp):** in a second clone at the same commit (`corpus-default` with the same config), with a fresh semble cache and the same encode cache, `doc-search index` — Expected: about a minute, all cache hits. Record it.
- [ ] **Step 4 (w-mbp):** `doc-search eval` with the 65-query set (`~/scratch/doc-search-gte-eval/eval.jsonl`) on the first clone, local config — Expected: the docs leg near 0.841 / 0.622 recall@10 / MRR (the §4 rule still met); `DOC_SEARCH_LIVE=1` pytest of the live cases.
- [ ] **Step 5:** Record the numbers in the commit body of a `docs(search): measured …` commit (design note §3 or the reference's numbers if they moved), then open the PR against `main`.
