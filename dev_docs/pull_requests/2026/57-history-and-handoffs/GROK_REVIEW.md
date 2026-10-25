# Grok review — History, hand-offs and notices

Reviewer: xAI Grok. Each section is one round, reproduced as answered (local paths removed); how each finding was resolved is in `FOLLOW_UP.md`.


## Round 1 — the design, before any code

I'll review the projects, notifications, and kitchen simulation code and answer the six design questions from what the modules actually do.I'll read the activity, notification, and status-change paths next so the answers sit on actual functions.Next I’ll trace status-change logging, comment hooks, tick rules, and how people/times render.## 1. History view

**Where.** Keep Activity in the ⋮ menu as the raw audit (`ProjectActivityLive` + core `activity_list/1`). Add a **History** tab on the project page (same rank as Comments) as the owner’s feed. Also show a **filtered slice of that feed in the task drawer** (the thread already lives there via `CommentsComponent` on `resource_type="assignment"`). One read model, two surfaces.

**Source.** Merge at **read time**, do not copy comments or hours into activity:

- assignment + project activity (`PhoenixKit.Activity.list/1`)
- comments (`PhoenixKitComments.list_comments/3` on `"project"` and `"assignment"`)
- time entries (`Ledger` / `Hours`, keyed by `assignment_uuid`)

Activity is append-only and pruned (`retention_days/0`); comments edit/delete. A write-time union would drift.

**Shape.** Group by **viewer-local day** (`PhoenixKit.Utils.TimeZone.for_viewer/1` + `shift/2`, then `L10n`). Hand-offs as sentences, comments as a quoted tail:

> Kadri reopened Measure the room: “wall A doesn't add up”

People via `People.display_name/1` (today `Web.Helpers.assignee_label/1` and the completed-by badge use `user.email`).

**Build on.** New `PhoenixKitProjects.History` (one query: project uuid + its assignment uuids + `metadata["project_uuid"]`). New `Web.ProjectHistoryLive` (or a History mode of `ProjectActivityLive`). `Paths.task/2` and `ResourceLinks`’s `raw_task_path/2` for deep links. `Refs.task_ref/2` in the sentence. `Hours` for effort lines. Drawer: same `History` filtered by `resource_uuid`.

`ProjectActivityLive.load_page/1` currently lists `resource_uuid: project.uuid` only, so the 29 starts / 27 completions / 3 reopens / 32 comments never appear there even though they are stored.

## 2. “Your turn”

**Trigger.** A task becomes **ready**: every `depends_on` is `done` (or it has none) **and** it is not itself `done`. Fire when an upstream completion (or project start, for roots with no deps) first makes that true. Position in the list is not a dependency. A parent becoming ready does not page its subtasks; the first ready child of an `in_progress` parent does. Completing the last child may auto-complete the parent (`Outline.settle_above/2` / `parent_auto?/1`); “your turn” then goes to **dependents of the parent**, not the parent’s assignee.

**Who.** Person assignee → `Activity.assignee_target_uuid/1` (the linked user). Team/department: expand via `People.TeamMembership` (add `user_uuids_for_assignee/1`), keep people who can open the project, `Notifications.fan_out_from_activity/2`. Unassigned: skip, or optionally the project manager (`Members` role `"manager"` / `"owner"`). Core already self-skips (`target_uuid == actor_uuid`).

**Where.** Not the LiveView and not a loose `projects:all` subscriber (that topic is unscoped). Hook the two sites that already emit `{:projects, :assignment_status_changed, %{uuid, project_uuid, from, to}}` after commit: `Projects.broadcast_status_changed/2` and `Outline.announce_status_change/1` (called from `update_assignment_status/2`, the form path, rollup, and `Outline.settle/3`). New `PhoenixKitProjects.Handoffs.on_status_changed/1` there covers LV, API, ticks, and scripts. Collapse with `Notifications.upsert_inapp/3` key `"ready:<assignment_uuid>"`. New action `projects.assignment_ready` (add it under `notification_types/0` `"tasks"`). Do **not** put the next person on the completed row’s `target_uuid` — that field is the changed task’s assignee, which is why the bell is empty today.

**Reopen upstream while downstream is in progress.** Do not auto-reopen the downstream row (work already started). Notify its assignee **on hold** (`projects.assignment_blocked`, upsert key `"blocked:<uuid>"`). Clear it when every upstream dep is `done` again and re-send “your turn” only if they are still not done. Kadri setting `waiting_on` by hand is the current workaround; make the block derived from deps.

## 3. Comments

Notify, in order, unique, self-skipped:

1. `@` mentions (core mention tokens / `Web.Mentions`)
2. The task’s person assignee (or team fan-out)
3. Earlier commenters on **that** thread (watchers)
4. The project manager only if nobody above exists

Skip the project-wide member list (too noisy on 32 comments).

Implement `on_comment_created/3` on `PhoenixKitProjects.ResourceLinks` and **register `"assignment"`** in `types/0` (today only `project` / `project_task` / `project_task_notes` / `project_notes`). LiveView comments go through `CommentsComponent` and log nothing; only `Web.Api.CommentsController` writes `projects.comment_added`.

**Comment + reopen together** (Kadri’s note, then reopen): one inbox row. Prefer **reopen requires a comment** on that task, and send a single `projects.assignment_reopened` whose `notification_text` includes the quote. Otherwise `upsert_inapp` on `"task:<uuid>:<recipient>"` so the later reopen refreshes the comment ping. Dedup mentions that core already delivered.

## 4. Notification text

Ship `notification_text` / `notification_icon` / `notification_link` on every projects `Activity.log` (core `Render` already prefers them; without them you get `humanize/1` → “Projects assignment reopened”, and `link_for/2` is nil for module actions). Link: `Paths.task/2` for tasks, `Paths.project/1` for membership/health. New `projects.assignment_ready` / `_blocked` can be standalone `Notifications.create/1` with the same keys.

| Action | Line |
|---|---|
| `assignment_ready` | Your turn: 3D model and layout |
| `assignment_reopened` | Kadri reopened Measure the room: “wall A doesn't add up” |
| `assignment_blocked` | 3D model and layout is on hold — Measure the room was reopened |
| `assignment_completed` (manager only, optional) | Marek finished Measure the room |
| `assignment_started` | Marek started Measure the room |
| `assignment_created` / assignee change | You were assigned Measure the room |
| `assignment_waiting` | Kadri is waiting on you: re-measurement of wall A |
| `comment_added` | Kadri on Measure the room: “…” |
| `member_added` | Liis added you to Kitchen — Kristi Valk |
| `work_logged` | Marek logged 1 h 50 m on Measure the room |
| `project_started` / `_completed` | Liis started / completed Kitchen — Kristi Valk |

---

## 5. What else (top five)

1. **Save this project as a template** — `create_project_from_template/2` exists; there is no “clone this live order, strip comments/hours/completion.” Highest leverage for the next kitchen.
2. **External wait with due date + reminder** — `waiting_on` is a 200-char badge (`Assignment`). Payment, stone supplier, and the LEGRABOX ETA need a date and an Oban ping, not a fourth lifecycle status.
3. **Reopen requires a reason** — accept; that reason is the comment, one notification. Reject a separate `"returned"` status (AGENTS.md already kept waiting as a badge).
4. **Blocked-because-upstream-reopened** — accept as a **derived** marker from unmet deps, plus the on-hold ping in (2). Jaan’s preassembly stayed `in_progress` while edging was reopened.
5. **Per-task files / required attachment on handoff** — reject as the next slice. Files are a project folder (`Attachments`); the sim’s photos already lived there. Structured measurement fields: later, as a library-task description template, not a new schema.

## 6. History correctness (today’s rows)

- **`ProjectActivityLive.load_page/1`** — filters `resource_uuid: project.uuid`, so assignment rows never show. Query project uuid ∪ assignment uuids ∪ `metadata.project_uuid`.
- **`Outline.mark_done/3`, `reopen/2`, `settle/3`, `settle_tree/2`** — PubSub only, no `Activity.log`. Log from `announce_status_change/1` with `mode: "auto"`, `metadata.via: "outline"`.
- **`Projects.propagate_rollup_to_parent/2`** — linking row status moves, broadcast, no activity. Log with `metadata.via: "rollup"`.
- **`Web.Api.TasksController` status** — logs the primary row; `also_changed` is JSON only. Same announce-site log as ticks.
- **Live comments** — no activity; API-only `projects.comment_added`. `on_comment_created/3` plus History’s comment merge.
- **`waiting_on`** — logged as `projects.assignment_updated`. New action or `changes.waiting_on` so History can say “waiting on …”.
- **`create_project_from_template/2`** — one `projects.project_created_from_template`; cloned tasks are births, not changes. One project row with a task count, not 26 `assignment_created`.
- **`Outline.sync/4`** — one `projects.task_list_edited`; new lines born `done` (`create_lines/3`) never get `assignment_completed`. Put `ticked` in that metadata.
- **`Outline.reopen/2`** — ancestors go to **`in_progress`**, not `todo`. History must say “reopened (in progress)”, not “started”.
- **`Web.Helpers.assignee_label/1` + completed-by `user.email` + `L10n.format_month_day_time/1`** — emails and raw UTC. `People.display_name/1` and `TimeZone.for_viewer/1`.


## Round 2 — the built code

I'll review the History, hand-off, and comment-notice work against the six questions, starting with the diff and the call sites that sit inside transactions.The hand-off calls sit next to the status writes. Next I’ll trace which of those writes still sit inside a transaction, and what a rollback does to the notice.The reopen handlers and the access checks behind the notices are the remaining holes. I'll read those next, then answer the six questions.## 1. Transactions

A rollback of the status write does not send a notice. Every current caller in `lib/` announces after its own transaction has committed.

`Outline.with_project_lock/2` buffers `{uuid, project, from, to}` and calls `announce_status_change/1` only on `{:ok, _}`. A rollback or a raise restores the buffer and announces nothing. A lock nested inside another (`Outline.Api.batch_create/4` → `reopen_parent/3` → `settle_placed/1`) hands its buffer to the outer lock, so the notice waits for the outer commit. `update_tracking_status/2` commits the status row before `settle_outline/2` and `broadcast_status_changed/3`. `link_interaction/4` and `AiTranslatable.put_translation/4` call `update_assignment_form/3` inside a transaction with description or translations only, so the status does not move and `Handoffs` is not entered. `clone_template/2` calls `start_ongoing/1` after the serializable transaction; `start_ongoing/1` returns without `start_project/2` while `repo().in_transaction?()` is true. `start_project/2` calls `Handoffs.project_started/1` after the cement transaction. `propagate_rollup_to_parent/2` updates the linking row, then calls `broadcast_status_changed/3`, outside `recompute_project_completion/1`'s transaction.

A notice for a committed change is dropped when `Handoffs.status_changed/2` rescues, and when `Activity.log/1` returns `{:error, _}` (`Notices.notify/3` ignores it). `update_assignment_status/2` runs `Outline.settle/3` (cascade notices already committed) and only then `broadcast_status_changed/3`. A crash between them loses the direct "your turn" / "on hold". An API idempotent retry then sees `invalid_transition` and does not send it again.

The hole the lock's own comment describes is unused: no caller in `lib/` wraps `with_project_lock/2` in another `Repo.transaction`. If one did, the activity and notification inserts would join that transaction and roll back with it, while `Activity.log/1` has already broadcast and `Notifications.insert_inbox_row/1` has already called `Events.broadcast/2`. A Postgres error inside the rescued `Handoffs` call would also abort that outer transaction, so the status write in the same transaction would be lost.

## 2. Cost on hot paths

One `status_changed(:auto, to: "done")` is: `get_assignment` + an activity insert (`log_auto/4`), `load/1` (the project's rows, then its dependency pairs), `label_of/1` (`get_assignment` again), then `People.assignee_user_uuids/1` once per woken row, then per recipient `notify_ready/4`'s `get_assignment`, `decorate/2`'s `get_assignment` and two `Auth.get_user/1`, an activity insert, and a notification insert.

That whole sequence runs once per cascaded row. `mark_done/3` is one `update_all`; `announce_status_changes/2` then calls `status_changed/2` in `Enum.each`. Tick a parent with 50 open subtasks: 50 full-project `load/1`s (100 statements) plus 50 auto-row reads, on top of the per-assignee queries. That is a per-row read on the hot path.

`Outline.sync/4` adds nothing when `settle_tree/2` changes no status. Each row it does change pays one full `status_changed/2` after the single lock. `POST /tasks/batch` inserts lines as `todo` or `done` and does not announce those inserts. `Handoffs` runs only when `reopen_parent/3` reopens a done parent (one change). The N `projects.assignment_created` logs pass no `target_uuid`, so `decorate/2` returns on the first clause. `clone_template/2` adds nothing inside the transaction. After commit, `project_started/1` is one `load/1` plus `assignee_user_uuids/1` per ready row.

`decorate/2` on any other `Activity.log/2` with a `target_uuid` other than the actor and no `notification_text` adds a subject read and two user reads. Auto rows have no target, so they skip it. `notify/3` pays `decorate/2` again per recipient.

## 3. Privacy

Yes. A removed member still receives the excerpt.

`CommentNotices.earlier_commenters/2` selects every distinct `user_uuid` on a published comment. Nothing checks `Members` or `Authz`. `Notices.notify/3` writes `notification_text` with that excerpt. Failing input: Ada comments on task T, then is removed (or her role is revoked). Ben comments "the client price is 12 400". Ada's bell gets `%{actor} on “T”: “the client price is 12 400”` from `Notices.text/2`. Core's inbox insert checks notification prefs, not project access.

A portal visitor on the public board does not. Those comments use `Portal.discussion_resource_type/0` (`"project_assignment"`). `on_comment_created/3` only handles `"assignment"` and `"project"`, so that visitor is not an earlier commenter of the staff thread.

The same leak exists for "your turn" and "on hold". `People.assignee_user_uuids/1` returns a person's account, else every non-trashed team member with an account, else every person whose `primary_department_uuid` matches. No project membership check. Failing input: task T is assigned to team Sales; Sam is on that team and is not a member of the project. When the dependency completes, Sam is told `Your turn: “T” — “Walls” is done · Kitchen`. A person assignee is only that person. The person clause wins when `assigned_person_uuid` is set, so a person-plus-team row does not fan out to the team.

## 4. History correctness

Deleted direct status lines disappear. `ProjectShowLive` logs `projects.assignment_completed`, `_started`, and `_reopened` with `metadata` `%{task: label}` and no `project_uuid`. `History.activity/3` keeps a row only when `resource_uuid` is the project or a current task, or `metadata->>'project_uuid'` is the project. `delete_assignment/1` removes the task from `task_index/1`. The page's status row matches neither side. Auto rows and handoff notices survive, because `log_auto/4` and `Notices.notify/3` store `project_uuid`, and `task_ref/4` falls back to `meta["task"]`. Comments on that task also go: `comments/4` filters to current task uuids, and `projects.comment_added` is in `@dropped`.

The `OR` cannot use an index. `phoenix_kit_activities` has btrees on `module`, `action`, `inserted_at`, `resource_type`, `target_uuid`, and `actor_uuid`. There is no `resource_uuid` index and no expression index on `metadata->>'project_uuid'` (`expected_schema.ex` around the activities indexes). `History.list/2` is `module = 'projects' AND action NOT IN (...) AND (resource_uuid = ANY($1) OR metadata->>'project_uuid' = $2) ORDER BY inserted_at DESC LIMIT 2000`. On a large activities table that is a walk of recent rows with the JSON predicate as a filter. The `:task` option drops the `OR` and keeps `resource_uuid IN [task]`. Direct, auto, and notice rows for that task use the task uuid, so the drawer still sees them. A row that only names the task inside metadata is missed there.

Folding collapses two causes. `fold_notices/1` groups `{action, task uuid, DateTime.to_unix(at)}` (seconds) and keeps the first row's metadata. Failing input: C depends on A and B; one tick marks both done in the same second. Two `projects.assignment_ready` rows for C differ in `after`. The history line keeps one `after` and merges `told`.

Comment "told" is wiped by retention. `projects.comment_added` does not match `Activity.history?/1`'s prefixes, so it is not `permanent`. `phoenix_kit_notifications.activity_uuid` is `ON DELETE CASCADE`. After prune, `with_comment_told/1` finds no rows and every comment shows nobody told. Ready / on-hold rows are permanent, so their `told` stays. `name_people/1` does `Enum.uniq_by(& &1.uuid)` and keeps the first `seen_at` in that folded list.

Sub-project tasks are absent from the parent on purpose: `task_index/1` is `project_uuid == parent`, and notices store the child's uuid. The linking row on the parent is included. A cap of exactly 2000 sets `truncated` even when nothing was dropped (`length(rows) >= @cap`).

## 5. Time zones

The Events form reads a local time and labels it UTC. `project_events_live.ex` `parse_moment/3` sends a timed value through `L10n.from_wall/1`. The inputs are labelled `Start time (UTC)` and `End time (UTC)` (about lines 673–684). Failing input: viewer zone `Europe/Warsaw` (UTC+2 on 2026-10-25), all-day unchecked, date `2026-10-25`, start `15:00`. The stored instant is `2026-10-25 13:00:00Z`. `event_time_label/1` then shows `15:00` via `L10n.format_date/1` and `L10n.local_time/1`. A UTC client sees 13:00. All-day stays UTC midnight of the picked date and is shown with `DateTime.to_date/1`, so that path stays a calendar date. Timed `format_date(%DateTime{})` and `local_time/1` each shift the original once.

The Hours CSV file name is the UTC date. `Report.filename/2` uses `DateTime.to_date(generated_at)`. `Report.stamp/2` shifts. Generated at `2026-10-24 23:00Z` for `Europe/Warsaw`, the file is `hours-…-2026-10-24.csv` and the body says `2026-10-25 01:00`.

The start dialog, the project form, the Hours page, and the API are sound. `default_start_at_local/1` shifts `utc_now` into the viewer zone; `parse_start_at/1` reads it with `from_wall/1`; display uses `L10n.format_datetime/1` once. The form's `local_input_value/1` shifts a `%DateTime{}` into the `datetime-local` value, and `normalize_datetime_local_attrs/2` uses `from_wall/1` on save (`scheduled_start_date` is `:utc_datetime`). Hours takes one offset from `KitDate.get_user_timezone/1` (the same user-then-site chain as `TimeZone.for_viewer/1`). `shift_to_offset/2` and `parse_datetime_local/2` delegate to `TimeZone`. `when_parts/2` formats a `%Date{}`, which `L10n.format_date/1` does not shift again. CSV body cells use that same shift. The API never calls `L10n` and never sets the process zone, so JSON stays UTC. A legacy numeric offset through `TimeZone.shift/2` moves the clock with `DateTime.add/2` and leaves `time_zone` as UTC; none of these pages then pass that value through `L10n.local/1`.

## 6. The reopen reason and the API

The submit is gated. `"reopen"` is behind `:tasks` and `:update_status`, with the assignment as the authz record, so an assignee can reopen their own task. `"ask_reopen"` is in neither `@gated_events` nor `@event_actions`, so any client who can see the project can open the dialog for a uuid `scoped_assignment/2` knows. The submit still checks. A board drag is the real gate bypass: `delegate_board_move/3` calls `gated_handle_event("reopen", ...)` after `board_move` has passed `:view_board` and `:update_status`, and it does not re-check `:tasks`. With tasks off and the board on, dragging a done card to To do reopens it. The typed list's tick goes through `handle_event/3` and is refused. Both of those paths send no reason, which the handler treats as empty.

The LiveView posts the comment before the status write, and it does not rescue. `post_reopen_reason/3` calls `create_comment/4`; only then does `update_assignment_with_activity/5` run. A raise from the comments stack aborts the event and the task stays done. A `{:error, changeset}` from the status update leaves the reason comment published, and `CommentNotices` has already run, on a task that is still done. The API does the opposite: `apply_transition/3` commits, then `post_reason/3` rescues to `:ok`, so a comments failure cannot fail a reopen that used to succeed.

A team assignee is never told the reason. `CommentNotices` drops `assignee_user_uuids/1` when `metadata["reopen_reason"]` is true, on the claim that the reopen notice quotes it. `Activity.assignee_target_uuid/1` returns a user only for a person. Failing input: T is assigned to team Sales; reopen with "measure wall A again". The team is removed from the comment recipients, `target_uuid` is nil, and `hold_after/3` tells in-progress dependents only. Nobody on Sales gets the reason. A person assignee does, via `decorate/2` on `projects.assignment_reopened`.

A long reason is stored whole. The comments module rejects past `comments_max_length` (default 10_000) with `{:error, :content_too_long}`. The LiveView ignores that tuple and still puts the untrimmed string in permanent activity metadata. The history blockquote is `{quote_text(e)}`, so markup is escaped text. The bell quotes `Notices.excerpt/1` (plain text, 120 characters). A reason of hundreds of kilobytes becomes a permanent `jsonb` row.

An `@` mention in the reason is told to nobody. `recipients/3` rejects every `Token.parse/1` user uuid because `PhoenixKit.Mentions.notify/2` is assumed to have sent. `create_comment/4` in `core_notifications/comments.ex` never calls `Mentions.sync/4` or `Mentions.notify/2` (those run on task and project descriptions). Failing input: reason `See @[user:<Ada's uuid>|Ada]`. Ada is removed from the comment notice and gets no mention ping.

The comment's actor is the signed-in user on the page (`Activity.actor_uuid/1`). On the API it is `ApiKey.accountable_uuid/1`, with `attribution.label` set to the key name. A key with no accountable person posts no comment; the reason is still written on the activity row and quoted to a person assignee. A non-binary `reason` is ignored. An empty string reopens as before.

## Findings

- A tick of N rows reloads the whole project N times inside `Handoffs.status_changed/2`, and `assignee_user_uuids/1` runs per woken row.
- Removed commenters, and team or department members who are not on the project, receive the comment excerpt or the task title in the bell.
- A team-assigned reopen tells nobody the reason: the comment notice skips them, and the activity target is person-only.
- The LiveView writes the reason comment before the status update and does not rescue, so a comments raise blocks a reopen, and a failed status update leaves the comment behind.
- Page-logged status rows have no `project_uuid`, so deleting the task removes them from history. Comment "told" disappears when non-permanent `projects.comment_added` rows are pruned.
- `History.list/2`'s `metadata->>'project_uuid'` OR has no supporting index on `phoenix_kit_activities`.
- The Events time fields are labelled UTC and parsed as the viewer's zone. The Hours CSV file name uses the UTC date while the body is shifted.
- A mentioned user in a comment or a reopen reason is excluded from `CommentNotices` and never handed to `Mentions.notify/2`.
- `ask_reopen` skips the feature and permission gates; a board drag to To do skips the `:tasks` gate.


## Round 3 — the final sweep before the PR

## Part A

**1. Rules.** `ready?/2` and `clear?/3` match the guide: a task is ready only when it is `todo`, every dependency that is still in the list is `done`, and the same is true of every task above it. A missing dependency counts as met. List order is never a dependency. The actor is left out, and that case is tested.

These inputs still miss:

- Team or department, discussions off. Reopen "Quote", assigned to the workshop team, with the reason "Wrong board thickness." `Activity.assignee_target_uuid/1` is nil for a team, so the reopen row notifies nobody. `CommentNotices` runs only when a comment is posted, and `ProjectShowLive.post_reopen_reason/3` posts one only while discussions are on. The dialog says the worker is told. They are not. The same hole is on `TasksController.reopen_reason/4` when the key lacks `comments:write`.
- Resume hides the other tasks. Bob's "Order materials" is `in_progress` at position 1 and his "Boards" and "Hinges" are `todo` under it. All three were waiting on "Drawings". Alice finishes Drawings. `Handoffs.tell/3` sorts by position, keeps Order first, and sets `more: 2` plus `resume: true`. `Notices.text/4` matches the resume clause first and sends "Go on with Order materials". Boards and Hinges are never named.
- One click, two passes. "Pack" is the last subtask of "Production". "Install" depends on Production, "Delivery note" depends on Pack, both assigned to Priit. Completing Pack ticks Production inside `Outline` (`Handoffs` with `:auto`) and then `Projects.broadcast_status_changed/3` runs `Handoffs` again for Pack. Each pass groups its own rows, so Priit gets two "your turn" notices. If one task depends on both the parent and the child, that same task is notified twice.
- Start is not idempotent. `Projects.start_project/2` always calls `Handoffs.project_started/1`. A second `confirm_start_project` (two tabs, the modal already open) sends "your turn" again for every task that is still ready.

**2. Conventions.** History's read is a fixed set of queries. Auto rows are logged in `Handoffs` because the tick and the rollup have no LiveView, which is the documented exception. `reason` is not cast onto the assignment. `ProjectHistoryLive` has no `handle_params/3`, and its feed id is `project-history-#{uuid}`. New strings are gettext-wrapped and present in the Estonian and Russian catalogs. There is no `priv/gettext/default.pot` in the tree.

The new time-zone path has a hole: if `L10n.from_wall/1` cannot resolve a wall time, `Web.Helpers.normalize_local_to_utc/1` passes the raw string through, and Ecto stores it as UTC. The events form treats that same failure as invalid. The task drawer's accordion id is the bare `assignment-history`.

Estonian "Jätka ülesannet", "Ootel", and the partitive "ülesannet" are fine. Awkward ones: Estonian "märkis aega" for logging time, and Russian "получил(а)" / "видел(а)" beside a real name.

**3. Privacy.** Checked, sound. `Notices.may_view?/2` drops inactive users and anyone `Authz` will not let `:view` the project, including a team member with no grant. `ProjectHistoryLive.mount/3` requires `:view`. Reopen's submit is gated on `:tasks` and `:update_status`. `close_reopen` is not gated.

**4. History.** A normal person-assignee story (finish, your-turn, reopen reason, comment, deleted task kept by `project_uuid`) reads back correctly, newest first, reopen reasons not duplicated.

- A team reopen's comment is dropped as `reopen_reason`, and the reopen row has no `target_uuid`, so the line quotes the reason and shows nobody told. The team was told through the comment notice.
- Tasks counted as "more" get no row. The drawer's filter is by `resource_uuid`, so "Boards" has no "your turn" line. `History.fold_notices/1` also keeps one recipient's `more` count on the shared line, so "and 2 more tasks" can describe one person's batch while the line lists everyone told.

**5. Tests.** Reverting `Handoffs`, `Notices`, `CommentNotices`, `History`, `Activity` (`permanent`, `project_uuid`), `Actor`, `People.assignee_user_uuids/1`, the outline tick, `project_started`, the notification types, or the Reopen dialog would fail `handoffs_test.exs` or `project_history_live_test.exs`.

No asserting test covers: `L10n` and the events/project-form zone round trip, the API `reason`, a sub-project rollup logged `:auto`, project-comment recipients, `PubSub.broadcast_to_project/3`, `Paths.project_history/1`, the task-drawer history, the resume-plus-more text, or a team reopen with discussions off.

## Part B

1. Put the reopen reason on the on-hold notice. The installer otherwise hears only that something upstream was reopened, which is the rework loop's whole point.
2. Tell a still-`todo` assignee when their "your turn" is cancelled (upstream reopened, or a dependency added). Design will start on measurements that have already come back.
3. Notify when "waiting on" is set or cleared. Client payment, site access, and a delivery hold installation, and today that is only a history line.
4. Say "your turn" when a ready task is assigned on a project that has already started. "Gave you a task" also fires while the task is still blocked.
5. Make invoice issued or paid, and a moved installation date, history sentences and notices to the next trade. The office reads the order as money and the day on site.

## Findings

**BUG - HIGH** — Reopening a team or department task tells nobody unless a comment is posted. `Activity.assignee_target_uuid/1` is nil, and `CommentNotices` never runs when discussions are off or the actor may not comment. The dialog says they are told.

**BUG - MEDIUM** — `Notices.text/4` matches `resume: true` before the "more" clauses, so `Handoffs.tell/3` drops every other task from the bell when the lowest-position task is the one that can go on.

**BUG - MEDIUM** — A completion that also ticks a parent runs `Handoffs` twice (`Outline.announce_and_hand_off/1`, then `Projects.broadcast_status_changed/3`). One person is told twice, including twice about the same task if it depends on both rows.

**BUG - MEDIUM** — `Projects.start_project/2` sends "your turn" again on a second confirm. `confirm_start_project` does not check `started_at`.

**BUG - MEDIUM** — History shows nobody told for a team reopen (`History.normalize/3` drops the reason comment, and the reopen row has no target). Tasks folded into "and N more" have no line of their own, and the count kept on the shared line is one recipient's.

**BUG - MEDIUM** — The "after" name is the primary `title` from `Handoffs.load/1`. The rest of the sentence is in the recipient's language, so an Estonian reader gets "Sinu kord: «Kavanda» — «Measure» on tehtud".

**BUG - MEDIUM** — `Web.Helpers.normalize_local_to_utc/1` stores an unresolvable wall time as UTC. A Tallinn fall-back or spring-gap start time is the wrong instant.

**NITPICK** — `id="assignment-history"` is not namespaced, so a second embedded task form collides. Estonian "märkis aega" and Russian "получил(а)" / "видел(а)" read awkwardly next to a name.
