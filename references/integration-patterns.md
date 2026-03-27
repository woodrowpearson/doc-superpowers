# Integration Patterns

How other skills can integrate with doc-superpowers. doc-superpowers actions are context-agnostic composable primitives — they have zero knowledge of the wrapper skill invoking them.

## Cross-cutting: CLAUDE.md & README.md Sync

Every integration pattern that results in doc changes (new specs, structural changes, new commands) must verify CLAUDE.md and README.md are current. CLAUDE.md is loaded at Claude session start — if it's stale, every subsequent session works with incorrect context. README.md is the project's public documentation — if it lists outdated features, users don't know what the tool can do.

After any doc-superpowers action that creates, moves, or removes files:

1. Check CLAUDE.md sections (Directory Structure, Key Files, Commands) against actual filesystem
2. Check README.md sections (feature list, action list, usage examples) against actual capabilities
3. If stale, update per `references/doc-spec.md` CLAUDE.md / README.md update rules
4. Include CLAUDE.md and README.md changes in the same commit as the doc changes

This applies to all callers — code review callbacks, commit review phases, wrapper skills invoking spec lifecycle actions, and standalone invocations. If your integration creates artifacts in `docs/` or modifies project structure, CLAUDE.md and README.md sync is your responsibility.

## Called BY code review skills (callback pattern)

When a code review skill completes, it should check if doc updates are needed:

```
After code review completes, check:
  1. Run freshness check (script or git heuristic)
  2. If stale docs detected:
     - Print: "Documentation may need updating. Run /doc-superpowers review-pr"
     - Include the list of stale docs in the review output
  3. If structural changes detected (new/removed dirs, scripts, key files):
     - Check CLAUDE.md sections match current state
     - Check README.md feature/action list match current capabilities
     - Include CLAUDE.md / README.md in the list of stale docs if drifted
```

## Called BY commit review skills

Add documentation review as a phase in commit review:

```
Step N: Documentation Review
  1. From the changed files, determine which doc scopes are affected
  2. Run freshness check
  3. If stale docs found, append to review summary:
     "### Documentation ({N} stale docs)"
     List each stale doc with its changed code_refs
  4. Check CLAUDE.md against actual filesystem — if changed files affect
     paths/commands/key files listed in CLAUDE.md, include it in the stale list
  5. Check README.md against actual capabilities — if changed files affect
     features/actions listed in README.md, include it in the stale list
```

## Called BY wrapper skills (spec lifecycle pattern)

Wrapper skills integrate doc-superpowers spec lifecycle actions at pipeline interception points. See `spec-lifecycle-protocol.md` for the full integration guide.

```
Post-brainstorm → spec-generate --design-doc=<path>
                  (spec-generate syncs CLAUDE.md if new dirs bootstrapped)
During plan    → spec-inject --phase=plan --plan=<path> --specs=<paths>
After chunk    → spec-inject --phase=execute --specs=<paths>
Pre-finish     → spec-verify --mode=post-execute --specs=<paths> --design-doc=<path>
                  (spec-verify checks CLAUDE.md currency as part of compliance)
During review  → spec-verify --mode=review --changed-files=<paths>
```
