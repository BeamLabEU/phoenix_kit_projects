# Claude Review — PR #64

**Reviewer:** Claude Opus 5.5
**PR:** Show faces in the people picker and mention chips while typing (mdon)
**Reviewed:** 2026-11-19

A small follow-up to #63, found in a browser check of the merged work. No panel review: two narrow changes.

- `PeopleSource.with_users/1` reads the accounts of a page's people in one query (`PhoenixKitProjects.People.Person` join `User`, so `WITHOUT_STAFF` builds still compile) and puts `user:` on each row. Core's picker draws `user_avatar` for a row with `user`. A failure leaves the rows as they were (the plain icon), and nothing is read for a page with no people.
- `description_editor/1` passes `mentions={true}`. Its `@`/`#` suggestions were already on. An older Leaf ignores the attribute.

Verification: compile (with and without `WITHOUT_STAFF`), credo `--strict`, dialyzer; 63 tests across the picker, dialogs and popup; dev-box browser check.

## Second round (2026-11-20): the boss's post-merge review of #63

Each item from his "Left, recorded" list, checked against the code before and after:

- **Notify list removal:** relies on core #1051's `can_remove`. The server already accepted a removal without the right (only additions are checked), and a test covers it under restrictive floors.
- **Back over unsaved changes:** `task_frames_dirty?/1` looks at every frame Back would close. A crafted `pkp_url_discard` only closes what a clean Back would.
- **Admission actor:** the context forwards opts to `Members.admit_assignees/3` on every path. Subtask creates carry no assignees, the time board changes deadlines only, and portal requests admit nobody until accepted, so those three need no actor.
- **Quick add:** one title keeps the old path, several go through `Outline.sync` (its line cap applies).
- **Side panel:** a crafted non-boolean `wide` changes nothing. The hook re-sends on reconnect.
- **Ids:** `form_key/1` is the task's uuid or `"new"`. A new-task form never opens over another new-task form.
- **Event line breaks:** no change needed (see the PR description).
