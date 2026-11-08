# Full audit — findings (Claude, 2026-11-08)

Whole-module audit at `17f47c5` (0.33.1); see [`README.md`](README.md) for how
it was run. Line numbers are as found at that commit. Each finding was checked
against the code; the few marked PLAUSIBLE were not traced end to end. What was
done about each is in [`FOLLOW_UP.md`](FOLLOW_UP.md), under the same numbers.

## BUG - CRITICAL

1. **Replaying V14 fails the next upgrade and re-queues accepted portal tasks.**
   `migrations/schema.ex:1026-1052`. `up/1` replays every version on each bump;
   V14 drops and re-adds `review_status_check` without V23's `removed`
   (validated against every row: any held task fails the migration) and re-runs
   `SET review_status = 'pending' WHERE source = 'portal' AND public = false AND
   status = 'todo'`, sending accepted requests back to review.

## BUG - HIGH

2. **An "everyone" project's viewer seat goes to every account.**
   `authz.ex:457`, `members.ex:87-97,179-189`. No `projects` permission check; via
   `/dashboard/projects?open=` any signed-in account (a shop customer) opens the
   project and, under the open default floors, edits its tasks. The UI promises
   "anyone with access to the Projects module".
3. **`Health.set/4` writes the whole `settings` map from a stale struct.**
   `health.ex:58`. A page mounted before an owner made the project private or
   tightened a floor puts the old visibility/floors/features back.
4. **API keys page keeps its rights from mount.** `api_keys_live.ex:58-63`. A
   revoked `api_keys_manage` keeps minting shared manager keys and rotating
   anyone's.
5. **A shared host topic opens one viewer's drawer on every viewer's page.**
   `popup_host_live.ex:335-371`. An `:opened` with `frame_ref: nil` is accepted
   by every host whose stack is empty.
6. **The project's "who may comment" floor is not enforced on the web.**
   `project_show_live.ex:7064, 7463`; `assignment_view_live.ex:626-654`. The API
   enforces `:comment`; the comment boxes do not.
7. **`detach_subproject` skips the move's owner check.**
   `project_show_live.ex:3703-3717`. `:edit_tasks` on the parent (viewer floor)
   took any sub-project out; `ProjectMove.run/4` needs `:edit_settings`.
8. **Deleting a task deletes the sub-projects under it.**
   `assignment_form_live.ex:1953-1981` (and the page's delete). The question says
   "and its 1 subtask"; the whole child project goes.
9. **Typing an estimate rewrites it: "1.5 hours" saves as 2 minutes.**
   `duration_input.ex:116-134`; `assignment_form_live.ex:1691`;
   `task_form_live.ex:401`. Conversion on `validate` redraws the unit select
   as minutes under the focused amount.
10. **V12's and V21's constraint guards are not prefix-safe.**
    `schema.ex:2350-2363` (`current_schema()`), `:1959-1971` (`conname` alone):
    every replay on a named-schema install fails with `duplicate_object`, or
    skips the constraint.
11. **Adding a task with its library dependencies aborts on a repeated edge.**
    `projects.ex:4320-4371`, `:847-857`. A unique violation inside the
    serializable transaction poisons it; the next statement crashes the form.
12. **Cloning a template shares its one-off tasks.** `projects.ex:2629-2645`.
    Renaming a cloned task renames it in the template and every other clone.
13. **Portal screenshots picked with the file dialog are dropped.**
    `portal_live.ex:434,464-476`. No `phx-change`, so LiveView never tracks the
    picked file.
14. **Deleting a sub-project throws the parent's page out.**
    `project_gantt_live.ex:172`, `project_calendar_live.ex:275`. The tabs listen
    on the child's topic and take its `:project_deleted` as their own.

## BUG - MEDIUM

Permissions and leaks:

15. Hours tab shows any task's title by ref (`project_hours_live.ex:568, 293`).
16. Reordering projects has no permission check; "Reorder all" rewrites every
    project's position (`projects_live.ex:679-777`).
17. Overview tiles and the Workload widget count the whole site
    (`overview_live.ex:216,226`; `workload_widget.ex:41`).
18. "Reorder all" on the One-off lens reorders the whole library
    (`tasks_live.ex:437-447`).
19. The project form posts server-owned fields (`is_template`, the lifecycle
    stamps) through; the template form too, plus unvetted assignees
    (`project_form_live.ex:1059`, `template_form_live.ex:258`).
20. The status-source lock is checked against the mount-time project (project
    form, sub-project editor) (`project_form_live.ex:1057`,
    `assignment_form_live.ex:2939`).
21. The template form writes its mount-time settings back
    (`template_form_live.ex:262`).
22. The task form's `validate` prefills from any posted `task_uuid` — a private
    project's one-off task (`assignment_form_live.ex:2086`).
23. Save-time gate re-reads use the mount-time project struct
    (`assignment_form_live.ex:2175` and others).
24. "Generate default" statuses mints a site-wide list on task rights
    (`assignment_form_live.ex:2417`).
25. The typed list's rights are not refreshed when membership changes
    (`outline_list.ex:128`).
26. Events and Whiteboards keep `can_write` from the tab's mount
    (`project_events_live.ex:48`, `project_whiteboards_live.ex:74`); a viewer
    gets the New event form by clicking a day.
27. Switching Projects off does not stop the API or the portal
    (`api/auth.ex:39`, `portal.ex:192`).
28. The portal's `@` typeahead harvests commenters' emails (`portal.ex:540-582`).
29. A note's `usage.minutes` writes time without `time:write`, and skips
    `project_time` (`notes_controller.ex:84`).
30. Invoiced ledger entries can be amended or deleted over the API
    (`ledger.ex:297-418`; `invoicing.ex:79` fails open).
31. A failed read of a backfill flag re-grants revoked sub-keys
    (`phoenix_kit_projects.ex:355`).

Correctness:

32. Deadlock between the project-row `FOR UPDATE` and the numbering trigger's
    foreign-key check (`outline.ex:530`, `projects.ex:3476`).
33. Completion recompute is unlocked read-modify-write: two last ticks complete
    the project twice (`projects.ex:2848-2868`).
34. A second Start overwrites `started_at` (`projects.ex:2772`).
35. The eight-level nesting limit is bypassed (`task_conversion.ex:108`
    compares with 32; `create_subproject/2` checks nothing).
36. The typed list deletes a task with files of its own (`outline.ex:1067`).
37. The progress slider changes status past the step rules — releases a waiting
    task, ticks subtasks unasked, overwrites a stale row
    (`project_show_live.ex:4791-4848`).
38. Toggling a feature leaves the cards/list style/labels stale
    (`project_show_live.ex:651-708`).
39. Comment buttons on an expanded sub-project's tasks do nothing
    (`project_show_live.ex:6600`).
40. Ctrl+Enter in a card title navigates the host away in an embed
    (`outline_list.ex:595`).
41. The deadline popover snaps shut on every patch (`project_show_live.ex:2460`).
42. Task form: toggles reload the raw record (next Save rewrites the words);
    sub-project rows get a Done checkbox; the sub-project editor drops the
    status-title choice; native validation blocks Save on a hidden tab; "Add &
    next" carries the repeat rule; the subtask link navigates the host away.
43. `TaskNotes.create` broadcasts before its transaction commits
    (`task_notes.ex:426`).
44. `Invoicing.generate_draft/2` can bill twice and is not atomic; its totals
    and line text are off (`invoicing.ex:125-310`).
45. Labels made over the API lose their `via: api` metadata and credit the
    wrong key (`labels.ex:165`, `tasks_controller.ex:683`).
46. Notices name the task and project in the sender's language
    (`notices.ex:240-249`).
47. Ending/reopening ongoing work logs action names History does not know
    (`project_form_live.ex:4023`).
48. The edit form shows Start mode/date with the lifecycle flag off
    (`project_form_live.ex:3275`).
49. The Modules page crashes when embedded without an `"id"`
    (`project_modules_live.ex:94`).
50. The whiteboard delete dialog promises the drawing is kept
    (`project_whiteboards_live.ex:369`).
51. The Events tab has two month navigators that drift apart
    (`project_events_live.ex:464-498`); multi-day timed events show the end time
    only.
52. The Tasks page without `manage_library` has no search, lens, Columns or view
    switcher (`tasks_live.ex:774-868`).
53. `idempotency_liveness_test.exs` leaks a key per run and is untagged
    (hard-fails without a database).
54. PLAUSIBLE: `javascript:` links reach the description editor
    (`description_editor.ex:137`).

## IMPROVEMENT - HIGH

55. Any task rename anywhere reloads every open project page
    (`project_show_live.ex:278, 610`).
56. Per-project reads on the Hours page on every load and every `:work_logged`
    (`project_hours_live.ex:377-402`; also `api_keys_live.ex:217, 292`).
57. Permission-dependent behaviour is mostly tested as admin.

## IMPROVEMENT - MEDIUM

58. Save-error flashes show raw Ecto templates (`%{count}`) and English field
    names (project, task, assignment forms; API keys page; project page).
59. Missing plurals ("(s)", "1 tasks", "+N more" never translated — its
    catalogue entry is plural).
60. French plural form 0 hard-codes "1" ("1 ligne" for an empty history).
61. Translation quality: German "Sie" in a "du" catalogue; "Teilaufgabe" vs
    "Unteraufgabe"; "Open their page" plural; "Ongoing" = "Running" in es/pl/it;
    "Workflow Statuses" singular; "default assignee" as "recipient"; Italian and
    Polish slips.
62. "API keys" tab label missing from the gettext manifest; 14 dead msgids.
63. Untranslated: the portal's comment-access note, the invoice line text, the
    "Edit Assignment"/"Assignment updated." wording (the UI says "task").
64. Primary-language names in widgets, the member dashboard.
65. Hand-rolled controls where core has components (TimeLive's date nav, select,
    toggle, tabs; and many others).
66. Static DOM ids in embeddable pages (project timeline, board columns,
    quick-add, the three lists' reorder dialogs, the forms).
67. Unknown events crash the project page, Overview, Files, Gantt, Calendar.
68. API: `Idempotency-Key` over 128 bytes silently ignored; error table missing
    codes; `validation_failed` for store failures with `inspect`; author emails
    on comments and notes; `/people?q[x]=1` 500; uppercase uuids "No team";
    home fallback to an empty grant.
69. Accessibility: icon-only buttons and unlabeled inputs (several pages), the
    outline's keyboard model, the portal alert.
70. Stale docs: README (single assignee, five tables, old arities), AGENTS.md
    (`ApiKeys.move/3`, `recent_for_project/3`, gettext note), the sub-projects
    guide's assignee section, `mix.exs` dependency comments, moduledocs
    (Ledger "append-only", `project_by_ref`, `sync_project_rollup`, "core-owned"
    staff tables), `i18n_triage.md`.
71. Test hygiene: `test_helper.exs` re-requires compiled support files ("redefining
    module" warnings), runs the entities chain twice, has a stale header;
    vacuous assertions; `authz_test` passes on failed DB reads.
72. Further reads per row or per item (mentions per row, the assignment form's
    per-render reads and unused option lists, notices fan-out, ListMetrics
    `:parents`, the project form's staff directory, portal visitor reloads,
    ProjectApiLive, ProjectMove targets, the completion recompute's preloads,
    the exponential closure tree).
73. Settings-page toggles flip the page's copy rather than set a value.
74. Hours weeks always start on Monday.
75. Deleting a library task relies on the database cascade; a deleted one-off
    row leaves its Task behind; serialization failures are not retried.
76. History reads activity with a predicate no index serves (core's table).

## NITPICK

77. Dead public functions (`Projects.assignment_by_ref/1`,
    `AssigneeSet.none_exists/0`, `Assignees.recent_for_project/3`,
    `recent_picks_key/0`, `Refs.key_length/0`, `Ledger.totals_for_branches/1`,
    `time_for_assignments/1`, `Paths.project_hours/1`,
    `Statuses.recement_project_statuses/1`, `set_status_entity/3`,
    `Health.label/1`).
78. Smaller items: last-owner check-then-act; a comment `parent` from another
    thread; `#` task search offers pending rows; `Grants.grant/5` doc; misplaced
    `attr` block in the project form; "Needs: <raw flag keys>"; a hardcoded
    API-keys path; CSV `defuse/1` misses a leading `\r`; inline `onclick`.
