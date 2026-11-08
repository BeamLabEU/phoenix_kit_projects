# Follow-up — full audit of 2026-11-08

How each finding in [`CLAUDE_REVIEW.md`](CLAUDE_REVIEW.md) stands, by its
number. **Fixed** names where, and the test that pins it when there is one;
**Not changed** says why; **Open** is left for later, with what it would take.

## Fixed

1. **V14 replay** — the column add and its backfill run in one `DO` block only
   when `review_status` is absent; the CHECK is added only when absent, by
   `conrelid`. `test/integration/migration_replay_test.exs` replays the chain
   over a held task and an accepted portal request in a named schema (it fails
   on the old code with the check violation).
2. **Open seat** — `Authz.module_reacher?/1`; `effective_role/2` takes a scope or
   a uuid and gives the open seat only to a module-reacher;
   `Members.open_project_uuids/1` the same for both listing functions.
   `members_test.exs` "an everyone project's open seat needs the Projects
   module".
3. **`Health.set/4`** — `jsonb_set` on `settings["health"]` only.
   `project_hub_pages_test.exs` "a stale struct never writes the other settings
   back".
4. **API keys rights** — `put_rights/1` from the live scope, recomputed in
   `phoenix_kit_scope_changed/1` (core calls it on a role change) with a reload.
5. **Shared host topic** — `emit_opened` stamps `user_uuid`; `PopupHostLive`
   drops another viewer's `:opened` (`own_viewer?/2`; an `:opened` without the
   key is the host's own). `popup_host_live_test.exs` "another viewer's click on
   a shared host topic opens nothing here".
6. **Comment floor** — the Comments tab, the task drawer and the task view hand
   the comments component a nil user below `:comment` (read-only thread);
   recomputed on membership and project changes.
7. **`detach_subproject`** — goes through `ProjectMove.run(child, :top, …)`
   (rights and move lock); `move_lock_test.exs` still pins the lock.
8. **Deleting a task over a sub-project** — `Projects.subproject_below?/1`;
   the page and the form refuse with "A sub-project sits under this task…".
   `task_conversion_live_test.exs` "deleting a task with a sub-project under it".
9. **Estimate while typing** — `DurationInput.keep_typed/2` echoes the typed pair
   (params, and out of `changes`, which a form shows first); conversion still
   decides validity and happens on save. `duration_input_test.exs` "while typing,
   the estimate shows what was typed" (fails on the old code).
10. **Prefix-safe guards** — V12 and V21 look the constraint up by
    `conrelid`; `migration_replay_test.exs` replays twice in a named schema;
    `expected_schema_test.exs` no longer needs its `@known_gaps`.
11. **Repeated closure edge** — `dependency_exists?/2` before the insert, both
    in-transaction sites. `closure_pull_test.exs` "diamond with a tail" (fails on
    the old code).
12. **Clone shares one-off tasks** — `clone_task_uuid/1` copies an `ad_hoc` task.
    `projects_context_test.exs` "a one-off task of the template is copied".
13. **Portal file picks** — the report form has `phx-change="report_change"`
    (LiveViewTest cannot drive the browser's file dialog; covered by reading
    LiveView's upload tracking).
14. **Child's `:project_deleted`** — only the tab's own project's leaves; a
    child's reloads. `project_gantt_live_test.exs` "deleting a sub-project
    redraws the timeline".
15. Hours task pick only from the tab's projects, stored as a uuid.
16. Project order is `admin_all`'s: the three events refuse, no drag, the
    multi-only gate. `list_lvs_handlers_test.exs` "the site's order is an
    administrator's".
17. `count_projects(viewer:)`, `assignment_status_counts(viewer:)` on the
    Overview and the Workload widget.
18. "Reorder all" honours the lens (`reorder_all_tasks/2` `:ad_hoc`); one-off
    reordering and dragging on that lens are an administrator's.
19. `@server_owned` dropped from both forms' posts (the template form also
    drops assignees).
20. Both locks are asked of the project as stored now.
21. The template form folds onto `current_record/1`.
22. `validate` prefills only from a task the picker offered, with the library
    flag on.
23. `refresh_project/1` before every save-time gate read.
24. Only from the sub-project form, with `Authz.can_use_templates?/1`.
25. The project page reloads on `:project_members_changed` /
    `:project_grants_changed` (the typed list's rights come with it).
26. `WebHelpers.tab_write?/5` at every write, the flag refreshed on membership
    changes; the new-event form opens only for a writer.
    `project_events_live_test.exs` "a writer whose rights were taken away
    meanwhile writes nothing".
27. API: 503 `module_disabled`; the portal resolves nothing while the module is
    off. `api_test.exs` "the module switched off", `portal_test.exs` "the module
    switched off closes every portal". `DataCase` now switches the module on, as
    `LiveCase` did.
28. Matched and shown by core's display name only.
29. Minutes need `time:write`; a project note's minutes need `project_time`.
    `api_agent_test.exs` "a note's minutes are time".
30. `Ledger.update_time/3`, `update_amount/3`, `delete_entry/2` refuse an
    invoiced entry (`Invoicing.invoiced?/1`, fail-closed); the API answers 409
    `invoiced_entry`. `invoicing_test.exs` "an invoiced entry is never amended".
31. `backfill_done?/1` reads the flag with its own query; unreadable → nothing
    granted; a flag that does not save is said. `permission_subkeys_test.exs` "a
    flag that cannot be read grants nothing".
32. `FOR NO KEY UPDATE` in `Outline.with_project_lock/2`,
    `create_task_with_assignment/3`, `start_project/2` (AGENTS.md and the
    quick-add guide say so).
33. The recompute locks the project row first.
34. A second Start writes nothing and tells nobody; the page logs no second
    start. `projects_context_test.exs` "a second Start leaves the stored start".
35. `Projects.room_for_subproject?/1` in `create_subproject/2` and the
    conversion; `:too_deep` reaches the form's message and the API (409).
36. `Outline.carrying/1` counts `AssignmentFile` rows. `task_files_test.exs`
    "a task with files of its own counts as carrying something".
37. 100 on an open task is `complete_or_ask/3`; a waiting task stays waiting;
    `in_progress` only with the step; `expect:` against a stale row.
    `project_show_schedule_test.exs` (two new tests).
38. The features/modules handler reloads the rows and labels.
39. Inset rows draw no discussion buttons (the thread is the sub-project's).
40. `outline_open` goes through `WebHelpers.navigate_or_open/2`.
41. The deadline popover keeps `open` across patches
    (`JS.ignore_attributes`) and closes on Save/Clear.
42. `hold_saved/2` after the toggles; sub-project rows get their badge and the
    toggle refuses them; `fold_completion/3` builds on the folded settings;
    `novalidate` on both forms; `reset_for_next/1` clears the repeat choice and
    suggestions; the subtask link is a `smart_link` (a frame in a drawer).
43. `PubSub.after_commit/1` around the note's transaction.
44. One transaction under `pg_advisory_xact_lock`; refs failure rolls the
    draft back; total = sum of the lines' cents; translated line text.
45. The caller's metadata kept; the calling key credited.
46. `Notices.line/5` names in `RecipientLocale.for_rendering/1`'s language.
47. `projects.project_completed` / `projects.project_reopened`.
48. `@fx[:lifecycle]` on `:edit`.
49. The no-id mount goes through `refuse/2`.
50. The message follows `board.file_uuid`.
51. `show_header={false}` on the component; `end_label/2` prints the end's date
    when it is another day.
52. A read-only toolbar (lens, search, sort, Columns, view switcher).
    `permission_subkeys_test.exs` "still has the tools to find a task".
53. The key deleted in `on_exit`, `@moduletag :integration`, waits by monitor.
54. `DescriptionEditor.safe_content/1` replaces link/picture addresses outside
    http(s)/mailto/tel/pkfile/relative; entity-spelled schemes lose their
    brackets. `description_editor_test.exs` "never hands the editor a link that
    runs script".
55. A task rename reloads only a page showing that task.
58. `WebHelpers.changeset_error_text/3` + `field_label/1` (core's
    `translate_error/1`); the five ad-hoc helpers use it.
59–63. `ngettext` for every counted message; French form 0 uses `%{count}`;
    the corrections in all seven catalogues; "API keys" in the manifest (the
    merge removed 26 dead msgids); the portal note and invoice text translated;
    "task", not "assignment", in the form's messages and its tab. Every new
    msgid is filled in all seven languages; `mix gettext.extract
    --check-up-to-date` passes.
64. `Widgets.Helpers.project_name/1` / `task_name/1` in every widget; the member
    dashboard reads the localized name and description.
70. README, AGENTS.md, the sub-projects and quick-add guides, `i18n_triage.md`,
    `mix.exs` comments and the moduledocs corrected.
71. `test_helper.exs` loads the support modules with `Code.ensure_loaded!/1`
    (no "redefining module" warnings), runs the entities chain once, and says
    what it does; four vacuous assertions tightened; `authz_test` notes where
    the database-backed proof is.

Partly fixed:

- 33 — the project recompute is locked; `write_rollup`'s re-read of the link
  row under a lock is not done.
- 41 — the deadline popover only; the status and assignee menus close on a
  patch as before (click-and-go menus).
- 42 — the navigate-mode back arrow and the status-fields link still leave
  without the Close question.
- 57 — new refusal tests for the open seat, project reordering, a revoked tab
  writer, the read-only Tasks page and the note minutes; the rest of the
  reviewer's list (Members/Files/Modules/API-keys page refusals, embeds with a
  plain module key) is open.
- 65 — TimeLive uses core's `date_nav`, `nav_tabs`, `select` and toggle
  `checkbox`; the other hand-rolled controls are open.
- 66 — the project timeline, board columns, quick-add and the three lists'
  reorder dialogs; the forms' ids (`assignment-form`, `task-form`, …) are open.
- 67 — catch-alls on the project page, Overview and Files; Gantt and Calendar
  are open.
- 68 — the 422 `idempotency_key_invalid`, the error table's missing codes, the
  author names, `/people` and assignee uuids, the home fallback; storage
  failures still answer `validation_failed`.
- 69 — the Filters button, the whiteboard delete button, the portal alert.
- 78 — the `#` search, the `attr` block, the "Needs:" labels, the API-keys
  path.

## Not changed

- **Notices for members without the module key** (secondary-contexts reviewer):
  by design — members reach their projects on the user dashboard without the
  key, so they are told about them.
- **Frame refs unique per node only** (PLAUSIBLE, cluster): `frame_ref` is an
  integer by contract; the viewer check in 5 already confines a broadcast to
  its viewer's hosts.
- **77 — unused public functions**: public API of a Hex package; removing them
  is for a minor release. `Health.label/1` stays for the same reason.
- `dev_docs/pull_requests/2026/ca85176-release-audit/REPRO_TEST.exs`: a record
  of that audit, which its own FOLLOW_UP explains.

## Open

- 56, 72 — the per-item reads (each needs its batched form and a `batched_*`
  test).
- 73 — settings toggles should send the value they switch to.
- 74 — Hours weeks from core's `week_start_day`.
- 75 — a library task's delete through `delete_assignment/1`; orphan one-off
  tasks; retrying `:serialization_failure`.
- 76 — an index on `metadata->>'project_uuid'` belongs in core's chain.
- The history feed's sentences built from fragments (German word order); one
  msgid per line with placeholders.
- Idempotency rows: a retention purge and a request fingerprint.
- The last-owner race; a comment `parent` from another thread.
- An invoice's text in the billing profile's language.
- Core's Russian/Estonian short month names; `uk` and `zh` catalogues.
- The test log's "Cache settings unavailable" warnings come from core's
  `Cache.put/3` path, which logs without its test-mode check.

## Verification

- `mix precommit`: clean (credo `--strict` no issues; dialyzer passes — one new
  ignore for an opaque-`MapSet` false positive in `Authz.module_reacher?/1`).
- `WITHOUT_STAFF=1 mix compile --warnings-as-errors`: clean.
- The full suite on a scratch database, against the updated lock (core 3.4.0,
  AI 0.29.1, staff 0.11.2, leaf 0.10.1): **2828 tests, 0 failures, none
  excluded** (2803 before the audit; 25 new tests). No "redefining module"
  warnings any more.
