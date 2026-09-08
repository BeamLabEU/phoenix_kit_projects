# The project page, the list pages, and the breadcrumb trail

How the admin surface is laid out: the project page's top-level tabs, the
URL map under `/admin/projects/*`, the shared list-page architecture, and
the header trail every page sets.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Feature notes.

## The project page's top-level tabs

The show page is a set of **top-level tabs**, one per thing a project can
be: **Tasks** (which holds the four task views List / Board / Timeline /
Calendar behind its own, subordinate strip, plus the add actions, the
lifecycle bar, health and the schedule / progress / effort card), one tab
per enabled extension that contributes one (Events, Whiteboards, …) and
**Comments** — the project's own thread, inline, switched by the project's
*Discussions* extension (its existing per-project on/off) and the comments
module being on. Each stands alone in an otherwise empty project — a
project can be *only* a whiteboard or *only* a discussion. The header is
the project, not a tab — and on the standalone page most of it is the SITE
header: the breadcrumb carries the name, and core's
`page_toolbar` (`{ProjectShowLive, :header_toolbar}`, a function component
rendered with the LiveView's assigns; its events land in the LiveView)
puts the workflow-status picker and the ⋮ menu beside it. What stays in
the page is the project's face — Completed / Archived badges and the
description — and with neither, nothing: the tabs start right under the
site header (`header_face?/2`). The project's assignee is NOT shown on the
page (nothing acts on it; it lives on the edit form).
Embedded mounts have no site header, so they keep the h1 and render the
same toolbar component in the body. Files / Members / Activity stay in the
⋮ menu as project chrome. A single top-level tab renders no strip; with
nothing on at all the page shows the nothing-on empty state with a link to
Modules. Templates keep the Tasks pane alone, without either strip.

Resolution lives in `ProjectShowLive` (`tab_for_action/3` → `gate_tab/2` →
`gate_comments_tab/2` → `resolve_landing_tab/4` at mount;
`resolve_switch_target/2` on `switch_tab`), and every target is validated
against the feature map / the contributed tab list — a forged event lands
on the list. `top_tab_of/1` maps a task view to `:tasks`; switching back to
Tasks reopens the view you left (`task_view`). Task-row comments keep the
side drawer; only the project-level thread moved into the tab.

Addresses (`Paths`): `:id/tasks`, `:id/tasks/board`, `:id/tasks/timeline`,
`:id/tasks/calendar`, `:id/comments`, `:id/<extension tab key>` (the
`projects/:id/:tab` catch-all, declared LAST — after `templates/*`, whose
first segment would otherwise read as an id; extension tab keys must not
reuse a literal sibling). The legacy `:id/board|gantt|calendar` still
open their view. `tab_url/3` is the canonical address a tab reports.

## URL paths

Under `/admin/projects/*`: the list is the landing page and project pages
sit directly under it — `new`, `:id`, `:id/edit`, `:id/tasks`,
`:id/tasks/board|timeline|calendar`, `:id/comments`,
`:id/<extension tab>`, `:id/files|activity|members|modules` (and the
legacy `:id/board|gantt|calendar`), `:project_id/assignments/new`,
`:project_id/assignments/:id/edit` — beside the literal siblings `tasks`
(+ `tasks/new`, `tasks/:id/edit`), `templates` (+ `templates/new|:id|:id/edit`)
and `overview`. The legacy `list/…` addresses (the list used to live
there) redirect to the same path without the segment (`ListRedirectLive`,
hidden `projects/list` + `projects/list/*rest` tabs). **Declaration order
is route order**: `admin_tabs/0` lists the literal siblings and the legacy
redirects before `:id`, and `new` before `:id` — `landing_test.exs` pins
it. Use `PhoenixKitProjects.Paths`.

The parent tab and the first subtab both render `ProjectsLive` at
`/admin/projects`. The **Projects** subtab's matcher is a regex
(everything under `projects` except the `tasks`/`templates`/`overview`
siblings) because tabs match independently and a `:prefix` on `projects`
would light it on those too.

## Show-page task views (List / Board / Timeline / Calendar)

Both alternate views render the SAME schedule through the shared
`PhoenixKitProjects.ScheduleLayout` (tree flatten +
`PhoenixLiveGantt.Layout.sequential/2` walk, hour-precise,
weekday/weekend-aware), so they can never disagree about a task's dates.
The Timeline is `ProjectGanttLive` (`phoenix_live_gantt`); the Calendar is
`ProjectCalendarLive` (`phoenix_live_calendar` month grid, top-level
assignments as all-day status-colored bars capped per day with "+N more",
the same whole-day popup as the Overview, and the same Filters panel
(shared `Web.AssigneeFilter` glue + `<.assignee_filter_panel>`;
sub-project bars match DESCENDANT-aware — any subtree task belonging to
the person keeps the bar); a sub-project is one bar spanning its subtree,
click drills into the child; dates deliberately UTC-unshifted to match the
Timeline, unlike the Overview calendar). Tabs are instant assign flips;
each nested LV lazy-mounts on first open and stays mounted. URL sync is
the strip's `data-url` + core's `PkUrlMirror` hook, opt-in via
`session["tab_url_sync"]` for embeds.

`ProjectShowLive` is large — it handles the vertical timeline, status
transitions, inline duration editing, per-task progress sliders,
dependency badges, schedule/projected-end calculation. Sections are marked
with `<%!-- ... --%>` HEEx comments for navigation.

## The Overview subtab

`projects/overview` is the LAST subtab ("an overview and a dashboard are
different things, both have their value"). Its pieces are also
dashboards-module widgets (see
[`dashboard-widgets.md`](dashboard-widgets.md)) for anyone who wants them
on a `phoenix_kit_dashboards` board, and `OverviewLive` stays the
embeddable root view for host apps.

What it renders: active projects with progress bars, my tasks,
upcoming/setup/completed projects, stats. Its Calendar tab has two modes:
**Tasks (default)** — every leaf task across all projects on its scheduled
days (identity-colored by project, per-day cap with a Google-style "+N
more"; a day-cell or "+N more" click opens a whole-day popup via
`PkDialogTrigger` + a kept-in-DOM modal; month + agenda views) — and
**Projects** (the original one-bar-per-project view with the configurable
overdue marker, plus a **"Late only" lens** in its toolbar — bars of late
running projects only, same `summary.late` tier as the cards; count-badged,
hidden at 0, kept while active).

Tasks mode carries an **assignee filter** — one Linear-style chip rail: a
MULTI-person core `<.search_picker>` (search-on-focus browse, DB-limited
pages with Load more, picked people excluded from suggestions; **only
RELEVANT people are offered** — someone at least one non-template
assignment points at directly / via a team / via a department in their
scope, and the per-project Calendar tab narrows that to its own rendered
tree via `assignee_search_scope`) plus quick-adders for **Me** (hidden
without a staff person) and **Unassigned** (a dashed chip with live count;
hidden while the count is 0) that insert removable chips beside the input;
every active filter is a visible chip, all filtering as one union, with a
**Clear** button that renders only while filtering (resets chips +
Unassigned + Overdue + Personal-only); the header is just a **Filters
funnel button** (badged with the active count; the whole funnel hides while
the UNFILTERED walk has zero items — a fresh install has nothing to
filter) + the mode toggle; every control lives in a client-side popup panel
(JS.toggle open — patch-safe — with phx-click-away dismiss): picker,
Me/Unassigned quick-adders, chips, Personal-only/Overdue-only, Clear;
INHERITED semantics by default — the person plus their teams and
departments via `PhoenixKitProjects.Assignees`, with a "Direct only" toggle
and "via Team" provenance in the popup rows) and an **"Overdue only"**
toggle (late = not done + scheduled span past — red inset ring on chips,
`late` badge in popup rows; hidden while the raw walk has no late items,
kept while active). The raw walk is cached in assigns; filter flips are
in-memory.

## List pages (Projects / Tasks / Templates) — shared architecture

All three list LVs follow one shape (`TemplatesLive` is the most complete
reference):

- **No in-content header row.** The create action is a "+" in the admin
  breadcrumb (core `page_action` assign: `%{icon, label, navigate}`) plus a
  dashed full-width add-row at the list's foot.
- **Toolbar order** (core's `bulk_actions_toolbar`): search + data filters in
  `:leading` (left), the view tools — sort selector, Columns, the Tasks view
  switcher — in `:trailing` (right, after the contextual Reorder/Delete/Clear).
  Same left/right split as the catalogue tables and core's `table_default`
  toolbar row, so the kit's lists read alike. The show page likewise sets
  the header trail ("Admin Panel / Projects / ‹name›", see **Breadcrumbs**)
  instead of a back-link + h1 row — **embeds keep the full header**
  (`router_mounted?` gates it; embeds have no admin breadcrumb).
- **Recency default sort** — `updated_at desc` ("Last edited"); Manual
  (`:position`) one selector switch away. **DnD is gated off under ANY
  filtered view** (non-position sort, active search, Projects' status
  filter): the DnD handlers renumber the dropped list to absolute `1..N`,
  so a sparse subset would collide with hidden rows' positions.
- **Column visibility** — a Columns dropdown of optional columns, persisted
  site-wide (one comma-joined settings row per page:
  `projects_list_columns` / `projects_tasks_columns` /
  `projects_templates_columns`) via `ListUi.read_visible_columns/3` +
  `toggle_visible_column/4`. Batched lookup maps (`assignment_counts_for_projects/1`,
  `template_usage/1`, `task_usage/1`, `creation_actors/2`) only query while
  their column is visible; `toggle_column` reloads so a newly-shown column
  gets its map. "Created by" resolves from the activity log's creation
  entries (best-effort — pruned/off-form rows render a dash). Template
  "Uses" counts the durable `settings["created_from_template_uuid"]`
  back-link every clone stamps (activity rows get pruned; the back-link
  doesn't).
- **Hybrid search** (core `<.search_toolbar>` + core `TableLocalSearch`
  hook): at ≤100 rows (`@local_search_threshold`) the FULL set is loaded,
  SQL search is deliberately NOT applied, and the client hook narrows rows
  instantly via each row's lowercase `data-search` haystack
  (`ListUi.search_haystack/2` — primary fields + every translated value,
  matching the SQL coverage exactly). Above the threshold: SQL search
  (`:search` opt — escaped ilike over name/description/title + a
  values-only `jsonb_each` on translations) + load-more pagination + the
  toolbar spinner (`loading_indicator={not @local_search?}`). `search`
  payloads are coerced via `ListUi.coerce_search/1` (a forged `search[x]=y`
  map would crash the re-render otherwise). The load-more footer hides in
  local mode; `filtered_count` (footer) is search-aware while `total_count`
  stays the full-set count (reorder modal's honest "Reorder all N").
- **Titles are links** — every title anywhere in the module navigates
  (list titles → edit/show, assignment rows → assignment edit, sub-project
  names → child project) via `<.smart_link>` with `link link-hover`, so
  emit-mode embeds get events instead of dead text.
- TasksLive's List/Groups switcher is an icon-only join in the toolbar's
  `:trailing` slot (far right, apart from the data controls); the Groups
  view repeats it and lays group cards in a responsive grid with a
  columnar Standalone list.

## Breadcrumbs (the admin header trail)

Every page sets core's `page_section` (+ `_path`), `page_crumbs` and
`page_title` through `Web.Crumbs`, so the trail reads the same everywhere:

| page | trail (linked crumbs in *italics*) |
|---|---|
| list · Tasks · Templates · Overview | *Projects* / Tasks |
| project (any tab) | *Projects* / Test |
| sub-project | *Projects* / *Parent* / Child |
| Files / Members / Modules / Activity | *Projects* / *Test* / Files |
| add task · add sub-project | *Projects* / *Test* / Add task |
| edit a task in a project | *Projects* / *Test* / Edit ‹task› |
| new / edit project | *Projects* / New project · *Projects* / Edit Test |
| library task new / edit | *Projects* / *Tasks* / New task · Edit ‹task› |
| template / new / edit | *Projects* / *Templates* / ‹name› · New template · Edit ‹name› |
| settings | *Settings* / Project settings |

Rules: the module tab is always the section, so nothing can read
"Admin Panel / New project"; crumb labels reuse the subtab labels
verbatim (the list page titles are "Tasks"/"Templates" too — one name per
place); sub-pages are crumbs, never a "Test · Files" title; "Add" attaches
to the project crumb, "New" creates a standalone record; edit names its
object (core's "Edit Jane Doe"); the List/Board/Timeline/Calendar tabs are
views of one place and stay out of the trail; sub-projects show their
ancestors (`Projects.parent_chain/1`, bounded to 8 hops). Known core limit:
`page_title` is also the browser tab title, so a short leaf ("Files") makes
a weak tab — a separate browser-title assign in core is the fix, not a
fused title here. `breadcrumbs_test.exs` pins every row; the test layout
renders `page_crumbs` as `data-crumb` anchors.
