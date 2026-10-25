# A project's history, hand-offs and the notices around them

Status: plan, 2026-10-25. Built from a simulated kitchen order (26 tasks,
nine people, three rework loops) and a panel of codex, grok and zai, which
converged on every point below. The raw answers are not kept in the repo.

## Why

The owner wants to read a project as a story: "the measurer finished, the
designer got told it was his turn, found a mistake, reopened the measuring
with a reason, the measurer was told, fixed it, finished again…". The
simulation showed none of that is visible today:

- the Activity tab lists only project-level rows (it filters on the project's
  uuid; every task row carries the task's uuid);
- finishing a task notifies nobody downstream (`target_uuid` is the changed
  task's own assignee, usually the actor, and core skips self-notices);
- a comment notifies nobody (`"assignment"`, the type task comments use, is
  not even registered with the comments module);
- notifications read "Projects assignment reopened": no who, what or link;
- people show as emails and times as UTC;
- rows the tick rules or a sub-project rollup change write no activity row.

## What is built

1. **Names and times.** `People.display_name/1` / `User.display_name/1`
   wherever an email was printed. `L10n` prints every instant in the
   viewer's zone (`TimeZone.for_viewer/1`, settled once per LiveView next to
   the locale); the Events tab reads typed times in that zone too.
2. **History** (`PhoenixKitProjects.History`): one read model merged at read
   time — the activity rows of the project and of its tasks, the project's and
   tasks' comments, the ledger's time entries — normalised to
   `%{at, kind, actor, task, text, quote, link}`, newest first, paged. Shown
   as a **History** tab on the project (grouped by the viewer's day, one
   sentence per line, comments quoted) and filtered to one task in the task
   drawer. The raw **Activity** page stays in the ⋮ menu as the audit view.
3. **Every status change is a row.** The two places every change already
   passes through — `Projects.broadcast_status_changed/2` (direct and
   rollup) and `Outline.announce_status_change/1` (tick rules) — call
   `Handoffs.status_changed/2`. Rows the caller did not log itself (tick
   rules, rollups) get an `auto` activity row there.
4. **"Your turn"** (`projects.assignment_ready`): when a task's last unmet
   dependency is done — and for tasks with none when the project starts — its
   assignee is told. A container becoming ready also wakes its subtasks that
   have no unmet dependencies of their own. Never inferred from list order.
   Team and department assignees fan out to their people.
5. **"On hold"** (`projects.assignment_on_hold`): an upstream task reopened
   while a downstream one is in progress tells that assignee; the row shows an
   "On hold" badge derived from its unmet dependencies.
6. **Comments notify**: the task's assignee, people @-mentioned, earlier
   commenters on that thread; the project's managers for project comments.
   Never the author.
7. **Reopen asks why.** The Reopen button opens a small dialog; the reason
   becomes the task's comment and the notification quotes it (one notice, not
   a comment notice plus a reopen notice).
8. **Notification text.** Every projects notice carries
   `notification_text` / `_icon` / `_link`, written in the RECIPIENT's
   language (`RecipientLocale`) — core renders module text as stored, so
   each recipient gets their own row.
9. **Waiting on** is its own history line ("Anne is waiting on: the client's
   bank transfer" / "no longer waiting").

## Not built, on purpose (next slices, by the panel's ranking)

- A wait with a due date and a reminder (needs a scheduled job and a column).
- Save a finished project as a template (clone without people's work).
- A client approval step on the portal.
- Structured fields on a task (the measurements) and a required attachment
  on hand-off — comments and the project files carry them for now.
- A durable outbox for notices (codex): notices are written after the commit
  from the process that made the change; a crash between the two loses the
  notice, never the change.
