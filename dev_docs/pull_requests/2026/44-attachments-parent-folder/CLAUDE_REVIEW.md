# PR #44 — Project folders under a host-configured parent

**Reviewed:** 2026-09-15 · **Author:** timujinne · **Verdict:** merged; fixes
applied post-merge, shipped in 0.25.1.

+494 / −39 across 3 commits (`11fb1e9`…`d483dc0`), landed via merge `3007652`.
The PR bumped `@version` to 0.25.0, which was never published; its fixes and
the ones below ship together as 0.25.1.

## What it does

Adds two host hooks to `Attachments` — `:attachments_parent_folder` (which
folder a project's folder lives under) and `:attachments_folder_name` (what it
is called) — with a four-step read-only resolution (host-name-under-parent →
deterministic-under-parent → deterministic-at-root → deterministic-anywhere)
so legacy root `project-<uuid>` folders are reused rather than twinned. Threads
an actor uuid through `folder_uuid` / `ensure_folder` / `list_files` /
`attach_files` (a created folder's `user_uuid`). Portal submission images are
now placed in `<project folder>/Portal submissions/`.

## Findings

### BUG - HIGH — Folder identity is the `{parent, name}` pair; a shared parent plus a constant host name merges projects

`find_resource_folder/2` accepts the first live folder named `host_name` under
`parent` as the project's folder. Core's `Folder` records no owning resource,
so nothing distinguishes project A's folder from project B's. A host whose
parent hook answers a shared container and whose name hook answers a constant
(the PR's own test `Hook` does exactly this: every project → `"Project"` under
one `"Projects"` folder) makes the second project resolve — and attach into —
the first project's folder. Each Files page then lists the other project's
files to that project's members: a cross-project exposure. The create-race
retry path reaches the same wrong folder.

**Not fixed in code — documented.** A real fix needs an ownership marker on the
folder; core's schema has none, and stamping `description` (the only free
text column) would be visible and editable in the media browser. The contract
— "the pair must be unique per project" — is now stated in the moduledoc and
the CHANGELOG. The intended host shape (a per-sub-order parent with a fixed
name) is safe. If a host needs a shared container, the right follow-up is an
owner reference on core's `Folder`, not a workaround here.

### BUG - MEDIUM — `remove_file/2` resolved the folder without the actor

`list_files/2`, `attach_files/3` and `ensure_folder/2` got the actor;
`remove_file/2` did not. With an actor-dependent parent hook and a host name,
the Files page listed a file from the actor's folder, then removal resolved
with `nil` actor, found no folder, returned `:ok` as a no-op — and the page
flashed "File removed." while the file stayed.

**Fixed:** `remove_file/3` takes the actor (and a loaded `%Project{}`);
`ProjectFilesLive` passes it. Test: `remove_file/3 resolves the same
actor-dependent folder list_files/2 does`.

### BUG - MEDIUM — Lookups could return a trashed folder

Core's `phoenix_kit_media_folders_name_parent_idx` is partial
(`WHERE trashed_at IS NULL`), so a trashed folder and a live one with the same
name/parent coexist. `find_folder_under/2` had no `trashed_at` filter (unlike
the PR's own `find_folder_anywhere/1` and `Portal.find_child/2`) and `limit: 1`
without ordering — so after someone trashed a project folder in /admin/media,
Projects kept resolving and attaching into the trashed one, where the media
browser hides everything. Pre-existing for the root lookup (the removed
`get_folder/1`), widened by the PR to the parent lookups.

**Fixed:** both clauses filter `is_nil(trashed_at)`. Test: `a trashed project
folder is never reused; ensure_folder/2 makes a live one`.

### BUG - MEDIUM — Portal placement was not actually best-effort

`place_in_project_folder/3` is documented "best-effort: the submission is saved
even if the folder cannot be resolved", but only handled non-`:ok` returns.
`find_child/2` has no rescue; a raise propagated through `store_one_attachment`
(its `try` has only `after`) to `take_attachments/2`'s rescue, which refuses
the whole report as `{:error, :invalid}` — and the file stored a moment
earlier is never passed to `discard_stored/1`, so it is orphaned. On a public,
account-less endpoint.

**Fixed:** `rescue` + `catch :exit` on `place_in_project_folder/3`. No test —
there is no seam to inject a DB raise into `find_child/2` without mocking the
repo; the change is a two-clause rescue.

### IMPROVEMENT - MEDIUM — CHANGELOG described behaviour the code doesn't have

The 0.25.0 entry said unconfigured installs keep "exactly today's behaviour"
and that portal images go into the project folder "when the parent hook
resolves a folder". In fact `place_in_project_folder/3` runs for every
submission with a project, hooks or not: every install now gets a root
`project-<uuid>` folder with a `Portal submissions` child on the first report
with an image. That behaviour is reasonable (and matches the PR title), so it
stays; the entry is corrected and a test pins the unconfigured shape (`portal:
with no hooks configured, a submission still lands under
project-<uuid>/Portal submissions`).

### IMPROVEMENT - MEDIUM — The Files page re-read the project on every load

`load_files/1` passed `project.uuid` to `list_files/2`, which (via
`load_project/1`) re-fetched the row it already had in assigns — on mount
(twice, disconnected + connected), and after every add/remove. `remove_file`
and `attach_files` did the same. **Fixed:** the LV passes the loaded struct to
all three; the specs accept `binary() | Project.t()`.

Left as is: mount still resolves the folder twice (the `folder_uuid` assign,
then `list_files`). That is two runs of at most four indexed single-row reads,
not a per-item read, and folding them would change `list_files`' public shape.

### NITPICK — A raising name hook blanked the Files page (fixed)

`parent_folder_uuid/2` rescued a raising hook back to "no parent", but
`folder_name/2` had no rescue: a host bug surfaced as `folder_uuid/2` → `nil`
(an empty Files page even though the deterministic folder existed) and
`ensure_folder/2` → `{:error, _}`. Now falls back to the deterministic name,
and both hooks also `catch :exit`. Test: `a raising name hook falls back to
the deterministic name`.

### NITPICK — Duplicate actor helper (fixed)

`ProjectFilesLive` gained `current_user_uuid/1`, a copy of
`Activity.actor_uuid/1` that the same file already calls. Replaced.

### NITPICK — `project!/1` returned `nil` (fixed)

A bang name promises a raise; it returned `nil` for a missing project (which
callers rely on). Renamed `load_project/1`.

### NITPICK — DataCase test outside `integration/` (fixed)

`attachments_parent_folder_test.exs` uses `DataCase` but sat in
`test/phoenix_kit_projects/`; moved to `integration/` per AGENTS.md.

### NITPICK — `%Folder{}` in a `@spec` failed `credo --strict` (fixed)

`find_resource_folder/2`'s spec returned `%Folder{} | nil`, which
`Credo.Check.Warning.SpecWithStruct` flags — so `mix precommit` stopped at
credo and dialyzer never ran on the merged PR. Core's `Folder` defines no
`t()` type, so the spec is now `struct() | nil`.

### NITPICK — Portal resolves the project folder once per image (not fixed)

`place_in_project_folder/3` runs `ensure_folder/2` + `ensure_child/3` per
stored file. Bounded at `@attachment_max_count` (3), and only after the
honeypot, fill-time and rate-limit gates; hoisting it would thread folder
state through the all-or-nothing reduce for a negligible saving.

## Verified independently

- **Hooks-off resolution matches the old behaviour** except the two intended
  changes (trashed folders skipped; a deterministic folder under any parent is
  found last): with no parent, steps 1–2 short-circuit on `nil` and step 3 is
  the old `get_folder/1` query.
- **The create-race retry** re-resolves with the bare `%Project{}` after the
  `{:ensure, …}` call has had the chance to build the parent chain, so a
  read-only hook sees the parent that now exists.
- **`Storage.attach_file_to_folder/2`** (core) adopts a homeless file, no-ops on
  its own home, and links a file homed elsewhere — so placing a portal image
  never moves a file out of another folder.
- **Whiteboards** threads `board.created_by_uuid`, which may be `nil`;
  `ensure_folder/2` only sets `user_uuid` when an actor is present.
- **Staff reference**: `phoenix_kit_staff`'s `Attachments.find_or_create/3` is
  the same find → create → re-resolve shape, so the portal's `ensure_child/3`
  bounded retry is consistent with it.

## Gate

`mix precommit` clean; full `mix test` against a live Postgres (DB-backed
tests included, none excluded).
