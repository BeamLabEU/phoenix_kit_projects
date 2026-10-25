# Follow-up — PR #41

How each finding in `CLAUDE_REVIEW.md` stands against the current code.

- **BUG - MEDIUM: `Attachments.download_urls/1` restated an old core URL
  rule** — **Fixed** in `20ae3fb`. `Attachments.download_urls/1` /
  `row_url/3` (`lib/phoenix_kit_projects/attachments.ex:315-357`): no link for
  a system-managed file, the signed route for an edit in progress or a
  private library (`Libraries.private_among/1`), else the bucket URL or the
  signed one; `batched_reads_test.exs` pins it against `download_url/1`.
- **IMPROVEMENT - MEDIUM: `Manager.public_url/2` still resolves the bucket
  per file** — **Fixed in this sweep.** `download_urls/1` takes the bucket
  URLs from core's batched `Storage.direct_urls/1` (a fixed number of reads,
  no bucket request); what it leaves out keeps the app's signed URL. The
  core floor is `>= 2.64.0` for it.
- **IMPROVEMENT - MEDIUM: `ProjectShowLive` loads each expanded child's whole
  descendant forest** — **Fixed in this sweep.**
  `Projects.assignments_by_project/2` takes `depth: 1` (the given projects'
  own rows, one statement), and the page passes it
  (`batched_tree_summaries_test.exs`).
- **NITPICK: roles are still one `Roles` read each** — **Fixed in this
  sweep:** one grouped read of core's role assignments for the counts and
  one of its roles for the names (`Grants.role_member_counts/1`,
  `Grants.role_names/1`).
