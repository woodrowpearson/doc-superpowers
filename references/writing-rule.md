# The writing rule — the block a project copies

This is the rule for the text another person or agent reads: docs, plans, issues, pull-request (PR) bodies, commit messages and instruction files. A project copies everything from the opening marker line to the closing marker line, both included, into its `AGENTS.md` or `CLAUDE.md`, unchanged, and adds its own readers below the block.

`references/writing.md` holds the key format, the lint that counts what it can of the rule, and how to run it.

<!-- doc-superpowers:writing-rule v3.14.0 -->
## Writing

Every text another person or agent reads follows this rule: docs, plans, issues, pull-request (PR)
bodies, commit messages and instruction files. doc-superpowers' `references/writing.md` holds the
key format, the lint and how to run it.

**Everywhere.**

1. Know the reader and the job they do with the text. Put first what that job needs first.
2. Every code (a decision, issue, spec, record, run or finding id) has words before it with the
   code in brackets, a link, or an entry under `## Key`. Treat shorthand that is not a code the
   same way.
3. GitHub links issue and PR numbers, so a `#` and a number passes in PR bodies, issues and
   comments. In a committed file it needs a link.
4. Name a thing by what it does. Put an identifier in backticks after the words, and only where
   the reader needs it to act.
5. Short sentences: at most 35 words in the terse register, 40 in the full one.
6. Keep each claim within its evidence, and say what was not checked.
7. Detail goes in a linked file. The text keeps the conclusion and the link.

**Terse** (read between other work): one idea per list item, at most two sentences and 50 words.
Plans, issues, PR bodies and agent instructions are terse.
**Full but plain** (read to learn the system): complete, with each term defined on first use and
one term per concept. Specs, decision records, designs and generated docs are full but plain.

**What comes first, by scenario.**

- Someone decides: the question, the options, the recommendation and why, the date needed,
  evidence by link.
- Someone reviews a PR: what changed, in one sentence; what must hold before it merges; what was
  not run.
- Someone picks up an issue: what is wrong; how to see it; what done looks like.
- Someone follows a plan: the steps, each with its files and its check.
- An agent follows instructions: the rules, then the commands.
- Someone learns the system: what it decides or requires, then why, then the detail.

Add your project's own readers below this block.
<!-- /doc-superpowers:writing-rule -->
