# Agent Prompt Template

Each dispatched review agent receives this template, filled with scope-specific details:

```
Review documentation for accuracy against current code.

Docs to review:
{list of docs in scope, flagging which are stale}

For each doc:
1. Read the doc completely
2. Read the code_refs directories/files (or inferred code locations)
3. Report:
   - Accurate sections (no changes needed)
   - Stale sections (describe what changed in code vs what doc says)
   - Missing sections (new code not covered by doc)
   - Conflicting info (doc contradicts other docs or code)

Focus on: {scope-specific focus areas}

VERIFICATION REQUIRED: Report findings WITH evidence (exact quotes from doc vs
code). No "looks stale" without specific discrepancies.

Output format:
## {doc filename}
### Status: FRESH | STALE | MISSING_COVERAGE
### Findings:
- [P0/P1/P2/P3] Description of issue
  - Doc says: "..."
  - Code shows: "..."
  - Suggested fix: "..."
```

## Scope-Specific Focus Areas

Generate focus instructions based on detected project type:

| Project Signal | Secondary Signal | Focus Areas |
|---------------|-----------------|-------------|
| `Package.swift` / `.xcodeproj` | `Sources/*/Views/`, SwiftUI imports | SwiftUI views, state management, navigation, accessibility |
| `Package.swift` / `.xcodeproj` | `Vapor`, `Hummingbird`, no UI code | Server-side routes, middleware, model definitions |
| `Package.swift` | CLI tool (no UI framework) | Command parsing, output format, argument handling |
| `package.json` / `tsconfig.json` | `src/components/`, React/Vue/Svelte | Component structure, hooks, state management |
| `package.json` / `tsconfig.json` | `src/routes/`, Express/Fastify/Hono | API routes, middleware, request/response schemas |
| `Cargo.toml` | — | Module boundaries, trait implementations, error handling |
| `go.mod` | — | Package structure, interface compliance, handler signatures |
| `requirements.txt` / `pyproject.toml` | `manage.py`, Django/FastAPI/Flask | API endpoints, ORM models, serializers |
| `firebase.json` / `functions/` | — | Cloud Functions, security rules, schemas |
| `.github/workflows/` | — | CI/CD pipeline accuracy |

## Spec-Aware Review

When the project has `docs/specs/` with formal specs, agents should also check:

| Signal | Focus Areas |
|--------|-------------|
| `SPEC-{CAT}-NNN-*.md` files exist | Check spec `Status` field matches implementation state; verify `code_refs` point to real files |
| Spec has `Status: Draft` but code exists | Flag as P1 — spec wasn't updated during implementation |
| Spec has `Status: Implemented` but code diverged | Flag as P0 — spec claims implementation matches but code has changed |
| Changed files not covered by any spec's `code_refs` | Flag as P2 — unspecified implementation |
| `Source` field in spec points to design doc | Cross-check design doc intent against spec content |

Add these checks to the standard review cycle when specs are detected in the project.
