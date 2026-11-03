# PR #60 — the boss's three review lists (statuses, popups, several assignees, history, task page): review record

**Author:** Max Don (with Claude)
**Reviewer:** Claude (Opus 5.5), 2026-11-02/03, against HEAD `5a58c7f` (#60 plus a `mix.lock` bump)
**Method:** about 56k added lines over 197 files. The diff was split into seven slices (assignees, status flows,
files and rich text, the task form and view, the project page and drawer, project forms and features, time
and calendars), each read by a separate reviewer. Every finding was checked against the code before
anything was changed, and every fix has a test that fails when the fix is reverted, except where marked.
#59's findings are in `../59-tasks-deadlines-time-page/CLAUDE_REVIEW.md`. Older bugs found on the way, in
code that #60 reworked, are at the end.
**Verdict:** one CRITICAL, three HIGH and fourteen MEDIUM bugs fixed. Three older HIGH/MEDIUM bugs were fixed too.
The rest are recorded, each with the reason it was left.

## Findings

- **BUG - CRITICAL: stored XSS in every description editor.** Leaf 0.8 renders the markdown it is handed with
  `MDEx.to_html(…, render: [unsafe: true])` and no allow-list, into a contenteditable via `raw/1`, and
  `DescriptionEditor` passed it the stored description as written. Raw HTML reaches a description from the
  public portal (a submission becomes the one-off task's text), from any API key with `tasks:write`, or from a
  hand-made form post. So `<img src=x onerror=…>` ran in the session of whoever opened the task, project,
  template or library form, an admin included. → **Fixed:** `DescriptionEditor.safe_content/1`, applied in the
  component and in the form's `set_content` push. It detects raw HTML with MDEx's own parser (the engine and
  options Leaf renders with, so code spans and fences are judged exactly as Leaf judges them) and then shows
  every tag's `<` as `&lt;`, keeping only the bare `<sub>`/`<sup>`/`<u>`/`<br>` Leaf writes itself. A text
  with no raw HTML is passed through untouched. Tests: `description_editor_test.exs`, "the editor never
  renders raw HTML": a stored `<img onerror>` in the task form, an unclosed `<div` line, escaped backticks,
  and code left alone.
- **BUG - HIGH: the sub-project short editor wrote the whole project changeset with the parent's `:edit_tasks`.**
  `save_subproject` passed the posted `subproject[…]` map to `Projects.update_project/2`, and the project changeset
  casts `archived_at`, `is_template`, `key`, `started_at`, `external_url`. Any viewer of the parent (the default
  floor) could archive a child they may only view, flip it into a template, re-key it, or stamp its start. It
  also never asked `:assign_tasks`, and `subproject[preset]` reached `create_project`'s preset handling.
  → **Fixed:** the editor writes only the fields it draws (`@subproject_fields`), re-reads `:assign_tasks` at
  save, and folds `settings` onto the child as stored now rather than the mount-time copy. Tests:
  `form_owned_fields_test.exs`, "the sub-project short editor".
- **BUG - HIGH: choosing or removing the cover wrote back the whole `settings` map read at mount.** `put_cover/2`
  replaced the JSONB column, so a feature, access floor, visibility or completion change made since (in the
  same page's Modules card, say) was silently undone. That is the lost update `Features.set_flags` and
  `Authz.set_overrides` already avoid with `jsonb_set`. → **Fixed:** `Projects.set_cover/2` writes the one key
  atomically. Test: `write_gate_test.exs`, "the cover is its own key…".
- **BUG - HIGH (functional): a description's pictures were invisible to every member but the uploader and an
  Owner/Admin.** They are stored in Media, where core lets only those read, and `InlineImages` asked the
  reader's own storage right. The task's Files list showed the same file to everyone, because it signs without
  a reader check. → **Fixed:** resolution by the text's holder (`holder:` on `InlineImages.resolve/3` /
  `urls_for/3`, `RichText`'s `holder` attr, every editor and render site). A file the project holds (any of
  its tasks' own files, so a repeat's copied text still shows them, or a file in the project's folder), or
  for a library task a file in the task library's folder, is signed for whoever may read the text, while it
  is in Media. A file moved into a library keeps that library's rule, and anything else needs the reader's
  own right. Tests: `api_description_images_test.exs`, "a picture the project holds in Media reaches every
  reader…" (and a foreign file is still refused).
- **BUG - MEDIUM: the API signed any file the shared key's minter could read.** `Json.viewer/0` built the
  minter's scope for a shared key, and references were resolved with no check that the file was the
  project's. A key an admin made for a contractor's agent could mint a fresh URL for any file on the site whose
  uuid the holder knew. → **Fixed:** a shared key acts for nobody (no storage rights of its own). It gets the
  project's pictures through the holder rule, and public ones. Test: "a shared key is not handed its minter's
  storage rights".
- **BUG - MEDIUM: a description's markup could cover the page.** `RichText` kept MDEx's default allow-list, which
  allows `style` and `class` on `span`/`code`/`pre` and `class` on `div`. A `position:fixed` box (or the
  host's `fixed inset-0` classes) drew over every row of the task list. → **Fixed:** both attributes come off
  those four tags. Test: "a writer's style or class cannot pin a box over the page".
- **BUG - MEDIUM: pictures and the cover were stored without the form's write right.** A paste is a
  `handle_info` and an upload's progress a callback, so neither reached the `WriteGate` hook. The project,
  template, library-task and sub-project forms stored files for a user whose right was revoked mid-edit. The
  sub-project editor stored them into the child's folder with only the parent's `:edit_tasks`. `remove_cover`
  was not in `write_events/0`. → **Fixed:** `DescriptionImages.allow/3` takes each form's save rule and asks
  it before every store (the sub-project editor also asks `:upload_files` on the child). `cover_progress`
  asks `WriteGate.allowed?/1`, and `remove_cover` joins `write_events/0`. Tests: `write_gate_test.exs`.
- **BUG - MEDIUM: finishing a repeating task from the form completed the project while the next one was open.**
  `update_assignment_form/3` decides completion inside the hand-off batch, and `Repeats.next/2` makes the
  occurrence only when the batch ends. → **Fixed:** `Repeats.announce/3` recomputes the project's completion
  after the occurrence is made. Test: `repeats_test.exs`, "finished through the form…".
- **BUG - MEDIUM: releasing a sub-project's row told nobody, though the dialog listed who would be told.**
  `Handoffs.load/1` read the link row's own (empty) assignee set, while the dialog named the child project's
  assignee. → **Fixed:** a row with no assignees of its own takes the child's. Test: `handoffs_test.exs`, "a
  sub-project's row tells the sub-project's assignee".
- **BUG - MEDIUM: the sub-project "next up" dialog showed the parent's tasks to someone who cannot open the
  parent.** → **Fixed:** offered only with `:view` on that project. Test: `subproject_next_up_test.exs`.
- **BUG - MEDIUM: repeating deadlines moved in UTC, not on the wall clock.** "Every Friday 17:00" in Tallinn
  came back at 16:00 after the clocks changed. A month rule took its anchor day from the UTC date, a day
  early in western zones. → **Fixed:** `Repeats.shift/2` moves the wall clock in the finisher's zone (`L10n`'s;
  UTC where a process has none, as before), and `anchored/2` takes the local day. Tests: "on the finisher's
  wall clock".
- **BUG - MEDIUM: the project Calendar's today, snap-to-today and Week/Day now line were UTC**, while its
  deadline markers and timed events are in the viewer's zone. → **Fixed:** both come from `L10n`. No test: this
  suite's fixtures cannot give the viewer a zone other than UTC.
- **BUG - MEDIUM: typing a time with another script's digits crashed the form.** `TimeInput.parse_clock/1`
  matched `\d` under `/u` (full-width `１７` from a CJK input method), and `String.to_integer/1` raised. A crafted
  nested part crashed `fold/1` too. → **Fixed:** `[0-9]`, and posted parts read as text only. Tests:
  `time_input_test.exs`.
- **BUG - MEDIUM: the project page called `PhoenixKitStaff.Paths` directly.** That breaks the People doorway
  and the `WITHOUT_STAFF=1` compile gate, and shows dead links while staff is off. → **Fixed:**
  `People.staff_page_path/2` (guarded `apply/3`, nil while staff is unavailable), and the name renders without
  a link. Tests: `project_show_boss_review_test.exs`.
- **BUG - MEDIUM: two saves replacing a task's assignees at once could interleave** (a union of both sets, or a
  pair-index error). → **Fixed:** `AssigneeSet.write_rows/3` locks the task row first. No test: a
  two-transaction race does not fit the sandboxed suite.
- **BUG - MEDIUM: a trashed person could be ticked, and a forged `kind:uuid` crashed a new task's save.** →
  **Fixed:** new picks go through `Assignees.describe_pick/2` (no trashed person), and the save takes the
  picker's server-held list, not the posted copy. Test: "a trashed person cannot be ticked, nor a forged one
  saved".
- **BUG - MEDIUM: the New project form ignored the site's feature defaults.** Boxes started at the catalog
  default and were pinned against it, so with the site's `project_time` on, switching it off on the form was
  not pinned and the project inherited "on". → **Fixed:** seeded and pinned against
  `Features.site_default_values/0`. Test: `project_form_creation_test.exs`, "a site default is what a box starts
  at…".
- **IMPROVEMENT - MEDIUM: a picture in a task row's description read Files once per row, on every reload.** →
  **Fixed:** `ProjectShowLive` reads every row's pictures once per project shown (`row_image_urls/2`), passed
  through `RichText`'s new `urls` attr. Test: `batched_reads_test.exs`, one row versus five.
- **BUG - MEDIUM (not fixed): making a started or done task a sub-project reopens it and drops its estimate.**
  The first rollup of an empty child writes `todo`, `progress 0` and the child's total, logging an automatic
  reopen. Left for a decision: carry the row's status and estimate into the new sub-project, or refuse or
  ask for started and done tasks.
- **BUG - MEDIUM (not fixed): Back in the browser drops unsaved drawer edits.** `pkp_url_task ""` closes the task
  frames without honouring a frame's `closeable: false`. Left: the fix spans the `PkpDrawerUrl` hook and the
  host and needs a browser to verify, since LiveViewTest cannot see `popstate`.
- **BUG - MEDIUM (not fixed): the edit form's subtask links leave without asking.** A bare
  `<.link navigate>` drops edits held until Save, and inside a drawer it moves the whole host page. Left for
  the same reason as the previous item. The fix is an in-drawer swap guarded by `ConfirmAction.close`.
- **IMPROVEMENT - MEDIUM (recorded):**
  - `create_project/2` called inside a caller's transaction skips the preset's extensions and the ongoing start.
    The doc promises one call; a host that wraps it must run the two after commit.
  - The library picker re-folds every title on each render, and an NFD-stored "Õ" sorts with "O".
  - The picker reads each chip on mount (`describe/3` per key, where `rows_for/2` is batched).
  - Dependencies kept across a task→sub-project conversion are invisible to readiness and notices.
  - A late finish makes an already-overdue next occurrence.
  - Undoing an accidental Done leaves a duplicate occurrence.
  - `pkp_url_task` pushes a frame (and its ref) before the view's access check.
  - About 40 static DOM ids remain in the stackable task form (`assignment-form` itself, the Leaf root, the
    date hooks).
- **NITPICK:**
  - Fixed:
    - The project Calendar's overdue count no longer counts a task twice.
    - The outline draft row's id is keyed.
    - A forged `set_status` no longer crashes the page.
    - `Repeats.normalize/1` takes no crash from a forged nested param.
    - `DurationInput.to_minutes/1` no longer overflows on `1e308`.
    - Estimates are capped below the INTEGER column's range.
    - `People.assignee_keys(%Task{})` reads `default_assigned_*`.
  - Recorded:
    - `board-column-<status>` ids are not namespaced. The id predates these PRs, and `PkpBoard` does not key on it.
    - A month rule's anchor ignores a deliberately moved deadline.
    - A mention token inside a link address is spliced into the attribute (broken markup, not exploitable).
    - The Modules page's preset dialog does not say "Embedded" switches the portal off.
    - A repeating parent and subtask finished together copy the subtask twice.
    - Round trips through task↔sub-project leave orphaned one-off tasks.
    - `log_actor` and `subtask_add` do not re-ask their rights or flag.

## Older bugs found while reviewing (in code #60 reworked)

- **BUG - HIGH: the task form passed unfiltered `assignment[…]` keys to `Assignment.changeset/2`.** That made the
  following possible with a crafted save:
  - move a task to another project (`project_uuid`);
  - nest any project as a sub-project, skipping every check `link_existing_subproject` makes, cycles
    included (`child_project_uuid`);
  - link another project's one-off task, which made it renameable (`task_uuid`);
  - set progress past its flag.

  #60's new Save path carried it. → **Fixed:** `strip_server_owned/2` in both save paths. The task a new row
  stands for is the library picker's own tick, never a posted uuid. Tests: `form_owned_fields_test.exs`.
- **BUG - MEDIUM: the form's status radios needed only `:edit_tasks`.** A project that reserves status for
  managers let any member finish a task (and release its dependents) through the form, and a status outside
  the offered choices was accepted. → **Fixed:** a status change needs `:update_status` (the record decides an
  assignee's own grant) and one of `AssignmentStatusBadge.choices/2`. The radios are hidden without the right.
  Test: "the form's status is the page's status step".
- **BUG - MEDIUM: a dependency could join two projects**, showing a private task's title and status under "Waits
  on". `Dependency`'s moduledoc said the context enforced it, but it did not. → **Fixed:**
  `Projects.add_dependency/3` refuses a pair from two projects. Test: `dependencies_test.exs`.
- **BUG - MEDIUM (recorded): renaming a one-off task from the form skips the `projects_using_task/1` rule.** A
  template's one-offs are shared by every project made from it; `TaskFormLive` checks every using project.
- **BUG - MEDIUM (recorded): `subtask_toggle` and the portal toggles hold the raw row.** A later Save then reads
  an agent's untouched description as changed and takes its wording away (`words_by_key_uuid`). The fix is
  routing them through `hold_saved/2`.

## Validation

- Baseline at `5a58c7f`: `mix test` **2694 tests, 0 failures** (integration and LiveView included, against an
  isolated PostgreSQL), and `mix precommit` green.
- After the fixes: see `FOLLOW_UP.md`.
