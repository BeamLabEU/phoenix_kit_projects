# Follow-up — release review v0.34.0..HEAD

2026-11-23, Claude (Opus 5.5), on `MISTRAL_VIBE_REVIEW.md`. This is not a PR folder (see that file).

## Admission inside two transactions — fixed, as the review did it

Checked by hand and kept:

- `PubSub.after_commit/1` is a `repo.transaction`. The API's PATCH (`write_update`) and the next-up dialog
  (`in_one_write`) both admitted inside one. No third site does: the template clone, the closure pull and the
  portal already admit after their commits, and the task form, the outline and the time board open no
  transaction.
- The dialog flushes its held admissions before its held logs, and both run before `Handoffs.batch` ends. So the
  hand-off notices still reach the people just admitted, because `Notices.may_view?/2` is asked when they are
  sent.
- On the API, the hand-offs run before `do_update`'s admission. PATCH takes no `status`, so this needs a reparent
  that settles a parent and adds an assignee in the same call. Accepted.

Two notes against the review:

- **Severity: MEDIUM rather than HIGH.** The activity rows rolled back with the transaction, so only core's
  `{:activity_logged}` broadcast could escape. After `update_fields/3`, no API step realistically fails. The
  dialog's rollback needs a failed write mid-dialog.
- **The new `api_test.exs` case does not pin the ordering.** With the lib changes stashed it still passes
  (1 test, 0 failures), because the old in-transaction admission committed too. It pins the actor and
  `source: "api"`. A real pin needs a rollback after the assignee write, which neither path offers a test without
  faking a database failure. Left as it is.

## Gate

`mix format --check-formatted`, `mix precommit`: pass. 149 targeted tests: 0 failures. These cover the API, the
next-up dialogs, assignee admission, hand-offs and the fourth list.
