# PR #31 review — Admin UI overhaul: shared list architecture, breadcrumb chrome, hybrid search + quality sweep

- **PR:** [#31](https://github.com/BeamLabEU/phoenix_kit_projects/pull/31) — `mdon/main` → `main`
- **Merge:** `feecafc` (49 commits)
- **Author:** mdon · merged by ddon
- **Reviewer:** Claude (Sonnet 5), post-merge
- **Scope:** 48 files, +10731 / −5710. Introduces a shared `ListUi` architecture (column
  persistence, search coercion, haystacks, Columns dropdown) used by `ProjectsLive`,
  `TasksLive`, `TemplatesLive`; a hybrid client/server search (≤100 rows: full load +
  `TableLocalSearch`, >100 rows: escaped SQL `ilike` with pagination); DnD reordering gated
  off under filtered/searched views; the show page's identity moved into the site breadcrumb;
  plus a self-described "quality sweep" (4 triage agents) covering activity-logging gaps,
  dead code, docs, and a test delta audit — folded into the same branch.
- **Verdict:** One real data-integrity bug in the DnD-gating fix this PR itself introduced (a
  case the PR's own reasoning should have covered but didn't), one tautological test
  assertion that silently defeats its own regression check, and one over-broad `rescue`
  clause that deviates from the module's declared convention — all fixed at review time. One
  minor duplication left as a nitpick. Everything else the PR's own quality-sweep claimed
  (activity-logging error branches, `handle_info` catch-all ordering, breadcrumb
  producer-contract test, emit-mode title-click test, search escaping/no-op semantics,
  batched-lookup correctness, template-clone atomicity, staff-lookup rescue coverage,
  raw-walk caching, descendant-aware sub-project matching, direct-only consistency, PubSub
  scoping) verified correct by reading the actual code, not just the PR description.

## Findings

### BUG - HIGH — DnD reorder gating doesn't account for load-more pagination truncation (FIXED)

`lib/phoenix_kit_projects/web/projects_live.ex:504-505`,
`lib/phoenix_kit_projects/web/tasks_live.ex:748`,
`lib/phoenix_kit_projects/web/templates_live.ex:440`.

This PR added `draggable?` gating on `status_filter == nil` / `search == ""` specifically
because the underlying reorder primitive (`PhoenixKit.Utils.Reorder.reorder/4`, via
`write_project_positions/1` etc.) renumbers the **dropped list only** to `1..N` — rows not in
that list keep their old position untouched. Applying that over a filtered/searched subset
would silently corrupt the hidden rows' relative order, so the PR correctly gated DnD off in
those cases.

It missed the equivalent case: server-search mode (`local_search? == false`, i.e. >100 total
rows) with `pagination == "load_more"` (the default) caps the loaded set at `loaded_count`
(50 initially). With Manual sort selected, empty search, no status filter, and >100 rows, only
the first batch is loaded — yet `draggable?` was still `true`, so dragging within that visible
page reorders exactly the same "renumber a subset to 1..N" hazard the PR explicitly guards
against elsewhere.

**Failure scenario:** a library with >100 rows that have never been manually touched (many
sharing `position: 0`, tie-broken by `inserted_at`) — switching to Manual sort loads the 50
oldest by tiebreak; dragging one reassigns the visible 50 to `1..50`, while the remaining
`position: 0` rows outside the loaded page are left at `0` and now sort *ahead* of the rows the
user just arranged — silently corrupting the manual order just set. No crash, just quiet data
corruption reachable via the default pagination mode without touching search or filters.

**Fix:** added `@loaded_count >= @total_count` to all three `draggable?` computations, so DnD
is only enabled once the full matching set is loaded (consistent with how the same file already
treats "Load more" as mutually exclusive with a stable manual order).

### BUG - HIGH — tautological test assertion silently defeats its own regression check (FIXED)

`test/phoenix_kit_projects/web/list_lvs_handlers_test.exs:434`:

```elixir
refute html =~ ">—</td>" and false
```

Elixir's operator precedence makes this `refute((html =~ "...") and false)`, which always
reduces to `refute false` — the assertion passes unconditionally regardless of `html`'s
content. It was meant to confirm the "Last used" column renders a real date rather than falling
back to the em-dash placeholder; as written it can never fail, meaning a regression that broke
that column would go undetected. This is exactly the kind of assertion a large "sweep" commit
can introduce that reads as a real check in the diff but isn't one.

**Fix:** dropped the stray `and false`, restoring the real assertion.

### BUG - MEDIUM — `DashboardWidgets.project_options/0` rescues all exceptions, not the module's declared set (FIXED)

`lib/phoenix_kit_projects/dashboard_widgets.ex:54-61`. The PR changed a silent
`rescue _ -> [...]` into a logged `rescue e -> Logger.warning(...); [...]`, which is a real
improvement (the PR's stated goal), but the clause is still a bare `rescue e ->` — every other
DB-backed resilience rescue in this codebase (`assignees.ex`, `projects.ex`,
`overview_live.ex`, `project_form_live.ex`, `task_form_live.ex`) scopes to
`e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError]`, the module's declared
convention (AGENTS.md, "Cross-module staff lookups"). A bare rescue here would swallow and
silently degrade-and-log *any* exception — e.g. a `KeyError`/`ArgumentError` from a genuine bug
in the sort/map pipeline — masking a programming error as a benign DB blip instead of letting
it surface.

**Fix:** scoped the rescue to `[Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError]`,
matching every other instance of this pattern in the codebase.

### IMPROVEMENT - MEDIUM — `ilike` escaping duplicated instead of shared (not fixed)

`lib/phoenix_kit_projects/projects.ex` defines `escape_like/1` (escapes `\`, then `%`, `_`, in
that order — correct, avoids double-escaping) and uses it for project/template/task search.
`lib/phoenix_kit_projects/assignees.ex:176-183`'s `search_people/3` reimplements the identical
escaping inline rather than calling the shared helper. Functionally correct today (verified:
same escape order, same result), but the two copies can drift if the escaping rules ever change
— a fix in one and not the other would silently reopen wildcard-injection surprises in one
search path. Left as-is rather than restructuring module boundaries as part of a review-time
fix (`escape_like/1` isn't currently exposed as public API from `Projects`, and this PR's scope
is elsewhere) — flagged here so a maintainer can hoist it into a shared location on the next
touch of either search path.

## Verified correct (no issue — checked against the PR's own claims, not taken on faith)

- Six mutation handlers (`detach_subproject`, `link_subproject`, sub-project create/edit saves,
  `generate_default_statuses`, inline `create_task`) all call `Activity.log_failed` on their
  error branches with action names matching their success-path counterparts.
- `ProjectsSettingsLive`'s new `handle_info` catch-all logs at debug level and is correctly the
  last clause (no ordering hazard shadowing the specific `{:flush_display_log, ...}` clause).
- Breadcrumb producer-contract fixture (`test/support/test_layouts.ex`) and the emit-mode
  title-click test (`embedding_emit_test.exs`) both assert real rendered/broadcast behavior, not
  just presence of a function.
- No test weakened; no new `async: true` against the known shared-fixture deadlock path.
- Search escaping is parameterized (`ilike(field, ^pattern)`), not string-concatenated — no SQL
  injection surface. Blank/nil search is a correct no-op via a catch-all clause.
- Batched lookups (`creation_actors/2`, `task_usage/1`, `template_usage/1`,
  `assignment_counts_for_projects/1`) are single grouped queries, missing entries default
  safely, no N+1.
- `created_from_template_uuid` is stamped inside the same transaction as project creation in
  `clone_template/2` — a rollback discards the whole clone, no orphaned/unstamped state
  possible.
- Every new DB-backed `PhoenixKitStaff` lookup in `assignees.ex` has the declared rescue.
- The local/server search threshold is computed from the unfiltered total (by design — local
  mode must hold the whole loadable set for the client-side hook to work without a round trip).
- Calendar/assignee-filter: the "raw walk" is genuinely cached and reused across filter
  toggles (no requery on toggle); sub-project bar matching walks the full descendant subtree,
  not just direct children; "Direct only" is applied in the same pass that produces both the
  filtered set and the visibility-gate counts (no count/filter drift); no PubSub topic or cache
  keyed without proper per-project scoping. One pre-existing, PR-unrelated NITPICK noted below.

## NITPICK — brief stale-content flash possible on rapid day-popup close-then-reopen (not fixed, pre-existing)

`lib/phoenix_kit_projects/web/components/day_popup_modal.ex` + core `Modal`'s `PkDialog` hook
close the `<dialog>` client-side (`dialog.close()`) immediately on ESC/backdrop/✕, before the
server's `close_day_popup` round-trip lands and nils `day_popup`. In the narrow window between
client-side close and server ack, a new day-cell click can trigger an instant `showModal()`
reopen showing the previous day's stale rows (kept in DOM) until the queued close + new-day
messages are processed and repaint. Self-corrects within one round trip — not a data leak, just
a cosmetic flash. This mechanism predates PR #31 and wasn't touched by it (the PR's only
popup-related change was an unrelated `popup_host.ex` z-index bump for a different
embedded-frame modal stack) — left on record for a maintainer to pick up separately rather than
scope-creeping into this review's fixes.
