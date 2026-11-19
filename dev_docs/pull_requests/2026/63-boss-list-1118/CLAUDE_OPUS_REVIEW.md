# PR #63 — the boss's fourth list: post-merge review

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5), 2026-11-19. Reviewed after the merge (`597f8d1`), against the local core checkout
(`PHOENIX_KIT_PATH=../phoenix_kit`), because core 3.7.0 is not on Hex yet.
**Method:** three read-only reviewers split the lib diff: the project page and its JS; the forms and the people
source; members, notices and mentions. Every finding below was checked against the code before it was acted on.
`CLAUDE_REVIEW.md` beside this file is the author's own panel record, and nothing in it is repeated here.
**Verdict:** the feature work is sound. Four MEDIUM bugs in assignee admission and five on the project page and in
the forms are fixed, each with a test. Two release blockers are outside this repo.

## Release blockers (outside this repo)

- **core 3.7.0 is not on Hex.** `mix.exs` needs `>= 3.7.0`, and the newest release is 3.6.1, so `main` resolves only
  with `PHOENIX_KIT_PATH`. Publish nothing until core ships the people picker.
- **Item 21 depends on comments #53, which is still open.** `AssignmentViewLive` hands `mention_people` /
  `mention_warning` to `CommentsComponent`. Only `phoenix_kit_comments#53` reads them: comments 0.6.0 ignores both,
  so `@` doesn't offer the task's people first and there is no warning. Once #53 is released, raise the comments pin
  to that version.

## Findings

### Members, notices

- **BUG - MEDIUM: admission ran inside the caller's transaction.** `create_assignment/2` admits assignees, and it is
  called inside the SERIALIZABLE template clone and the closure pull.
  - A failed statement aborts a Postgres transaction. For example, a unique violation on a member row inserted at the
    same moment, which `admit_assignees`' rescue hid. The clone's next insert then failed with "current transaction
    is aborted" and the whole project creation rolled back.
  - The member broadcast and the notice also went out before the commit.
  - → **Fixed:** `admit: false` on the in-transaction calls. The clone admits every row after it commits
    (`admit_project_assignees/2`), and the closure admits in its post-commit loop.
  - Test: "a project cloned from a template admits the template's assignees after its commit".
- **BUG - MEDIUM: accepting a portal request never admitted its people.** `admit_assignees` skips a pending row, and
  `review_assignment/3` flipped it to accepted with a bare change. Later edits look only at keys added after that.
  - → **Fixed:** `review_assignment(:accepted)` admits.
  - Test: "accepting a task that waited for review admits its people then".
- **BUG - MEDIUM: the Done / next-up dialogs admitted deactivated accounts and tagged them "added when you
  confirm".** `admit_kept/4` called `add_member` with no `assignable_user?` and no template check, and
  `assignee_reach` called an inactive account `:cannot_open`.
  - → **Fixed:** there is now one rule, `Members.admit_users/3`, used by `admit_assignees` and the dialogs.
    `assignee_reach` answers `:inactive`, and the dialog tags it "Account deactivated", a new string translated in
    all 7 locales.
  - Tests: the deactivated and template cases of `admit_users`, and the `:inactive` reach.
- **NITPICK → fixed: a race could demote a manager.** If someone made the person a manager between the "not a
  member" check and `add_member`, `add_member` changed the role back to member. → `add_member(only_new: true)`
  answers `{:error, :already_member}`. Test: "an admission never changes a seat someone already holds".
- **IMPROVEMENT - MEDIUM → fixed in part: per-person reads.** `admit_users` reads the accounts and the existing seats
  once for the whole list. `Notices.may_view?/2` stays per candidate, but by then the list is only people who are new
  and active.
- **IMPROVEMENT - MEDIUM, left: most create paths log admission with no actor.** The assignment form's create calls,
  the API and `TimeBoard` call the context without `actor_uuid:`, so their `member_added` rows name nobody. API-made
  rows also lack `metadata.via`.
  - Threading the actor through every call site (and the API metadata through the context) is a change of its own.
    Recorded.
- **IMPROVEMENT - MEDIUM, documented: a sub-project's own assignees admit nobody.** `Projects.update_project/2` has no
  admission. Whether it should admit into the child project is a product question, so the gap is now written in
  AGENTS.md rather than guessed at.
- **NITPICK, left:** `metadata["note"]` / `["reason"]` are stored beside the capped quote. They are only
  grapheme-capped upstream (2,000 characters).
- **NITPICK, left:** the 16 KB quote test asserts only when core draws quotes (`if quote = …`). It is vacuous on
  3.6.1 and real on the local core.

### The project page

- **BUG - MEDIUM: Done on a task inside an expanded sub-project used the parent's rights.** Done always asks now, so
  that task reached `build_next_up` with the page's project. The pickers' `:assign_tasks`, the kept-recipient seats,
  the tags, the people source and the Done note's comment check all used the parent.
  - → **Fixed:** `next_up_for/3` builds the dialog in the task's own project, the pickers' `source_opts` follow
    `next_up.project_uuid`, and `may_comment_next_up?` asks that project's discussions switch.
- **BUG - MEDIUM: the side panel offered the project's general Discussion while `project_comments` was off.** One
  example is the `"embedded"` preset. → **Fixed:** the panel uses the same switch as the Comments tab. Test added.
- **BUG - MEDIUM: duplicate DOM ids.** The side panel's Timeline, Calendar or History rendered beside the same view's
  own (kept-mounted) tab, so both copies had the same ids. The Gantt's id, the calendar's sync hook and day dialog,
  and the history list were all duplicated.
  - → **Fixed:** a `"dom_scope"` session key (a lowercase word, validated in `assign_embed_state/2`) prefixes the
    three views' ids, and the panel passes `"side"`. Test added. The table in AGENTS.md lists the key.
- **BUG - LOW: the Done dialog of a sub-project row offered additions it never applied.** `assign_added/3` ignores a
  sub-project row. → **Fixed:** that picker is read-only there, as the row pickers already were.
- **IMPROVEMENT - MEDIUM → fixed: people added in the dialogs were not in the task's history.** → `assign_added/3`
  logs `projects.assignment_updated` with the change (`tell: false`), as the deadline edit does.
- **NITPICK → fixed:** the panel's calendar lacked `"step_intents" => "1"`; the panel's history passed an unread
  `"compact"`.
- **IMPROVEMENT - MEDIUM, left: without the right to assign, nobody can be taken off the notify list.** Core's
  picker hides × with `can_edit=false`. Fixing it needs a "removable without adding" mode in core's `PeoplePicker`.
- **IMPROVEMENT - MEDIUM, left: a pasted multi-line quick add writes one task per line,** each with its own
  broadcasts. The outline's paste does it in one `Outline.sync`; routing it there is a refactor of its own.
- **IMPROVEMENT - MEDIUM, left: the side panel mounts its view below 2xl, where CSS hides it.** It would need a
  `matchMedia` hook.
- **NITPICK, left:** `open_comments` and the `comments_resource` modal are no longer reached from any template. The
  dialog's tag computation reads every comment of each row's task, but only on dialog events.

### The forms

- **BUG - MEDIUM: a file uploaded in an unsaved edit stayed attached when the host closed the frame.** This covers
  the drawer's ✕ "Discard" and the browser's Back. Only the form's own Close / Cancel cleaned it up.
  - → **Fixed:** `AssignmentFormLive.terminate/2` removes `session_files` best-effort. Save empties the list.
  - Left: Back (`close_task_frames`) still pops a dirty frame without asking. Held changes are lost then, never
    written.
- **BUG - MEDIUM: the B2 fix was incomplete.** A held "Sits under" and held new subtasks were written at Save after
  Subtasks was switched off. → **Fixed:** `apply_held/1` drops them, and held ticks stay. Test: "with Subtasks off
  by Save, a held parent and held subtasks are dropped; a tick stays".
- **IMPROVEMENT - MEDIUM → fixed: the assignment form's picker could make staff records for a viewer whose Save is
  refused.** → `picker_allowed?/1` also asks `write_allowed?/1`, as the project form's does.
- **NITPICK → fixed:** `adopt_summary` now applies the button's rule to a one-off task, whose description lives on
  its task. The edit-mode `subtask_add` has an `is_binary` guard and a catch-all for crafted input.
- **IMPROVEMENT - MEDIUM, core: search drops a person who appears under two groups.** Core's picker keys option DOM
  ids on `{kind, uuid}`, while `Assignees.page/…` returns a person once per matching group. The fix belongs in core
  (use the source's row `:id`).
- **NITPICK, left:** `id="assignment-assignee"` / `"subproject-assignee"` and `waits-on-<uuid>` are not namespaced
  per record. A subtask's form opened over its parent's duplicates them. The picker ids are what tests and helpers
  drive, so renaming them is a sweep of its own.
- **NITPICK, left:** event descriptions now render as markdown, so single line breaks in older plain-text
  descriptions collapse.

### Catalogue

Fine. 72 new strings from the PR plus 1 from this review, with no empty or fuzzy entry in any locale (checked with a
parser; `msgattrib` isn't installed here). Every msgid the PR removed is gone from the code.
