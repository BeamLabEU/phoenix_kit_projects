# Codex review — History, hand-offs and notices

Reviewer: OpenAI Codex (gpt-6.1-sol in the last round). Each section is one round, reproduced as answered (local paths removed); how each finding was resolved is in `FOLLOW_UP.md`.


## Round 1 — the design, before any code

### 1. History view

Use both:

- Replace the existing Activity tab with a human-facing **History** tab, retaining `/activity` for compatibility and offering “Audit details” for raw metadata.
- Add the same feed filtered to one assignment inside the task drawer/form. Build this into `AssignmentFormLive`, rather than maintaining a second history implementation.

Create a `PhoenixKitProjects.ProjectHistory.list/2` read model, used by ProjectActivityLive.load_page/1. Merge at read time:

- Activity rows for the project, its assignments, and optionally its sub-project tree; use `PhoenixKit.Activity.list(query: ...)`, not its current single-`resource_uuid` filter.
- Published `"project"`/`"assignment"` comments.
- `Ledger.list_entries/2` time entries, using `ended_at || inserted_at`.

Suppress `projects.work_logged` and `projects.comment_added` activity rows when their canonical work entry/comment is present, otherwise API comments and time appear twice. Use keyset pagination over a normalized `{occurred_at, source, uuid}`.

Render sentence templates, not core’s generic `activity_list/1`: “Kadri reopened Measure the room: ‘Wall A doesn’t add up’”; “Marek logged 1h 25m”; “3D model became ready for Kadri.” Group by the viewer’s local day, then time. Resolve task links with Paths.task/2.

Use `People.display_name/1`, adding a batched user-UUID lookup; fix Web.Helpers.assignee_label/1 and the completed-by badge similarly. Shift timestamps through `PhoenixKit.Utils.TimeZone.for_viewer/1` and `shift/2` before L10n formatting.

Workflow activities must be permanent or stored in a dedicated journal; ordinary core activity retention cannot underpin a complete order history.

### 2. “Your turn”

The trigger is a **readiness edge**, `not ready → ready`, after commit:

- The project starts and a todo task has no dependencies.
- The last unfinished explicit dependency becomes done.
- A dependency is removed, or a ready task receives/changes its assignee.

Position is presentation, not workflow: do not infer “next” from outline order. Tasks without dependencies are all ready when the project starts. Nesting is also not a dependency; notify concrete subtasks, not an auto-completing parent/container. A sub-project link is a rollup, while tasks inside the child follow their own dependencies.

For a person assignee, notify the linked user. For team/department assignees, expand to active linked users with project access, deduplicate them, and treat the task as a shared queue that someone claims by starting.

Do not make a PubSub subscriber authoritative. `:assignment_status_changed` reaches every current status path, but it is ephemeral, can be delivered more than once, and sometimes precedes an enclosing transaction’s commit. Put readiness calculation and a durable, idempotent outbox in the context transition path around `Projects.update_assignment_status/2`, `Outline.settle/3`, and sub-project rollups. PubSub remains a UI wake-up. Unique `{event_uuid, recipient_uuid}` delivery plus core’s notification uniqueness makes retries safe.

If an upstream task reopens, derive `blocked_by_dependencies` without overwriting the downstream status. Notify an in-progress assignee: “3D model is on hold because Measure the room reopened.” Alert the manager if the downstream task is already done, because prior output may now be invalid.

### 3. Comments

Notify the union of:

- The task’s person/team/department assignee.
- Explicit `@mentions`.
- Prior participants/watchers, with unsubscribe.
- The project manager only for project comments, reopens/returns, blockers, or an explicit watch—not every routine reply.

Remove the author, inaccessible users, and duplicates before delivery.

There is a code mismatch to fix first: comments use `"assignment"`, but ResourceLinks.types/0 does not register that alias. Add it, then implement `on_comment_created/3` there.

Make “comment + reopen” one context operation, e.g. `return_assignment/4`, with a shared correlation ID and `reason_comment_uuid`. Emit one `projects.assignment_returned` notification to overlapping recipients; the comment hook should suppress its generic notice for them while still notifying unrelated mentions/watchers.

### 4. Notification text

Stamp `notification_text`, `notification_icon`, and `notification_link` at the Projects emitter; core Render already honors them.

| Action | One-line text | Link |
|---|---|---|
| `assignment_created` | “New task assigned: Measure the room — Valk kitchen.” | `Paths.task/2` |
| `assignment_updated` | “Kadri updated your task Measure the room.” | Task |
| `assignment_started` | “Kadri started Measure the room.” | Task |
| `assignment_completed` | “Marek completed Measure the room.” | Task |
| `assignment_reopened`/`returned` | “Kadri returned Measure the room: ‘Wall A doesn’t add up.’” | Task/comment anchor |
| `assignment_ready` | “Your turn: 3D model is ready — Valk kitchen.” | Task |
| `assignment_blocked` | “3D model is on hold because Measure the room reopened.” | Task |
| comment/mention | “Kadri commented on Measure the room: ‘You forgot…’” / “Kadri mentioned you…” | Comment anchor |
| member added/role changed/removed | “You were added to Valk kitchen as member.” / “Your role is now manager.” / “You were removed…” | Project/members |
| health updated | “Valk kitchen was marked At risk: materials delayed.” | Project |
| event created/updated/deleted | “Installation appointment was added/changed/cancelled — Valk kitchen.” | Events tab |
| project completed/reopened | “Valk kitchen was completed.” / “Valk kitchen reopened after Measure the room reopened.” | Project |

Settings, API-key, display, template, and ordinary dependency actions should remain audit-only; readiness changes generate their own user-facing notification.

### 5. Top five missing additions

1. **Required handoff package:** structured, unit-aware measurements/estimates plus required drawings, photos, or approvals before completion.

2. **Atomic return/rework:** require a reason and record a “returned” transition and rework count; keep `todo/in_progress/done` as the steady statuses.

3. **External waits:** replace free-text `waiting_on` with owner, expected/due date, reminder, escalation, and resolved timestamp for payments and suppliers.

4. **Impact blocking:** show a derived “blocked because X reopened” marker and an impact queue for already-started or completed downstream work.

5. **Project → template:** clone a successful order into a scrubbed template, preserving structure, dependencies, role assignees, gates, and relative dates—not customer data or history.

### 6. Correctness gaps in today’s rows

- Outline.settle/3 and settle_tree/2: cascaded ticks/reopens only broadcast and auto-completions misleadingly inherit the child actor. Journal every derived transition after commit with `mode: auto` and its trigger.

- AssignmentFormLive.autosave_now/1: status changes become one generic “updated” row per visit, while context-triggered project completion is unlogged. Emit typed transitions from the context result.

- TasksController.do_transition/3: only the requested row is logged; `also_changed` cascades are not. Journal the complete transition set with API-key attribution.

- Outline.sync/4: creates/removes/restores/renames and initially checked tasks collapse into one count-only `task_list_edited` row. Return and journal per-row effects.

- Projects.clone_template/3: cloned assignments/dependencies have no history, and automatic start is not logged. Store a clone manifest/count plus per-task provenance and a start event.

- Projects.propagate_rollup_to_parent/2: link-row and recursively completed/reopened parent transitions only broadcast. Journal both with `source: child_project` after the rollup commits.


## Round 2 — the built code

### 1. Transactions

Concrete failure: `Repo.transaction(fn -> Projects.update_assignment_status(a, %{status: "done"}); Repo.rollback(:later) end)`.

`Projects.broadcast_status_changed/3` is reached from:

- `Projects.update_assignment_form/3`
- `Projects.update_assignment_status/2`
- `Projects.propagate_rollup_to_parent/2`

In normal in-tree use, each runs after its own status transaction has committed. `Outline.announce_status_change/1` similarly runs after the outermost `with_project_lock/2` for `settle`, `move`, `sync`, `restore`, and `Outline.Api.batch_create`; nested project locks correctly pass their buffered events outward. `clone_template` causes no status hook.

However, wrapping any public operation in another `Repo.transaction` breaks that guarantee. The inner transaction is only a savepoint, so activity and notification rows are broadcast before the real commit. A later rollback removes their database rows, but connected clients can already have received phantom activity/bell PubSub messages. A handoff database error can also poison and roll back the enclosing transaction despite being rescued.

Notices can also be lost after a committed status change: every Handoff failure is swallowed, and activity insertion and notification creation are separate best-effort statements.

### 2. Cost on hot paths

Concrete failure: `Outline.sync/4` causes 100 parents to change status.

`Handoffs.status_changed/2` has no fixed statement count:

- Direct `todo → in_progress`: zero Handoff statements.
- Direct completion/reopen with nobody downstream: two shape reads plus `label_of/1`’s preloaded `get_assignment/1`; that is at least three query calls, with `get_assignment` expanding into several preload statements.
- Every auto change additionally performs a preloaded assignment read and one activity insert.
- Each candidate downstream row performs one `People.assignee_user_uuids/1` query.
- Each notified user causes further assignment, actor and recipient reads, an activity insert, notification routing reads, and normally a notification insert.

Thus an N-row tick cascade is O(N) shape reads and writes: for N auto completions/reopens, at least N assignment reads, N activity inserts and 2N full-shape reads, before assignee/recipient work. This violates “no per-item reads on a hot path.”

`Outline.sync/4` pays that cost for each auto-changed parent. `POST /tasks/batch` adds none for newly inserted rows, but may trigger it for an auto-reopened parent. `clone_template` adds none because clones start as `todo`.

`Notices.decorate/2` adds, for each supported targeted activity, a subject read plus actor and recipient reads; core then reads the recipient again. It is also per-recipient rather than batched.

Concrete locale failure: a recipient with no preferred locale, site default English, and an Estonian-speaking actor receives Estonian text because `RecipientLocale.base/1` returns `nil` and `in_locale/2` preserves the sender’s locale.

### 3. Privacy

Concrete failure: `CommentNotices.earlier_commenters/2`; user U comments, is removed from a private project, then somebody comments again. U remains in the comments query and receives the new excerpt without any `Authz.can?/5` check.

This also leaks pending/moderated comments: `on_comment_created/3` runs regardless of `comment.status`, so earlier commenters can receive an excerpt before approval.

A normal portal commenter is sound: portal discussions use `"project_assignment"`, not `"assignment"` or `"project"`, so this handler does not include them.

Concrete group failure: assign a task to team T, add user U to T, but give T no project grant. `People.assignee_user_uuids/1` returns U and Handoffs sends the task/dependency names although U cannot pass the project’s `:view` gate. Department assignees have the same problem.

### 4. History correctness

Concrete failure: complete a task through `ProjectShowLive`, then delete it. That activity has `resource_uuid = task_uuid` but normally no `metadata.project_uuid`; because `task_index/1` no longer contains the task, the row disappears. Deleted-task comments and notes disappear too. Time remains because it is queried by project, but its task label becomes blank.

A parent includes its sub-project linking row, but not the child project’s internal activities, comments, notes, or time.

The `resource_uuid IN (…) OR metadata->>'project_uuid' = …` predicate has no expression index added here. The unindexed JSON branch prevents the lookup from remaining bounded by the resource index and can scan/sort the module’s activity rows on a large table.

Concrete folding failure: two independent `"assignment_ready"` notices for the same task within one second are grouped solely by `{action, task_uuid, second}`. Their actors and `"after"` metadata collapse to an arbitrary first row.

`told/1` and `with_comment_told/1` only see in-app `Notification` rows. External-only delivery and digests appear as “not told”; after non-permanent comment-notice activity is pruned, a retained comment also loses its historical recipient list. The SQL `OR` itself does not duplicate rows.

### 5. Time zones

Events, the start dialog, and the project form are checked, sound: timed values round-trip viewer wall time → UTC → viewer wall time; all-day events deliberately retain their stored calendar date. API timestamps and `/hours` days remain explicitly UTC. CSV row timestamps use the report’s explicit zone and are not double-shifted.

Concrete Hours failure: `ProjectHoursLive.do_load/1` passes one current `Period.offset_seconds/1` into all SQL day grouping. Around Tallinn’s DST change, `2026-10-24 21:30Z` displays as October 25 under UTC+3, but a post-switch +2 grouping places it on October 24.

Concrete report mismatch: `Hours.Report.filename/2` uses the UTC date. A report generated at `2026-10-24 21:30Z` displays “Oct 25 00:30” in Tallinn but downloads as `…-2026-10-24.csv`.

### 6. Reopen reason and API

Concrete permission failure: a user/key allowed `update_status` but denied commenting can still create a reason comment. `ProjectShowLive` checks only `:update_status`; the API requires only `status:write`. The API also forces `status: "published"`, bypassing both `comments:write` and moderation.

Concrete ordering failure: `ProjectShowLive.post_reopen_reason/3` commits the comment before changing status. If the status update then fails, an orphan “reopen reason” comment and mention notifications remain while the task stays done. The API has the inverse partial-success problem: status commits first, then comment creation can fail silently.

Concrete crafted input: LiveView `"reason" => %{"x" => "y"}` raises in `to_string/1`. Blank reasons bypass the HTML `required` control, and arbitrarily long reasons are not validated before mutation; comment rejection is ignored while the permanent activity metadata retains the full text. HEEx escapes markup and notice excerpts use plain text, but valid mention tokens still generate mention notifications.

The comment author is otherwise correct: the LiveView uses the current actor; the API uses `ApiKey.accountable_uuid/1` and labels the attribution with the key.

### Findings

- High: notification audiences are not re-authorized; revoked commenters and ungranted team/department members receive private text.
- High: reopen reasons bypass comment permission, API scope, and moderation.
- High: Handoffs introduces multiple N+1 query families on tick/sync paths.
- Medium: outer transactions can emit phantom notices before rollback.
- Medium: deleted-task and child-project history is incomplete; notice folding can merge unrelated events.
- Medium: Hours day grouping is DST-inconsistent with its displayed timestamps.


## Round 3 — the final sweep before the PR

Read-only review completed; no files changed and no application or tests run. `priv/gettext/default.pot` is absent from the supplied tree, so POT completeness could not be verified.

For Part A:

1. **Rules:** `Handoffs.ready?/2` and `clear?/3` checked, sound for valid accepted outlines: dependencies, ancestor dependencies, held exclusions and independence from list order. Dispatch, grouping and start failures are below.
2. **Conventions:** History’s batched reads, mass-assignment guards and absence of `handle_params/3` checked, sound. Automatic activity logging follows the documented exception. DOM, notification-read and gettext issues are below.
3. **Privacy/authorization:** two concrete failures below.
4. **History:** deletion, grouped handoffs, waiting changes and attribution have concrete failures below.
5. **Tests:** static audit of assertions, excluding incidental compilation failures:

| Tests containing regression-sensitive assertions | Changed production files covered |
|---|---|
| `integration/handoffs_test.exs` | `activity.ex`, `actor.ex`, `comment_notices.ex`, `handoffs.ex`, `history.ex`, `notices.ex`, `outline.ex`, `people.ex`, `projects.ex`, `pub_sub.ex` |
| `notification_wiring_test.exs` | `lib/phoenix_kit_projects.ex` notification declarations |
| `web/project_history_live_test.exs`, feature/destructive-button tests | `paths.ex`, `web/components/history_feed.ex`, `web/project_history_live.ex`, `web/project_show_live.ex` |

Changes without behavioral assertions that distinguish them from the previous implementation:

- `l10n.ex`; `web/{helpers,member_projects_live,project_events_live,project_form_live,project_whiteboards_live}.ex`: viewer-zone setup, conversion and round trips; helpers’ name/actor changes.
- `web/api/{auth,docs,tasks_controller}.ex`: process actor, documented reason parameter and reason posting.
- `web/assignment_form_live.ex`: drawer History and typed status/waiting logging.
- `resource_links.ex`: actual handler registration/delegation—the new integration tests install overrides; `web/gettext_manifest.ex`: History registration.

Also unpinned: department fanout, direct-status/membership notification wording, History time/notes/read receipts/folding/pagination, and production History route registration.

For Part B, ranked additions beyond the plan’s exclusions:

1. **Explicit handoff acceptance or refusal:** seeing a bell does not establish that someone accepted responsibility.
2. **Revision and rework-cycle references:** show which measurement, drawing or cutting-list revision a completion approved.
3. **Before/after values for consequential edits:** explain changed prices, installation dates, estimates and ownership.
4. **Reassignment and unowned-work routing:** tell the replacement worker and expose ready work with nobody responsible.
5. **Hard versus advisory blockers:** an invoice correction may block handing over paperwork while installation can continue.

The remaining findings are:

- **BUG - HIGH — Visibility bypass.** notices.ex:decorate/2: assign a private-project task to a nonmember, then reopen it with a sensitive reason. Direct activity notifications bypass `may_view?/2` and disclose task/project/reason text.

- **BUG - HIGH — Comment authorization bypass.** tasks_controller.ex:post_reason/3: a member key with `comments:write`, allowed status updates, and manager-only commenting can post through `reopen(reason: ...)`; the normal comment endpoint refuses it.

- **BUG - MEDIUM — Duplicate cascade handoffs.** `projects.ex:update_assignment_status/2` → `Handoffs.wake/3`: parent P has last child C; Bob’s D depends on both. Completing C sends D’s notice through automatic P completion and again through direct C completion.

- **BUG - MEDIUM — Duplicate form notices.** `assignment_form_live.ex:autosave_now/1`: on the first status edit of Bob’s task, `log_typed_changes/3` and `log_edit_once/2` both target Bob, producing “completed/reopened” plus “changed your task.”

- **BUG - MEDIUM — Repeated project-start notices.** `projects.ex:start_project/2`: submit two stale Start dialogs. Both calls announce every ready task because the write does not require `started_at` still to be nil.

- **BUG - MEDIUM — Department recipients omitted.** `people.ex:assignee_user_uuids/1`: Bob belongs to a Production team but has Sales as his primary department. `Assignees.match/2` includes him for Production-department work; notice fanout excludes him.

- **BUG - MEDIUM — Child-task Reopen does nothing.** project_show_live.ex:gated_handle_event/3 and render/1: reopen a completed task inside an expanded sub-project. The handler accepts it, but the dialog searches only `@assignments`, excluding displayed child tasks.

- **BUG - MEDIUM — Inherited hold is invisible.** `project_show_live.ex:task_card/1`: container P depends on A; its in-progress child C has no direct dependency. Reopening A sends C an on-hold notice, but C’s badge checks only direct dependencies.

- **BUG - MEDIUM — Grouping loses task information.** `handoffs.ex:tell/3` stores only the first task and a count. Starting X and Y for Bob leaves Y’s drawer without its handoff; `Notices.text/2` additionally ignores that count for hold/resume notices.

- **BUG - MEDIUM — Task deletion disappears.** activity.ex:with_project_uuid/1: page/API removal logs after deletion, without `project_uuid`. The lookup then fails, so project History cannot find the removal event.

- **BUG - MEDIUM — API waiting changes lose their meaning.** `tasks_controller.ex:do_update/3`: PATCH `waiting_on: "client deposit"` records only changed field names. History says “edited,” without the wait or its eventual clearance.

- **BUG - MEDIUM — Author attribution is lost.** `history.ex:normalize/3`, `name_people/1`: an API comment/note attributed to “Kitchen agent” appears under its accountable human; agent/staff time UUIDs are looked up only as users. Nil actors render without the promised “Someone.”

- **BUG - MEDIUM — Mention duplicates remain.** `comment_notices.ex:recipients/3`: @mention Bob through the comments box. This handler sends a comment notice while core sends its mention ping—the module’s own documentation confirms both.

- **BUG - MEDIUM — Duplicate embedded DOM IDs.** `assignment_form_live.ex:render/1`: open two task drawers containing History. Both accordions use literal `id="assignment-history"`, violating the embedding contract.

- **IMPROVEMENT - MEDIUM — Assignee reads grow per task.** `handoffs.ex:tell/3`: starting 200 ready tasks assigned to Bob performs 200 person queries before grouping. Batch distinct assignees before recipient expansion.

- **BUG - MEDIUM — Preference strings escape gettext.** `phoenix_kit_projects.ex:notification_types/0`: “Your turn” and both new descriptions are plain, unregistered strings, absent from the supplied ET/RU catalogues.

- **NITPICK — Russian agreement.** `notices.ex:text/2` → Russian catalogue produces `«Доставка» выполнено`. Use `задача «%{after}» выполнена` to avoid title-dependent gender. The reviewed new Estonian notice translations are sound.

## Round 4 — the fixes made after the sweep

Read-only review; no files changed and no tests executed.

1. **Who is told.** Ordinary single-event form saves, API transitions, quick-add, typed-card rename/tick, board drag, actor exclusion, and silent `Handoffs.log_auto` rows: **checked, sound**. Exceptions: combined form changes, later autosaves, targeted template rows, and deletion paths below.

2. **Recursion and noise.** Recursion: **checked, sound**. Notice rows have a target and `"notice" => true`; automatic rows have `"auto" => true`. Neither can fan out. Supplied bulk/import paths and `Outline.sync` gain no assignee-notice storm; API batch lines are unassigned. PATCH bookkeeping and batch-read overhead remain below.

3. **PATCH transaction.** Its nesting—`Handoffs.batch` → `PubSub.after_commit` → Outline transactions—is **checked, sound**: returned errors roll back and discard hand-offs; exceptions restore broadcast/status buffers and clear the hand-off batch. Nested rollback poisons the enclosing Ecto transaction, so it cannot later commit successfully. The reverse nesting has a failure below.

4. **Mentions.** Published comments’ normal delivery and subsequent comments-box re-sync: **checked, sound** against the available core implementation. Both use `comment`/`content`; core preserves `notified_at` when rebuilding rows, so re-sync neither clears delivery nor duplicates the ping. Moderated comments remain an exception.

5. **Privacy.** `Notices.notify/3` filters recipients before writing their notice, and assignment mention visibility now delegates correctly: **checked, sound**. Direct targets denied access still receive a generic core notification because decoration preserves `target_uuid`, although the project’s words are withheld. History has the disclosure below.

The remaining findings are:

- **BUG - HIGH** — project_history_live.ex:load/1: Open History as a non-admin member of a private project, remove that membership, then post another comment. The subscribed view reloads and exposes the new words; authorization runs only at mount.

- **BUG - MEDIUM** — notices.ex:with_display/6: Give a template task to another administrator through the form. Its explicit person target bypasses `notify/3`’s template filter and receives “gave you a task”; `may_view?/2` succeeds for that administrator.

- **BUG - MEDIUM** — assignment_form_live.ex:log_typed_changes/3: Alice changes Bob’s task to Carl and `in_progress` in one save. Carl receives both `assignment_started` and `assignment_reassigned`; only the generic update is suppressed. Both save implementations share this helper.

- **BUG - MEDIUM** — Same file, `autosave_now/1` → `log_edit_once/3`: Change status, let it save, then change priority or description during the same visit. `edit_logged?` suppresses the second save’s entire update event, so the assignee receives no notice of that subsequent change.

- **BUG - MEDIUM** — `AssignmentFormLive.handle_event("delete_task", …)` and `OutlineList.handle_event("outline_purge", …)` log removal without calling `Notices.removed/3`. Separately, tasks_controller.ex:delete/2 with `cascade=true` tells only the root’s people; differently assigned deleted descendants receive nothing.

- **BUG - MEDIUM** — Same controller, `do_update/3`: PATCH an assigned task with only `{"parent": "<other-task>"}`, `position`, or `interaction`. With no reassignment, `tell: true` produces “changed your task” for operations the contract explicitly treats as quiet bookkeeping.

- **BUG - MEDIUM** — pub_sub.ex:after_commit/1: Inside `Outline.with_project_lock/2`, call `after_commit/1` to update an assignment, then roll back the outer lock. The inner transaction returns successfully and flushes its broadcasts before the actual commit; subscribers hear a change that rolls back.

- **BUG - MEDIUM** — comment_notices.ex:on_comment_created/3: Enable comment moderation and submit a task comment containing an @mention through the comments box. The pending callback claims nothing, so the box sends core’s mention ping immediately; later approval invokes no creation callback, leaving the task’s other people untold.

- **IMPROVEMENT - MEDIUM** — `TasksController.do_batch/2` → `Notices.tell_assignees/2`: Submit 500 lines. Although these assignments are necessarily unassigned, every activity performs a full `Projects.get_assignment/1` with preloads before discovering that; passing `tell: false` for this batch avoids 500 unnecessary assignment loads.

## Post-merge recheck — 2026-10-25

Reviewed merge `a40f5fd` and Claude's follow-up `549c4e1` on `main`,
including the fixes recorded in `FOLLOW_UP.md`. PR #57 is the only merge
since the previous Codex post-merge pass on #56; #51–#56 already have
their own Codex reviews. This pass concentrates on the merged History,
notice, handoff and transaction paths rather than repeating the design
review above.

### BUG - MEDIUM — History attached recipients to the wrong edit (fixed)

`History.attach_notices/1` found an event by action, task and a two-second
window. Two quick updates to the same task attached both updates' notices
to the newer event, leaving the older event with nobody told. The matcher
also ignored the actor, so one person's notice could be attached to another
person's edit. A notice delivered more than two seconds after its event
remained a duplicate, independent History line. Repeated handovers had the
same defect.

New assignee and handover notices now carry `source_activity_uuid`, the
UUID returned when their original activity row was written. History folds
them by that reference, independent of timing. Older notices retain the
time-based fallback with an additional actor check. If a referenced event
is outside the read cap, its notice remains visible rather than joining an
unrelated event. There is no migration or attempt to reconstruct ambiguous
historical associations.

Regression coverage exercises two rapid edits, delayed delivery, two
handovers, and legacy notices from different actors. Before the fix, the
rapid-edit test failed because the older edit's `told` list was empty.

### IMPROVEMENT - MEDIUM — Claude's scope test did not exercise the leak (fixed)

Claude's production guard correctly rejects a task outside the project.
Its new test supplied a random UUID with no rows, which also returned an
empty history before that guard existed. Added a real foreign task with
activity, a ledger correction, a published comment, a published note and
time. Each source must be present when queried through its own project and
empty when queried through the other project. The original unknown-UUID
check remains useful and is retained.

### Other checks and limits

- Rechecked the notice visibility gate, template suppression, actor
  exclusion and the `notice`/`auto` recursion guards; no additional defect
  established in these paths.
- Rechecked `PubSub.after_commit/1` buffering and the API PATCH's enclosing
  handoff batch and discard path. Its documented outermost-transaction
  requirement remains; this pass does not add a general transaction hook.
- Embeddable History continues to avoid `handle_params/3`, and rechecks
  project access on reload. Viewer time-zone and actor state remain local
  to each page/request process.
- Previously documented per-recipient write reads, grouped handoff limits,
  agent/staff attribution limits and the empty state on a failed History
  read are outside these fixes.

### Validation

- Full PostgreSQL-backed suite: **2163 tests, 0 failures, 1 excluded**.
  The existing builds-alone migration test requires core's
  `TestSupport.ModuleChainCheck`, absent from the locked core version;
  integration tests were enabled.
- New regression tests with the current reader: **5 tests, 0 failures**.
- Read-side negative control: loaded History from `549c4e1^` into a
  separate test VM, without editing the checkout or writing old BEAMs.
  All **5 new tests failed as expected**, reproducing the foreign-task
  exposure and each notice-folding defect. The current reader then passed
  the same five tests again.
- `mix precommit`: **passed** (forced compilation with warnings as errors,
  formatting, unused-lock check, Hex audit, strict Credo and Dialyzer).
  The existing seven Dialyzer suppressions are unchanged.
- Final formatting, warnings-as-errors compilation and `git diff --check`:
  **passed**.

No version bump or release is part of this pass.
