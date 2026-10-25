# Zai review — History, hand-offs and notices

Reviewer: Zhipu GLM-5.3. Each section is one round, reproduced as answered (local paths removed); how each finding was resolved is in `FOLLOW_UP.md`.


## Round 1 — the design, before any code

All six questions answered below, from the code as read (every claim names its file).

---

**Preliminary — why the Activity tab is empty today.** `project_activity_live.ex:97` filters `PhoenixKit.Activity.list(resource_uuid: project.uuid)`, but task-level rows are logged with `resource_uuid` = the *assignment* uuid (`project_show_live.ex:1110-1118`), and comments are not activity rows at all. The history isn't missing; it's filtered out.

## 1. History view

**Where:** both. Replace the Activity tab (same embed point in `project_activity_live.ex` — rename to History) with the project timeline, and add a per-task timeline in the task drawer (`assignment_form_live.ex` already loads the thread at :345/:420; put the task's activity rows beside its comments).

**Data source:** merge at read time — do not migrate or double-log. New context `PhoenixKitProjects.History.list(project_uuid, opts)` that merges three reads into one normalized stream (`%{at, actor, kind, task, sentence, link}`):
- activity rows: `PhoenixKit.Activity.list/1` already accepts a `query:` opt — pass an Ecto query with `resource_uuid in ^[project.uuid | assignment_uuids]` (uuids from `Outline.shape/1`, one query). No core change needed.
- comments: `PhoenixKitComments` rows for resource types `"project"` + `"assignment"` scoped to those uuids (the exact call `kitchen_sim.exs:267` makes).
- time entries: `Ledger` work entries (they are logged as activity today, but the raw row lacks the note — enrich from the ledger).

**How it should read:** grouped by day header, one sentence per row, hand-offs narrated with names and quotes: *Kadri reopened "Measure the room" — "wall A doesn't add up"*. Names via `People.display_name/1` (people.ex:179), not `user.email` (`helpers.ex:59`); timestamps via `PhoenixKit.Utils.TimeZone.for_viewer/1` + `shift/2`, not `L10n.format_month_day_time`'s raw UTC (l10n.ex:48). Link every task row with the `raw_task_path/2` shape `ResourceLinks` already builds (resource_links.ex:120). Load-more paging as today.

## 2. "Your turn"

**Trigger:** when a task lands `done`, wake every **dependent** (reverse of `list_all_dependencies/1`, projects.ex:4759) whose dependencies are *now all* done and whose status is `todo`. Compute woken tasks by diffing before/after dependency-satisfaction under the project lock — this is naturally once per cycle and survives a settle that ticks several rows at once. "Next in order" for dependency-free tasks: no, nothing to key on. Subtask→parent: only when the parent carries its own assignee.

**Who:** the person assignee; team/department rows fan out to members — `Notifications.fan_out_from_activity/2` (notifications.ex:83) already exists for exactly this and needs no extra activity rows.

**Where:** in the context, not a PubSub subscriber. All three write paths (LiveView :1108, API `apply_transition` :1092, tick rules) already pass through `Projects.update_assignment_status`/`Outline`; PubSub is fire-and-forget, so a node without a live subscriber (boot, restart) silently loses a hand-off forever, and the `{:projects, :assignment_status_changed, %{uuid, from, to}}` payload is too thin — a subscriber must re-read everything. Concretely: after commit, write ONE activity row per woken task (`projects.assignment_ready`, `target_uuid` = the *dependent's* assignee via `assignee_target_uuid/1`, metadata with `notification_text`/`notification_link`). The activity→notification bridge then delivers, applies prefs and self-skips for free. Note the current wiring can never do this: `assignee_target_uuid/1` targets the *changed* task's assignee, who is usually the actor.

**Reopen upstream while downstream is in progress:** yes — one `projects.assignment_blocked` row targeted at the downstream assignee ("3D model is on hold — Measure the room was reopened"). Note dependencies gate nothing today (tasks can start regardless); the notification is the cheap half, the state marker is Q5.

## 3. Comments

Notify: the task's assignee + earlier commenters on that task + @-mentions (parse with `web/mentions.ex`) + the project's manager-role member. Self-skip comes free (`Notifications.maybe_create_from_activity/1` skips `target == actor`). Mechanism: implement the comments-module hook — I verified `ResourceLinks` does **not** implement `on_comment_created/3` today — and cover resource type `"assignment"` (what `PhoenixKitComments.create_comment` actually receives), not just the `"project_task"` type `ResourceLinks.types/0` owns; fan out from a single `projects.comment_created` activity row.

**Double notification with a reopen:** make the reopen *require* the reason as its comment (Q5 #1) and emit one combined row; failing that, have the comment fan-out skip anyone already targeted by a same-task `*_reopened` row written in the same request.

## 4. Notification text (one line + link, set `notification_text`/`notification_icon`/`notification_link` at the `Activity.log` call sites — `Render` reads exactly these, render.ex:55-57)

| action | line | link |
|---|---|---|
| assignment_created | "Liis assigned you 'Measure the room' in Kitchen — Kristi Valk" | task drawer |
| assignment_ready (new) | "It's your turn: '3D model and layout' — its dependencies are done" | task drawer |
| assignment_reopened | "Kadri reopened 'Measure the room': wall A doesn't add up" | task drawer |
| assignment_blocked (new) | "'3D model and layout' is on hold — 'Measure the room' was reopened" | task drawer |
| assignment_completed | "Marek finished 'Measure the room'" (target: dependents' assignees/manager, not the actor) | task drawer |
| waiting_on set | "'Materials received' is waiting on: LEGRABOX runners (ETA 25.09)" | task drawer |
| comment_created | "Kadri commented on 'Measure the room': Re-measured wall A…" | task drawer |
| member_added | "Liis added you to Kitchen — Kristi Valk" | project page |

Task links: the `raw_task_path/2` shape (project key + `tasks?task=REF#task-uuid`). Apply display_name + viewer timezone to the bell too.

## 5. What else is missing — top five by value

1. **Reopen requires a reason** (posted as the task comment): accept — it is the owner's own story, and it makes the history, the notification and the assignee's context one artifact.
2. **"Returned" state + blocked marker**: accept — `todo` after a reopen is indistinguishable from never-started; a distinct state drives "on hold" downstream (Q2) and the rework loops the owner described.
3. **External waits with a date and reminder**: accept — `waiting_on` is free text (outline.ex:1048); the sim's payment/supplier waits need a `waiting_until` + daily digest reminder to assignee and manager.
4. **Save-as-template**: accept, low effort — `create_project_from_template/2` (projects.ex:2331) exists; the missing half is extracting a finished project back into one (tasks + deps + assignee-by-role).
5. **Client-facing approval step**: the client approves the design but has no seat — a portal link for approve/reject beats structured measurement fields and required attachments (reject both: comments + project files carry measurements and hand-offs well).

## 6. Data correctness under the history (file:function → one-line fix)

1. `Outline.mark_done/3` + `reopen/2` (outline.ex:403/384): auto-ticked subtasks, auto-completed parents and reopened ancestors leave **no rows** — from the post-commit buffer in `with_project_lock/2`, `Activity.log_many` one `mode: "auto"` row per changed uuid.
2. `Outline.sync/4` typed list (create_lines/hold_rows/delete_rows/revive_lines, outline.ex:871/992/1001/805): created (incl. created-*done*), held, deleted and revived tasks log nothing — log from the returned summary (`assignment_created` per created row, one summary row for held/removed).
3. `Projects.propagate_rollup_to_parent/2` (projects.ex:2747): a sub-project's linking-row status flips silently — log `projects.subproject_rollup` when `link.status` moves.
4. `Projects.clone_template/3` (projects.ex:2341): cloned assignments with pre-assigned people produce no `assignment_created` rows or notifications — `log_many` after commit for assigned rows.
5. `TasksController.update_fields` (tasks_controller.ex:759) → `update_assignment_form`: a PATCH moving `status`/`waiting_on` settles and broadcasts but logs nothing — detect the status move there and log the matching action.
6. Misleading, not missing: `Outline.mark_done/3` clears `waiting_on` (outline.ex:413) with no row, and the sim's cleared-waiting writes read as bare "assignment updated" — log waiting_on set/clear as its own action with the text.

*(~1,320 words.)*


## Round 2 — the built code

# Review: Projects History / Handoffs / Notices

## 1. Transactions — checked, sound on every live path, with one latent trap

I traced every caller. `broadcast_status_changed/3` is called only from `update_assignment_status/2` (projects.ex:4503), `update_assignment_form/3` (:4138) and the rollup (:2766) — all after `update_tracking_status/1`'s own transaction has committed. `announce_status_change/1` (outline.ex:556) runs only from `announce_status_changes/2` after the lock transaction commits (`{:ok,_}` guard), and `Handoffs.project_started/1` runs after `start_project/2`'s transaction commits (projects.ex:2632). No caller of `update_assignment_status`/`complete_assignment`/`reopen_assignment`/`Outline.settle|sync|restore` sits inside an outer `Repo.transaction` today, so: a rollback never leaves a notice (rows roll back with, or are never written for, the change), and a committed change always gets its announce — nothing lost short of the swallowed `:exit`/rescue paths, which log.

Latent trap, worth a guard comment: the lock's own docstring (outline.ex:510-512) admits that a caller wrapping `with_project_lock/2` in its own `Repo.transaction` gets the announcement *before* the outer commit — there, `Handoffs`' reads/inserts join the caller's transaction. `Handoffs.status_changed`'s rescue does not save that caller: a DB error inside it aborts the Postgres transaction, the rescue swallows it, and the caller's *status change* then fails at commit — exactly the "a change is never lost to a notice" the moduledoc promises. No current caller does this; a `Repo.in_transaction?` raise or a deferred-announce would make the promise structural.

Race note: two people ticking the last two subtasks of a parent both announce after their own lock commits; each `wake_after` re-`load/1`s the shape post-commit, both see a ready task, and the assignee can get two "your turn" notices for one readiness. Correctness survives; the bell duplicates.

## 2. Cost on hot paths — real per-row reads, violates the module rule

A tick that cascades over N rows (`Outline.settle` → `tick_below`/`settle_above` → announce loop, outline.ex:573-575) calls `Handoffs.status_changed(change, :auto)` **per row**, and per row it does: `Projects.get_assignment` (1 SELECT + preloads) in `log_auto`, `load(project_uuid)` — 2 SELECTs re-reading the *whole* shape per cascaded row, invariant across the batch (handoffs.ex:222-258), `label_of` → `get_assignment` again (duplicate of `log_auto`'s), and per woken row `People.assignee_user_uuids/1` (1 SELECT) plus `notify_ready` → `get_assignment` again. That is ≥5 statements per cascaded row before any notice — ~5N, in the caller's LiveView/conn process (latency lands on the tick click). Per notified person add one INSERT plus `decorate`'s own `get_assignment`, `Auth.get_user` ×2 (actor re-read per row) and `get_project` for the project name — ~6 more. A 100-subtask container tick ≈ 500-1500 statements. Fix shape: load the shape once per announce batch, pass the assignment struct through (`log_auto`/`label_of`/`notify_ready`/`decorate` re-fetch the same row four times), batch the names.

`Outline.sync/4` itself is fine inside the lock (`note_status_changes` buffers, batches write); the cost is the per-row announce above after commit. `POST /tasks/batch` inserts don't announce (creation isn't a change); only `reopen_parent`'s single settle can. `clone_template` writes all-todo rows (no announce) and pays `project_started/1` once after start — `load` once, but `assignee_user_uuids` per ready row and ~6 per person; rare, acceptable. `Notices.decorate/2` adds ~4 reads to every targeted `Activity.log/2` — fine per action, but it is what makes the per-row cascade above 12-15 statements.

## 3. Privacy — yes, both vectors are real

- `CommentNotices.earlier_commenters/2` (comment_notices.ex:112-120) selects every distinct past commenter on the resource with **no membership or access check**. A removed member, a demoted ex-manager — anyone who ever commented — keeps receiving `%{actor} on "task": "<120-char excerpt>"` in their bell for every later comment on that task/project, plus a link they can no longer open. Project comments gate *owners/managers* through current `Members.list_members/1` but the earlier-commenter arm bypasses that gate entirely.
- `People.assignee_user_uuids/1` (people.ex:171-208) resolves a team/department assignment to **every** non-trashed member with an account — no project membership, role, or grant is consulted. "Your turn"/"on hold" (and task-comment notices) reach people who never had access to the project, and keep reaching a person after their membership is removed (the assignment fields persist). Whether assignment-is-the-grant is the product call, but removed-members and never-members both falling through is the same hole the members arm half-closes.

A portal visitor who commented (if that flow exists for logged-in viewers) lands in the first bucket permanently.

## 4. History correctness — one real miss, one index risk

- **Deleted tasks' direct rows vanish.** `activity/3` matches `resource_uuid in ^ids`, where `ids` is the project + *current* assignments. Rows written by the direct paths — `update_assignment_with_activity` (project_show_live.ex:1115-1123, metadata only `task`/`reason`), dependency logs (assignment_form_live.ex:2354) — carry **no** `metadata["project_uuid"]`, so once the task row is deleted its completed/reopened/started lines drop out of `History.list/2`. The moduledoc's "their rows still say what they were through metadata["task"]" only holds for rows that already carry `project_uuid` (auto rows, notices). Failing input: complete a task on the page, delete the task, open History — the completion line is gone; `task_ref`'s `meta["task"]` fallback is unreachable. Fix: stamp `project_uuid` on those logs (or read deleted uuids too).
- **Index:** the `or fragment("?->>'project_uuid' = ?")` needs an expression index (`(module, (metadata->>'project_uuid'))`) or the OR forces a scan of everything `module == "projects"` on a large `phoenix_kit_activities`; `ids` itself can be thousands of uuids. Verify the migration added one.
- Folding: two "your turn" notices for one task in the same second from *different* completed predecessors fold into one line quoting only the first's "after"; across seconds they don't fold (the §1 race shows up as two bell rows). `told` lists only recipients whose in-app prefs allowed a notification row — someone told by email only reads as not told. Sub-project rows stay in their own project (rollup rows carry the *parent's* uuid — correct); no duplicate lines found (comment notices dropped, reopen-reason comments nil'd, the reopen's own row kept).

## 5. Time zones — coherent inside the diff; two edges

The Events tab round-trips consistently (`from_wall` on write, `local_date/local_time` on read, all-day kept as stored UTC midnights, `event_date/2` splits correctly); the start dialog and project form round-trip (`local()` prefill :2989/:3111, `from_wall` parse :2796/:315); the API and the Hours report/CSV remain UTC/own-offset by design and agree as instants.

- **Pre-deploy data shifts:** timed events created before this change were stored as `DateTime.new!(date, time, "Etc/UTC")` (old parse_moment) and are now *displayed* in the viewer's zone — every legacy timed event is silently re-timed by the offset on the grid and in "what's next". No migration was run; worth a note or a one-off backfill decision.
- `Widgets.Helpers.date/1` (widgets/helpers.ex:163) prints raw UTC `YYYY-MM-DD` — a dashboard card's deadline date now disagrees with the same project's dates on every projects page (widgets render in the host's process, where the zone key is never set — `L10n` can't fix it from there without the host setting the zone).
- Edge: `L10n.from_wall` → nil in a DST gap surfaces as "Pick a date for the event" for a date the user did pick.

## 6. Reopen reason and the API

Gating/permission: checked, sound — `"reopen" => :tasks` on the page, `scoped_assignment/2` on both handlers, the API validates `to in allowed` and the take-policy; the comment posts as the actor (page: `Activity.actor_uuid`; API: the key's accountable person, attribution `personal` + key name), and `reopen_reason` metadata correctly suppresses the assignee's duplicate comment notice.

- **Page order is backwards:** `post_reopen_reason/3` runs *before* `update_assignment_with_activity` (project_show_live.ex:2159-2160). If the update fails the changeset, the reason comment stands on a task that never reopened (and `log_failed` records the reason as an attempted reopen). The API path has it right (transition, then `reopen_reason/4`) — swap the page to match.
- **No transition check on the page:** `gated_handle_event("reopen", …)` never checks the task is currently done. A stale tab (or forged event) on a todo task posts the comment and writes `projects.assignment_reopened` with the reason — `broadcast_status_changed` no-ops (`from == to`) but the notice row still fires: the assignee is told "reopened: 'reason'" for a non-change. The API rejects todo→todo; add the same `was == "done"` guard.
- **Uncapped `reason`:** the API takes `conn.params["reason"]` (tasks_controller.ex:1101-1111) and the page a `to_string` of any param — no length cap anywhere. The notice truncates (`excerpt/1`, 120) but the *permanent* activity row stores the full string and History's `quote` prints it all; a 1 MB reason is one request away. The comment insert may also fail its own content cap silently, so "posted to the discussion" quietly doesn't happen while the notice still quotes it. Cap at the same limit the comment uses.

---

### Findings

1. **[High] Q4** Deleted tasks' page/API-written status rows (no `metadata["project_uuid"]`) fall out of `History.list/2` once the assignment row is gone — `task_ref`'s `meta["task"]` fallback is dead code for them. Stamp `project_uuid` in `update_assignment_with_activity` and the dependency logs.
2. **[High] Q2** `Handoffs.status_changed` per cascaded row: ≥5 statements/row (`load/2` re-reads the shape per row; `get_assignment` ×3 for the same row), ~12-15 with notices — per-item reads on the tick hot path, in the user's process.
3. **[High] Q3** `earlier_commenters/2` has no access gate — removed members keep receiving comment excerpts forever; `People.assignee_user_uuids/1` notifies team/department members with no project access either.
4. **[Med] Q6** Page reopen posts the reason comment before the transition and never checks the task was done — failed reopen leaves an orphan reason comment; stale-tab reopen sends a "reopened" notice for a non-change.
5. **[Med] Q6** `reason` is unbounded into permanent activity metadata and the History quote; comment-posting is best-effort and can silently not happen.
6. **[Med] Q5** Legacy timed events (stored UTC-as-typed) now display shifted; no backfill.
7. **[Med] Q1** Latent: a future caller nesting `with_project_lock/2` in its own transaction makes `Handoffs`' writes join it, and a notice failure aborts the caller's change despite the rescue — the moduledoc's core promise. Guard or defer.
8. **[Low] Q4** `metadata->>'project_uuid'` OR clause needs an expression index or it scans; verify the migration added one. Same-second folds can merge two different predecessors' "your turn" into one mis-attributed line; `told` misses email-only recipients.


## Round 3 — the final sweep before the PR

Everything verified. Here is the sweep.

# Part A — quality sweep

**1. Rules (`Handoffs`).** `ready?/2` + `clear?/3` are sound: deps met (nil dep = met), ancestor chain walked, `depth > 100` fails closed on cycles, list order never used; container-wake and resume branches check the right statuses, and `hold` correctly includes descendants (their readiness is ancestor-gated too). Two defects:

- **Double notify on one tick.** `update_assignment_status/2` produces *two* `statuses_changed/2` passes per write: the outline's `:auto` announce fires inside `settle_outline` (`outline.ex:552→582`), the caller's `:direct` after (`projects.ex:4503`). `wake/3` dedupes within a pass only (`Enum.uniq_by` in `handoffs.ex:447`). Failing input: container `P` with subtask `S`; `X` (todo, Bob) depends on **both** `P` and `S`; Alice ticks `S` done → outline ticks `P` done. Bob gets two `projects.assignment_ready` notices (after=S, after=P) and History shows two "Ready to start" lines (`fold_notices` keys on `meta["after"]`, so they don't fold).
- **Unlocalized "after"/auto labels.** `Handoffs.load/1` selects `coalesce(t.title, cp.name)` raw, while `Notices.subject_label` and `History.task_index` use `Assignment.label(_, lang)` with `translations`. With a translated task, one notice reads `Sinu kord: „3D mudel“ — „Measure the room“ is done` — recipient-language task, primary-language prerequisite (`handoffs.ex:422,496`; also the deleted-task label in History via `meta["task"]`).

Checked, sound: cross-project deps would read as "met" (`clear?` nil branch) but every `add_dependency` call site is same-project; re-start via stale `confirm_start_project` re-notifies but the modal guards it; "more" for on-hold is set but unused in text/tail (cosmetic).

**2. Conventions.** The batched-reads rule is breached on the new hot path: `Handoffs.tell/3` does per person `Projects.get_assignment` + `project_of` get_project, and `Notices.notify/3 → may_view?/2` does `Auth.get_user` + `Authz.can?` **per recipient** — a department-assigned task with 25 people ≈ 100+ queries inside one status change, synchronously in the LiveView/API process. Same shape in `CommentNotices.on_comment_created/3` per recipient. `Activity.with_project_uuid/1` adds one assignment read per logged row for callers that don't pass `project_uuid` (`update_assignment_with_activity` doesn't). Embeddable-LiveView, mass-assignment (`reopen_reason/1` type-guards, 2000 cap), LiveView-layer logging, namespaced ids: all conform. i18n: all new strings wrapped and present in et/ru po; one wrong Estonian form and two awkward prefix translations (findings).

**3. Privacy.** Checked, sound: every new notice path gates on `Notices.may_view?/2` (tested for team non-members and leavers); History/comments are published-only and gated `:view`; the reopen reason reaches only people who can already open the project. `decorate/2` paths add text to rows whose reach is pre-existing, not new. Minor: History shows "who was told" to every project viewer — only names of people with access; acceptable.

**4. History.** Merge, fold, told-joins and second-order sorting check out against the code; deleted tasks keep struck-through names via `metadata["task"]`. Three nits: `total` counts capped entries (says 2000 at 3500, `history.ex:703`); `truncated` false-positives at exactly `@cap`; guide claims actor-less rows read "Someone" but the feed's actor span is simply hidden when `actor` is nil (`history_feed.ex:71`).

**5. Tests.** Strong for handoffs/notices/comments/History/reopen dialog. **No test would fail if reverted:** `l10n.ex` (the whole viewer-zone feature), `web/helpers.ex` (`normalize_local_to_utc`, zone+Actor in `declare_ref_writer`), `project_events_live.ex` zone reads, `project_form_live.ex` `local_input_value`, `member_projects_live`/`project_whiteboards_live` zone, `api/auth.ex` Actor.put, `api/tasks_controller.ex` reason path, `assignment_form_live.ex` `log_typed_changes` + drawer history, `pub_sub.ex` `broadcast_to_project` (History live-reload on comments untested), `projects.ex` `:auto` **rollup** rows (only the outline-tick auto row is tested), `project_history_live` filter/load_more.

# Part B — what is missing (ranked)

1. **A per-person digest of open hand-offs** ("your turn since yesterday / still on hold") — the bell fires once, on the event; a missed ping stalls the chain silently, and the plan's own no-outbox note makes loss possible.
2. **History export (PDF/CSV)** — client approval and handover need a signed, shareable record of approvals, changes and reasons; screen-only defeats the audit story.
3. **Client-scoped History on the portal** — the approval loop's other half; today the client learns changes through a person relaying them.
4. **Reopen-loop escalation** — after N reopens of the same edge, tell the owner/manager; production rework loops otherwise ping-pong between two people with nobody managing cost.
5. **"Waiting since N days" derived badge** on ready-but-unstarted and on-hold rows (read-time derived, like the On-hold badge) — the production manager's at-a-glance stall detector.

# Findings

- `BUG - MEDIUM` — double "your turn" notice + duplicate History line when a task depends on both a directly-ticked row and a row the tick rules move: `handoffs.ex:statuses_changed/3` called twice per write (`projects.ex:4496+4503`, `outline.ex:552`).
- `BUG - MEDIUM` — "after" prerequisite name (and auto-row task label) bypasses task/sub-project translations: `handoffs.ex:load/1` `coalesce(t.title, cp.name)` vs `Assignment.label/2` everywhere else.
- `BUG - MEDIUM` — Estonian "Sinu kord: „%{task}“ **võib alata**" — wrong verb form; should be "võib alustada" (`et/default.po:8605`) — the flagship notice, seen on every hand-off.
- `IMPROVEMENT - HIGH` — per-recipient `may_view?` (get_user + can?) and per-person assignment/project reads in the notice path: ~4–5 queries × people told per status change/comment, synchronous in the request (`notices.ex:notify/3`, `handoffs.ex:tell/3`, `comment_notices.ex`).
- `IMPROVEMENT - MEDIUM` — no tests for the time-zone layer (`l10n.ex`, `helpers.ex` inputs, events/form LiveViews) nor the API `reason`/Actor paths; a revert of `from_wall` to append-`Z` passes the suite.
- `IMPROVEMENT - MEDIUM` — pre-existing typed times (stored as-UTC under the old rule) now display shifted by the viewer's offset; decide whether to communicate/migrate.
- `NITPICK` — on-hold "more" count computed but unused in text and History tail (`handoffs.ex:tell/3`).
- `NITPICK` — `total`/`truncated` mis-report at the 2 000-line cap (`history.ex:688,703`).
- `NITPICK` — actor-less rows render with no actor, not "Someone", contradicting the guide (`history_feed.ex:71`).
- `NITPICK` — awkward prefix + task link in ET ("Töö algas ülesande all X") / RU ("Начата работа внутри X") / EN ("Work started under X"); rescue logging records only `error.__struct__`, no message.

## Round 4 — the fixes made after the sweep

Read: the Notices contract guide, `delta.diff` (full; the file is cut mid-hunk in the preferences list), `delta_test.diff`, and the current `notices.ex`, `activity.ex`, `handoffs.ex`, `pub_sub.ex`, `history.ex`, `comment_notices.ex`, `outline.ex` + `outline/api.ex`, `projects.ex` (status/batch paths), `assignment_form_live.ex`, `project_show_live.ex`, `outline_list.ex`, `tasks_controller.ex`.

**1. Who is told.** Form: `log_typed_changes` (status row targeted at the person, or fanned out for a team) + `told?` suppressing the generic row, and `Notices.reassigned` covering hand-overs — a person is told once per save in every combination I walked (typed-only, status-only, reassign-only, status+reassign). API: create fans out (`tasks_controller.ex:302`), PATCH suppresses the generic row when reassigned (`:398`), transition targets or fans out (`:1109`), delete calls `Notices.removed` (`:857`); page delete likewise (`project_show_live.ex:2333`). Templates die in `notify/3`'s `is_template` gate even via the fan-out (tested). The reopen-reason comment excludes *all* the task's people, matching the fan-out that now covers teams (tested). Two gaps below (F1, F2); `Handoffs.log_auto` rows carry `auto` and never fan out; `wake`/`hold` tell only downstream people, never the changed task's own.

**2. Recursion and noise.** No loop: `notify/3`'s rows carry `"notice" => true`, which `tell_assignees/2` rejects; `reassigned`'s audit row passes `tell: false`. Bulk paths are quiet for a structural reason, not a `tell: false`: `POST /tasks/batch` and `Outline.sync` create only *unassigned* rows (`outline/api.ex:221-248`, `outline.ex` step 1), so `assignee_user_uuids` is `[]`; sync writes one `task_list_edited` row (`log_sync`). Bulk status ticks are `auto`. `outline_nest`/move log `assignment_moved` (not an assignee action). Doc drift: the guide still names `Notices.tell_group/3`, which no longer exists (F6).

**3. `after_commit` + PATCH.** Nesting is sound: `Outline.with_project_lock` inside the PATCH is a savepoint; its status announcements buffer into the `Handoffs.batch` (`statuses_changed` sees the buffer) and its PubSub calls go through `send_msg` into `@deferred`. Rollback via `{:error, _}` drops held broadcasts in `after_commit`'s `cond` and `write_update` calls `Handoffs.discard/0`; an exception is caught in both layers and the buffers deleted (tested: rollback, raise, nested join, discarded batch). A rolled-back inner step (`reparent` `:cycle`, `update_tracking_status` changeset) unwinds to the outer rollback; nothing partial escapes. The flush's `uniq` only collapses byte-identical reload signals (`:assignment_reordered`, `:history_changed` carry just the project uuid) — harmless. No notice rows are written inside the transaction (nothing inside `write_update`'s fun logs task actions).

**4. Mentions.** `claim_mentions` runs before `recipients`' skip/uniq and `notify`'s `may_view?` filter — a mentioned non-viewer is told zero times *by design* (privacy over ping), and an already-delivered mention isn't retold. The box's own re-sync is pinned by the new test (sync + `notify` after create → one `comment_added`, zero `mention.created`). Notes claim through the same source type, consistent. Only edge: `sync` returning `{:error, _}` raises into `mentioned/1`'s rescue → API comments tell the mentioned zero times (index is broken anyway); box comments still get the box ping.

**5. Privacy.** `decorate` refuses a task line for a `target` who may not open the project (row written, no text — pinned by test); `notify` filters every recipient; the removed-task notice links to the project, not the dead task; emit-mode History renders plain text (`links: false`); ledger corrections only appear while the ledger feature is on. Found nothing reaching a non-viewer.

## Findings

- **BUG - MEDIUM** — Removing a task by deleting its line in the typed list tells its people nothing. `Outline.sync` step 4 (`outline.ex:776-782`) soft-removes known rows with no line; `outline_sync` (`outline_list.ex:226`) writes only `task_list_edited`. Failing input: team-assigned task, viewer with `outline_can.delete`, delete the line, blur → row gone, no `assignment_removed`, no `Notices.removed` — the trash button on the same task does tell. Table row "a task removed (page, API)" is unmet.
- **BUG - MEDIUM** — A PATCH that only moves a task tells its people "changed your task". `do_update` (`tasks_controller.ex:398`) logs `assignment_updated` with `tell: not reassigned?`; `assignment_attrs` admits `position`, and `parent` goes through `reparent` — both pure moves, yet they fan out, while the dedicated move endpoint passes `tell: false` for the same act (`:915`). Input: `PATCH /tasks/{id} {"position": 5}` on a team task → every member notified.
- **IMPROVEMENT - MEDIUM** — Deleted notes are never scrubbed. `on_comment_deleted` (`comment_notices.ex:133`) handles only `"assignment"`/`"project"`; a deleted note/redirect keeps its excerpt in permanent notice rows and History, though `scrub_comment/1` exists and the moduledoc calls these rows "the only place those words can be taken back".
- **NITPICK** — One form save changing status *and* assignee on a group task notifies the new group twice ("started your task" fan-out from `log_typed_changes:2644` + "gave you a task" from `reassigned`).
- **NITPICK** — Closure-create extras (`assignment_form_live.ex:2255-2265`) fan out one "gave you a task" per extra when the form's attrs carry an assignee — N+1 notices for one save.
- **NITPICK** — Guide drift: `history-and-handoffs.md` still describes `Notices.tell_group/3` (gone; the fan-out is `tell_assignees/2`), and `decorate/2` is now `/3`.
- **NITPICK** — `PubSub.after_commit/1` inside a *plain* `Repo.transaction` (not another `after_commit`) would flush at savepoint release, before the real commit; no current caller does this, but the contract only forbids it implicitly.
