# PR #46 — Project files on core's ResourceFolders; actor and activity through core

**Reviewed:** 2026-09-26 · **Author:** Dmitri Don (mdon) · **Verdict:** merged;
one nitpick fixed post-merge, nothing blocking.

31 files, +4481 / −5470, landed via merge `8484e6e` (the bulk of the churn is
the `.po` re-sort and the ~1100-line `MediaReorganizer` collapsing onto core).

## What it does

- Raises the core floor to `>= 2.38.0 and < 3.0.0` and drops every
  feature-detection shim that floor makes dead: `Attachments` now delegates
  the folder convention (resolve / ensure / list / attach / detach) to
  `Storage.ResourceFolders`; `MediaReorganizer` becomes a declaration fed to
  `Reorganizer.ResourceSource`; `file_icon/1` delegates to `Utils.Format`;
  `media_reorganizer/0` gains its `@impl`.
- `Activity.log/2` / `log_failed/2` call core's `PhoenixKit.Activity.log/3` /
  `log_failed/3`; `actor_uuid/1` delegates to `PhoenixKitWeb.Actor.uuid/1`
  (scope first, then the bare user). The context-layer `log_activity/1` in
  `Projects` drops its local rescue.
- Edit forms open on the viewing language (`mount_multilang(open_on:)`).
- Edit-page trails follow core's admin-header-trail guide: the record is a
  crumb, the leaf is "Edit"; the drawer (no trail) keeps a naming `heading`
  via `keep_host_title/1` preferring a pre-assigned `:heading`.

## Verification

- `PhoenixKit.Activity.log/1` (core 2.40.1 in the lock) rescues everything and
  catches `:exit` / `:throw`, and `log/3` answers a malformed call with
  `{:error, :invalid_arguments}` — the removed local rescue was redundant, not
  load-bearing. Only observable change: a sandbox-ownership error in a test now
  logs a warning instead of being silently swallowed.
- `PhoenixKitWeb.Actor.uuid/1` handles a socket, a bare assigns map and `nil`;
  a scope whose user is nil falls through to `:phoenix_kit_current_user`, so the
  embedded path (`assign_embed_user/2`, no scope) still resolves the actor.
- `ResourceFolders.detach/2` is documented never to raise and `folder_uuid/2`
  keeps its rescue + `:exit` catch, so `remove_file/3` losing its local rescue
  cannot crash `ProjectFilesLive`.
- `keep_host_title/1`: in navigate mode `<.page_header>` hides its `<h1>`, so
  the admin header's "…/Name/Edit" trail is not doubled by "Edit Name"; in a
  drawer the heading still names the record. No `:new` path pre-assigns
  `:heading`, so the `||` never picks a stale value.
- Template edit now uses `Crumbs.under_project/3`, whose template clause yields
  `Templates / <name>` — correct.
- Gate: `mix precommit` clean; `mix test` 1608 tests, 0 failures (Postgres up,
  nothing excluded); `WITHOUT_STAFF=1 mix compile --warnings-as-errors` clean.

## Findings

### NITPICK — Doc comment stranded above the wrong function (fixed)

The new `child_crumbs/2` / `task_crumbs/1` / `edit_titles/1` helpers in
`AssignmentFormLive` were inserted between `assignee_kind/1` and its comment
("Which assignee `<select>` is active…"), so that comment now headed the crumb
helpers' comment block. Moved back above `assignee_kind/1`.

### NITPICK — Sub-project edit crumb is not `Authz`-filtered (left)

`Crumbs.project/3` drops ancestors the viewer cannot `:view`, but the new
`child_crumbs/2` links the linked child unconditionally. Not a new exposure:
the same name was already the page title before this PR, and the form itself
edits the child's fields, so anyone on it already sees the child. Left as is;
revisit if the sub-project form ever becomes reachable by someone without
access to the child.

### NITPICK — `ensure_folder/2` rescues but does not catch `:exit` (left)

`folder_uuid/2` catches `:exit`, `ensure_folder/2` only rescues. It was the
same before the PR, and `ResourceFolders.ensure/4` guards its own DB work, so
not worth a change here.
