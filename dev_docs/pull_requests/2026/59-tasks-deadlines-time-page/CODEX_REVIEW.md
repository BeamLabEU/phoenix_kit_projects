# PR #59 — Codex review

Reviewed 2026-10-30 against `5ea8d52`, after merge `c1ed3d8`.
Author: Max Don. Scope: waiting/readiness transitions and their notices,
deadline/real-time fields and API handling, task view/drawer integration,
the rebuilt form, assignee creation/search, Time-page loading and rendering,
migrations, and the affected schedule/list/widget consumers.

## Findings

### BUG - HIGH — Pending staff creation trusted cached assignment rights

`staff_create_confirm` was absent from the form's write-event list, and
`may_assign?/1` used the `can_assign?` and feature values loaded earlier.
Someone whose access was revoked, or whose project's assignment floor was
tightened while confirmation was open, could still create a staff record.
The later autosave's refusal did not undo that independent write.

Fixed: staff creation passes through `WriteGate`, and assignee actions read
the current project's assignment floor and feature flag. Regressions cover
both replacing the live scope and changing the stored assignment floor after
opening the confirmation. Both verify that no person or creation activity
was written.

### BUG - MEDIUM — Stale time corrections could restore an invalid finish

`correct_assignment_times/2` validated the caller's struct. If another
session reopened a completed task, a stale correction could restore
`completed_at` on the now-open task. A concurrent correction of the start
could likewise leave the finish before the stored start.

Fixed: lock and reload the assignment, then validate and update it within
one transaction. Broadcast only on success. Context regressions cover a
reopen and a changed start between reading and correcting the task.

### BUG - MEDIUM — Time-page refreshes introduced queries per project

`TimeLive.load/1` asks `TimeBoard.editable_projects/2` on mounts, broadcasts
and minute ticks. That function mapped projects through authorization and
extension/flag lookups, causing query growth with the number of projects
shown, even for an administrator.

Fixed: batch extension enablement and feature gates, and resolve the user's
project roles once through `Members.accessible_projects/1`. The individual
deadline write still rechecks its current permission. A query-counter test
compares one project with five for a member; a separate test compares the
batch results with individual rules, including open/restricted projects,
disabled tasks/dates, private projects, and templates.

### IMPROVEMENT - MEDIUM — Calendar smoke coverage depended on the month boundary

The calendar fixture started its five-workday schedule today, but its smoke
test expected every task title in the first month's grid. On 2026-10-30 the
second task fell outside that grid, producing an unrelated baseline failure.

Fixed: anchor this fixture on the tenth of the current month, keeping both
tasks in the initial month. Tests specifically covering future schedules
continue to use their own dates.

## Validation

Validation results are recorded in `FOLLOW_UP.md`. No release changes.
