---
date: 2026-09-27
status: Open
priority: P1
type: bug
component: doc-index
source: sweep-skill
cluster-key: sweep-skill:full-repo:I-2
run-id: 05ea982
related-files:
  - scripts/doc-tools.sh
  - scripts/test-doc-tools.sh
  - skills/doc-superpowers/SKILL.md
  - docs/issues/2026-07-29-index-write-is-not-atomic.md
screenshots: null
axiom-agent: null
branch: null
design-doc: null
report: docs/plans/2026-09-27-full-repo-05ea982-audit-findings.md
---

# I-2 — The index persistence layer assumes one uninterrupted writer

> Cluster **I-2** of sweep run `05ea982`, ranked #3 of 14. Evidence lives in the
> [findings index](../plans/2026-09-27-full-repo-05ea982-audit-findings.md) (S1, X). The fix is
> **Task 2** of the [fix plan](../plans/2026-09-27-full-repo-05ea982-fix-plan.md). It supersedes the
> fix proposed in `2026-07-29-index-write-is-not-atomic.md`.

## Summary

Six verbs write `docs/.doc-index.json`. Each does its own read-modify-write:
- none of them takes a lock;
- five truncate the target with `>`;
- the INT/TERM traps clean up and then **resume**;
- a 0-byte or non-object file reads as a valid, empty index.

The skill's `update` action dispatches one agent per stale doc, and each agent calls
`update-index`. That is exactly the concurrent-writer case this layer cannot handle.

## Incorrect assumption

**A3:** "There is one writer, it is never interrupted, and the file is always valid JSON."

## Verified evidence (measured)

- `doc-tools.sh:311,503`: the traps delete the accumulators and then resume. The results:
  - Single-pid TERM at 1.5 s: `build-index` installs a **truncated** index (225/300 entries), rc 0.
  - `timeout -s INT` (Ctrl-C-like) was ignored in 2 of 5 runs.
  - `{ sleep 10; } | timeout 3 build-index`: TERM is swallowed while the verb is blocked on stdin, so
    it runs to EOF and installs an **empty** index.
  - `check-freshness` after TERM prints a summary that disagrees with its own `.docs`.
- `:701+792, 814+918, 949+980, 1018+1089, 1131+1167`: no lock. Ten parallel `update-index` runs lose
  9 of 10 updates, all with rc 0.
- The same writers: two overlapping truncating writes leave a valid JSON prefix followed by a stale
  tail. The file is permanently unparsable (6 of 25 mixed-writer bursts). The hooks' `|| exit 0` then
  silently disables the gate.
- `:485-488,627-656,694-701,811-814`: the index shape is never validated.
  - A 0-byte index gives `check-freshness` rc 0 with every doc untracked.
  - `add-entry` prints "Added 1 entry" and leaves a 1-byte file.
  - Racing readers reported stale 0 in 7 of 209 runs.
- `:701-980,1131-1167`: each write verb re-parses the whole index once per path. That is O(k·N),
  or 205 ms/doc for `update-index` at N=4,000.
- `:437,453`: `mktemp` + `mv` installs the index with mode 0600.

## Proposed fix (fix plan Task 2)

One internal primitive that every writer uses:

- `_index_load`: a shape-validated snapshot.
- `_index_lock`: a portable `mkdir` spin-lock (`flock` is not on macOS).
- `_index_apply <jq-program>`: lock → snapshot → one jq pass over the batch → tmp file beside the
  target → `chmod` to the prior mode → `mv`.
- Traps: `EXIT` cleans up; `INT` exits 130; `TERM` exits 143. Never resume.

Writers report the keys they *actually* changed. A no-op writes nothing. Every writer becomes
O(N + k).

## Acceptance criteria

- [ ] `kill -TERM` mid-`build-index` leaves the previous index byte-identical, rc ≠ 0.
- [ ] `{ sleep 3; } | timeout 1 build-index` leaves the index unchanged.
- [ ] 10 parallel `update-index` runs on 10 stale docs leave 0 stale.
- [ ] A writer racing a reader for 10 s: the index always parses.
- [ ] A 0-byte index makes every verb exit non-zero with a clear message.
- [ ] The resulting index is mode 0644 under umask 022.
- [ ] `update-index` of 50 docs on a 4,000-entry index takes < 1 s (was ≈10 s).

## Related

- `docs/issues/2026-07-29-index-write-is-not-atomic.md` is still open. The sweep adds two root
  causes the tmp+mv fix alone would not address: the resuming trap, and concurrent writers.
  - That issue's exposure premise (the post-commit hook runs `update-index`) is false; see I-6.
  - Mark it Resolved when this cluster closes.
- The foundation for I-3 (`set-code-refs`, batch `move-entry`) and I-4.
