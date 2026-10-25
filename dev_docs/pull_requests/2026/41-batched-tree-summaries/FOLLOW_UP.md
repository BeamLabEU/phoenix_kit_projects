# Follow-up — PR #41

How each finding in `CLAUDE_REVIEW.md` stands against the current code.

- **BUG - MEDIUM: `Attachments.download_urls/1` restated an old core URL
  rule** — **Fixed** in `20ae3fb`. `Attachments.download_urls/1` /
  `row_url/3` (`lib/phoenix_kit_projects/attachments.ex:315-357`): no link for
  a system-managed file, the signed route for an edit in progress or a
  private library (`Libraries.private_among/1`), else the bucket URL or the
  signed one; `batched_reads_test.exs` pins it against `download_url/1`.
- **IMPROVEMENT - MEDIUM: `Manager.public_url/2` still resolves the bucket
  per file** — **Open.** `row_url/3` calls `Manager.public_url/2` once per
  file (`attachments.ex:356`). Core 2.64.0 now ships a batched form,
  `Storage.direct_urls/1` (fixed query count; private and ineligible files
  keep the app URL); adopting it needs the core floor raised to
  `>= 2.64.0` and the batched-vs-`download_url/1` test kept green.
- **IMPROVEMENT - MEDIUM: `ProjectShowLive` loads each expanded child's whole
  descendant forest** — **Open.** `project_show_live.ex:720-721` still calls
  `Projects.assignments_by_project/1`, which follows links to the full depth
  (`projects.ex:2995`), and uses only each child's own rows. A `depth:`
  option on `load_forest/3` (stop after the roots) would fix it.
- **NITPICK: roles are still one `Roles` read each** — **Open.**
  `Grants.subject_reaches/1` calls `subject_reach("role", …)` per distinct
  role (`grants.ex:279`, which does `get_role_by_uuid` + `users_with_role`
  at `:218-220`), and the members page's `role_names/1` does one
  `get_role_by_uuid` per role (`web/project_members_live.ex:188-197`). Core
  lacks a batched by-uuid role lookup and a batched per-role user count; the
  names alone could come from the page's existing `Roles.list_roles/0` read.
