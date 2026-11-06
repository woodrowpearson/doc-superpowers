# Security

## Reporting a vulnerability

Report it privately through this repository's **Security → Report a vulnerability** tab (GitHub private vulnerability reporting). Please do not open a public issue. Say what an attacker controls and what they gain, with a way to reproduce it if you have one.

## Supported versions

Fixes go into the latest release. There are no backports: upgrade, then re-run `hooks install --ci` if you use the CI tier, because its workflows and step scripts are copies in your repository.

## What is trusted

doc-superpowers reads repositories and runs in other people's CI, so the question is what an attacker's input can reach.

| Input | How it is treated |
|---|---|
| Docs, frontmatter, `docs/.doc-index.json`, ledger items, ref names | Data. Crafted content must not run commands. A case where it does is a vulnerability. |
| `docs/ledger/config.json`, `docs/spec-claims/`, `docs/search/config.json` | **Code, by design.** See below. |
| `docs/writing/config.json`, `docs/writing/ceilings.json` | Data. Crafted content must not run commands. The config's code patterns compile as regular expressions in Python's engine, and the lint sets no timeout of its own, so a pattern that backtracks badly slows the run until the caller's budget or CI timeout ends it. |
| A pull request from a fork | Never runs with this workflow set's secrets: the AI jobs check that the head repository is the same one. |
| A pull request from a same-repository branch, an `@claude` comment by a member | Instructions can reach the AI agent, which holds secrets. See below. |

### Repository config is code

These run commands that the repository names:

- `inflight.pre_push_check` in `docs/ledger/config.json` runs through `sh -c` from the ledger's git hooks.
- Items and pull-request adapters named in the ledger config run as programs.
- Spec-claims adapters run repository paths, and the tests those adapters run.
- doc-search's launcher and its hook entries are committed files that your client runs.

So with the ledger or claims tiers installed, **checking out a hostile branch and committing can run that branch's command**. It is the same trust you give a repository's `Makefile` or `package.json`. Do not install these tiers in a clone you do not trust.

### AI CI jobs

A steered agent can use whatever its job holds. The scoped tool lists and the commit checker keep an agent on task; they are not a sandbox. `.git/config` holds no token, but the agent's process environment does. `references/hooks.md`, *What an AI job's agent can reach*, states what is reachable and what to protect. Protect the base branch and `release/**` before you install an AI workflow.

The accepted `issue_comment` trigger in `doc-review-pr.yml` runs only for a member's comment on a same-repository pull request, and its job has `contents: read`.

## The release a project's CI fetches

The AI workflows fetch this plugin at run time, in jobs that hold secrets, so this is the most valuable place to attack. `install --ci` records the commit the release tag names as `DOC_SUPERPOWERS_COMMIT`, and `prepare-agent.sh` stops the job if the tag holds any other commit. Treat that failure as a possible compromise. `install --ci` refuses the same move for a version already installed, until you set `DOC_SUPERPOWERS_PLUGIN_COMMIT` to accept it. The pin is taken on first use: it detects a tag moved after you installed, not one that was already wrong when you did.

This repository's `v*` tags are protected against updates and deletion, and published releases are immutable.

## Tool versions

These are the floors the code needs. Below the advised version it still runs, and `doc-tools.sh` warns on stderr once a day (`DOC_SUPERPOWERS_NO_TOOL_ADVICE=1` silences it), except for python3, which has its own check. The floors stay low because distributions backport fixes under old version strings and stock macOS ships older tools, so a hard failure would block users without protecting them.

| Tool | Floor | Advised | Why |
|---|---|---|---|
| bash | 3.2 | any | No reachable CVE at the floor: Apple's 3.2.57 carries the Shellshock patches. |
| jq | 1.6 | 1.8.2 | Crafted JSON or strings reach crashes and memory bugs in older versions, including CVE-2026-32316, -33948, -39979, -40164, -40612, -47770 and -49839. Stock macOS ships 1.7.1. The CI templates install a checksum-verified 1.8.2. |
| git | 2.36 for claims over merges | 2.43.7, or the fix on your branch (2.44.4, 2.45.4, 2.46.4, 2.47.3, 2.48.2, 2.49.1, 2.50.1) | CVE-2025-48384 and -48385 on cloning a hostile repository; CVE-2022-23521 on reading a hostile `.gitattributes`. Stock macOS Command Line Tools ship 2.39.5. |
| git, with in-flight refs | | 2.55.0 | CVE-2024-52005: a remote's terminal control characters reach your terminal during `git fetch`. |
| gawk, where `awk` is gawk | | 5.4.1 | Four 2026 CVEs, one in the `getline` path these scripts use. BWK awk and mawk: nothing reachable. |
| python3 | 3.9 | 3.12 or later | Only the writing lint runs it, with the standard library alone, and a host without it loses nothing else. 3.9 is past its end of life and gets no security fixes, so the floor is where the lint works, not a version to prefer; stock macOS Command Line Tools ship 3.9.6. There is no daily warning: the writing verbs probe the interpreter themselves and exit 3 below the floor. |

As `git(1)` advises, do not run git, or this plugin, inside a `.git` that came from an untrusted archive.

## The writing lint

- It reads Markdown and git output, downloads nothing, and writes a file only through `ceilings --update`. It runs only when called.
- The engine runs as `python3 -I -B -X utf8`: `PYTHON*` variables, the user site and the current directory stay off its import path, and it writes no bytecode. `DOC_SUPERPOWERS_PYTHON` names the interpreter it runs, so it is as trusted as `PATH`.
- The lint sets no timeout, and a pattern is not the only way to make it slow. One very long line, or a reorganisation with many deleted and added sentences, can run for minutes. Give the caller its own budget.

## doc-search

- Python dependencies are locked with hashes (`search/uv.lock`, always `--frozen`). `scripts/check-ci.sh dep-audit` checks every locked package against the advisory databases, and Dependabot watches the lock.
- The opt-in transformer model is fetched from Hugging Face at a pinned revision, as an ONNX graph and a `tokenizer.json`. No pickle is loaded.

## Checks

`bash scripts/check-ci.sh zizmor dep-audit gitleaks` runs the workflow audit (over the rendered templates too), the lock audit and the secret scan over the history. `.gitleaksignore` holds the reviewed false positives, and an accepted zizmor finding carries its reason inline.
