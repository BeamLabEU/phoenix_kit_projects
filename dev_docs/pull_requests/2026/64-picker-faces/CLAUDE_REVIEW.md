# Claude Review — PR #64

**Reviewer:** Claude Opus 5.5
**PR:** Show faces in the people picker and mention chips while typing (mdon)
**Reviewed:** 2026-11-19

A small follow-up to #63, found in a browser check of the merged work. No panel review: two narrow changes.

- `PeopleSource.with_users/1` reads the accounts of a page's people in one query (`PhoenixKitProjects.People.Person` join `User`, so `WITHOUT_STAFF` builds still compile) and puts `user:` on each row. Core's picker draws `user_avatar` for a row with `user`. A failure leaves the rows as they were (the plain icon), and nothing is read for a page with no people.
- `description_editor/1` passes `mentions={true}`. Its `@`/`#` suggestions were already on. An older Leaf ignores the attribute.

Verification: compile (with and without `WITHOUT_STAFF`), credo `--strict`, dialyzer; 63 tests across the picker, dialogs and popup; dev-box browser check.
