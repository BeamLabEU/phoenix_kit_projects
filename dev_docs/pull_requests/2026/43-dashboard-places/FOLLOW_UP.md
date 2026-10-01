# Follow-up Items for PR #43

Triage of `CLAUDE_REVIEW.md` and the PR's own `QUALITY_SWEEP.md` against the
current code on `main` (2026-10-01). The Claude review raised no findings of
its own (verdict "no changes required"); the items below are the ones the
quality sweep listed under "Surfaced, not changed", plus the deferred item
both documents mention. The sweep's "Fixed" table was applied before merge
and is not repeated here.

## Fixed (pre-existing)

- ~~**`list_projects_for/2` materialises every accessible project to build a
  uuid list**~~ — `projects.ex:873-882`. `maybe_scope_to_viewer/2` now calls
  `Members.accessible_project_uuids/1` (`members.ex:154`), which selects uuids
  directly, so `phoenix_kit_dashboard_viewer_context/2`'s `limit: 2` call no
  longer loads every accessible project first. Commit `8ae601f`, shipped in
  0.24.1.

## Files touched

None — documentation only.

## Verification

- Read `projects.ex` `list_projects_for/2` and `maybe_scope_to_viewer/2`;
  `git log -S accessible_project_uuids` for the fix commit.
- Read `Authz.subject_user_uuid/1` and grepped `lib/` for `user_active?` and
  `ensure_active_user` (only the embed identity path in `web/helpers.ex:713`
  calls the latter).
- Grepped `priv/gettext/default.pot` for the notification-type, preset and
  creation-block strings, and traced their render sites.
- Grepped `lib/` for `String.capitalize`.
- The still-live items from PRs #31, #35 and #40 that the sweep pointed to are
  tracked in those folders' own `FOLLOW_UP.md`, not repeated here.

## Open

All awaiting Max's decision.

- **IMPROVEMENT - LOW — Deactivated users are not checked by `Authz`.**
  `authz.ex:394` (`subject_user_uuid/1`) accepts any scope carrying a user
  struct; core's `Scope.user_active?/1` is called nowhere in `lib/`. Today the
  embed path filters with `Auth.ensure_active_user/1`
  (`web/helpers.ex:710-713`) and the dashboards host does the same, so the
  exposure needs a caller that builds a scope some other way.
- **IMPROVEMENT - LOW — `notification_types/0` labels reach no catalogue.**
  `lib/phoenix_kit_projects.ex:71-` — labels and descriptions such as
  "Membership, health, and task updates in your projects" are plain strings,
  absent from `default.pot`. Core renders them raw with no backend hook, so a
  fix needs a core change as well.
- **IMPROVEMENT - LOW — Preset names are untranslated.**
  `features.ex:322` (`presets/0`) — e.g. "Simple to-do list" is not in
  `default.pot`, and `web/project_modules_live.ex:511-516` renders
  `preset.name` / `preset.description` without `translate_catalog/1`.
- **IMPROVEMENT - LOW — Creation-block labels are untranslated.**
  `features.ex:392-397` (`@creation_blocks`) — "From template" / "Start
  timing" are rendered raw at `web/projects_settings_live.ex:674`
  (`{block.label}`); "Start timing" is not in `default.pot`.
- **NITPICK — Humanized field names in error flashes are English-only.**
  `String.capitalize` on `Atom.to_string(field)` at
  `web/project_form_live.ex:1552`, `web/task_form_live.ex:413`,
  `web/assignment_form_live.ex:1631` and `web/project_show_live.ex:1034`.
