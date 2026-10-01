# Follow-up Items for PR #44

Triage of `CLAUDE_REVIEW.md` against the current code on `main`
(2026-10-01). Most findings were fixed in the post-merge commit `7abaf41`
(0.25.1). Since then PR #46 (`11447d5`) moved the folder convention into
core's `PhoenixKit.Modules.Storage.ResourceFolders`, so several fixes now live
in core; each was re-checked there.

## Fixed (pre-existing)

- ~~**BUG - MEDIUM — `remove_file/2` resolved the folder without the
  actor**~~ — `attachments.ex:272-286`: `remove_file/3` takes the actor and
  resolves through `folder_uuid/2`; `web/project_files_live.ex:134-137`
  passes `Activity.actor_uuid(socket)`. Commit `7abaf41`.
- ~~**BUG - MEDIUM — Lookups could return a trashed folder**~~ — resolution
  now runs through core `ResourceFolders.resolve/1` (`attachments.ex:132-139`),
  whose `find_under/2` and `find_named_all/3` both filter
  `is_nil(f.trashed_at)` (core `resource_folders.ex:286`, `:317`). The
  portal's own `find_child/2` filters it too (`portal.ex:773-779`).
- ~~**BUG - MEDIUM — Portal placement was not actually best-effort**~~ —
  `portal.ex:723-746`: `place_in_project_folder/3` has `rescue` and
  `catch :exit`, both answering `:ok`. Commit `7abaf41`.
- ~~**IMPROVEMENT - MEDIUM — CHANGELOG described behaviour the code doesn't
  have**~~ — `CHANGELOG.md` 0.25.0 entry now says portal images are placed
  "on every install, hooks or not". Commit `7abaf41`.
- ~~**IMPROVEMENT - MEDIUM — The Files page re-read the project on every
  load**~~ — `web/project_files_live.ex:71`, `:110`, `:119`, `:134`, `:170`
  pass the loaded `%Project{}`; `load_project/1` short-circuits on a struct
  (`attachments.ex:106`).
- ~~**NITPICK — A raising name hook blanked the Files page**~~ —
  `attachments.ex:114-117` uses core `ResourceFolders.host_name/3`, which logs
  a hook failure and answers `nil` (deterministic name); core's `guarded/1`
  rescues and catches every kind (`resource_folders.ex:222-229`).
- ~~**NITPICK — Duplicate actor helper**~~ — `ProjectFilesLive` has no
  `current_user_uuid/1`; it calls `Activity.actor_uuid/1` throughout.
- ~~**NITPICK — `project!/1` returned `nil`**~~ — renamed `load_project/1`
  (`attachments.ex:106-107`).
- ~~**NITPICK — DataCase test outside `integration/`**~~ — now
  `test/phoenix_kit_projects/integration/attachments_parent_folder_test.exs`.
- ~~**NITPICK — `%Folder{}` in a `@spec` failed `credo --strict`**~~ —
  `attachments.ex:124-125` returns `struct() | nil`.

## Files touched

None — documentation only.

## Verification

- Read `attachments.ex`, `portal.ex` (placement and `find_child/2`),
  `web/project_files_live.ex`, and the 0.25.0 / 0.25.1 `CHANGELOG.md`
  entries.
- Read core `lib/modules/storage/resource_folders.ex` (`host_name/3`,
  `resolve/1`, `find_under/2`, `find_named_all/3`, `guarded/1`) in the
  workspace checkout; the lock pins core 2.40.1.
- Located the moved test file; `git log --grep "#44"` for the fix commit.

## Open

All awaiting Max's decision.

- **BUG - HIGH — Folder identity is the `{parent, name}` pair; a shared parent
  plus a constant host name merges projects.** `attachments.ex:132-139`
  calls `ResourceFolders.resolve/1` with no `:pointer` and no `:claimed?`, so
  two projects whose hooks answer the same parent and the same name share one
  folder and each Files page lists the other's files. Only documented
  (moduledoc `attachments.ex:40-45`, CHANGELOG), not fixed in code. Note: core
  now offers a `:claimed?` / `:pointer` mechanism (`resource_folders.ex:340-
  376`), but projects stores no folder pointer to use it with.
- **IMPROVEMENT - LOW — Files page mount resolves the folder twice.**
  `web/project_files_live.ex:71` (`folder_uuid` assign) and `:110`
  (`list_files/2` resolving again). The review left it as is (two runs of at
  most four indexed single-row reads).
- **NITPICK — Portal resolves the project folder once per image.**
  `portal.ex:713` calls `place_in_project_folder/3`, which runs
  `ensure_folder/2` + `ensure_child/3` (`portal.ex:723-726`) per stored file;
  bounded at the attachment max count (3). The review left it as is.
