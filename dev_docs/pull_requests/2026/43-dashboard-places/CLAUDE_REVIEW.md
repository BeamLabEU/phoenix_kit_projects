# PR #43 — Declare the two places a dashboard can appear in Projects

**Reviewed:** 2026-09-11 · **Author:** mdon · **Verdict:** merged, no changes
required.

+1148 / −157 across 8 commits (`028ed22`…`d368e38`), landed via merge `a31cd5e`.
The PR already carries its own `QUALITY_SWEEP.md` (a self-review with fixes
applied before merge); this is an independent second pass over the same diff.

## What it does

Adds the duck-typed `phoenix_kit_dashboard_slots/0` contract (mirrors
`phoenix_kit_widgets/0`: plain maps, no dependency on `phoenix_kit_dashboards`,
no `@impl`) declaring two places a dashboard may be shown: `"projects.module"`
(a `:module_tab` under `:admin_projects`, context-free) and `"projects.project"`
(a `:record_tab` inside the project page, providing the `"projects.project"`
context kind). Adds `phoenix_kit_dashboard_viewer_context/2` to resolve "my
project" for a viewer — conservatively `nil` unless exactly one project is
reachable. Marks the widgets' shared `project_field/0` with `context:
"projects.project"` so the dashboards host can offer it as a bind target.
Backfills 7 i18n msgids that were reaching no catalogue at all, and fixes a
`mix.exs`/`mix.lock` drift (`phoenix_kit_templates` unlocked) that broke a
clean checkout before any gate could even run.

## Verified independently

- **Contract shape against the actual consumer.** Cross-checked both slot maps
  against `PhoenixKitDashboards.Slot.from_map/2` in the local
  `phoenix_kit_dashboards` checkout: required fields present, `surface:
  :module_tab` validates `parent_tab` is a declared atom (`:admin_projects`
  exists in `admin_tabs/0`), `:record_tab` needs no `slug` (generates no
  route), `provides`/`cardinality`/`gettext_backend` all normalize as intended.
  The QUALITY_SWEEP's two rejected findings (slug collision with `projects/:id`,
  missing slug on the record slot) both check out against the consumer's own
  routing code (`slots.ex` always builds `dashboards/places/<slug>`, never
  under the declaring module's namespace).
- **The `:record_tab` slot isn't an orphan declaration.** It has no renderer
  inside `ProjectShowLive`, which looked suspicious until tracing it: rendering
  is `phoenix_kit_dashboards`' own job via its `phoenix_kit_project_extensions/0`
  contribution (`Web.ProjectDashboardLive`, an embedded `live_render` tab
  through this module's existing `Extensions.Registry`/`ext_tabs_for`
  machinery) — the same "sibling module contributes an extension" path
  Comments and other hub surfaces use. Nothing to wire on this side.
- **Gettext, code vs. catalogue.** Diffed every `gettext`/`gettext_noop`
  literal in `lib/` against `default.pot`; 0 real misses (the 16 that appeared
  missing on a naive scan are month abbreviations/date formats in `l10n.ex`,
  which deliberately use core's `PhoenixKitWeb.Gettext` backend per this
  module's documented hybrid convention, not this module's own catalogue).
  All 7 locale `.po` files have exactly 1 empty `msgstr` (the header) and 0
  fuzzy entries.
- **`rescue`/`catch` on `phoenix_kit_dashboard_viewer_context/2`** uses the
  implicit-try `def ... rescue ... catch ... end` sugar correctly and mirrors
  `ext_tabs_for`'s degrade-and-log shape.
- **The known, deliberately-deferred item** (`list_projects_for(scope, limit:
  2)` still materializes every accessible project via
  `Members.accessible_projects/1` before the `LIMIT` narrows the outer query —
  correctly flagged in the PR's own sweep as pre-existing and out of scope for
  a slot-declaration PR) still holds; not re-raising it here since it already
  has a `FOLLOW_UP.md` trail on PR #35 and a stated fix shape.

## Verification

| Check | Result |
|---|---|
| `mix deps.get` | clean (confirms the `mix.lock` fix holds on a fresh resolve) |
| `mix precommit` | **passes** (format + `compile --warnings-as-errors` + `credo --strict` + dialyzer) |
| `mix test` | **1518 tests, 0 failures**, Postgres was reachable this session so this run includes the `:integration` and LiveView suites, not just units — the new `dashboard_slots_test.exs` (7 tests) included and green |
