# Release review — everything since v0.34.0 (the last Hex release)

**Author:** Mistral Vibe, 2026-11-22. This is not a PR folder: it reviews the
whole range `v0.34.0..HEAD` (33 commits: PRs #63 and #64, the dependency
upgrades, and the `phoenix_kit` floor bump to 3.7.0) ahead of the next Hex
publish. Hex's latest release of `phoenix_kit_projects` is 0.34.0
(2026-11-08), matching the tag, so the range is exactly what the next
release will ship beyond 0.34.0.

## Method

- Read the #63 / #64 review records (`63-boss-list-1118/`, `64-picker-faces/`)
  and re-verified their claims against the code and the locked deps.
- Four read-only reviewers covered the slices (people picker / project page /
  forms / context + gettext + test infra); every finding was checked against
  the code by hand before being acted on.
- Ran the gate and the suite on the range, then fixed what the review found
  and re-ran both.

## Verified

- **Deps.** Locked `phoenix_kit` is 3.7.0 and does ship
  `PhoenixKitWeb.Components.PeoplePicker`, so the new floor
  `>= 3.7.0 and < 4.0.0` (mix.exs:127, guarded by
  `core_pin_conformance_test.exs`, consistent with AGENTS.md) is justified;
  3.7.0 is on Hex since 2026-11-22, so the #63 release blocker is lifted.
  `phoenix_kit_comments ~> 0.5` admits the locked 0.6.0; the known gap stands:
  comments 0.6.0 does not read the `mention_people` / `mention_warning`
  assigns (`AssignmentViewLive`), so item 21's mention list stays inert until
  comments #53 ships — the assigns are inert extra assigns there, no crash
  (recorded in the #63 review as waiting on that release; the `~> 0.5` pin
  admits the future 0.x automatically).
- **No migration-chain change** (`@current_version 30`); nothing for
  `mix phoenix_kit.update` to apply.
- **Packaging.** `priv/media/` (24 MB of runtime output) is excluded via
  `exclude_patterns`; `mix hex.audit` finds no retired/advisory packages.
- **Gate on the range (before my fix):** `mix precommit` pass (format,
  `compile --force --warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, `credo --strict` 0 issues, dialyzer 8 skipped / 0 unnecessary);
  `WITHOUT_STAFF=1 mix compile --warnings-as-errors` pass (the People seam
  holds); `mix test` 2879 tests, 0 failures, DB-backed tests included.
- **Gettext.** 74 new msgids vs v0.34.0, all present and translated in all 7
  locales (de, es, et, fr, it, pl, ru; plural forms filled); zero empty
  `msgstr`, zero `fuzzy`; the 33 removed msgids dropped everywhere.
- **Permission surface.** Every mutating event on the project page and the
  forms re-checks the right at the write (WriteGate / `authorized_handle_event`
  / per-handler `Authz.can?`); server-owned fields stay uncastable; the removed
  `open_comments` event opens nothing (test-pinned); `dom_scope` and
  `url_param` are validated; the bare `pkp_url_discard` is unreachable except
  as the confirm dialog's answer; quick-add cannot remove/reopen/reparent.

## Found and fixed (this review)

- **BUG - HIGH: admission ran inside two transactions.** The convention this
  release itself established ("admission writes, logs and notifies, so it
  never runs inside a transaction") was violated by two call sites that
  #63's fix missed:
  - `Web.Api.TasksController` — the PATCH's whole write chain runs in
    `write_update`'s `PubSub.after_commit` transaction, and `update_fields/3`
    called `Projects.update_assignment_form/3` with the default `admit: true`,
    so an assignee change admitted (member row + `projects.member_added` +
    core's immediate `{:activity_logged}` broadcast and notification fan-out)
    inside it. A refusal later in the chain rolled the rows back but not the
    broadcast/notification — a phantom "you were added".
  - `ProjectShowLive` — the Done / next-up confirm runs `admit_kept/4` and
    `assign_added/3` inside `in_one_write`'s transaction; the LV's held-logs
    mechanism did not cover `Members`' direct `Activity.log`.
  - **Fix:** `admit: false` on both writes; the API admits in `do_update` after
    `write_update` returns (i.e. after commit), the dialog holds its
    admissions in a `@held_admissions` process key that `in_one_write` flushes
    only when the transaction committed — before the held logs, so their
    notices reach the people just admitted. `assign_added`'s history entry now
    goes through the LV's `log_activity/2` too. Regression test:
    `api_test.exs` "PATCHing a task's assignees … admitted after it commits,
    marked as the API's" (seat + `member_added` row with `source: "api"` +
    the `{:activity_logged}` broadcast after the 200).

## Left on record (not release-blocking)

- `mention_people` / `mention_warning` are dead until comments #53 ships
  (see above); a code comment naming the required comments version would help.
- Email is matched by full substring and shown as a sublabel in the assignee
  search, visible to anyone holding `:assign_tasks` on one project
  (pre-existing product decision; core's own user source matches prefix-only
  and shows no email).
- `PeopleSource.me/1` does not check the linked account is still active.
- Bare picker DOM ids in the embeddable `TaskFormLive` / `ProjectFormLive`
  (pre-existing); stale AGENTS.md sentence about the removed autosave timer;
  `ProjectFormLive`'s link-dep / project-file events rely on their own
  narrower checks, not `write_events/0` (pre-existing).
- Most create paths still log admissions with no actor (recorded in #63).

## Gate after the fix

- `mix precommit`: pass. `WITHOUT_STAFF=1 mix compile --warnings-as-errors`:
  pass. `mix test`: 2880 tests, 0 failures (full suite, DB-backed).
  Targeted re-runs: next_up_done + api_test 42/42; assignee_admission,
  handoffs, project_show_next_up, subproject_next_up, boss_list_1118,
  write_gate, embedding 167/167.

## Verdict

**Ship.** One HIGH bug found by this review and fixed with a test; everything
else the range touches verifies against its own review records, the locked
deps, and a green gate.
