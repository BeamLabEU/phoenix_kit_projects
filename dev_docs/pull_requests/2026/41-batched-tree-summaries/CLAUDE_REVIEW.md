# Claude (Sonnet 5.5) review — PR #41, after the merge (2026-10-14)

PR #41 (`mdon/feat/batched-tree-summaries`, merge `348caed`): the 2026-09-05 N+1
audit — `Projects.assignments_by_project/1` (one read per depth level),
`project_tree_summaries/1`, `ScheduleLayout.trees/1`, `Extensions.enabled_map/1`,
`Features.flags/1` / `gates/1` over one context, `Grants.subject_reaches/1`,
`People.names_by_uuid/2`, `Portal.review_details_for/1`,
`Attachments.download_urls/1`, `list_all_dependencies/1` on a list, and the
LiveViews/widgets that now call them. Reviewed against HEAD (`7920a5e`) and core
2.62.2, because a batched form restates a rule the per-item form owns, and the
rule can move underneath it.

## Verified, no change needed

- **`load_forest/3` bounds hold.** Level `d` is read for `d = 0..31`; the
  builders descend while `depth + 1 < 32`, so a built node's assignments were
  always read. A project that is both a root and another root's descendant is
  loaded at its shallowest level, which has at least as many hops left as any
  later occurrence.
- **Cycle guards.** `path` in both `build_tree_node` and `collect_items` skips a
  link back to an ancestor; `load_forest` never re-reads a uuid already in `acc`.
- **Batched == per-item**, checked against the per-item code: `enabled_map/1` vs
  `enabled?/3` (unknown key false, unavailable false, explicit row wins, else the
  catalog default), `subject_reaches/1` vs `subject_reach/2` (membership count;
  department = memberships of its teams; role = `users_with_role` length),
  `review_details_for/1` (earliest submission, pinned with an `order_by`).
  `list_assignments/1` carries the same `accepted` filter and order as the forest.
- **Fail-closed rescues.** `gates/1` / `flags/1` / `enabled_map/1` fall back to
  all-false / empty, never to "on".
- `Features.on?/2` now reads the extension map even for an unknown flag key
  (one `list_rows/1`); harmless.

## Fixed

- **BUG - MEDIUM: `Attachments.download_urls/1` restated core's URL rule as it
  was, and core has since moved.** It returned `Manager.public_url(path) ||
  signed_url` for every file with an original instance. Core 2.62.2's
  `Storage.get_public_url/1` returns **nil for a `system_managed` file** (an
  edited image's hidden unedited original), serves the **app's signed route, not
  the bucket's object URL, while an image edit is pending/failed**, and **never
  hands a private-library file the bucket URL**. So the Files page, which used to
  ask core per row, could show a download link for a hidden original and link a
  private-library or mid-edit file straight at the bucket. Impact is bounded
  (the files are ones the project attached) but it is a privacy rule, and the
  batched form had no test at all. Now: system-managed → no link; an edit in
  progress or a private library (`Libraries.private_among/1`, one query for the
  page's libraries — core's own batched form) → the signed route; else the
  bucket URL or signed. A core without `private_among/1` falls back to
  `download_url/1` per file. `batched_reads_test.exs` pins the batched answer
  against `download_url/1` for an ordinary, a mid-edit, a system-managed and a
  private-library file, and that the module's own reads do not grow with the
  files.

## Noted, not changed

- **IMPROVEMENT - MEDIUM: `Manager.public_url/2` still resolves the bucket per
  file** (four statements each on a configured bucket). Core has no batched
  form; the Files page's list is capped at 200. The instance read, which was the
  per-row twice-per-render read, is batched.
- **IMPROVEMENT - MEDIUM: `ProjectShowLive` loads each expanded child's whole
  descendant forest** (`assignments_by_project/1` follows links to depth 32) and
  uses only the child's own rows. Fewer statements than one `list_assignments/1`
  per child for shallow trees, more rows loaded than needed for deep ones. A
  `depth:` option on the loader would stop it at the roots; not worth it until a
  project nests deeply with several children expanded.
- **NITPICK: roles are still one `Roles` read each** in `subject_reaches/1` and
  the members page's labels (core has no batched form; AGENTS.md already lists
  it as known and left).
