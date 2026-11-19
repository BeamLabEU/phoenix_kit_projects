# Follow-up — PR #63

2026-11-19: how the findings of the post-merge review (`CLAUDE_OPUS_REVIEW.md`) were resolved. The findings of the
author's panel are in `CLAUDE_REVIEW.md`.

## Fixed, each with a test

- **Admission:**
  - moved out of transactions (`admit: false`, then admitted after the commit);
  - an accepted portal request now admits its people;
  - one rule, `Members.admit_users/3`, which the Done / next-up dialogs use too, with an `:inactive` reach;
  - `add_member(only_new: true)`;
  - batched account and seat reads.
- **Project page:**
  - Done on a sub-project's inset task is judged in that task's project;
  - the side panel's Discussion follows `project_comments`;
  - `"dom_scope"` keeps a second copy of Timeline, Calendar and History apart;
  - the Done picker of a sub-project row is read-only;
  - assignees added in a dialog are logged;
  - `step_intents` on the panel calendar.
- **Forms:**
  - `terminate/2` removes unsaved uploads;
  - a held parent and held subtasks are dropped when Subtasks is off by Save;
  - `picker_allowed?` also asks `write_allowed?`;
  - `adopt_summary` applies the button's rule;
  - `subtask_add` has guards.

## Left, recorded

- No actor on admissions from most create paths (form creates, API, `TimeBoard`).
- A sub-project's own assignees admit nobody (now documented).
- Removal-only picker mode for the notify list (needs core).
- Quick-add paste writes line by line.
- The side panel mounts below 2xl.
- Back does not ask before dropping a dirty task frame.
- Two-group search duplicates (core).
- Static picker DOM ids.
- Markdown event descriptions.
- `metadata["note"]` stored beside the quote.
- The conditional 16 KB quote test.

## Before the next release

1. Core 3.7.0, with `PeoplePicker`, must be on Hex: `mix.exs` needs `>= 3.7.0`, and Hex has 3.6.1.
2. `phoenix_kit_comments#53` must be merged and released, then the comments pin raised to it. Until then the `@`
   people list and the warning (item 21) do nothing.

## Gate (this tree, against the local core, `PHOENIX_KIT_PATH=../phoenix_kit`)

- Full suite: 2873 tests, 0 failures, none excluded. The merged PR alone gave 2865 tests and 0 failures.
- Passing: `mix compile --warnings-as-errors`, and `mix quality.ci` (format check, `credo --strict`, dialyzer).
- `WITHOUT_STAFF=1 mix compile --warnings-as-errors`: passes.
- `mix precommit`'s `deps.unlock --check-unused` step fails only under the path override, which rewrites `mix.lock`
  (`ex_aws_ec2` is unused by the local core). The committed lock is unchanged.
- `.po` files: no empty or fuzzy entries in any of the 7 locales.
