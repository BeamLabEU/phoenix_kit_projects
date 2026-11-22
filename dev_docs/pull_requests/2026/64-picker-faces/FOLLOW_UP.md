# Follow-up — PR #64

2026-11-22: how the findings of `CLAUDE_OPUS_REVIEW.md` were resolved. `CLAUDE_REVIEW.md` is the author's own
record.

| Finding | Outcome |
|---|---|
| A bare `pkp_url_discard` closed a dirty frame without asking | **Fixed.** The direct handler is removed, and only the dialog's `confirm_action_ok` discards. `task_in_url_test.exs` sends the event bare while the frame is dirty and asserts that nothing closes. |
| `review48_lv_test.exs` kept checking the removed `open_comments` | **Fixed.** Rewritten as "the removed comments popup's event opens nothing". |
| The picker's faces add one read per described chip and load whole accounts | **Left.** The lists are small and cached in the picker. The fix is a batched `describe` in core's `Source` behaviour. |
| A pasted quick add logs one `task_list_edited`, not a `assignment_created` per task | **Left.** It matches the outline's own paste, as the PR intended. |

Also in this pass: `mix.lock` carried an `ex_aws_ec2` entry that nothing uses. It came in with `b4b04db` (lib
upgrades) on `main`, and it stopped `mix precommit` at `deps.unlock --check-unused`. It is removed with
`mix deps.unlock --unused`.

## Gate

On `main` with #64 merged and these fixes, against core 3.7.0 from Hex:

- `mix precommit`: pass. It covers format, `compile --force --warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, `credo --strict` and dialyzer.
- `WITHOUT_STAFF=1 mix compile --warnings-as-errors`: pass.
- `mix test`: 2,879 tests, 0 failures. None excluded, so the DB-backed tests ran.
