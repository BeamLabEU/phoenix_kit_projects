# Codex review — PR #49 and the release candidate (2026-10-13)

Reviewed PR [#49](https://github.com/BeamLabEU/phoenix_kit_projects/pull/49),
merged as `fc2d9f2`, the dependency update `4a736fc`, and Claude's local fix
`6cb9607`. The published version is 0.29.0; this review prepares its subsequent
changes without publishing or creating a tag.

## Claude's progress verified

The membership-change fix is correct. The test drives `Members.remove_member/2`
and its actual `:project_members_changed` broadcast. Additional tests now drive
real site-role grant creation/revocation and project visibility changes; both
confirm the other events Claude added refresh the edit link correctly.

The project-specific view gate runs before constructing the admin URL. The
core helper additionally checks admin-area and module access. Anonymous users
and non-members of a private project receive no project UUID in the page.
An `everyone` project intentionally permits module users to view its admin
page; direct membership is not required for that visibility mode.

Verified the helper's permission option, component global attributes, and
`phoenix_kit_scope_changed/1` callback dispatch directly against the published
core 2.49.0 tarball. No dependency-floor increase is required.

## Additional findings and fixes

### BUG - MEDIUM: deleting a project left its portal and edit link visible

Deletion emits `:project_deleted`, which the portal ignored. An open board
retained its old DTO and admin link even though resolving the slug now failed.
The portal now handles deletion and displays its uniform unavailable state.
The regression test deletes the project through `Projects.delete_project/1`.

### BUG - MEDIUM: a live module-permission change left the edit link stale

Core refreshes the viewer's scope through its own hook and consumes the
notification. The portal had no `phoenix_kit_scope_changed/1` callback, so its
previously computed admin URL survived a refreshed scope that no longer held
the module permission. It now exports the callback and refreshes its derived
state. The test uses core's real callback dispatcher with both a revoked and
a restored scope, checking that the public board remains available.

### BUG - MEDIUM: open issue details and discussions did not refresh

The PubSub handler reloaded the board DTO but never called `load_issue/1`.
Consequently an updated status remained stale and unpublishing an issue left
its discussion rendered. Assignment deletion was also ignored altogether.
Reloads now refresh both the board and the selected issue; created/deleted
assignments and project lifecycle events join the event list. Regression tests
drive actual status changes, unpublishing, and deletion without synthetic
broadcasts.

### BUG - MEDIUM: participation changes did not refresh portal controls

`Portal.set_participation/3` wrote the policy but emitted no notification.
Existing tabs retained report/reply controls based on the old policy.
Successful writes now broadcast `:portal_participation_changed`, and the
portal reloads on that event. A regression test tightens and restores the
submission policy while the board stays mounted.

### IMPROVEMENT - MEDIUM: the new label was absent from translation catalogs

Extraction and a no-fuzzy merge found exactly one new msgid, `Edit project`,
with no removed or reworded messages. Registered it in the POT and translated
it in de, es, et, fr, it, pl, and ru. Kept existing entries unchanged to avoid
unrelated reference-only churn.

### IMPROVEMENT - MEDIUM: the dependency update broke the standalone test host

The initial complete run had 1,729 tests and 35 failures. The newer core emits
prefixless URLs for single-language hosts, while this repo's test router only
serves locale-prefixed admin routes and had never configured language support.
LiveCase now explicitly enables multilingual URLs with the default-language
prefix inside each sandbox transaction. The database-free Paths tests exercise
the documented boot/mix-task URL shape. With this configuration, the complete
suite passed 1,736 tests with zero failures and no excluded integration tests.

## Validation and release state

Final focused checks and the release gate are recorded in `FOLLOW_UP.md`.
The changelog records the changes under Unreleased; version 0.29.0 and its tag
remain the published release. No migrations or dependency requirements changed.

Per-viewer reloads still resolve the slug and read the board. Issue routes
add one bounded detail reload; there is no query per issue in the board list.
The project and core permission topics are separate: project membership/grant
changes reload through this module's PubSub, while core scope changes use its
callback dispatcher.
