# History, hand-offs and notices

How a project tells its own story, and who hears about what. The plan and
the reasons are in `dev_docs/plans/2026-10-25-history-and-handoffs.md`.

## History (`PhoenixKitProjects.History`)

Read at request time from what the project already records — nothing is
copied into a history table:

| Source | What it gives |
|---|---|
| core's activity rows with `module = "projects"` whose `resource_uuid` is the project or one of its tasks, or whose `metadata.project_uuid` names it | starts, completions, reopens (with `metadata.reason`), waiting-on, "your turn", "on hold", members, settings |
| the comments on `"project"` / `"assignment"` (and the notes types) | comments, quoted |
| the ledger's `kind: "time"` entries | time logged, with the note |
| core's notification rows for the activity rows above | who was told, and when they saw it |

Dropped on read: `projects.comment_added` and `projects.work_logged` (the
comment and the entry are the line), a comment carrying
`metadata.reopen_reason` (the reopen's own line quotes it), and a change
that failed (`db_pending`, the audit feed's attempt). The "your turn" and
"on hold" rows of one change are folded into one line naming everyone
told; a change's extra notice rows (a team's people told of a reopen) join
that change's own line as who it told.

A deleted task's activity rows are still found (every task row names its
project in `metadata.project_uuid`, stamped by `Activity.log/2`) and show its
recorded name struck through, without a link; its comments and notes are
not (they are found by the task's uuid). Rows
written before history existed (and rows from paths that log no actor)
read as "Someone".

Shown by `Web.ProjectHistoryLive` (the project's History tab, only when the
project has tasks) and in the task drawer (`AssignmentFormLive`, the task's
lines only), both through `Components.HistoryFeed`. ⋮ → Activity stays the
raw audit log.

**Cost.** One read per source, whatever the project's size — but core's
`phoenix_kit_activities` has no index on `resource_uuid` (only module,
action, actor, target, type, time), so the activity read finds the
module's rows through the `module` index and filters them one by one. The per-project
Activity page has the same shape. On a site with a very large activity
table the fix is a core index on `(resource_uuid, inserted_at)`, a core
migration — not something this module's chain may add to a core table.

History rows are written `permanent` (`Activity.history?/1`), so core's
activity retention never prunes an order's story — comment notices too,
since they are how a comment's line says who it told.

## Hand-offs (`PhoenixKitProjects.Handoffs`)

Called after every status change from the two places all paths already
announce through — `Projects.broadcast_status_changed/3` (page, form, API,
sub-project rollups) and `Outline.announce_status_change/1` (the tick
rules). A new way to change a status must go through one of them.

- **One pass per write.** `Projects.update_assignment_status/2` and
  `update_assignment_form/3` run inside `Handoffs.batch/1`: the rows the
  tick rules move announce first, the caller's own change after, and all of
  them are reacted to together — a task waiting on both a subtask and the
  parent it closed is told once.
- **Ready.** A task is ready when it is `todo`, every task it depends on is
  `done` (a dependency held out of the list counts as met), and the same is
  true of every task above it. When a task is done, the tasks that depend on
  it — and the subtasks under them — that became ready tell their assignee
  (`projects.assignment_ready`). Work already `in_progress` that was waiting
  on it is told it can go on (`"resume" => true`). Starting a project tells
  each person once about what is ready, naming the first and counting the
  rest; "go on" and "your turn" are separate notices, each naming its
first task. Only the call that actually started the project tells (a
second Start is silent). List order is never a dependency.
- **On hold.** A done task reopened while a task that depends on it is in
  progress tells that assignee (`projects.assignment_on_hold`). The row shows
  a derived "On hold" badge while anything it depends on is open; nothing is
  stored.
- **Rows nobody logged.** Changes the tick rules or a rollup make
  (`cause: :auto`) get an activity row with `metadata.auto = true`,
  attributed to `PhoenixKitProjects.Actor` — the person whose change set
  them off. The LiveViews declare the actor in `assign_embed_user/2`, the
  API in `Web.Api.Auth`; a process that declared nobody acts as nobody.
- Team and department assignees fan out to their people
  (`People.assignee_user_uuids/1`; a department's people are those whose
  primary department it is and the members of its teams, as "My tasks"
  counts them).

## Notices (`PhoenixKitProjects.Notices`)

Core's bell renders a module's notice exactly as the activity row carries it
(`notification_text`, `_icon`, `_link`) and cannot translate it per reader,
so each notice is its own row, written in the recipient's language
(`RecipientLocale`), marked `"notice" => true`.

- `Activity.log/2` passes every entry through `Notices.decorate/2`: an entry
  with a `target_uuid` other than its actor gets its line. That covers the
  existing call sites (assigned, started, completed, reopened, membership).
  A task's line is written only for someone who may open the project; a
  membership line always (a removed member is told).
- The task a hand-off names as done is read again per reader
  (`metadata.after_uuid`), so it is in the reader's language; the row keeps
  the primary name.
- `Notices.notify/3` writes one row per recipient, the actor left out.
- Comments: `CommentNotices` is the comments module's handler for
  `"assignment"` (registered apart from `ResourceLinks`, which is also the
  `#` search handler — a second searchable type would list every task twice)
  and for `"project"` (through `ResourceLinks`). A task comment tells the
  assignee and earlier commenters; a project comment its owners and managers
  and earlier commenters, and people @-mentioned in it — once: the handler
  records the mentions and claims their delivery, so the comments box's own
  "You were mentioned" ping finds them delivered. A reopen reason does not tell the
  task's assignees again — a person, or a team's or department's people
  (the reopen's notice quotes it). Only published comments
  tell anyone, and only people who may open the project.
- **A task event that names no recipient tells the task's people itself.**
  `Activity.log/2` hands every `assignment_created/updated/started/
  completed/reopened` row to `Notices.tell_assignees/2`: a row with a
  `target_uuid` (a person assignee, named by the caller) is its own notice;
  one without (a team or department, or a path that does not name the
  assignee — the API, quick-add, the typed list) writes one notice row per
  person. A row that should tell nobody passes `tell: false` (a list move,
  an interaction link, the form's "changed" row when the same save already
  told them); the tick rules' `auto` rows and notice rows never fan out.

| Event | Who is told |
|---|---|
| a task given, changed, started, done, reopened by someone else | the task's people |
| a task handed on (`projects.assignment_reassigned`, form and API) | the new people ("gave you a task") and the old ones ("handed … to …") |
| a task removed (page, API) | its people |
| your turn / on hold / go on | the people of the tasks it concerns |
| a comment on a task | its people, earlier commenters, the mentioned |
| a comment on a project | its owners and managers, earlier commenters, the mentioned |
| a person's note or a new direction on a task | its people, the mentioned (an agent's working notes tell nobody) |
| added to a project, role changed, removed | that member |

  Nobody hears of their own act; nobody hears of a template's tasks; every
  notice passes `may_view?/2`.
- Preference types: `handoffs` (ready, on hold) and `comments` under the
  projects type.

## Reopen asks why

The task row's Reopen opens a dialog; the reason is posted to the task's
thread (flagged `reopen_reason`) and stored on the reopen's row, so the
notice quotes it. A team's or department's people are told by
`Notices.tell_group/3` (the row's own notice names one person), so the
reason comment tells none of the assignees again. The API's `transition`/`reopen` take an optional
`reason`. The typed list's tick and a board drag reopen without asking.

## Time zones

`L10n` prints every instant in the viewer's zone (`TimeZone.for_viewer/1`,
settled per LiveView beside the locale; scope-less embeds call
`Web.Helpers.put_session_viewer_zone/1`). A typed wall clock is read with
`L10n.from_wall/1`; a wall clock the zone skips (the hour clocks go
forward) is refused, never stored as UTC. An all-day event keeps its
stored date.
