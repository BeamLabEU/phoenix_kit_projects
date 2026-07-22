# PR #32 review — Migrate the four multilang forms onto phoenix_kit_ai's `ai_multilang_tabs`

- **PR:** [#32](https://github.com/BeamLabEU/phoenix_kit_projects/pull/32) — `mdon/main` → `main`
- **Merge:** `a57f5d8` (2 commits)
- **Author:** mdon · merged by ddon
- **Reviewer:** Claude (Sonnet 5), post-merge
- **Scope:** 5 files, +22 / −45. `AssignmentFormLive`, `ProjectFormLive`, `TaskFormLive`,
  `TemplateFormLive` each replace a hand-rolled `<.multilang_tabs>` + sibling
  button/progress/hint `<div>` pair with `phoenix_kit_ai`'s bundled
  `<.ai_multilang_tabs>` (0.16.0, already satisfying this repo's `~> 0.4` floor).
  `mix.lock` also picked up routine transitive bumps (`elixir_make`, `etcher`,
  `phoenix_kit`, `lazy_html`) unrelated to the form change.
- **Verdict:** Clean, mechanical de-duplication. `ai_multilang_tabs`'s defaults
  (`class: "card-body pb-0"`, `ai_row_class: "flex items-center gap-3 -mt-3 px-6"`)
  reproduce what `ProjectFormLive`/`TaskFormLive`/`TemplateFormLive` were
  hand-building, and `AssignmentFormLive`'s explicit `ai_row_class` override
  (dropping `px-6`) matches its prior no-padding placement inside an
  already-padded card-body. The one visible change — the `border-b
  border-base-200` separator under the tabs disappearing — is intentional
  (called out in the PR's own comments) and cosmetic, not a regression. The
  component is already imported project-wide via `PhoenixKitProjects.Web.Components`
  (`import PhoenixKitAI.Components.AITranslate`), so no new import/alias was
  needed. `<.ai_translate_modal>` placement (outside each `<.form>`, required
  because HTML forbids nested forms and the modal carries its own selector
  forms) is untouched by this PR. No test asserts on the row's classes, so
  nothing broke there. No bugs found; nothing fixed.

## Findings

None. Verified by reading the actual `ai_multilang_tabs/1` definition in
`phoenix_kit_ai` (mirrored 1:1 between the sibling checkout and this repo's
`deps/`) against all four call sites, confirming:

- The row's visibility guard (`enabled?(@ai_translate) and @multilang_enabled
  and match?([_, _ | _], @language_tabs)`) mirrors the tabs' own render
  condition, so single-language sites never show an orphaned AI row.
- The redundant `:if={@multilang_enabled}` still present on
  `AssignmentFormLive`'s call is pre-existing (core's `multilang_tabs/1`
  already self-guards on the same condition) and predates this PR — not a
  regression it introduced.
- `~> 0.4` in Hex's requirement syntax means `>= 0.4.0, < 1.0.0`, so the
  installed `phoenix_kit_ai` 0.16.0 satisfies the floor; the large-looking
  version gap in `mix.lock` isn't a constraint violation.
