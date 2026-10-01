# PR #47 — Scope the sub-project picker to the viewer; move dialogs and forms onto core components

**Reviewed:** 2026-10-01 · **Author:** Dmitri Don (mdon) · **Verdict:** merged; one
release blocker (the PR needs a core that is not published yet), one date-dependent
test fixed, one nitpick fixed. Nothing wrong with the behaviour change itself.

31 files, +1272 / −909 outside the `.po` re-sort (merge `96aba85`, follow-up lock
bump `89f78d1`).

## What it does

- **Security fix.** `Projects.available_projects_to_link/2` takes a scope: a site admin
  sees every candidate, anyone else only the projects `list_projects_for/2` would show
  them. `AssignmentFormLive` re-resolves that set at save time, so a forged
  `link_child_uuid` is refused. `link_subproject/2` rejects an archived child
  (`:archived`).
- **UI standardisation.** Every hand-rolled `<dialog>`, `<select>`, form-action row, card
  section and the comments drawer move onto core's `modal`, `select`, `input`,
  `form_actions`, `form_section`, `popover_panel`, `nav_tabs`, `load_more`, `empty_state`.
  Create buttons move into the list toolbar's `:primary` slot. Closing a dialog is no
  longer a gated event. Component ids carry the project uuid.
- Gettext: new msgids for the two link errors, resource-link subtitles, role and colour
  names; `.po` files re-sorted.

## Findings

### BUG - HIGH — the PR is written against core APIs that no published core has

The Hex-published `phoenix_kit` 2.42.1 (the newest release, and what `>= 2.38.0 and < 3.0.0`
resolves to) does not declare three things this PR uses. They exist only in the
`## Unreleased` state of the local `../phoenix_kit` checkout, which carries the same
`2.42.1` version string:

| Used here | Where | Missing in Hex 2.42.1 |
|---|---|---|
| `submit_disabled` on `form_actions` | task / template / project / assignment forms | 5 call sites |
| `:primary` slot on `bulk_actions_toolbar` | `ProjectsLive`, `TasksLive`, `TemplatesLive` | 3 call sites |
| `:actions` slot on `form_section` | `ProjectFormLive` (People badge), `ProjectsSettingsLive` | 4 call sites |

Phoenix reports an undeclared attr or slot as a **warning**, so a host build still
succeeds and the page just loses the control: no "New project / task / template"
button on the three list pages, and Save / Add stay enabled while an AI translation is
in flight, while no participant is staged, or while "Nest existing" has nothing to pick.
`mix compile --warnings-as-errors` against the Hex core fails with 12 warnings; it is
clean against `PHOENIX_KIT_PATH=../phoenix_kit`.

**Not fixed at review time, deliberately.** The cure is a core release shipping those three
APIs and then raising the floor — a cross-repo, outward-facing step, and a floor naming a
version that did not exist would have broken `mix deps.get` for every consumer. The release
was held until core shipped them.

**Resolved 2026-10-01:** `phoenix_kit` 2.43.0 carries all three. The floor is now
`>= 2.43.0 and < 3.0.0` (`mix.exs`, `core_pin_conformance_test.exs`, AGENTS.md) and the
package shipped as 0.28.0; the published tarball's requirement was checked.

**Added:** `test/core_ui_api_conformance_test.exs` pins every core component API the
LiveViews rely on (attrs and slots). Verified both ways — green against the local core,
and against Hex 2.42.1 it fails on exactly the three gaps above, with a message saying
which piece is missing and to raise the floor.

### BUG - MEDIUM (test) — "overdue only keeps late bars" fails in the first days of a month

`project_calendar_live_test.exs` started the project 5 days ago with a 1-day task. The
grid opens on `initial_anchor/2`: today's month when the schedule spans today, else the
schedule's first month. The on-time (3-week) bar spans today, so the grid opens on the
current month; the Overdue-only toggle then removes it, leaving a late bar that lies wholly
in the *previous* month — never rendered. Failed on 2026-10-01; a start 5 days back stays in this month only from about the 6th.
The PR's only change to that LiveView is skeleton classes, so this predates it.

**Fixed:** the start is clamped to the 1st of the current month and the late task is one
hour long, so the late bar is always in the opened month. Passes on 2026-10-01.

### NITPICK — five `phx-disable-with` attributes mis-indented

Added by the PR in `project_events_live.ex`, `project_members_live.ex`,
`project_modules_live.ex`, `project_whiteboards_live.ex`, `project_show_live.ex`;
`mix format` leaves them alone. **Fixed** (whitespace only).

### NITPICK — save-time eligibility check loads every candidate

`link_existing_subproject/2` builds the whole eligible list as `%Project{}` structs to test
one uuid. It is the same list the picker already loaded on mount, the page is
rare and admin-side, and a targeted `exists?` would duplicate the picker's filter rules
(the thing that must not drift). **Left as is.**

## Verified, no change needed

- **Link scope is fail-closed.** A nil / anonymous scope yields `where: false` (empty
  picker), not everything; template parents skip the narrowing by design (a shared
  library, no membership) and the test pins it. The embedded mount reconstructs
  `:phoenix_kit_current_scope` through `assign_embed_user/2`, so embeds do not hit the
  empty case.
- `:archived` is handled in both the context guard and `link_error_message/1`; no other
  caller of `link_subproject/2` maps errors.
- `error_summary/2` now calls core's `translate_error/1`; read against core, it is the
  same `dgettext("errors", …)` / `dngettext` logic as the deleted local copy.
- Core's `checkbox` posts a hidden `"false"`; `event_attrs/1` reads `all_day in ["true", "on"]`,
  so the create-event dialog still works.
- Dropping `max-h-[60vh] overflow-y-auto` from the review dialog is fine — core's `modal`
  scrolls its own content.
- Un-gating the four `close_*` events is correct, with a test for the health dialog.
- Gettext: 1001 msgids, identical in the `.pot` and all seven `.po` files; no empty and no
  fuzzy entries. The few msgstrs equal to English are genuine cognates ("Info", "Error" in
  Spanish, "Accent" in French, "Neutral" in German).

## Validation

At review time, against `PHOENIX_KIT_PATH=../phoenix_kit`: `mix test` 1614 tests, 1 failure
(the calendar test above, since fixed); `mix precommit` clean.

Before the 0.28.0 release, on the published deps (core 2.43.0, phoenix_kit_ai 0.25.0):
`mix precommit` clean (format, `--warnings-as-errors`, credo strict, dialyzer),
`mix test` 1619 tests, 0 failures with no integration tests excluded, and
`WITHOUT_STAFF=1 mix compile --force --warnings-as-errors` clean. Re-checked after the
release: tag `v0.28.0` is annotated, points at the release commit `317b8de` and is on
origin; Hex lists 0.28.0; the tarball has no `priv/media`.
