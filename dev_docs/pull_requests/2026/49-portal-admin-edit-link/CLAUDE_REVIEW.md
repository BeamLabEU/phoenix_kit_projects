# Claude (Sonnet 5.5) review — PR #49, after the merge (2026-10-13)

PR #49 (`timujinne/admin-edit-link`, merge `fc2d9f2`): an "Edit project" link in
the public portal board header, for a viewer who may VIEW the project. Files:
`web/portal_live.ex`, `web/portal_live_test.exs`. Read against core's
`AdminEditHelper` / `AdminEditLink` (installed 2.62.2).

## Verified, no change needed

- **Core floor holds.** `AdminEditHelper.assign_admin_edit/3` with the
  `:permission` option shipped in core 2.22.1; the module's floor is 2.49.0.
- **Gate order is right.** `WebHelpers.template_or_viewable?/2` runs BEFORE the
  helper builds the href, so a module-key holder who is not a member never
  gets the project uuid in the page (the tests assert `refute html =~ uuid`).
- **Dead/switched-off/refused slugs** reach neither `assign_admin_edit/2`
  branch, and `clear_admin_edit/1` runs first on every reload, so a reload that
  fails resolve leaves no link.
- `id` on `<.admin_edit_link>` rides the component's `:rest` global attr.
- `Paths.project/1` already goes through `Routes.path/1` (prefix-safe).

## Fixed

- **BUG - MEDIUM: the link was not withdrawn when the viewer's standing
  changed, only when a hand-picked event arrived.** `PortalLive` reloads on
  `:portal_rotated`, `:project_modules_changed` and `:assignment_updated`
  only. `Members.remove_member/3` (and add/role-change/ownership-transfer)
  broadcasts `:project_members_changed`, grants broadcast
  `:project_grants_changed`, and a visibility change broadcasts
  `:project_updated` — none reloaded the board, so a removed member's open tab
  kept an "Edit project" link (to a page that then bounces) until some
  unrelated event fired. The PR's test "withdrawn when a live session's viewer
  stops being a member" passed only because it `send`s
  `:project_modules_changed` by hand, an event the real removal never emits.
  The three events are now in the reload list, and the test drives the real
  `remove_member` broadcast with no manual message. Impact was low (the link is
  only an href to a page that re-checks authorization), but the code comment
  and the test both claimed the behaviour.

## Noted, not changed

- `:project_updated` now reloads every open portal tab on each project edit
  (a resolve + public view per viewer). Edits are infrequent and the reload
  also refreshes the board's name/description, which was stale before; if it
  ever shows up in a profile, narrow it to visibility changes by carrying a
  flag in the payload.
