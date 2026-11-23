# doc-search: a cloud leg for code — design

**Status:** Draft (under review)
**Date:** 2026-11-22
**Issue:** #99 (the repeatable benchmark; this design is its "Then" section)
**Builds on:** `2026-10-19-doc-search-design.md` §8 (the cloud docs leg), `2026-11-10-doc-search-shared-server-design.md`

## 1. Why

doc-search's cloud leg embeds docs with Vertex `gemini-embedding-001` and searches them in Firestore. Code has had only semble's local static model. A spike measured what a cloud leg would give code, on a consumer repository at one commit of its main branch: 6,571 code files, 169,875 semble code chunks, 60 known-answer questions (30 that name an identifier, 30 paraphrased). k = 10; recall@10 / MRR.

| Code leg | All (60) | ident (30) | paraphrase (30) |
|---|---|---|---|
| local (semble, today) | 0.733 / 0.630 | 1.000 / 0.983 | 0.467 / 0.276 |
| cloud alone, `CODE_RETRIEVAL_QUERY` | 0.983 / 0.825 | 1.000 / 0.861 | 0.967 / 0.789 |
| cloud alone, `RETRIEVAL_QUERY` | 0.928 / 0.666 | 1.000 / 0.756 | 0.856 / 0.577 |
| equal RRF (k = 60), `CODE_RETRIEVAL_QUERY` | 0.978 / 0.803 | 1.000 / 0.983 | 0.956 / 0.622 |
| shaped weighted RRF (identifier: 1 : 1; else cloud 10 : 1) | 0.983 / 0.882 | 1.000 / 0.983 | 0.967 / 0.780 |
| **local for identifier-shaped, else cloud 10 : 1 (this design)** | **0.983 / 0.873** | **1.000 / 0.967** | **0.967 / 0.780** |

All 30 identifier questions are identifier-shaped by §7's rule and none of the 30 paraphrased ones is.

The same repository's docs, for comparison (its 66-question docs set): local 0.808 / 0.607, with the cloud fused 0.924 / 0.796. Code gains more than docs did: paraphrased code questions go from finding under half the right files to nearly all.

Caveats: the question set is small, and an agent wrote it while reading the code. The fusion weights were tuned on the same 60 questions. The benchmark of #99 re-checks them on a second, independently written set.

## 2. Goals, non-goals, anti-goals

**Goals**
- A cloud leg over code, opt-in per repository, beside the cloud docs leg and built the same way: a guarded writer, a Firestore collection with a commit stamp, a read path that drops branch-changed files.
- The user chooses which corpora go to the cloud: docs, code, or both.
- Paraphrased code questions find the right file; identifier questions keep local's ranking.
- `status`, `check` and `eval` show the code leg as they show the docs leg.
- A search whose cloud leg did not answer says its results are local-only, and the agent asks the user before relying on them.

**Non-goals**
- A new embedding model, a new vector store, or a server-side index (Vertex Vector Search).
- Changing the local legs, their memory, or the idle unload.
- The offline benchmark cache and the `--max-usd` guard of #99 (that issue stays open for them).

**Anti-goals**
- Code leaving the machine without the repository saying so. The design of 2026-10-19 named "code leaves the machine" as an anti-goal; this design reverses it only for a repository that sets `cloud.code`, and the privacy section says what goes where.
- A branch writing the shared corpus. The base guard, stamp, lease and orphan cap carry over unchanged.
- A cloud failure taking search down. The local legs always answer.

## 3. Approaches

1. **A Firestore collection, like the docs leg (chosen).** One more collection with its own stamp and lease, written by `index --cloud`, read with `find_nearest`. It reuses the writer's guarantees and the reader's bounds. Cost: a flat index reads every vector, so a search over about 170k chunks is slower than over the docs collection; it runs beside the local legs under `cloud.timeout_s`.
2. **A downloaded vector file per host.** The writer publishes the matrix (about 260 MB at float16 for 170k × 768); each host searches it in memory. Fast queries, but a new sync path, per-host disk and memory on hosts that already swap, and a second consistency model beside the stamp.
3. **Vertex Vector Search.** An approximate index that scales, but it bills per node-hour whether anyone searches, and it is new infrastructure for every consumer.

## 4. Configuration

`cloud` keeps its shape; two keys are added.

```json
"cloud": {
  "vertex":    { "project": "…", "location": "…", "model": "gemini-embedding-001", "dimensions": 768 },
  "firestore": { "project": "…", "database": "…", "collection": "doc_chunks", "meta_collection": "corpus_meta" },
  "docs": true,
  "code": { "collection": "code_chunks" }
}
```

- `cloud.docs` (boolean, default `true`): the docs corpus goes to the cloud. `false` turns the docs leg and its writes off while `cloud` stays set. Existing configs keep today's behaviour.
- `cloud.code` (object or `null`, default `null`): the code corpus goes to the cloud. `{}` takes every default. Keys:
  - `collection` (default `"code_chunks"`): the Firestore collection, in `cloud.firestore.database`.
- The code stamp is `<meta_collection>/code-index`, the code lease `<meta_collection>/code_catch_up_lease`. Neither is configurable: they live beside the docs ones and cannot collide with them.
- `cloud.docs: false` with `cloud.code: null` is a config error (`cloud` would do nothing).
- `cloud.code` needs `code.enabled: true`: the code leg it fuses with is the local code leg.
- Unknown keys under `cloud.code` are errors, as everywhere else.
- `DOC_SEARCH_CLOUD=0` still turns the whole cloud off.

- `cloud.code.exclude` (glob list, default `[]`): code paths never sent, on top of the built-in deny list (§10).
- `cloud.code.timeout_s` (seconds, default `10`): the code leg's own per-call budget; its deadline is this plus the grace, so a code search waits at most about 16 s on the cloud, not 26.

**Update order.** A release before this one rejects `cloud.code` and `cloud.docs` as unknown keys, so `check` on a 3.19.x host reports "invalid config" (not-ready when required, search off when not). What a host runs is the release its launcher finds (the newest cached plugin version, `DOC_SUPERPOWERS_ROOT`, a Codex checkout), which a repository's own pin may not decide; a cloud VM may install what the pin names. So a repository adopts in this order: (1) every host's newest cached release, and the pin, at ≥ 3.20.0, sessions restarted; (2) whatever drives `index --cloud` and reads its output updated for this release (§6); (3) the code collection's vector index created; (4) optionally the first `index --cloud --corpus code` run by hand from the base branch with a scratch config, so the flip finds a stamp; (5) last, one commit setting `"requires": ">=3.20.0"` with `cloud.code`. The flip sends code to the cloud, and a driver that runs on session start uploads on its own from then on. From this release on, `check` reports the `requires` floor before parsing the rest of the config, when the raw text's floor is above the running version, so a later key added this way reads "plugin too old", not "invalid config".

## 5. The code corpus

**Files.** *In scope* is a path test only (it must answer for a deleted path, as `Corpus.in_scope` does): HEAD's tracked files (`git ls-tree`) that the local code index would hold, not in the docs corpus (a docs-corpus file is the docs leg's, even when the code index also holds it), not matched by the built-in deny list or `cloud.code.exclude`. "Would hold" applies semble's own walker rules to HEAD's tree: an extension semble's code index takes for `code.content`, not under one of semble's default ignored directories (`node_modules/`, `dist/`, `build/`, `.venv/` and the rest of its list), not matched by any directory's `.gitignore` or `.sembleignore` as committed at HEAD. A parity test holds the set equal to what semble's walker yields over a checkout of the same commit, so archived code a repository keeps out of its local index never reaches the cloud. Size and content are checked when the file is read: over 1,000,000 bytes (a fixed constant, semble's default; not semble's `SEMBLE_MAX_FILE_BYTES` override, so every host writes the same set), binary or not UTF-8, its chunks are purged, not written. The bytes come from `git cat-file`, never the working tree.

**Chunks.** semble's own chunker, `semble.chunking.chunk_source(text, path, language)` with `detect_language(path)`: the chunks the local code leg and the spike used. The stamp records the chunker as `semble-<major>.<minor>`; a stamp with another makes a catch-up a full run, as `chunker_version` does for docs. semble is pinned `>=0.7,<0.8`, so the id cannot change within this release line and a semble patch never forces a re-embed; a test pins the chunk boundaries of fixture files in the main languages, so a lock bump whose patch moves them fails this repository's suite instead of silently mixing cuts (and then raises the id by hand, `semble-0.7.r2`).

**Resumable rewrites.** A rewrite (another chunker or embedder in the stamp) trusts no stored sha, so an interrupted one would start again from zero. Code chunk 0 therefore also carries `chunkerId` and `embedderId`; a rewrite skips a file whose chunk 0 has this run's sha, chunker and embedder, so a rewrite cut short resumes where it stopped. The docs corpus's documents are unchanged.

**Fields** (deterministic ids, a hash of path and ordinal, as the docs writer): `path`, `chunkIndex`, `text` (the chunk, at most 6,000 characters embedded), `startLine`, `endLine`, `fileSha256`, `chunkerId` and `embedderId` (chunk 0 carries the three a catch-up or rewrite trusts), `embedding` (768, `RETRIEVAL_DOCUMENT`), `language`, `headingPath` (empty), `lastIndexedAt`. No `docType`: code is not filtered by type.

**Firestore index.** One flat vector index on `embedding` (dimension = `cloud.vertex.dimensions`) on the code collection, as the docs leg's unfiltered index:

```
gcloud firestore indexes composite create --collection-group=code_chunks --query-scope=COLLECTION \
  --field-config=field-path=embedding,vector-config='{"dimension":"768","flat":"{}"}' --database=<db>
```

Terraform's `google_firestore_index` wants two `fields` blocks; there the first is `__name__` ascending, as the consumer's existing unfiltered docs index does.

## 6. Writing

`index --cloud [--catch-up|--full|--prune-orphans] [--corpus docs|code]` writes each corpus the config turns on, docs first; `--corpus` limits the run to one. Each corpus runs the writer's full sequence on its own (base guard, stamp, lease, file set, per-file sha check, deletes, orphans, stamp on success), so a docs failure never blocks the code stamp and the reverse.

**Output a driver reads.** With one corpus run (every pre-3.20 config, and `--corpus`), the output and exit codes are byte-identical to today's: no prefix. With both, each report line is prefixed `docs: ` or `code: `, the docs block first. An error line always starts at column 0 with `doc-search: ` and ends with ` (docs)` or ` (code)` when both run; a lease another host holds refuses with the docs writer's text, `doc-search: the corpus lease is held by …`. The exit with two corpora: the higher of the two exits that are not a lease refusal; 2 only when nothing else failed and a lease refused. So a docs failure (1) beside a code lease refusal exits 1, and a driver that maps a lease refusal to "someone else is doing it" never hides the docs failure.

The writer is refactored, not copied: `CloudIndexer` takes a corpus description (file set, chunker, chunker id, collection, stamp and lease names, document fields), and the docs and code corpora are two instances of it.

A first code run embeds every chunk. On the measured repository: about 26M input tokens (about $4–5 at the online rate), about 170k document writes, and about an hour of embedding. Later catch-ups embed only changed files.

## 7. Reading

The code cloud leg is a second `CloudLeg` over the code collection, with its own stamp, changed-path set and failure memory. Its query is embedded as `CODE_RETRIEVAL_QUERY` (the spike's best: +0.06 recall and +0.16 MRR over `RETRIEVAL_QUERY`). It asks for `limit × 3` chunks.

It runs for `scope=code` and `scope=all`, on its own thread, started with the docs cloud leg before the local legs, and is waited for at most its own deadline (`cloud.code.timeout_s` + 5 s + the join margin). It does not run when the search has a `path_prefix` (the nearest 30 of about 170k chunks rarely survive a prefix filter) or when the query is *identifier-shaped* (the spike: on those, the local leg alone scores 1.000 / 0.967 recall@10 / MRR against 1.000 / 0.983 fused, one question one rank lower, for a few seconds and a read bill on every identifier search); the local code leg answers alone. A word is identifier-shaped when, stripped of surrounding quotes, brackets and punctuation, it has at least 4 characters and contains `_`, `.`, `/`, a digit, a lowercase letter or digit followed by an uppercase letter (`ItemDetailSheet`, `getURL`), or two uppercase letters followed by a lowercase one (`HTTPServer`); `APIs` and `URLs` count, `CTA` and `end-to-end` do not. Its allowed set is the local code index's own files (`indexed_files`, so `.sembleignore` holds on the reading side too) minus the docs corpus's. Hits on branch-changed files are dropped, as for docs, and the local code leg serves those files.

**Fusion.** The local code leg's code-kind hits and the cloud code hits are fused per file by weighted RRF (k = 60), each leg collapsed to one hit per file first (its other chunks counted in `more_in_file`), the local chunk representing a file both found, cloud weighing 10 : local 1 (the spike's best on paraphrased questions; identifier-shaped ones never reach fusion).

In `scope=all` the local code list also carries doc-kind hits (corpus files the code index holds); they keep their positions in the list and the fused code hits fill the others in order. The list then joins the docs list exactly as the local code list does today (`interleave_with_floor`), so the docs/code floor is unchanged. When the cloud code leg is off, failed, skipped or not run, the code list is the local one, as today.

## 8. Status, check, eval

- `status`: a `cloud code:` line per worktree, from the code stamp, as the `cloud:` line is from the docs stamp (stamp commit, its relation to HEAD, chunker, the branch-changed count of code-corpus files). Never a scan of the collection.
- `check`: no new row. The code cloud leg's failures are notes, as the docs cloud leg's are.
- `eval`: a `cloud-code` leg (the cloud code leg alone, asked with the code index's file set) after `cloud`; the `code` leg becomes the fused code list when the code leg is on, as `docs` already includes the docs cloud leg. A code question set uses the existing JSONL format; `kind` is free text.

## 9. Cloud first, local on request

A search whose cloud leg (docs or code) failed, timed out or was skipped answers from the local legs today, with a note in the header that agents easily read past. The owner wants to be asked instead:

1. The header carries `local_only`: one `(kind, reason)` pair per kind (`docs`, then `code`) whose configured cloud leg the search used did not contribute. The reason is `failed` (an error, no credentials, a missing extra), `timeout` (over its deadline, or held back by the 60 s failure memory after a timeout), `no-stamp` (the corpus has never been written) or `building` (docs only: the docs index is still building, so the leg was not started). Not for a cloud that is unconfigured, turned off by `DOC_SEARCH_CLOUD=0`, not run because of a `path_prefix`, an identifier-shaped query or an empty allowed set, or that answered with no hits. `scope=all` with the docs cloud answering and the code cloud failing is `(("code", "failed"),)`.
2. The legs' notes keep their exact text (`cloud failed: …`; the code leg's read `cloud code failed: …`, `cloud code skipped: …`), so no note gains a suffix. The rendered header line shows `local-only: code (failed)`, or `local-only: docs (timeout), code (failed)`, after the model labels, and the structured response carries the pairs.
3. The rule reaches every agent: `references/search.md` → *Tools* says it for every repository, and the search-rule block's "use when" widens to a search answer marked local-only. What a caller does depends on the reason and on who it is:

   | Caller | `failed` | `timeout`, `no-stamp`, `building` |
   |---|---|---|
   | A top-level interactive session | The first time in the session: tell the user why, ask whether local-only results are OK before relying on them. A yes holds for the session; a no stops the task and reports the failure. | Rely on the results; mention it once if it bears on the answer. Never ask: these pass on their own. |
   | A subagent | Never ask: say in its report that its results were local-only, and why. | The same. |
   | An unattended run (a scheduled routine, `claude -p`, an agent working while the user is away) | Note it in the run's output or handoff and carry on; never halt. | The same. |

   A session where the cloud is known not to be reachable (a cloud VM without credentials) sets `DOC_SEARCH_CLOUD=0`, which is not local-only, so it never asks. Projects re-copy the block (it reads `outdated` until they do).
4. Nothing in doc-search blocks or waits for the answer: the search still returns the local results at once, so a session that never asks loses nothing it has today.

**uv stays as the host sets it.** The launcher keeps passing `UV_OFFLINE` through and never sets or clears it: a host that keeps uv off the package index (a supply-chain decision) keeps doing so. The one launcher change is the message: when uv fails with `Network connectivity is disabled`, the launcher prints the warm-up the user runs once after a plugin update, with the network on, naming the environment the launcher itself uses (the env hook may set `UV_PROJECT_ENVIRONMENT` or `UV_CACHE_DIR`, which a person's shell does not). It is addressed to the agent as something to ask the user to run, never to run itself (unsetting `UV_OFFLINE` is the user's supply-chain decision), and it is one line, so a probe that keeps only the first `doc-search:` line keeps the command:

```
doc-search: uv is offline and this release's packages are not cached; ask the user to run, with the network on: env -u UV_OFFLINE [UV_PROJECT_ENVIRONMENT='…'] [UV_CACHE_DIR='…'] uv sync --project '<root>/search' --frozen --no-dev --inexact <extras>
```

`serve` and the other verbs print it and exit 1. `check` and `gate` answer through the launcher's existing unrunnable path (a not-ready verdict with this as the fix; `gate` exits 0 with hook JSON), so the hook contract holds.

## 10. Privacy

With `cloud.code` set, the writer sends every in-scope code file's text to Vertex AI for embedding and stores the chunks' text and vectors in the configured Firestore database. Readers send each search query to Vertex. Nothing is sent for a repository without `cloud.code`. `references/search.md` → *Privacy* states this, beside the docs leg's line.

The code extensions include files that can hold secrets (`.tfvars`, `.conf`, `.pem` under `config`). A built-in deny list keeps these out whatever the config: `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `*.tfvars`, `*.tfvars.json`, `.env`, `.env.*`, `*.env`, `id_rsa*`, `id_ed25519*`, `id_ecdsa*`, `*secret*`, `*secrets*`, `*credential*`, `*credentials*`, `.npmrc`, `.pypirc`, `.netrc` (matched on the file name, case-insensitive). `cloud.code.exclude` adds the repository's own globs. Neither replaces a secret scanner: a secret in an ordinary source file is sent with it.

## 11. Performance

Firestore's flat index reads every vector. The docs collection (about 108k chunks) measured 2.7 s p50 warm and up to 14 s cold, with a 1.7 s query embedding; the code collection (about 170k) is about 1.6 times larger. If the time scales with size, that is about 4.3 s warm and about 22 s cold, so the first, cold code search of a session may overrun `cloud.code.timeout_s` (10 s): it answers local-only with reason `timeout`, which asks no one (§9), and later searches are warm. The leg is skipped with a note when it overruns; a failure is remembered for 60 s, as for docs. Identifier-shaped queries never pay it (§7).

Read cost is unmeasured; an estimate (one read per up to 100 index entries scanned) is about 1,700 reads per code search. The measurement below replaces both estimates. If the cold first search proves the common case, a follow-up is a background warm-up query when the server starts.

**Measured before the release, not after.** The branch's writer uploads the consumer's code corpus (the owner-approved first upload, run from the consumer's base branch with this build as `DOC_SUPERPOWERS_ROOT`), then a timing run of the 60 code questions records p50 and p95 of the code leg, end to end, and the Firestore reads per search from the project's usage metrics. The numbers go into `references/search.md` → *Hardware and performance*. The release goes ahead when p95 is under `cloud.code.timeout_s`; otherwise the default budget, the chunk size or the default-on behaviour is revisited first. The writer's full-collection scan (`_indexed_paths`, `SCAN_TIMEOUT_S` = 300 s, set at docs size) is timed in the same run.

## 12. Release

v3.20.0, a minor release (new config keys, a new CLI option, a launcher change). The full `bash scripts/check-ci.sh` gates it. Docs: `references/search.md` (Configuration, CLI, Cloud leg, Privacy, Hardware and performance, Troubleshooting), `scripts/help/search.txt`, `references/search-rule.md` (the widened block, stamped), `RELEASE-NOTES.md`, `CLAUDE.md`'s counts, `docs/codebase-guide.md`. The release notes tell projects that copied the search-rule block to copy it again (it reads `outdated` until they do). Before the release, §11's measurement runs and its numbers go into the docs.

## 13. Left to the builder

- How the corpus description is factored inside `cloud/write.py` and `cloud/read.py`, provided each existing test of the docs path passes unchanged.
- Where exactly the launcher captures uv's stderr for the one offline pattern, provided a test pins it.
- Status line wording, within the shape above.
