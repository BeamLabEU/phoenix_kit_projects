# Codex review — post-merge recheck (2026-10-23)

PR #55 by `timujinne`, merge `dc91c7b`; base `ba9b007` includes Claude's
review. This pass also rechecks the high-risk paths and follow-up findings
from PRs #51–#54. It does not expand into the old, pre-convention PR backlog.

## BUG - MEDIUM — matching msgids did not mean translated output

Claude's review says that the changed setup instruction cannot fall back
to English because its msgid matches the template and all seven catalogs.
The match is correct, but `de`, `es`, `fr`, `it` and `pl` have an empty
`msgstr` for that instruction. Those locales do fall back to English.
This predates the rename; #55 preserved the gap, and the earlier review
mistakenly declared it closed.

Filled this instruction in those five languages, keeping the HTTP header,
endpoints and neutral `ACME` examples intact. Added a runtime regression
that renders the instruction through every configured locale, rejects an
English fallback, and checks the API examples. Estonian and Russian were
already translated and are unchanged.

This is a focused correction to the instruction changed in #55. Other empty
translations documented by Claude for #54 remain a separate translation
backlog; this review does not claim all catalog entries are complete.

## Documentation improvements

The live AGENTS.md history now calls the real project "the host's project"
instead of claiming it was named "ACME Manager". Neutral examples of key
suggestion still use `ACME Manager` → `ACME`. Archived reviews and PR
summaries were left as found; another rewrite would further change the
historical record.

## Other fixes in this pass

- [PR #53](../53-host-hooks-move-lock/CODEX_REVIEW.md): fixed prefixed registry reads.
- [PR #51](../51-subtasks-typed-list/CODEX_REVIEW.md): corrected fixture documentation and the migration overview.
- PR #54 follow-up: the gate found a `plug_crypto 2.2.0` security advisory;
  updated only that lockfile entry to 2.2.1. See the dated addendum in
  [its Codex review](../54-global-api-keys/CODEX_REVIEW.md).
- [PR #52](../52-gettext-split-by-locale-domain/CODEX_REVIEW.md): no further change needed.

## Validation

- Baseline before edits: `mix test`, **2070 tests, 0 failures**.
- Final `mix test`: **2072 tests, 0 failures**. PostgreSQL was available;
  integration and LiveView tests ran (no integration exclusion).
- Focused registry, setup-prompt and schema-prefix checks: **10 tests,
  0 failures**.
- `mix precommit`: **passed** — format, forced compilation with warnings as
  errors, unused-lock check, Hex security audit, strict Credo and Dialyzer.
  Dialyzer used the existing seven suppressions; none were added or widened.
- Staff-absent gate: **passed** — `WITHOUT_STAFF=1 mix deps.get` followed by
  `WITHOUT_STAFF=1 mix compile --force --warnings-as-errors`, using an
  isolated build copy with the staff package removed.
- Prefixed PostgreSQL smoke check: **passed** in an independent VM with
  prefix `pkp_registry_review`. Verified lookup, former keys, reserved / free
  keys and suggestions; the scratch schema was rolled back. Loading the
  original `ba9b007` context in the same setup reproduced the failed lookup.
- `git diff --check`: **passed**.

No schema migration, package version bump or release is part of this pass.
