# FOLLOW_UP — PR #18 (AI-translation shared pipeline)

Triaged 2026-06-14 during the quality sweep. Reviewer: `CLAUDE_REVIEW.md`
(findings F1–F4 fixed in-review; O1–O5 were the open items). Each verified
against current code.

## Fixed (pre-existing — in review)

- ~~F1: `present?/1` helper~~ — present in `ai_translatable.ex`.
- ~~F2: documented the adapter rescue~~ — present.
- ~~F3: aligned binding~~ — present.
- ~~F4: +4 adapter tests~~ — present in `ai_translatable_test.exs`.

## Fixed (Batch — 2026-06-14)

- ~~**O1 [MEDIUM]: `"assignment"` AI-translate was half-wired**~~ — the resource
  type was registered in `ai_translatables/0` and fully supported server-side
  (`AITranslatable.fetch`/`source_fields`/`put_translation`, `AITranslateBinding`),
  but `assignment_form_live.ex` had no AI-translate button (project/task/template
  all did). **Wired it** (commit `6dd7a50`): `use AITranslate.Embed`,
  `assign_ai_translation` for the `"assignment"` resource on task-assignment
  edits, and the button/progress/hint row + modal, styled to match the siblings.
  Browser-verified: button renders, modal opens, description disables in flight.
- ~~**O5 [LOW]: no assignment adapter fixture/tests**~~ — added `fixture_assignment/1`
  + adapter tests (`fetch` / `source_fields` / `put_translation` for the
  assignment `description`) in `ai_translatable_test.exs` (commit `6dd7a50`).

## Skipped (with rationale)

- **O2 [LOW]: broadcast suppressed vs post-commit** — `broadcast: false` is
  intentional and documented in `ai_translatable.ex`; the review said "no action
  if left as-is". No change.
- **O3 [LOW]: minor adapter/binding duplication** — intentional layering
  (adapter = storage, binding = field mapping); note-only in the review. No change.
- **O4 [LOW]: `put_translation/4` concurrent FOR-UPDATE merge untested** — the
  merge re-reads `FOR UPDATE` so concurrent per-language jobs don't drop each
  other's siblings, but it's exercised only sequentially. A true two-process race
  test is flaky-prone (shared-connection sandbox timing) for low marginal value.
  Skipped by recommendation. Trigger to revisit: if concurrent per-language
  writes are ever observed dropping siblings in practice.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_projects/web/assignment_form_live.ex` | Wire AI-translate (Embed + assign_ai_translation + button/modal) |
| `test/phoenix_kit_projects/ai_translatable_test.exs` | `fixture_assignment/1` + assignment adapter tests |

## Verification

`mix precommit` clean (format / credo --strict / dialyzer). Assignment form +
adapter + embedding suites green; AI button + modal browser-verified, 0 console
errors.

## Open

None.
