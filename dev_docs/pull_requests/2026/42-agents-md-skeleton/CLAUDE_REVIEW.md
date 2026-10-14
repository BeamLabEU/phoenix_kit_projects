# Claude (Sonnet 5.5) review — PR #42, after the merge (2026-10-14)

PR #42 (`mdon/main`, merge `f3c40ff`): AGENTS.md onto the shared module skeleton
(feature notes split into `dev_docs/guides/*.md`), `test_helper.exs` preflight
through core's `PostgresPreflight`, and `embedding_test.exs` asserting form ids
instead of page titles. Docs and test harness only; no runtime code.

## Verified, no change needed

- Every guide AGENTS.md links (`dev_docs/guides/{embedding,project-page,quick-add,
  workflow-statuses,sub-projects,multilang-content,whiteboards,dashboard-widgets,
  schedule-math}.md`) exists.
- The `embedding_test.exs` change is right: `live_isolated` does not render the
  admin layout's `page_title`, so the old text assertions only passed by
  accident of an earlier layout. The form ids (`project-form`, `task-form`,
  `template-form`, `assignment-form`) are what those tests are named for.
- `test_helper.exs`: `PostgresPreflight` is used only when loaded, otherwise
  `:try_connect` — the "`mix test` never hard-fails on a missing DB" contract
  holds. The entities migration step is guarded by `Code.ensure_loaded?`.

## Noted, not changed

- **NITPICK:** the `test_helper.exs` comment still says the module's core floor
  is `~> 2.0`; it is `>= 2.54.0 and < 3.0.0`. The `Code.ensure_loaded?` guard is
  harmless either way.
