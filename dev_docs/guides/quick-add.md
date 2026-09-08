# Quick-add — the "Add a task" row and the add-task sheet

How a task gets added to a project: the dashed composer row, the sheet it
opens, the keyboard loop, one-off tasks, and the per-project library flag.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Feature notes.

`Components.QuickAddComposer` is the dashed "Add a task" row at the foot
of a real project's task list (not templates), OUTSIDE the sortable
container. It is the second way into the same right-hand sheet as the
"Add task" button at the top ("the add a task should both open the popup
and inside there should we have that stuff setup"): a `<.smart_link>` into
`AssignmentFormLive` in Create-new — a popup button in popup/emit mode, a
link to the add page on a host in navigate mode. The keyboard loop lives
in the form: **Enter** adds and closes (the browser's implicit submission
presses the FIRST submit button, "Add"); **Shift+Enter** presses "Add &
next" through core's `PkShiftEnter` hook on the title
(`data-shift-enter-click`); the button carries `name="then" value="next"`,
which LiveView sends as the submitter, and `save` reads it as `add_next?`.
After a successful create with it set, `after_create/2` emits `:saved` with
`close: false` (the frame stays, the page behind refreshes its list) and
`reset_for_next/1` re-runs the `:new` mount keeping the user's tab and "add
to library" choice, marks the form clean (`notify_dirty(false)` — Esc
closes again) and bumps `form_seq`, which re-keys the title's wrapper so
`phx-mounted={JS.focus(...)}` lands the cursor back in the title. The same
mount focuses the title when the sheet opens.

**The write** is `Projects.quick_add_assignment/3` →
`create_task_with_assignment/3`: one transaction that locks the project row
(`FOR UPDATE`, so concurrent adds never share a bottom `position`), inserts
the library `Task`, inserts the `Assignment`. NOTHING else inside —
broadcasts (`:task_created`, `:assignment_created`) fire after commit and
the activity log stays with the LiveView (it knows the actor). The full
form's "create new task" mode calls the same helper with its full attrs, so
the two paths cannot drift.

**One-off tasks.** An assignment has no title of its own — every ad-hoc
add mints a library `Task` — so a composer would have filled the reusable
library with "call the client" fifty times over. The chain adds
`phoenix_kit_project_tasks.ad_hoc` (default false, indexed): quick-adds
set it, and `list_tasks/1` + `count_tasks/1` take `ad_hoc: :exclude`
(default — every library surface: list, grouped view, the assignment
form's picker, the stat tile) `| :only | :all`. The Tasks page's
**Library | One-off** lens (URL `lens=`, which appears once one-off tasks
exist) lists them; "Add to library" (row menu, or the edit form's "One-off
task" checkbox) promotes one — `projects.task_promoted` in the activity
log. The assignments pointing at a one-off task are ordinary in every way.

**The full form's defaults:** on `:new`, **Create new** is the first and
default tab and "Add to the task library" is OFF — a one-off unless the
user means it; **From library** is the second tab and is not rendered at
all while the library is empty (`@task_options == []`). The Create-new
title is a real `Task` changeset (`@task_form`, params `task[title]` /
`task[translations][<lang>][title]`) rendered with `<.translatable_field>`
under the language tabs next to the description, so a new task gets its
title in every language like one made on the Tasks page; `save` merges the
title's translations with the description's into the task row. The language
strip is passed `class="pb-0"` because it sits inside the card body already
— the default card padding made it a narrower box of its own. User-facing
copy never says "template" for a task (the select is "Task", the back link
"Tasks"). The word "template" is reserved for PROJECT templates in
user-facing copy — a library entry is just a task.

**The library is a per-project feature flag** (`library`, owned by the
`tasks` extension, default on — `Features.gates/1` exposes it as
`fx.library`). Off, the add-task form has no From-library tab and no
"Add to the task library" box: every task is typed in place (a stale or
forged switch/pick/promote is refused at the handler and at save time).
The **Simple checklist** starting point turns it off through the
`simple` preset; Team project, Client project and Public intake leave
it on; the project's Modules & Features page flips it later like any
flag. The Tasks page itself stays global — the flag is whether THIS
project draws on the library, not whether the library exists.

**The task list itself is a creation decision.** The New project form
carries the `tasks` extension as the first row of the *Task features*
drawer — off hides the flag rows, the receipt says "No tasks", the summary
"Off — no task list" — and a fifth starting point, **Just a space**
(`Archetypes` key `space`: `extensions_off: ~w(tasks discussions)`, preset
`simple` for the day tasks come on), makes a project that is only the tabs
it picks (a class that is only its whiteboards). Tasks is reconciled at
save like every extension (`apply_creation_capabilities/2`); it is never
listed among the add-ons (`creation_ext_groups/1`, `extensions_summary/1`).
Discussions defaults on except for Simple checklist and Just a space.
The card copy in `Archetypes` is catalog data translated at render
time, so every literal is wrapped in `gettext_noop/1` — without it the
extractor never saw the cards and no locale had them.

**The in-progress step is a flag too** (`in_progress`, default on,
`fx.in_progress`; the `simple` preset turns it off — "a checklist item
is done or it is not"). Off: a to-do row offers Done directly (no
Start; `start_task` is gated on this flag and refused), the add-task
form's Status offers To do / Done, and the board drops its middle
column — unless a row already sits in `in_progress` (legacy, or the
flag flipped mid-flight): that row keeps its Done button, stays
selectable in the form, and holds the column open, so nothing ever
disappears. The row lifecycle itself (`todo → in_progress → done`) is
unchanged in the schema; the flag only removes the middle step from
the UI and the event surface.

**The task list's controls are conditional** (`ListControls`: "no reason
to show the filters without multiple statuses or under ten tasks — but
controllable via the settings"). The Active / Done / All lens and the sort
dropdown render only when `ListControls.show?/2` says so: mode `auto`
(default) = the project has tasks on BOTH sides of the lens AND at least
`threshold` (default 10) tasks; `always` / `never` override. Site-wide
settings on `/admin/settings/projects` ("Task list controls"), keys
`projects_list_controls_mode` / `_threshold`, validated on read. Under
the rule `apply_list_lens/1` shows the whole project in manual order —
which is exactly what drag-reordering needs, so small projects reorder
by hand without the old "Reordering off" detour through the All lens.
The "Review submissions" button is not a control and keeps its row
whenever there is something to review. Tests that pin the lens itself
set the mode to `always` first.

**The sequence rail means "these run one after another"** — the
schedule is a sequential walk in drag order and the vertical line down
the list is that walk. It draws only when the claim is true:
`@list_manual?` (manual sort) AND `@list_whole?` (the All lens — a slice
of the plan is not the walk) AND `@fx.scheduling` (a checklist has no
walk). The numbers are positions in the project either way.

**Reordering works under a lens.** `list_manual?` is only "the manual
sort is on screen" — under Newest/Recent a drop means nothing and the
handles go with a "Reordering off" note. A drop under the Active or
Done lens sends the rows the client could see; `merge_visible_order/2`
folds that into the whole plan (the visible rows keep the SET of slots
they occupied and take their new order within them, hidden rows stay
put) before `Projects.reorder_assignments/3` writes every position.
The earlier rule refused any drop while rows were hidden.

**The lens and the sort share one frame:** the sort select and the
note render in core `nav_tabs`'s `:trailing` slot, so the row reads as
one bar, not two boxes.
