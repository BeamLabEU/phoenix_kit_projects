# PR #59 — waiting tasks, deadlines, real times, the task view and the Time page: review record

**Author:** Max Don (with Claude)
**Reviewer:** Claude (Opus 5.5), 2026-11-02/03, against HEAD `5a58c7f` (after #60 merged on top)
**Method:** the diff split into seven slices (assignees, status flows, files and rich text, the task form and view,
the project page and drawer, project forms and features, time and calendars), each read by a separate
reviewer. Every finding below was checked against the code before anything was changed. Most #59 code was
reworked again by #60, so findings are filed by the PR that introduced them. #60's are in
`../60-boss-review-lists/CLAUDE_REVIEW.md`, and that file also lists the older bugs found along the way.
Codex's four findings (`CODEX_REVIEW.md`) were already fixed and are not repeated here.
**Verdict:** two HIGH and three MEDIUM bugs fixed, each with a test that fails when the fix is reverted. The rest
are recorded below, each with the reason it was left.

## Findings

- **BUG - HIGH: rights in a parent project wrote to a sub-project's tasks.** `ProjectShowLive.child_task_allowed?/5`
  compared the raw client string with the uuids on the page, and a string that matched neither skipped the check.
  The handlers then resolved the same string through `scoped_assignment/2` → `Projects.get_assignment/1`, which
  also accepts a task ref (`CKEY-3`), an upper-case uuid or a padded one. So someone with `:delete_tasks`
  in the parent and no role in the child could expand the child and delete, complete or start its tasks by
  sending another spelling of the uuid. The same gap had three more forms. `save_duration` wrote to the
  server-held `editing_duration_uuid` while the check read `params["uuid"]`. `detach_subproject` was not in
  the child check at all. `save_work_entry` judged `:log_time` by the parent's floors (that one predates #59).
  → **Fixed:** `authorized_handle_event/3` turns the record param into the uuid the handler will act on
  (`canonical_record/3`, with the same resolver the handlers use) before either check. `save_duration`'s record
  is the row the page holds open. `detach_subproject` joins `@record_param_events`. `save_work_entry` asks the
  record's own project (`record_project/2`). Test: `hub_permission_enforcement_test.exs`, "another spelling of the
  child's task…" (upper-case, padded and ref spellings).
- **BUG - HIGH: the assignee picker listed every account on the site, with its email, to any project viewer.**
  `assignee_search` (added in #59) and, since #60, `assignee_browse` / `assignee_query` / `assignee_more` never
  asked `picker_allowed?/1`. Only picks were gated. A viewer whose floor kept them from assigning could still
  page through all staff and all non-staff accounts by sending the events, and `assignee_search` took any
  `limit`. → **Fixed:** the four listing events go through one gated clause (`list_event/3` behind
  `mod.picker_allowed?/1`, the right as it is now). The home lists are not read for someone who may not assign.
  `limit` is capped at 50 and safe for any type. Test: `assignee_picker_test.exs`, "who the lists are read for".
  **Still open, needs a decision:** someone who MAY assign (the default floor is `:viewer`) still sees every
  active account without a staff record, each with its email. Narrowing the offer (for example to accounts
  holding `projects`, which are the only ones who could open the task) changes who can be assigned, so it is
  left to the maintainer.
- **BUG - MEDIUM: one viewer's click in the task view ran on every page listening to the host topic.**
  `WebHelpers.emit_intent/3` broadcast `%{event, uuid}`, and every embedded `ProjectShowLive` on the host's
  `pubsub_topic` ran it under its own scope. The documented host pattern is one topic per record
  (`host:orders:<id>`), shared by everyone who has the order open. So A's Start could land as B's
  `started_by`, and A's Done could open the next-up dialog on B's screen. → **Fixed:** the intent carries
  `user_uuid` (the emitting viewer), and a page runs only its own viewer's. Test:
  `assignment_view_live_test.exs`, "a step another viewer's drawer asked for is not run here". The same-user
  case is left as is: a parent page and its sub-project's page for one person on one topic both hear the
  intent, the row's stale-status guard lets one write through, and the other shows a stale-data flash.
- **BUG - MEDIUM: the Time page planned a weekend-counting task about three times too long.** `base_line/3`
  took `ScheduleLayout.assignment_hours/2`, which converts with the calendar map when weekends count (a day
  is 24 h), and `walk_back/3` then spent those hours through 9-hour work days. A "2 days" task planned back
  from Friday 17:00 covered six days. → **Fixed:** the walk spends the estimate in work hours (`work_hours/1`,
  `Task.to_hours(_, _, false)`), and weekends still decide which days count. Test: `time_board_test.exs`, "a task
  that counts weekends plans its days as work days…".
- **BUG - MEDIUM: with one assignee, other people's logged time sat on the assignee's row.** The
  `{[person], []}` clause put every entry on that person's line, while two or more assignees gave each worker
  their own. So the same entries were attributed differently depending on the head count. → **Fixed:** one
  assignee goes through `shared_lines/6` like several. Test: `time_board_test.exs`, "time someone else logged on
  a person's task is on their own row".
- **NITPICK: the Time page's week always started on Monday.** → **Fixed:** core's `week_start_day`, read once at
  mount (`CalendarDisplay.read/0`). Test: `time_live_test.exs`, "the week starts on the site's first weekday…".
- **BUG - MEDIUM (not fixed): a multi-day plan is one segment on the Time page.** `planned_window/4` returns
  `{start_date start_time, end_date end_time}` as a single span. A Monday–Friday task with no times then widens
  Wednesday's day view to 24 h and draws the plan across the nights. The Calendar meanwhile shows a block
  each day, so the two pages disagree. Left: the fix is one segment per planned day (skipping days off), which
  changes how the page lays out lanes and needs a look in a browser.
- **IMPROVEMENT - MEDIUM (recorded): the Time page reloads everything once a minute per viewer, and on every
  site-wide broadcast.** It runs about twenty reads per tick. Written into AGENTS.md's "What this module does
  NOT do", next to the Overview's. The tick could recompute the live bars in memory instead.
- **IMPROVEMENT - MEDIUM (recorded): deadline readers ignore the `dates` flag.** The project page hides the chip
  and `TimeBoard.may_edit?` refuses writes when Dates is off, but the Time page, the calendars and the list's
  overdue count still read a stored deadline. So a project with Dates off can show a task overdue every day,
  with no way to clear it. Whether switching Dates off should hide stored deadlines or clear them is a product
  call.
- **NITPICK (pre-existing, recorded): the API compares a team's or department's uuid case-sensitively, and
  reads every team for each entry.** It does that in `Web.Api.Assignee.exists?/2`.

## Validation

See `../60-boss-review-lists/CLAUDE_REVIEW.md` → Validation (one run covers both PRs).
