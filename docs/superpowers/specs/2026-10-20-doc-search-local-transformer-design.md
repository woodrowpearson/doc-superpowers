# Design note: doc-search's opt-in local-transformer docs embedder

**Status:** Proposal, 2026-10-20. Not built. Tracking issue: woodrowpearson/doc-superpowers#45.
**Parent:** `2026-10-19-doc-search-design.md` §4. That section holds the decision rule, the measurement, and every number quoted here.
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
- **Order:** run the §4 distillation check first, as proposed?
