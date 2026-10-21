# Design note: doc-search's opt-in local-transformer docs embedder

**Status:** Built, 2026-10-21, on the branch `claude/mystifying-rosalind-516af1` (plan: `docs/superpowers/plans/2026-10-20-doc-search-local-transformer.md`); not yet released. The §4 distillation check ran on 2026-10-20 and did not meet its rule, so §2 is the lever. §8 records what the build decided beyond §2. Tracking issue: woodrowpearson/doc-superpowers#45.
**Parent:** `2026-10-19-doc-search-design.md` §4. That section holds the decision rule, the measurement, and every number quoted here. The user-facing reference is `references/search.md`.
**Target version:** after 3.7.0, as additive and opt-in. This note changes no release files.

## 1. Why

§4's rule asks for ≥ 0.05 recall@10 or MRR over semble's docs leg. On the full abundance corpus (6,301 docs, 194,564 semble chunks, 65 queries, k = 10), a gte-modernbert encoder inside semble beats it by **+0.154 recall@10 and +0.091 MRR**.

| Local docs leg | recall@10 | MRR |
|---|---|---|
| semble default (potion-code-16M-v2) | 0.687 | 0.531 |
| gte-in-semble | **0.841** | **0.622** |

- **Where it gains:** almost all of the gain is on paraphrase queries (0.650 → 0.850 recall). Identifier queries are unchanged (the identifier leg already finds them).
- **With the cloud leg:** the fused docs leg keeps its recall (0.887 → 0.880) and gains MRR (0.647 → 0.744).
- **Who it serves:** projects that do not run the cloud leg get the most from it. For abundance, which does, it is a ranking improvement.

## 2. What it would be

This section is the proposal; the build kept it as written except where §8 says otherwise.

- **Config:** `docs.model: "transformer:gte-modernbert-base"`.
  - The `transformer:` prefix names an entry in a small built-in registry. v1 has one entry: `Alibaba-NLP/gte-modernbert-base`, `onnx/model_int8.onnx`, CLS pooling, L2-normalized, 768-d, at most 1,024 tokens.
  - An unknown name is a config error that names the key.
  - `code.model` refuses the prefix: code stays static (parent §3(a)).
- **Extra:** `local-transformer`, which adds `onnxruntime`, `flatbuffers` and `protobuf`.
  - That is +3 packages on arm64 with macOS ≥ 14 (onnxruntime 1.31), and +7 on Intel macOS, where onnxruntime stops at 1.23.2.
  - Without the extra, the docs leg fails with one line: `doc-search: docs.model transformer:… needs the local-transformer extra`.
  - The launcher adds the extra when the config names a transformer model, as it does for `cloud`.
- **Encoder:** an object with `dim` and `encode(texts, **_) -> float32 (n, dim)`, unit norm.
  - It is injected at semble's model loader, `semble.index.dense._load_cached`, which is private API. A test pins that seam, so a semble upgrade that moves it fails loudly.
  - semble stays pinned `<0.8` until §6 lands upstream.
  - Batches are sorted by length (less padding).
  - Threads default to the performance-core count minus two, at least 2 (`hw.perflevel0.physicalcpu` on macOS), with a `docs.threads` override.
    - On an M1 Pro, 6 threads ran at 14.9 chunks/s, 8 at 14.1, and 10 (the efficiency cores included) at 8.1.
    - The CoreML provider partitions the graph 155 ways and runs at ~1 chunk/s. It stays off.
- **Encode cache:** per host, content-addressed, shared by every worktree and process on that host.
  - It is sqlite in WAL mode at `<user cache>/doc-search/encode/<model>.sqlite`.
  - The key is sha256 of the model id, the ONNX variant, the token limit, the onnxruntime version and machine arch, and the text. int8 kernels differ between x86 and ARM, so a synced cache must not mix them.
  - The value is the float32 vector.
  - **Writes happen per batch,** so a killed build resumes: the spike resumed from 22,196 cached vectors.
  - **Measured:** 764 MB for abundance.
  - A second worktree's docs build took **55 s**, all cache hits, against 63 s for semble's static model.
  - Query strings are not stored.
  - There is no eviction in v1. `status` reports the cache's size.
- **The first build per host must not block:** it took ~3.2 h for abundance on an M1 Pro.
  - The pool already builds in the background. While the transformer docs index builds, the docs leg serves semble's default docs index (one minute to build), so search works throughout.
  - `status` shows `docs: transformer index building, N / M chunks encoded, ETA …`. The transformer index replaces the static one once it validates.
  - The static index is kept until then, and only then.
- **Hardware:**
  - **M-series:** supported.
  - **Intel macOS:** allowed with a warning; for abundance, 3.6 chunks/s is ≈ 14 h.
  - `status` estimates the first build (chunks × a per-arch rate) before it starts.
  - **Linux** has wheels but is unmeasured.

## 3. What it costs

From parent §4, same host and corpus:
- **Peak RSS while building:** 4.7 GB.
- **Docs index per worktree:** 845 MB (768-d vectors), against 465 MB.
- **Query latency:** about +30 ms at p50, `scope=docs` end to end (76 ms against 45 ms).
- **Download:** 150 MB.
- **Code:** about 150 lines of adapter and cache, plus the build-progress and fallback wiring in `engines.py`.

## 4. Before building it: the distillation check

`model2vec.distill` turns gte-modernbert into a static Model2Vec model. It needs torch once, at distill time, and nothing at runtime. `docs.model` can already name such a model, so it is a zero-dependency candidate that builds in about a minute.
1. Distill it.
2. Score it on the same 65 queries.
3. Decide:
   - If it keeps at least two-thirds of the gain (≥ +0.10 recall@10 over semble's default), ship it as a documented `docs.model` value and close #45 without the extra.
   - Otherwise, build §2.

**Result, 2026-10-20: the rule is not met, so §2 stands.** A distilled gte keeps none of the gain: +0.003 recall@10 at both widths, and MRR falls.
- **Setup:** the M1 Pro of parent §4, in a venv of its own: model2vec 0.10.0 with the `distill` extra (torch 2.14.1, transformers 5.3.0).
  - `distill("Alibaba-NLP/gte-modernbert-base", pca_dims=256)`, and again with `pca_dims=512`. Everything else was left at the defaults: mean pooling, SIF 1e-4, float16, gte's 50,254-token vocabulary.
  - One more run used CLS pooling (`pooling="first"`, 256-d), because gte is trained with CLS pooling.
  - Each model got a fresh clone of abundance at `b8c7f61e5e`, with the cutover's `.sembleignore`, `docs.model` set to the model's path, `code.enabled: false`, and its own semble cache.
  - Scoring used the same 65 queries, k = 10, terminal docs included.

| Local docs leg | recall@10 | MRR | paraphrase (50) | Δ vs semble default |
|---|---|---|---|---|
| semble default (potion-code-16M-v2) | 0.687 | 0.531 | 0.650 / 0.453 | |
| distilled gte, 256-d | 0.690 | 0.502 | 0.650 / 0.438 | +0.003 / −0.029 |
| distilled gte, 512-d | 0.690 | 0.513 | 0.660 / 0.447 | +0.003 / −0.018 |
| distilled gte, 256-d, CLS pooling | 0.685 | 0.475 | 0.660 / 0.418 | −0.003 / −0.056 |
| gte-in-semble (§1) | **0.841** | **0.622** | 0.850 / 0.612 | +0.154 / +0.091 |

| Fused docs leg (+ cloud) | recall@10 | MRR |
|---|---|---|
| semble default | 0.887 | 0.647 |
| distilled gte, 256-d | 0.874 | 0.660 |
| distilled gte, 512-d | 0.874 | 0.686 |
| gte-in-semble | 0.880 | **0.744** |

- **Per query (512-d against semble's default):** better on 19, worse on 15, unchanged on 31. gte-in-semble improves 29 queries over the default; the distilled model improves 16 of those. The CLS-pooling model was scored on the local leg only.
- **Cost:**
  - **Distilling:** about 4 min per model, once, on 4 CPU threads (model2vec skips MPS on torch ≥ 2.8), at 1.5–1.9 GB peak RSS. The models are 26 MB (256-d) and 51 MB (512-d).
  - **Docs build:** 77 s (256-d) and 75 s (512-d), at 2.3 and 2.9 GB peak RSS. semble's default takes 63 s.
  - **Query:** p50 46 ms for the 256-d model, against 45 ms for the default. The 512-d measurement ran under heavy load and is not quoted.
- **Why it fails:** a distilled model embeds each vocabulary token once, with no context, and averages the tokens of a chunk. gte's gain is on paraphrase queries, which depend on the context that a forward pass over the whole chunk supplies.
- **Not tried:** tokenlearn training on top of the distilled model, and a corpus vocabulary. Training on gte's outputs needs gte to encode a training corpus, which costs a transformer pass over that corpus, so it is not the cheap lever this check was looking for.

## 5. Verification

- **Eval:** the 65-query set on the full corpus, local and fused, as in parent §4. The lever ships only if it still meets the rule.
- **Tests:**
  - The encoder contract: shape, norm, `dim`.
  - Cache keying: the same text in two worktrees hits; another model, variant or arch misses.
  - Resume after a kill.
  - The semble seam pin.
  - The missing-extra error.
  - The static fallback while building, and the swap once built.
  - `status`'s progress and estimate lines.
- **Benchmark:** first-build chunks/s and the warm-cache rebuild on M-series, recorded in the commit body.

## 6. Upstream: a pluggable encoder for semble (draft, not filed)

To be filed only with the owner's OK.

> **Title:** Pluggable encoder: let `SembleIndex` take an embedding model object, not only a Model2Vec path
>
> semble's dense leg loads a Model2Vec `StaticModel` (`index.dense.load_model` → `_load_cached`) and uses three things from it: `encode(texts)` in `dense.embed_chunks`, `encode([query])` in `search._search_semantic`, and `dim`. A caller that wants another encoder has to patch the private `_load_cached`.
>
> Why it matters: on a 6.5k-document Markdown corpus (194k chunks, 65 known-answer queries, k = 10), a gte-modernbert-base int8 ONNX encoder behind that seam raised docs-only recall@10 from 0.687 to 0.841 and MRR from 0.531 to 0.622. BM25 and semble's fusion were unchanged. The gain is on paraphrase queries. For code, semble's static default stays the better choice.
>
> Proposal:
> - A small `Encoder` protocol: `name: str`, `dim: int`, `encode(texts: Sequence[str]) -> np.ndarray` (float32, unit norm).
> - `SembleIndex.from_path(..., model=...)` and `load_from_disk(..., model=...)` accept an object implementing it.
> - The cache metadata records `encoder.name` where it records `model_path` today.
> - semble gains no dependency: the encoder lives in the caller's package.
> - Optionally, an entry-point group (`semble.encoders`), so that `model_path="<scheme>:<name>"` resolves through installed plugins.
>
> Non-goals: shipping a transformer runtime in semble, or changing any default. We can send the PR.

## 7. For the owner

- **abundance:** turn the lever on alongside the cloud leg? It costs one ~3 h build per M-series host and gives about +0.10 MRR at equal recall. Or keep abundance on cloud + static, and leave the lever to projects without a cloud leg?
- **Upstream:** file the §6 semble issue, and offer the PR?
- **Order:** the §4 distillation check ran first. It does not meet its rule (+0.003 recall@10), so the choice is between §2 and no local lever at all.

## 8. As built

The code is in `search/src/doc_search/` (`transformer.py`, `encode_cache.py`, `progress.py`, `engines.py`, `tools.py`, `cli.py`); `references/search.md` describes it for users. §2 held, with these differences and additions. The numbers in §1 and §3 are the spike's; they are not re-measured on the built code yet.

- **Builds run in a lane of their own.** A transformer docs build does not take a place in the pool's build line (one semble build at a time, a worktree's docs before its code). It runs in a second lane, one build at a time per pool, so the code index and other worktrees' static builds never wait behind an encode that takes hours. §2 had said only that the pool builds in the background.
- **One encoder per host.** An `flock` per model (`<cache root>/encode/<model>.lock`, holding the owner's pid) lets one process encode at a time: two sessions, or two worktrees' servers, would otherwise encode the same chunks on the same cores. A second process serves its static index while it waits (`status`: `docs: transformer index waiting for another doc-search process on this host (pid N) to finish encoding`), then checks for a saved index and otherwise builds from the cache the first process filled. Validation and saving happen inside the lock so that the waiter finds the saved index. Where `flock` is missing (Windows) or the lock cannot be set up, the build runs unlocked after one warning.
- **The model path carries the revision.** semble records `transformer:gte-modernbert-base@e7f32e3c00f9` (the first 12 characters of the registry's revision), not the bare name. A registry change to a new revision invalidates every saved transformer index (the saved path no longer matches), and the loader refuses a path no current entry has. §2's cache key already held the revision (as the model id), so the encode cache misses too.
- **A stale saved transformer index serves while it refreshes.** A restart behind another worktree's first build would otherwise leave docs building for hours. A transformer refresh is rechecked at most every ~3 min: the cooldown is 3 times the last build's seconds, with those seconds capped at 60 (`TRANSFORMER_COOLDOWN_CAP_S`), because a 3.2 h first build would otherwise delay a doc-edit refresh by about 10 h, and a refresh from the encode cache takes about a minute. A saved index that does not load (model files missing, say) falls back to the static index.
- **Evicting a worktree cancels its queued transformer build.** A build that waits for the static builds or for a place in the lane gives its places back and leaves; one that holds the lane or the host lock, or is saving, keeps the worktree resident until it ends.
- **The command line builds in the foreground, with no fallback.** `index`, `query` and `eval` build the transformer index themselves (the fallback is the server's), and print `doc-search: docs: transformer index …` progress lines on stderr every 30 s. The `semble-single` eval leg is skipped for a transformer docs model, since one index would encode the code with it.
- **Status.** Copy and fields, as built:
  - `docs: transformer index building, N / M chunks encoded, ETA … (R chunks/s; K from the encode cache)`, with the rate over the last minute of encoding.
  - Before the build starts, `queued` shows an upper bound: `docs: transformer index queued; at most 3 h 22 min for 194,564 chunks at ~16 chunks/s on this host (less for chunks already in the encode cache)`. It counts every chunk, ignores cache hits, and rounds down. Only arm64 macOS (16 chunks/s) and Intel macOS (3.6) have a rate; Linux gets no estimate until it is measured.
  - A build in another process is read from a file it publishes under `<cache root>/encode/progress/` (at most once a second; removed when the build ends, ignored when its process is gone).
  - The status JSON gains `docs.transformer` (`model`, `progress`), `cache.docs_fallback` and a top-level `encode_cache` (`path`, `bytes`).
  - `ready` counts a valid static fallback as ready. It describes what the MCP server can answer now; the command line instead builds the transformer index, so `cache.docs` is the key that says the transformer index exists.
- **The encode cache is a rowid table.** `vectors (key BLOB PRIMARY KEY, vec BLOB NOT NULL)`, WAL. The first design was `WITHOUT ROWID`; with ~3 KB vector rows that overflows the table's pages, and reading the 194,564 keys of abundance took 115 to 125 s, against 2.5 to 6 s as a rowid table. The cache is 764 MB for abundance's 183,970 distinct chunk texts (194,564 chunks). A cache location that cannot be written degrades the cache, the host lock and the progress file to nothing, with one warning each, and never fails a build. The key is the sha256 of the model id (source and revision), the ONNX variant, the token limit, the onnxruntime version, the CPU architecture and the text. Query strings are never stored.
- **Packaging.** The extra is `onnxruntime`, `flatbuffers` and `protobuf`, with onnxruntime pinned by marker: 1.31 on arm64 macOS (macOS ≥ 14) and Linux, 1.23.2 on Intel macOS, which has no Python 3.14 wheel (so Python 3.11 to 3.13 there; the package's `.python-version` is 3.12). The launcher adds `--extra local-transformer` when `docs.model` is a string starting `transformer:` (after `--extra cloud` when both apply), and `--all-extras` when `jq` is missing. Without the extra, the docs index fails with `docs.model transformer:gte-modernbert-base needs the local-transformer extra` (shown by `status`; no build, no fallback).
- **Config and environment.** `docs.threads` (1 to 256, or `null` for the performance cores less two, at least 2) and `DOC_SEARCH_CACHE_LOCATION` (an absolute path for the cache root) are new. An unknown name in `docs.model` is `invalid config: docs.model: unknown transformer model …`.
- **The Intel warning** is logged once per pool, for a first build; `status`'s model line names the Intel rate there.
- **Not yet done.** Re-measuring the first build, the warm second worktree, memory and query latency on the built code, on a quiet M-series host, and the live test (`search/tests/test_live.py`, `DOC_SEARCH_LIVE=1`) on that host. The numbers in `references/search.md` are §1's and §3's until then.
