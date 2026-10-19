# The work-ledger config: the defaults (design §B, verbatim; "validate" from
# 3.3.1), deep-merged under the host's docs/ledger/config.json. Run as
#   jq -n --argjson h <host-config-object> -f config.jq
# jq's `*`: objects merge key by key, recursively; arrays and scalars
# (including null) in the host replace the default, so a host may give a
# `fields` value as one name where the default is a list of candidates.
# One exception: a null `base` takes the default (origin/main) — every reader
# maps a non-string base to "" (no base), which is never what an explicit
# `"base": null` means.
{
  "schema": "ledger-config/1",
  "base": "origin/main",
  "items": { "globs": ["docs/issues/*.md"], "archive_globs": ["docs/archive/issues/*.md"], "adapter": null },
  "fields": { "key": "key", "ledger": "ledger", "status": "status", "severity": ["severity", "priority"],
              "date": "date", "summary": "summary", "changes": "changes", "consumes": "consumes", "relates": "relates",
              "superseded_by": "superseded_by", "owed": "owed", "aliases": "aliases", "paths": ["related-files", "code_refs"] },
  "status": { "open": ["open", "in progress", "draft", "triage"], "fixed": ["fixed", "resolved", "done", "completed"],
              "closed": ["closed", "obsolete"], "wontfix": ["won't fix", "wontfix", "wont-fix", "not planned"] },
  "severity_order": ["P0", "P1", "P2", "P3"],
  "resolution_heading": "## Resolution",
  "log_heading": "## Log",
  "doc_columns": { "spec": ["spec", "adr", "design-spec"], "plan": ["plan"], "handoff": null },
  "keys": { "mode": "cas", "remote": "origin", "counter_ref": "refs/doc-superpowers/ledger/counters" },
  "trailers": { "claims": ["Ledger-Claims"], "claims_by_path": [], "claims_by_ref": ["Fixes", "Closes", "Resolves"], "contract_change": "Contract-Change", "ack": "Ledger-Ack",
                "since": null },
  "inflight": { "enabled": false, "ref_prefix": "refs/doc-superpowers/inflight", "host_id": null, "max_age_days": 21, "pre_push_check": null,
                "pull_refs": "" },
  "views": { "branch": "doc-ledger-views", "recent_days": 14, "html": true },
  "cache": { "remote_ttl_minutes": 10 },
  "adapters": { "pr": null, "contracts": null },
  "state_watch": { "paths": [], "patterns": [] },
  "validate": { "require_relations": null },
  "init": { "stub_defaults": {} },
  "legacy": "docs/ledger/legacy.json",
  "legacy_ids": [],
  "legacy_ledgers": {}
} as $d
| ($d * $h) | if .base == null then .base = $d.base else . end
