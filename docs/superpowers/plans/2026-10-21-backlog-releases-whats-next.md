# Backlog, v3.5.0 / v3.7.0 releases and abundance adoption — what's next (handoff, 2026-10-21)

Session: `doc-superpowers-33` on w-mm. It stops here because the account is switching. Nothing it started is still running: every PR it opened is merged, and every worktree it used is removed (this note's own branch excepted).

## What this arc shipped

| Item | Where | State |
|---|---|---|
| Backlog #20 #21 #23 #24 #27–#31 #33 | PR #43 → **v3.5.0** (tag on `a6a3b72`) | merged, issues closed |
| Ledger upkeep / filing / declare (#39, part of #36) | PR #46 (built by session `doc-superpowers-70`) → **v3.7.0** (release commit `2f92dbb`, merge `0e0401b`) | merged; GitHub Release created; #39 closed; #36 left open as the tracker for #37 #38 #40 #41 |
| v3.6.0 (doc-search) | PR #44, cut by the doc-search session | not this session's work |

Releases follow the #28 flow: run `scripts/check-ci.sh` in full, tag the release commit, push the tag, then merge. `check-version --tag --remote origin` confirms it. GitHub Actions is billing-locked, so the local `check-ci` is the gate.

## abundance-mvp (all merged)

| PR | What |
|---|---|
| #3022 | pin → v3.5.0 for cloud VMs |
| #3023 | the pre-push ledger leg calls upstream `ledger validate --pushed` instead of a local copy of the check |
| #3031 | doc-search cutover. `abundance-docs` is removed from `.mcp.json`. The cloud leg is on (`abundance-mvp`, `us-west1`, `(default)` `doc_chunks` / `corpus_meta`). `scripts/docs_corpus/catch-up.sh` now writes with `doc-search index --cloud --catch-up`, with exactly the release the pin names (exit 7 if that release isn't installed). The old indexer refuses writes unless `DOCS_CORPUS_LEGACY_WRITE_ALLOWED=1`, a rollback switch |
| #3041 | adopt v3.7.0. Pin `min/tag/sha` → 3.7.0. A read-only `ledger upkeep` step in the `review` actions of ios-superpowers (10b) and backend-superpowers (6a). The plan convention is frontmatter `issue: <key>`; 7 row-only plans were backfilled. A SPEC-OPS-021 follow-on note |

Embeddings in abundance now:
- code: local semble `potion-code-16M-v2`;
- docs, local leg: the same model, plus the exact-identifier leg;
- docs, cloud leg: Vertex `gemini-embedding-001`, 768-d.

Docs are fused by file.

Hosts: w-mm and w-mbp both run plugin **3.7.0**. On w-mbp the doc-superpowers marketplace is pinned by `ref` in **both** `~/.claude/settings.json` (`extraKnownMarketplaces`; there it is a real file, not the dotfiles symlink) and `~/.claude/plugins/known_marketplaces.json`. Bump both together, or the marketplace reads "not found". The backups are `*.bak-docsp-v360` / `*.bak-v360`.

## Next steps

1. **gte docs model (#45).** Owner direction: abundance's local docs leg moves to gte-modernbert once it ships. The work belongs to the session "doc-search: gte local-transformer lever + encode cache (#45)", worktree `mystifying-rosalind-516af1`. Its eval gate is met (local docs leg 0.846 / 0.635, against 0.687 / 0.531 for the static model). Still owed before its PR: the final-review fix wave, the full check-ci, and a quiet-host re-measure. It ships as 3.8.0 or later. When it lands:
   - upgrade the plugin on both hosts first, because catch-up.sh exits 7 without the pinned release;
   - bump abundance's pin;
   - set `docs.model` in `docs/search/config.json`.

   The first build is about 3–5 h per M-series host (the encode cache is shared by its worktrees); on the Intel w-mm it is much slower.
2. **Retire `mcp_servers/abundance_docs/`** (spec §11 step 6, second half): once the owner approves after the eval. #3031 recorded fused 0.93 / 0.80 against cloud-only 0.92 / 0.74 on the 66-query set. Also update the unapplied terraform alert text, which still names the old indexer; that needs a terraform plan review.
3. **Watch the first catch-up** under the new writer. The expected result is an ordinary catch-up, with no full rewrite: the stamp has no `embedder_id` / `chunker_version`, and doc-search adopts it. The log is `~/.cache/abundance-docs-catch-up/` (`driver.log`, `catch-up.log`).
4. **Push advisory** (`undeclared-contract-change`). It is on in abundance. On the last 15 PRs it fired on 2, both real (ops-47's search flags, chat-340's SPEC-UI-013), and it adds about 20–45 s to a first push on w-mm. The opt-out is `validate.undeclared_contract_change: false`.
5. **Open doc-superpowers issues:** #37 (plan-authoring recipe), #38 (`ledger backfill`), #40 (unattended relation policy), #41 (contract grain audit), and #36 (their tracker). #36's own "Done when" says each row ships or is declined.
6. **Peer worktrees left alone** (not this session's): the ones under `/Volumes/abundance-worktrees/abundance-mvp/doc-superpowers/`, `.claude/worktrees/ledger-upkeep-filing-wrapper` (#46, merged; its owner `doc-superpowers-70` may delete it) and `.worktrees/spec-claims-design`. `/cleanup-review` audits them.

## Coordination

- Kill only PIDs you started. A broad `pkill -f <suite>` has killed other sessions' runs twice on w-mm.
- Whoever cuts a release runs the full `check-ci`, tags, pushes the tag, then merges, and creates the GitHub Release (one per release).
