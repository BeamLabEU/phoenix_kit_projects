Everything built on dev.greenoak.ee since the last PR (#48), on top of 0.30.0, ending with the boss's request of 2026-10-14: a simple to-do list you just type into. 57 commits. Each part was reviewed by outside AIs (codex, zai, grok) as it was built, and the whole branch went through a quality sweep before this PR.

**Needs BeamLabEU/phoenix_kit#933 released first.** The Hours page and the task list use four additions to core components (stacked `bar_chart`, a week-stepping `date_nav`, `search_picker`'s `chosen`, `select`'s label), so this branch does not compile against Hex core 2.62.2. Once #933 is out, the core floor in `mix.exs` should go up to that version.

## What is in it

**Tasks under tasks, and a list you type into (chain V23).**
- A task can sit under another task, to any depth, through `parent_uuid`. A trigger keeps the parent in the same project and stops cycles.
- `position` stays one depth-first order per project, so every reader that sorts by it still gets a sensible order.
- Counts and progress count only tasks with nothing under them.
- Ticking a task ticks everything under it. The last subtask ticked ticks its parent (a project setting can turn this off). Reopening a subtask reopens what it sits under. Ticking other people's subtasks asks first.
- The V19 checklist is gone: V23 turns every item into a subtask, and the API's checklist calls are replaced by `parent`, `POST /tasks/{id}/move`, `POST /tasks/batch` and a cascade delete.
- A project with nothing extra switched on shows its list as **one text field** (the `PkpOutline` hook, shipped via `js_sources/0`): a line is a task, Enter adds the next, Tab makes a subtask, pasting a list adds a task per line, and cut-and-paste moves a task with its number and its work.
- A removed line whose task carries something (hours, notes, an owner, dates) is **held** below the list until someone restores or deletes it.
- Richer projects keep the cards, now nested and foldable, with titles typed in place.
- A project picks Automatic, Always text or Always cards, and which features stay off the cards. The add form's Enter now adds the task and starts the next one.
- AGENTS.md has the full account.

**The task form.**
- Saves as it is changed; no Save or Cancel when editing.
- A time and AI-usage box.
- "Waiting on" and "Requested by" fields.
- Discussion and agent notes inside the form.
- Any task can be renamed there.
- A "Sits under" field and a Subtasks box.
- A new permission, "log time for other people".

**Projects.**
- An ongoing status for work that has no end, and a way to end it in the settings.
- A Move dialog: a project out of its parent, or under another one.
- Short names: a key for every project and a ref for every task (`ACME-42`), also usable as `#ACME-42` in text.
- Task start and end dates.
- The projects list gets columns, sorting and filters; key, client, human, AI and total hours.
- The project's key on every sub-page.

**Hours.** The work ledger read back:
- a tab per project and a site-wide page;
- people and AI agents shown apart;
- searched pickers for person, task and project;
- a stacked chart and a weekly timesheet;
- a report;
- `GET /hours`.

**API.** Assignee, dates, refs, subtasks, a briefing that counts subtasks; the guide and OpenAPI are regenerated from `Web.Api.Docs`.

## Migrations

- **V21:** task dates.
- **V22:** project keys and task numbers, both backfilled.
- **V23:** `parent_uuid` with its trigger, `review_status: removed`, task titles up to 500 characters, checklist items converted to subtasks and the column dropped.

The conversion is guarded so a replay of the chain converts and renumbers nothing. On dev.greenoak.ee, 19 checklist items became 19 subtasks.

## Verification

- `mix precommit` clean: format, compile --warnings-as-errors, deps.unlock --check-unused, hex.audit, credo --strict, dialyzer.
- **1985 tests, 0 failures** on the rebased branch.
- New tests: `outline_test.exs` (sync: new lines, renames, held and revived tasks, a task the browser never knew of, malformed lines; the tick rules; moves; cascade delete; the form's status path), `web/outline_list_test.exs` (text face, cards, board, settings, the form's Subtasks box), `outline_counts_test.exs`, `web/api_subtasks_test.exs`.
- The typed list's browser code was driven in headless Chromium against a stub server: typing, Enter, Tab, splitting a title, paste with indents and ticks, ticking, cut-and-paste keeping ids, undo, and typing over a selection that spans lines.
- Reviews: zai on the repo with six numbered questions, the sweep's three re-validation reviewers, and my own pass. Every finding is fixed or answered in this PR's review folder (`FOLLOW_UP.md`).
- Codex could not connect tonight; grok's review had not answered when this PR was opened.

## Test plan

- [x] `mix precommit`
- [x] Full suite on the rebased branch (1985 / 0)
- [x] V23 migration on dev's real data
- [x] Hook driven in a headless browser
- [ ] Max: click through the typed list and the cards on dev.greenoak.ee (the extension was not connected for a logged-in browser check)

No version bump, no CHANGELOG entry (the release commit's).
