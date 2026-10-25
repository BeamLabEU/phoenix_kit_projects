# Kimi review — History, hand-offs and notices

Reviewer: Moonshot Kimi (K3.1 Pro). Each section is one round, reproduced as answered (local paths removed); how each finding was resolved is in `FOLLOW_UP.md`.


## Round 3 — the final sweep before the PR

• Read-only review; no tests were run.

  ## Part A — checked, sound

  1. `Handoffs.ready?/2`, `clear?/3`, ancestor/held-dependency handling, wake/hold/resume traversal, self-exclusion, and grouping within one `statuses_changed/2` call are sound. Project-start exceptions are below.
  2. Mass-assignment guards remain intact; activity stays at the LiveView layer except the intentional automatic rows. No new `handle_params/3`. Estonian/Russian notice translations read acceptably.
  3. `ProjectHistoryLive.mount/3` and `Notices.may_view?/2` apply the expected view gate. The direct-notice and API-comment exceptions are below.
  4. History’s source merging, day ordering, notice folding, reopen-comment suppression, and recipient/seen joins are sound apart from the findings.
  5. Covered production changes: `phoenix_kit_projects.ex`, `activity.ex`, `actor.ex`, `comment_notices.ex`, `handoffs.ex`, `history.ex`, `notices.ex`, `outline.ex`, `paths.ex`, `people.ex`, `projects.ex`, `history_feed.ex`, `project_history_live.ex`, `project_show_live.ex`. Uncovered changes are listed below.

  ## Part B — missing for furniture orders, ranked

  1. **Reassignment history and old/new-assignee notices** — ownership during supplier, installer, and rework hand-offs must be unambiguous.
  2. **Invoice, payment, and revision events with amounts and task links** — design changes and rework must remain reconcilable with what the client was charged.
  3. **Date/dependency changes with old/new values and downstream warnings** — installation and supplier schedules need impact visibility, not merely current readiness.
  4. **Exact file/design revision links in History and notices** — production and installation must open the drawing version that caused approval or rework.
  5. **A resolvable owner for `waiting_on`, notified on assignment/clearance** — supplier and client blockers need an accountable recipient and an explicit unblock signal.

  ## Findings

  - **BUG - HIGH — Privacy:** `Notices.decorate/2` adds task/project text without `may_view?/2`. Assign a person who cannot open a private project, then log `projects.assignment_created`; they receive its title and link. `Notices.notify/3` is gated, but existing assignment activity is not.

  - **BUG - HIGH — Misleading History:** `History.activity/3` does not exclude or mark `metadata.db_pending`. A failed reopen logged by `Activity.log_failed/2` is rendered by `HistoryFeed.activity_sentence/2` as a successful reopen although the task remains done.

  - **BUG - MEDIUM — Authorization:** `TasksController.post_reason/3` checks `comments:write` scope but not the project’s `:comment` role floor. A member key with status/comments scopes can post a reopen reason where comments are manager-only.

  - **BUG - MEDIUM — Duplicate reopen side effects:** `ProjectShowLive.update_assignment_with_activity/5` ignores whether the database transition actually occurred. Two tabs reopening the same done task with different reasons both log and post; the second stale write changes nothing.

  - **BUG - MEDIUM — Ledger history:** `History` drops every `projects.work_logged` row while reading only current entries. Amend 60 minutes to 30 and History says only “logged 30”; delete the entry and its disappearance leaves no line.

  - **BUG - MEDIUM — Deleted tasks:** `Activity.with_project_uuid/1` looks up the assignment after `delete_assignment/1`, so the removal row lacks `project_uuid` and vanishes from project History. Existing time rows also render an empty live link because `normalize(:time, …)` does not mark the deleted task gone.

  - **BUG - MEDIUM — Repeated project starts:** `Projects.start_project/2` has no transition/idempotence guard. Calling it twice with ready tasks emits a second complete set of `assignment_ready` notices through `Handoffs.project_started/1`.

  - **BUG - MEDIUM — Already-running projects:** Start a project before adding its first no-dependency task, or use ongoing auto-start. `Handoffs.project_started/1` runs before the task exists and no later creation path emits `assignment_ready`; only a generic assignment notice may arrive.

  - **BUG - MEDIUM — Missing/mis-attributed actors:** `HistoryFeed.history_feed/1` suppresses actors for every `auto` row, hiding who triggered a parent tick/rollup. It also renders no “Someone” for nil or deleted-user actors, contrary to the guide.

  - **IMPROVEMENT - MEDIUM — Batching:** `Activity.with_project_uuid/1` performs an assignment SELECT per activity row. The 500-task API batch therefore adds 500 lookups; `Handoffs.tell/3` adds further per-recipient reads.

  - **IMPROVEMENT - MEDIUM — Gettext:** `priv/gettext/default.pot` is absent, so the required code-to-catalog check cannot pass. The new preference labels/descriptions in `PhoenixKitProjects.notification_types/0` are also unregistered and absent from Estonian/Russian catalogs.

  - **IMPROVEMENT - MEDIUM — Test gaps:** No behavioral coverage for non-UTC changes in `l10n.ex`, `helpers.ex`, `member_projects_live.ex`, `project_events_live.ex`, `project_form_live.ex`, `project_whiteboards_live.ex`; API `auth.ex`, `docs.ex`, or reopen `reason`; task-form history/typed logging; `pub_sub.ex` broadcasts; `resource_links.ex` assignment registration; or the gettext manifest addition.

  - **NITPICK:** `AssignmentFormLive` uses the static accordion id `assignment-history`; two embedded task drawers duplicate it despite the namespaced-DOM convention.
