# Follow-up — PR #47

How each finding in `CLAUDE_REVIEW.md` stands against the current code.

- **BUG - HIGH: the PR used core APIs no published core had** —
  **Fixed.** `fcd140d` added `test/core_ui_api_conformance_test.exs`, which
  pins every core component attr and slot the LiveViews rely on; `317b8de`
  raised the floor to the core that ships them. The floor is now
  `>= 2.54.0 and < 3.0.0` (`mix.exs:156`, `core_pin_conformance_test.exs`).
- **BUG - MEDIUM (test): "overdue only keeps late bars" failed early in a
  month** — **Fixed** in `fcd140d`. The test clamps the start to the 1st of
  the current month (`test/phoenix_kit_projects/web/project_calendar_live_test.exs:523`)
  and the late task is one hour long, so the late bar always lies in the
  opened month.
- **NITPICK: five `phx-disable-with` attributes mis-indented** —
  **Fixed** in `fcd140d` (events, members, modules, whiteboards and show
  LiveViews; whitespace only).
- **NITPICK: the save-time eligibility check loads every candidate** —
  **Open.** `link_existing_subproject/2`
  (`lib/phoenix_kit_projects/web/assignment_form_live.ex:1556-1566`) still
  builds the whole `nestable_projects/2` list to test one uuid. A targeted
  check would need the picker's filter as one shared query (so the two cannot
  drift), with `nestable_projects/2` and the check both built on it.
