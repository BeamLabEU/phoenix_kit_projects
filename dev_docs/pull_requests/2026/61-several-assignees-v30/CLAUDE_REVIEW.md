# PR #61 — several assignees on projects, sub-projects and library tasks (V30): review record

**Author:** Timujeen and Max Don
**Reviewer:** Claude (Opus 5.5), 2026-11-05, against HEAD `1409276` (#61 plus a `mix.lock` bump)
**Method:** read `AssigneeSet`, the V30 migration, the context, API and form diffs (the 49-file diff without
the `.po` files), then audited every remaining direct reader of the mirror columns and every path that copies
a set. Each finding was reproduced before it was fixed.
**Verdict:** one CRITICAL and one MEDIUM bug fixed, one IMPROVEMENT made. The design holds: nothing that copies
or reads a set was found still working from the one-assignee mirror.

## Findings

- **BUG - CRITICAL: `main` did not compile.** `5569029` added `@typep record` to `AssigneeSet`, and `record/0`
  is a built-in type on OTP 29: the only change to `erl_internal:is_type/2` between 28.5.0.8 and 29.0 is the
  line `is_type(record, 0) -> true;`. `.tool-versions` pins `erlang 29.0`, so `mix compile` stopped with
  "type record/0 is a built-in type and it cannot be redefined". OTP 28.4.1 and 28.5.0.8 answer `false`, which
  is how it could build elsewhere. → **Fixed** (`5da158b`): renamed to `holder_record` (`holder` was taken).
  No test: the compile is the check.
- **BUG - MEDIUM: `GET /project` named every assignee `null`.** `Json.project/1` is handed a project with no
  rows loaded, so `Assignee.list_json/1` fell back to `AssigneeSet.preload/1`, whose rows carry only uuids.
  The same went for `/me` and the answers of `POST /subprojects` and `POST /project/status`. PR's own test is named
  "…and names them all" but asserts only the uuids. → **Fixed** (`3466c40`): `AssigneeSet.preload_named/1` reads
  the rows through `link_query/1`, and `Json.project/1` loads the set once for both of its fields. Test:
  `task_assignee_api_test.exs`, "GET /project names the project's assignees (V30)"; it answered
  `[nil, nil, nil]` with the fix taken out.
- **IMPROVEMENT - MEDIUM: the briefing read per row.** PR batched `assigned_to_me`'s count but left
  `assigned_to?/2` on each listed row, a read per sub-project row. → **Fixed** (`3466c40`): one
  `held_keys_by/1` feeds both, and the single-row `held_keys/1` is gone. Existing test: "the filter and the
  briefing find a sub-project by its child's people". No query-count test: the briefing has per-row reads on
  purpose (see "Not done: a batched latest note per task" in `AGENTS.md`).
- **NITPICK: `prefill_from_template/3` still derives `assign_type` from the mirror.** With several defaults it
  keeps the previous value. Harmless: `clear_other_assignees/2` ignores it whenever `assignees` is posted,
  which the picker does. Left.
- **NITPICK: `default.pot` has drifted.** `mix gettext.extract --check-up-to-date` fails, on line references
  and 14 msgids the code no longer uses. Nothing is missing: no msgid was added, and #61's new strings are
  translated in all seven locales. Left for the next extract; it is 3,290 lines of churn.

## Checked and sound

- **Every copy of a set carries the whole set:** a template clone (project and task rows), a library task's
  defaults (`create_assignment_from_template`, the form's prefill and closure), `Repeats`, `TaskConversion`
  both ways, and a new library task made from a task.
- **The mirror's remaining readers:** `Handoffs` only as a fallback; `TimeBoard` loads `assignee_links`;
  `Authz`'s leftover map clause is not reached by any `:update_status` or `:log_time` caller, all of which pass
  an `Assignment` or nothing.
- **The V30 backfill loses nobody:** a holder's single-assignee CHECK means at most one column was ever set.
- **The project popup's files:** `remove_project_file` and the upload each re-ask `project_files_allowed?/1` of
  the project as stored now, and `Attachments.remove_file/3` detaches only from that project's folder.
- **A forged set:** `vet_posted/2`, `strip_gated_project_attrs/2` and the API's `exists?/2` all hold.
- **Hot paths:** `ListMetrics` and `Assignees.faces/2` stay batched.

## Not verified

No browser pass: the picker, the popup's upload and the cards were read and tested through `LiveViewTest` only.
