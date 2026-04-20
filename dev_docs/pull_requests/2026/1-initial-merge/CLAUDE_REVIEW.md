# Code Review: PR #1 — Initial Merge

**Reviewer:** Claude
**Date:** 2026-04-20
**PR:** https://github.com/BeamLabEU/phoenix_kit_projects/pull/1
**Scope:** 6297 additions / 1 deletion across 40 files — entire initial codebase (schemas, context, LiveViews, tests, scaffolding)

---

## BUG - HIGH

### 1. Database queries in `mount/3` across every LiveView — Iron-Law violation

**Files:** `lib/phoenix_kit_projects/web/overview_live.ex`, `projects_live.ex`, `tasks_live.ex`, `templates_live.ex`, `project_show_live.ex`, `project_form_live.ex`, `template_form_live.ex`, `task_form_live.ex`, `assignment_form_live.ex`

`mount/3` is invoked **twice** for every page load (HTTP render + WebSocket connect). Every DB query in `mount` therefore runs twice. Examples:

- `OverviewLive.mount` → `reload/1` fires ~7 queries (`count_tasks`, `count_projects`, `count_templates`, `list_active_projects`, `project_summaries`, `list_recently_completed_projects`, `list_upcoming_projects`, `list_setup_projects`, `list_assignments_for_user`, `assignment_status_counts`). That's ~14 queries per dashboard visit.
- `ProjectShowLive.mount` calls `get_project/1` and `load_assignments/1` (two more queries) unconditionally.
- All form LiveViews call `apply_action` from `mount`, which fetches the record and staff options.

**Fix:** move DB work to `handle_params/3`. Keep `mount/3` to setup only (empty assigns, `if connected?(socket), do: subscribe(...)`, loading flags). `handle_params/3` runs once per navigation.

---

### 2. `would_create_cycle?` is TOCTOU — concurrent inserts can still produce cycles

**File:** `lib/phoenix_kit_projects/projects.ex:702-756`

`add_dependency/2` walks existing edges, sees no cycle, then inserts. Two concurrent requests adding `A → B` and `B → A` can both pass the check (each sees an acyclic state), then both insert. Now the graph has a cycle.

The unique constraint on `(assignment_uuid, depends_on_uuid)` only catches duplicate identical pairs — it does not catch cycles introduced by different edges.

**Fix:** run the cycle check inside a transaction with `SELECT … FOR UPDATE` on the relevant rows, or wrap the insert in a serializable transaction. At minimum, document the limitation and add a background cycle-validation sweep.

---

### 3. PubSub topics are not tenant-scoped

**File:** `lib/phoenix_kit_projects/pub_sub.ex`

Topics (`projects:all`, `projects:tasks`, `projects:templates`, `projects:project:<uuid>`) are global. If PhoenixKit is ever run in a multi-tenant configuration (a direction the parent project clearly supports via Scopes), project mutations in one tenant will fan out to subscribers in other tenants — a data-leak vector per the Phoenix Scopes pattern (OWASP A01 Broken Access Control).

**Fix:** thread the `Scope` / `organization_id` through topics: `"projects:org:#{org_id}:all"`. Raise if scope is missing. The project-UUID topic is safe against *leaking* (you need the UUID), but the `:all`/`:tasks`/`:templates` topics are not.

---

## BUG - MEDIUM

### 4. `assignment_status_counts/0` includes archived projects

**File:** `lib/phoenix_kit_projects/projects.ex:296-306`

The query filters `p.is_template == false` but not `p.status == "active"`. Archived projects contribute to the dashboard's "Tasks todo / in progress / done" stats, inflating the displayed workload. Compare with `list_active_projects/0` (lines 245-254) which correctly filters `status == "active"`.

**Fix:** add `where: p.status == "active"` to match the dashboard's intent.

---

### 5. Template name collides with project name via shared unique constraint

**File:** `lib/phoenix_kit_projects/schemas/project.ex:47-50`

`unique_constraint(:name, name: :phoenix_kit_projects_name_index, ...)` is enforced across both templates and real projects (same table, same index). Cloning a template named "Onboarding" into a project also called "Onboarding" will fail the unique constraint, and `create_project_from_template/2` has no automatic name mangling — the caller has to pick a distinct name.

**Fix:** either (a) index name uniqueness only within `is_template = false` (partial index) and only within `is_template = true`, so a template and a project can coexist with the same name; or (b) document the constraint in `create_project_from_template/2`.

---

### 6. `apply_template_dependencies/1` swallows failures the LiveView can't surface

**File:** `lib/phoenix_kit_projects/projects.ex:128-136`, callers in `assignment_form_live.ex:261, 301`

The transaction may roll back with `{:error, changeset}`. The LiveView discards the return value and always flashes success. The user thinks the assignment plus template deps were created — when in reality only the assignment persisted.

**Fix:** inspect the return value; log or put_flash a warning when template-dep cloning fails. Alternatively make `create_assignment/1` itself apply template deps inside its own transaction (callers wouldn't have to remember to call it).

---

### 7. `OverviewLive` reloads the entire dashboard on every `:all` event

**File:** `lib/phoenix_kit_projects/web/overview_live.ex:42-45`

`handle_info({:projects, _event, _payload}, socket) → reload(socket)` refires ~10 queries on any mutation anywhere (including another user renaming a task in a distant project). With multiple admins active this becomes an N-by-M query amplifier.

**Fix:** compute the minimal assign delta for each event type (e.g. `:task_updated` needs no overview refresh), or throttle (`Phoenix.LiveView.send_update_after` pattern / debounce `reload/1` calls).

---

## IMPROVEMENT - MEDIUM

### 8. `count_assignments/1` is dead code

**File:** `lib/phoenix_kit_projects/projects.ex:666-670`

Not referenced from any LiveView, test, or other context function.

**Fix:** remove it, or add the call site that was intended.

---

### 9. `Dependency.changeset/2` — `unique_constraint` fields + name are redundant

**File:** `lib/phoenix_kit_projects/schemas/dependency.ex:32-35` and `task_dependency.ex:32-35`

`unique_constraint([:assignment_uuid, :depends_on_uuid], name: :phoenix_kit_project_dependencies_pair_index, ...)` — when `:name` is given, the list of fields is used only to select which field key the error is attached to. Passing both the pair and the name suggests the pair is enforced, when really the DB index determines enforcement. Either pass a single field (`:depends_on_uuid`) and the named constraint, or drop the explicit name and rely on the default from the field list.

---

### 10. `test_helper.exs` shells out to `psql` to detect the DB

**File:** `test/test_helper.exs:23-36`

`System.cmd("psql", ...)` fails when `psql` isn't on `$PATH` (common in containerized CI where the Postgrex client is installed but not the Postgres CLI). The code falls back to `try_connect`, but the `psql`-based check is brittle noise.

**Fix:** always attempt `TestRepo.start_link/0` and rescue connection errors — the rescue block already handles the "DB not reachable" case correctly.

---

### 11. `OverviewLive.mount` manually extracts `user_uuid` — duplicates `Activity.actor_uuid/1`

**File:** `lib/phoenix_kit_projects/web/overview_live.ex:14-18` vs `lib/phoenix_kit_projects/activity.ex:31-36`

Same case-on-assigns logic is written twice. `ProjectShowLive` has a third local copy (`actor_uuid/1` at line 181).

**Fix:** consolidate on `PhoenixKitProjects.Activity.actor_uuid/1`.

---

### 12. `remove_dependency` event calls `scoped_assignment/2` twice

**File:** `lib/phoenix_kit_projects/web/project_show_live.ex:384-402`

Two round-trips to `get_assignment/1` to verify both endpoints belong to the current project. A single `Repo.all` filtering both UUIDs at once would halve the query count.

---

## NITPICK

### 13. Missing scaffolding files (now added in this review branch)

The PR as originally opened did not include `LICENSE`, `CHANGELOG.md`, the strict `.credo.exs` used by other PhoenixKit siblings, or the extended `.gitignore` (no `/cover/`, no `*.plt`, no tarball exclusion). The `package.files` entry in `mix.exs` also listed only `LICENSE`, missing `README.md` and `CHANGELOG.md` which would have broken `mix hex.publish`. These have been brought in line with `phoenix_kit_posts` / `phoenix_kit_entities` alongside this review.

### 14. `Assignment.changeset` — `check_constraint` and `validate_single_assignee` duplicate the same user-facing message

**File:** `lib/phoenix_kit_projects/schemas/assignment.ex:95-120`

Both the DB check constraint and the pre-insert validation emit `"only one of team, department, or person can be assigned"`. Intentional (one for concurrent inserts, one for fast UI feedback), but the message only needs to live in one place — extract a module attribute.

### 15. `error_summary/2` renders raw validator messages without gettext

**File:** `lib/phoenix_kit_projects/web/project_show_live.ex:137-147`

`{m, _}` is the raw validation message ("is invalid", "must be greater than 0"). These are untranslated English strings, inconsistent with the rest of the UI which is routed through `gettext/1`.

### 16. `Project.changeset` — `counts_weekends` is optional but has a non-nil schema default (`false`)

**File:** `lib/phoenix_kit_projects/schemas/project.ex:25, 37`

Not a bug, but the `@optional ~w(counts_weekends ...)a` allows the caster to set it to `nil`, which then won't match the Ecto default. Callers (e.g. `clone_template`) explicitly pass `to_string(template.counts_weekends)`, so this currently works — but `validate_required(:counts_weekends)` would be more honest.

### 17. `Projects.list_assignments_for_user/1` — good pattern, document the degradation

**File:** `lib/phoenix_kit_projects/projects.ex:312-336`

The `rescue [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError]` around the staff lookup is exactly the pattern AGENTS.md describes (staff outage should not take the projects UI down). Worth a short `@doc` line calling this out so future maintainers don't "clean it up".

---

## What Works Well

- **Mass-assignment split (`changeset/2` vs `status_changeset/2`)** — excellent defense-in-depth. `completed_by_uuid` and `completed_at` can only be set by server-trusted code paths (`complete_assignment`, `reopen_assignment`, `do_update_progress`), and the `_form` suffix on `update_assignment_form/2` is a deliberate smell flag. AGENTS.md documents the rationale clearly.

- **Polymorphic assignee enforcement at two layers** — `validate_single_assignee/1` in the changeset for fast UI feedback, plus a DB `CHECK (num_nonnulls(...) <= 1)` constraint for concurrent-insert safety. Matches the Ecto-thinking rule of validating at both the boundary and the storage layer.

- **`scoped_assignment/2`** — every mutation event in `ProjectShowLive` validates that the target assignment belongs to the currently-viewed project before acting. Protects against crafted WebSocket messages (OWASP Broken Access Control).

- **`project_summaries/1` batches counts in one query** — no N+1 on the dashboard. Contrast with the naive `Enum.map(projects, &project_summary/1)` that would have been tempting.

- **Template cloning in a single `Repo.transaction`** — project, assignments, and dependencies either all land or none do. The two-phase clone (build a uuid_map from old→new, then translate dep edges) is the clean way.

- **Cross-context staff lookups guarded with `rescue`** — follows the "hard dep but isolate from outages" pattern from AGENTS.md.

- **Integration test suite covers the interesting transitions** — assignment state, dependency cycle rejection, template clone, broadcasts. The test_helper cleanly skips integration tests when Postgres is unreachable.

- **Schedule math with per-task `counts_weekends` override and velocity-based projection** — thoughtful; handles "weekend work counts toward velocity even in weekdays-only projects" as documented.

- **Activity logging at the LiveView layer, not the context layer** — keeps contexts pure (`{:ok, _} | {:error, _}`) and localizes the `actor_uuid` lookup where it naturally lives.

---

## Verdict

**Approve with follow-ups.** This is a solid initial merge — the mass-assignment guards, scoping, polymorphic assignee enforcement, and batched summary query show unusual care for a v0.1 drop. The items above are real but none block merge; #1 (mount queries) and #3 (tenant-scoped PubSub) are the ones I'd prioritize for the next PR.
