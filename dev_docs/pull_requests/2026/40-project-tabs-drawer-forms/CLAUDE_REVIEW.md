# Claude Review — PR #40 "Top-level project tabs, forms as a drawer, quick-add + one-off tasks, file-less whiteboards, the new-project form's task-less starting point"

**Merge commit:** `409f33f` (`mdon/pr/projects-arc`, 32 commits)
**Author:** Dmitri Don
**Size:** 108 files, +28081 / −9978
**Reviewed:** 2026-09-05, post-merge on `main`
**Skills invoked first:** `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## What the PR does

Five threads, one branch:

1. **Top-level project tabs.** The project page's Tasks/Board/Timeline/Calendar
   become one **Tasks** tab whose views live under `/:id/tasks[/board|timeline|calendar]`;
   every enabled extension and Comments are its peers, routed by a
   `projects/:id/:tab` catch-all declared last. The list segment leaves project
   URLs (`/admin/projects/list/…` → `ListRedirectLive`), the list becomes the
   module's landing page, and every page gets a real breadcrumb trail
   (`Web.Crumbs`).
2. **Forms as a right-hand drawer.** `PopupHost` stops hand-rolling a
   `<dialog>` and renders core's `<.modal placement={:end}>` per frame;
   a form reports unsaved input (`:dirty`) so Esc/backdrop cannot eat it,
   and an embedded form no longer steals the browser tab's title.
3. **Quick-add + one-off tasks (chain V15).** `tasks.ad_hoc` keeps
   project-minted tasks out of every library surface;
   `create_task_with_assignment/3` writes task + assignment in one locked
   transaction; the library page grows a Library/One-off lens with promotion.
4. **File-less whiteboards (chain V16 / core V183).** The salted blank-PNG
   bridge is gone: a board is its row, its shapes are annotations anchored to
   `"projects_whiteboard"` + the board uuid.
5. **New-project form.** Tasks as a toggle, a fifth "Just a space" archetype
   (`extensions_off: ~w(tasks discussions)`), site-configurable list controls
   (`ListControls`), and the Overview's pieces contributed as dashboards
   widgets (`RunningWidget`, `UpcomingWidget`, `CalendarWidget`).

## Verdict

The code is right. Two things stand between it and a release, and neither is
a defect in what this PR wrote: a **cross-repo release ordering** problem
(finding 1) and a red suite that a later dependency bump caused (finding 2).
Everything else I checked in the areas the Phoenix/Ecto skills point at came
back clean; the specifics are under "Checked and clean" so a later reader
knows what was actually verified rather than assumed.

## Findings

### 1. BUG - CRITICAL — the module cannot be published: it consumes unreleased core

`mix.exs` still floors core at `pk_dep(:phoenix_kit, "~> 2.0")`, and Hex's
latest `phoenix_kit` is **2.14.1**. Against that release the gate does not
compile:

```
$ mix compile --force --warnings-as-errors     # released core 2.14.1
warning: PhoenixKit.Annotations.delete_for_target/2 is undefined or private
  └─ lib/phoenix_kit_projects/whiteboards.ex:213  (delete_shapes_for_project/1)
  └─ lib/phoenix_kit_projects/whiteboards.ex:231  (delete/2)
warning: undefined attribute "placement"   for component …Core.Modal.modal/1
warning: undefined attribute "close_guard" for component …Core.Modal.modal/1
warning: undefined attribute "phx-value-frame-ref" / "data-frame-ref" for …modal/1
warning: undefined slot "trailing" / "inner_block" for …Core.NavTabs.nav_tabs/1
Compilation failed due to warnings while using the --warnings-as-errors option
```

The two `Annotations.delete_for_target/2` sites are not cosmetic: on a
released core, deleting a project or a file-less board raises
`UndefinedFunctionError` at runtime.

The core surface this PR needs is **committed but unpublished** in
`../phoenix_kit`, which sits at `@version "2.14.2"`
(`e3c49def Release 2.14.2 — PR #783 plus its review fixes`, on top of
`Release 2.14.1`): V183's `target_type`/`target_uuid` annotations +
`Annotations.delete_for_target/2`, `MediaCanvasViewer`'s `:board` assign,
`Core.Modal`'s `placement` / `close_guard` / global pass-through, and
`Core.NavTabs`' `:trailing` + `:inner_block` slots.

Against that checkout the whole gate is green:

```
$ PHOENIX_KIT_PATH=../phoenix_kit mix compile --force --warnings-as-errors   # exit 0
$ PHOENIX_KIT_PATH=../phoenix_kit mix format --check-formatted               # exit 0
$ PHOENIX_KIT_PATH=../phoenix_kit mix credo --strict     # 3058 mods/funs, no issues
$ PHOENIX_KIT_PATH=../phoenix_kit mix dialyzer           # Total errors: 7, Skipped: 7 — passed
```

**Not fixable here — and since resolved upstream.** AGENTS.md §"Cross-repo
release ordering" names the sequence, and it happened: `phoenix_kit` **2.14.2
was published to Hex during this review**. Re-resolved from Hex, the whole
gate is green (see Gate), and 0.22.0 shipped on it.

One thing this finding got wrong on the way through: the answer is *not* to
raise the requirement. I tried `">= 2.14.2 and < 3.0.0"` and
`core_pin_conformance_test.exs` rejected it — the `:phoenix_kit` requirement
must stay a two-segment `~> 2.0` that admits every core 2.x, because a pin
excluding a core minor makes `mix deps.get` unsolvable for any host running
this module beside a newer core, and that breakage lands only on consumers.
The pin is unchanged; the real floor is documented in `mix.exs` and the
CHANGELOG instead. A good test to have been caught by.

### 2. BUG - HIGH — `mix test` is red on `main`: 5 failures, all from the dependency bump, not from this PR

The suite came back `1497 tests, 5 failures`, every one the same crash:

```
** (FunctionClauseError) no function clause matching in
   PhoenixKit.Users.Roles.user_has_role_owner?/1
   # 1  %{email: "test-77058@example.com", uuid: "32df008b-…"}
   (phoenix_kit_comments 0.4.5) …/comments_component.ex:2021: user_is_admin?/1
   (phoenix_kit_comments 0.4.5) …/comments_component.ex:235:  update/2
```

Four are this PR's own new tests (the `/comments` tab in
`project_hub_pages_test.exs`), one is a pre-existing `PortalLiveTest`.

**It is not this PR's bug.** Traced it back: `phoenix_kit_comments` **0.4.5**
moved the viewer's admin check into `update/2` —

```elixir
|> then(&assign(&1, :viewer_is_admin?, user_is_admin?(&1.assigns[:current_user])))
```

— so it now runs on every mount of the component, for any `current_user`. In
**0.4.2** the same unguarded `user_is_admin?/1` existed but was only reached
from `can_delete_comment?/2`, i.e. per rendered comment. Core's
`user_has_role_owner?/1` has clauses only for `%PhoenixKit.Users.Auth.User{}`
and has done for years. The bump `0.4.2 → 0.4.5` landed in commit `c3a85db`
("libs got upgraded") **after** PR #40 merged, which is what turned these
green tests red.

Production is unaffected — core's `on_mount` puts a real `%User{}` in
`phoenix_kit_current_user`, which is what this module forwards to the
component. The break is entirely in the harness: `LiveCase.fake_scope/1`
built its user as a look-alike map `%{uuid:, email:}`.

**Fixed** — `fake_scope/1` now builds an actual (unsaved) `%User{}` struct,
which is what `Scope.user` is typed as anyway. The role lookup behind
`user_has_role_owner?/1` is a plain `exists?` query that answers false for a
uuid with no assignments, so the fixture keeps meaning what it meant.
`project_hub_pages_test.exs` + `portal_live_test.exs`: 54 tests, 0 failures.

Worth raising upstream regardless: a component that crashes on a
non-struct `current_user` handed to it by a host is a sharp edge —
`user_is_admin?/1` wants a `%User{}` clause and a `false` fallback.

### 3. IMPROVEMENT - MEDIUM — two 49-key placeholder assign lists that had to be edited in lockstep

`ProjectShowLive`'s embed mount clause (`mount(:not_mounted_at_router, session, …)`,
the fail-closed one for a session with no `"id"`) and `not_found_assigns/0`
carried **the same 49 keys**, differing in exactly two values
(`tab_url_sync?`, `wrapper_class`). Both exist because the page shell renders
before the redirect, so every assign the template reads must be present — which
is precisely the condition under which drift becomes a crash: add an assign to
one branch and the other renders `KeyError` on a misrouted embed.

**Fixed** — the embed clause now derives from `not_found_assigns/0` with the
two overrides. Verified the key sets were identical before collapsing them.

### 4. IMPROVEMENT - MEDIUM — `TasksLive`'s `one_off_count` has no mount default

`total_count`, `filtered_count` and `local_search?` all get a mount default
so the render is safe whichever load path ran. `one_off_count` — read by the
new Library/One-off lens strip — is assigned **only** in `load_list_tasks/1`,
never in mount and never in the Groups branch of `load_tasks/1`.

Not reachable today: the strip lives inside the flat-list branch, which
`load_list_tasks/1` always precedes, and a direct Groups-view mount leaves
`total_count` at 0 so the render takes the empty state instead. It is one
moved line from a crash, and it is inconsistent with its three siblings.

**Fixed** — `one_off_count: 0` added to the mount assigns.

### 5. IMPROVEMENT - MEDIUM — the new dashboard widgets re-run the Overview's N+1 on a refresh tick

`RunningWidget` (15 s) and `CalendarWidget` (60 s) both do

```elixir
Projects.list_active_projects(viewer: viewer) |> Enum.map(&Projects.project_tree_summary/1)
```

and `project_tree_summary/1` → `build_tree_node/1` runs `list_assignments/1`
**per project and recursively per sub-project**. `CalendarWidget`'s task mode
does the same shape through `ScheduleLayout.tree/1`.

On the Overview page this cost was paid once per navigation. As a widget it is
paid on every refresh tick, per connected dashboard viewer, forever. The
queries are correctly viewer-scoped — this is load, not a leak.

**Not fixed here.** The honest fix is a batched summary query (one grouped read
of assignments for a set of project uuids) feeding `project_tree_summary`,
which is real work in the context layer and well outside a post-merge sweep.
Recorded so the next person sizing a dashboard knows the cost is per-tick.

**Resolved by PR #41** (`348caed`, "Batch the per-item reads on the hot paths"),
which built exactly that and eleven more: `Projects.assignments_by_project/1`
reads the whole forest with one `WHERE project_uuid IN (…)` per depth level,
and `project_tree_summaries/1` / `ScheduleLayout.trees/1` build every node from
that map. Both widgets and `OverviewLive` call the plural forms now, so the fix
fires on the paths this finding named. Checked on re-review: the batched read is
filter-, order- and preload-identical to `list_assignments/1`; its depth cap
(`Projects.max_subproject_depth/0`) is the same bound the builders stop at, so a
node at the cap is not built rather than read as falsely empty; and both
builders carry a path set so a cycle in bad data terminates. #41 also caught an
N+1 this review missed — `Features.gates/1` was asking the database per flag and
per `requires` hop, 22 reads on every project-page mount and every
modules-changed broadcast; `Features.context/1` now gathers it once.
`test/support/query_counter.ex` locks the counts in by telemetry, and the new
suites assert node-for-node and span-for-span equivalence with the singular
forms. Gate green at `348caed`: 1511 tests, 0 failures.

### 6. NITPICK — `Projects.quick_add_assignment/3` takes an `_opts` it never reads

The `@spec` promises `keyword()` and the doc says the task lands "with the
project's defaults", but the body passes `%{}` as the assignment attrs and
ignores `opts` entirely. Harmless (the add-task sheet builds its own attrs),
but the docstring over-promises. Left as-is: narrowing a public signature is
not a sweep-sized change.

### 7. NITPICK — `RunningTiers.prioritize/4` hand-rolls what `Enum.sort_by/2` does

`Enum.map(&{sort_key(…), &1}) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))`
is a Schwartzian transform; `Enum.sort_by/2` already computes the key once per
element. Left as-is — correct, just longer than it needs to be.

### 8. NITPICK — a comment in `DashboardWidgets` contradicted the route table

`# The Overview dashboard's pieces (the page lost its admin route in 2026-09 …)`
— it did not. `admin_tabs/0` still carries `:admin_projects_overview` at
`projects/overview`, and `Paths.overview/0` still points at it; what changed
is that the Overview stopped being the module's *landing* page and became the
last subtab. **Fixed** the comment.

## Checked and clean

Recording what was actually verified, since "no finding" is only useful if a
reader knows the ground was covered:

- **`Features.@task_gates` vs the Tasks extension's declared `feature_flags`** —
  the two lists that must mirror each other. Both 16 keys, exact match, so
  `gates/1` and the `"full"` preset (now *derived* from `@task_gates`) cover
  every declared flag.
- **`AccessPanel.@requires` vs `Authz.@overridable`** — the PR rewrote
  `@requires` from single tuples to requirement *lists* and added the
  `{:ext, "tasks"}` prerequisite. All nine overridable action keys
  (`create_tasks edit_tasks delete_tasks assign_tasks update_status log_time
  comment upload_files set_health`) are present; none dropped, none invented.
- **`Extension.@reserved_tab_keys` vs the real route table** — still correct.
  `board`/`gantt`/`calendar` remain literal depth-2 siblings (the legacy routes
  are kept alongside the new `/tasks/*` ones), so reserving them is right;
  `assignments` is a depth-3 route and cannot be shadowed by a depth-2 tab.
- **Tab gating actually fires for the task-less project the PR claims to fix** —
  with the `tasks` extension off, `Features.gates/1` resolves every task gate
  false (the flags' owning extension is disabled), so `gate_tab/2` sends
  `/tasks/board` to `:list`, and `resolve_landing_tab/4` then sends `:list` to
  the first extension tab, or Comments, or the empty state. The
  `:project_modules_changed` handler re-runs the same pipeline after reloading
  the project — reloading matters, since the flags live in `settings["features"]`
  and the in-memory struct is pre-toggle.
- **The dirty guard is wired in every form, not just the one that motivated it** —
  `mark_dirty/1` is called from the `"validate"` handler of all four
  (`task_form`, `template_form`, `project_form`, `assignment_form`), so typing
  is what arms it, which is the case that matters.
- **Session sanitization on the drawer path** — `sanitize_session_overrides/1`
  drops `current_user_uuid`/`mode`/`pubsub_topic`/`frame_ref` at *both* ends
  (the `open_embed` emitter and `PopupHostLive` before it stamps the frame), so
  a crafted `phx-value-session` cannot open a form as another user or redirect
  its events. `decode_max_width/2` is a whitelist.
- **Whiteboard shape cleanup is reachable, not just defined** —
  `delete_shapes_for_project/1` is called from `delete_project_tree_in_tx/1`
  *before* the row delete and recursively for every sub-project, which is what
  it takes for a cascade that cannot reach core's annotations table.
- **The `down/1` chain** — V16 then V15, descending, each guarded by
  `if target < N`; V16's down deletes file-less boards, which is documented and
  unavoidable in the old shape. The V15 index is created unqualified and dropped
  schema-qualified, matching every other step in the file.
- **`ListControls.read/0`** — `String.to_atom/1` on the mode is fenced by a
  `mode in @modes` whitelist first; the threshold is clamped.
- **Widget viewer-scoping** — the three new widgets query through
  `viewer_for(scope)`; `resolve_project/2` re-checks `:view` on whatever a
  widget setting names.
- **The Iron Law** — `ProjectShowLive` queries in `mount/3` deliberately, with
  the reason in a comment: LiveView refuses to mount an LV exporting
  `handle_params/3` off-router, which would kill every `live_render` embed.
  That is the correct trade here, not an oversight.

## Gate

Against **`phoenix_kit` 2.14.2 from Hex**, after the fixes in findings 2–4 and
8 (the same results held against the local checkout before it was published):

| step | result |
| --- | --- |
| `mix format --check-formatted` | clean |
| `mix compile --force --warnings-as-errors` | clean |
| `mix credo --strict` | 3058 mods/funs, no issues |
| `mix dialyzer` | passed (7 errors, 7 skipped by `.dialyzer_ignore.exs`) |
| `mix test` | **1497 tests, 0 failures** (was 5 failures — finding 2) |

## Released

**0.22.0**, on `phoenix_kit` 2.14.2. Local and Hex were both at 0.21.2, so
everything in PR #40 was unreleased; a feature-sized PR makes it a minor.
