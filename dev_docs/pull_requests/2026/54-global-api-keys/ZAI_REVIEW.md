# Zai review of V24 (global API keys)

`zai` (GLM-5.3 through Claude Code, Bash/Write/Edit denied), trusted workspace with the snapshot as a subdirectory, 2026-10-16. Same brief as codex's first round.

All the evidence is in. Here is the review.

---

# Review: V24 global API keys (`phoenix_kit_projects`)

## 1. LEAKS

**LEAK — `GET /hours` sums time across sub-projects that are outside the key's reach.**

`hours_controller.ex:29`:
```elixir
          project_uuids: Hours.project_uuids(project.uuid, opts.include_subprojects),
```
`hours.ex:116-117`:
```elixir
  def project_uuids(project_uuid, include_subprojects?) when is_binary(project_uuid) do
    if include_subprojects?, do: Projects.subtree_uuids(project_uuid), else: [project_uuid]
```
`subtree_uuids` is the raw descendant walk — no grant, no `within_reach?` anywhere between here and `Hours.summary`. `include_subprojects` defaults to **true** (`hours_controller.ex:94`: `boolean(params["include_subprojects"], "include_subprojects", true)`), and the moduledoc's claim is false:

> `hours_controller.ex:8-9` — "and by default everything nested under it (`include_subprojects`, every such project being within the same reach)"

Failing input:
- Projects `A` → child `S` (linking assignment in `A`). `S` has 600 minutes of people's time and a task "Payroll review".
- Key `K`, shared, one grant on `A`: scopes `["time:read"]`, `inherit: false` (the "Covers its sub-projects" checkbox, `api_keys_live.ex:484`), or — same effect — a nearest grant on `S` with `scopes: []` ("no access").
- `access_for(K, S)` → `{:error, :no_access}` (verified: `api_keys.ex:259-260` `"%ApiKeyGrant{inherit: false} -> {:error, :no_access}"`).
- `GET /hours` with `K` (home `A`): `require_scope("time:read")` passes on `A`'s view, then the filter is `subtree_uuids(A) == [A, S]` → the answer includes `S`'s minutes per worker, per day, and with `group_by=task` the rows carry `S`'s task titles and `project_uuid`. Pre-V24 this was consistent (a key's reach *was* "its project and the sub-projects under it"); V24's `inherit=false` / empty-grant broke the equivalence the comment still asserts.

**Exposure (site-wide data through one project's grant) — `GET /people`.**

`people_controller.ex:16`:
```elixir
      {:ok, conn} <- Json.require_scope(conn, "people:read"),
```
followed by `people_controller.ex:23` `people = People.list_people()` — the whole site's people, teams and departments, gated only by `people:read` on the **home** project's view. A key granted `people:read` on exactly one project reads the entire staff directory (names + uuids). Not project-scoped at all, and there's no `project` param, so the flip side is also true: a key whose home grant lacks `people:read` but whose grant on another project has it is refused. Names-only, so weight it as design note, not a breach.

**Checked, sound on the rest of Q1:**
- Task/entry/note/comment-derived paths all resolve first: `TasksController.fetch/2` (`tasks_controller.ex:1162-1167` — `within_reach?` → `rescope` → `still_allowed` → `require_feature`), `LedgerController.own_entry/2` (`ledger_controller.ex:244-249`, comment "The entry's project's access decides (V24), not the home's."). `NotesController`, `CommentsController`, `LedgerController.task_*` go through `fetch`.
- `Json.require_scope/2` reads the rescoped view: `json.ex:63` `if ApiKey.scope?(conn.assigns.pk_api_key, scope),` — and `rescope/2` swaps in `ApiKeys.view/2` (`json.ex:127-131`), failing closed to `%{key | role: nil, scopes: []}`.
- `LedgerController.any_write_scope/1` does read the key's grants **globally** (`ledger_controller.ex:215-217`) — but deliberately, before the row is found, and the deciding check `require_scope(conn, entry_scope(entry))` runs after `own_entry`'s rescope. Correct.
- `Auth`'s `RefText` writer declaration closes over the home-time key struct (`auth.ex:48`), but `allows?/3` recomputes `access_for` per project, so the closure is reach-correct.
- No raw `key.scopes` read in any request path except `MeController` (labelled "home").
- Note (not new, pre-V24 parity): `Json.project/1`'s `subprojects:` list and the briefing's `brief_subprojects/1` show child names/status/completion through a parent grant even when `inherit=false` — informational only, same as the parent's own page.

## 2. ORDER

**Checked, sound** in both directions for every controller: every action that takes a project resolves it first — `scope_project` (Tasks `index/create/batch`, Notes `project_*`, Ledger `project_*/index`, Hours, Events, Project, Briefing, Ext `prepare`) or `fetch`/`own_entry` (task/entry paths) — and only then `require_scope`. Spot quotes: `tasks_controller.ex:60-61` (`Json.scope_project` → `Json.require_scope(conn, "tasks:read")`), `tasks_controller.ex:253-254` (`fetch` → scope), `ext_controller.ex:86-87`. `still_allowed/1` is wired as the backstop inside both `scope_project` and `fetch`.

Two **wrongly refused** exceptions:

**(a) The interaction walk-up is pre-gated on the *current* project's view.** `tasks_controller.ex:576-578`:
```elixir
      with %{ext: ext, module: provider} <- Extensions.api_provider("interactions"),
           true <- function_exported?(provider, :get, 2),
           true <- ApiKey.scope?(key, provider.scopes().read) do
```
`key` here is the view for the task's project. Failing input: key `K` with grant on child `S` = `["tasks:write"]`, grant on parent `A` = `["interactions:read"]` (the CRM-read-only shape V24's presets exist for), interaction `I` held by `A`'s client. `POST /tasks {project: S, interaction: I, title: "x"}` → `check_interaction` → the `with` fails at the pre-gate → `:error` → 404 "No such interaction on this project or the projects above it" — a message describing a walk (`tasks_controller.ex:579-589`) that this very line prevents from starting. The per-candidate `ApiKeys.allows?(key, p.uuid, provider.scopes().read)` at line 582 already gates each ancestor correctly, so the pre-gate adds nothing but the refusal.

**(b) `PeopleController`** (above) checks the home view with no project resolution at all.

## 3. RESOLUTION (`access_for/2`)

**Checked, sound:** the chain order is right. `projects.ex:3265` documents `parent_chain` as "The ancestors of a sub-project, ROOT FIRST", and `api_keys.ex:244-247` reverses it before prepending the project, so `Enum.find_value` walks nearest-first:
```elixir
    chain = [
      project_uuid
      | project_uuid |> Projects.parent_chain() |> Enum.reverse() |> Enum.map(& &1.uuid)
    ]
```
Nearest-grant-wins, `inherit: false` cutting off everything above, empty scopes on the nearest grant (including the project's own) = no access, `weaker/2` clamping a personal key to ≤ manager even when the person is `:owner` — all verified against the clauses at `api_keys.ex:249-264` and `386-388`.

**Gets wrong / surprising:**

**(a) Removing a person from project `P` does not end their API access to `P` when an inherited grant re-opens it.** `api_keys.ex:397-400`:
```elixir
    project_uuid
    |> list_for_user(user_uuid)
    |> Enum.each(&delete_grant(&1, project_uuid, opts))
```
Failing input: `X` is member of `A` and of child `P`; `X`'s personal key holds grant on `A` (`inherit: true`, any scopes) and a grant on `P`. Admin removes `X` from `P` (`Members.remove_member` → `revoke_for_user(P, X)` deletes only the `P` grant). Now `access_for(key, P)` finds `A`'s grant, `inherit: true` → `grant_role` reads `effective_role(A, X)` ≠ nil → `{:ok, …}`. The UI denies `X` (Authz resolves `P`'s own memberships) while `GET /tasks?project=P` with their key still answers. The docs frame "the key and its other grants live on" as benign; here the surviving grant is a tunnel back into the project they were removed from.

**(b) Membership is read on the GRANT's project, never the target's.** `api_keys.ex:274-280`:
```elixir
  defp grant_role(%ApiKey{user_uuid: user_uuid}, grant) do
    case Projects.get_project(grant.project_uuid) do
      nil ->
        {:error, :no_access}

      project ->
        case Authz.effective_role(project, user_uuid) do
```
This is documented ("sub-projects usually have no members of their own"), but it means a person who is a full member of the target and not of the grant's project is `:membership_ended` — e.g. their `A`-role came from a team grant that was later removed: every call 403s (including to `S`, where they are manager), until someone deletes the grant by hand; the page just shows "No access here". The UI's `add_grant`/`create_key` restrict options to the person's membership-visible projects (`api_keys_live.ex:91-97`), so the mismatched state mostly arrives via later membership changes — or via `ApiKeys.move/3` from ProjectMove, which relocates a personal key's grant to a project its person may not belong to.

**(c) Archived projects and templates:** `access_for` filters neither — an archived project's keys keep full access (and `/me` honestly flags `archived: true`); template grants can't be created from the UI and `access_for` doesn't special-case them. Checked, acceptable.

**(d) Depth bound:** both walks cap at 8 hops (`projects.ex:3262` `@max_parent_depth 8`), so a grant 9 levels up silently doesn't reach — fail-closed, consistent with `@max_nesting 7` on creation. Note only.

## 4. MIGRATION

**Up — every existing key keeps its access, checked with one narrow exception.**
- Translation (`schema.ex:1156-1166`): `tasks:read` → `project/notes/time/usage/events/people:read`; `tasks:write` → `status:write, notes:write`; `time:write` → `time:read`; `usage:write` → `usage:read`; `project:write` → `project:read`; provider scopes (`interactions:*`) pass through in `k.scopes`. That matches the endpoint matrix (docs table scopes == controllers' `require_scope`), i.e. each old scope keeps exactly the reads it previously implied.
- Sub-project reach preserved: the INSERT omits `inherit`, so the column default applies — `schema.ex:1136` `inherit BOOLEAN NOT NULL DEFAULT true`.
- Keys whose project was deleted can't exist pre-V24: `schema.ex:1006` created the FK `ON DELETE CASCADE`, so `WHERE k.project_uuid IS NOT NULL` covers every key; revoked keys harmlessly receive grants (revocation is checked before access).
- The narrow exception — the replay guard is **per key**, not per (key, project): `schema.ex:1170-1172`:
```sql
      AND NOT EXISTS (
        SELECT 1 FROM #{p}phoenix_kit_project_api_key_grants g WHERE g.api_key_uuid = k.uuid
      )
```
A key can only sit at "home set, zero grants" through a crash between `delete_grant`'s `delete_all` and its home-move (`api_keys.ex:187-198`, two separate writes, no transaction). If that happens, the next chain re-run (which the chain doc says happens wholesale) **resurrects a grant with the key's stale mint-time scopes**. Very low odds, worth knowing.

**Down — restores a usable V23 state, with one honesty gap.** `schema.ex:1193-1212` drops the grants table, deletes NULL-home keys, re-adds `ON DELETE CASCADE` and `SET NOT NULL` — structurally V23. But nothing ever wrote grant edits back to `k.scopes`, so after any V24-era scope/role change on the grants page, a down reverts each key's authorization to its **mint-time** scopes. Given the chain's own "down exists for protocol completeness only" stance, this is a nitpick, not a bug.

## 5. THE PAGE (`web/api_keys_live.ex`)

**Authorization of every `handle_event` — checked, one gap:**

All grant-mutating events funnel through `with_key`/`with_grant` → `editable?` (`api_keys_live.ex:112-117`):
```elixir
    socket.assigns.admin? or
      (is_binary(me) and (key.user_uuid == me or key.created_by_uuid == me))
```
- Non-admin editing someone else's key: only the minter path, and only keys they created (`create_key` sets `user_uuid: me` for personal, so cross-person minting is admin-only). Revoked keys refused (`api_keys_live.ex:302`).
- Granting a project the granter can't see: prevented — `allowed_project/4` (`:321-328`) restricts to the **key's person's** visible projects for personal keys, and to `[]` for shared keys unless admin (`:99-104`), so a non-admin can never add a grant to a shared key.
- Making a shared key: admin-gated — `api_keys_live.ex:128` `shared? = params["kind"] == "shared" and socket.assigns.admin?`.
- Setting a role on a personal key: the handler doesn't check sharedness (`:220-231` accepts any key+grant), but it's harmless — the grant role is only a cap and `weaker/2` (`api_keys.ex:386-388`) takes the weakest of cap / person's role / manager; the UI hides the control on personal keys.
- `set_home` needs an existing grant (`api_keys.ex:215`); `toggle_all` re-checks `admin?` inside `load`.

**The gap:** mutating an **existing** grant of a shared key (`set_preset`, `set_grid`, `set_role`, `toggle_inherit`) — and `rotate`/`revoke` — needs only `editable?`, i.e. **the minter keeps full shared-key powers after losing `admin_all`**, including widening a grant to the "Full" preset on a project they can no longer see. Only *creating* shared keys and *adding* grants to them are admin-gated. If `created_by_uuid` is meant to expire with the admin role, these handlers need the same `admin?` check `grant_options` applies.

**Why "Add a project" resets:** `api_keys_live.ex:527`:
```heex
                value=""
```
The select's choice exists only in the browser — the form is `phx-submit`-only, no `phx-change`, so the server never sees the pick — while the server unconditionally renders the prompt as selected. Change a preset on another row of the same card → `set_preset` → `load()` → the card re-renders, the patch applies the server's markup (prompt selected), and the select snaps back to "Pick a project".

**Other state a re-render loses:** every unsubmitted *select* on the page — the New key form's "Starts in project" (`:392`, `value={@new_project}`, only mount/`handle_params` set it), "Access there" (`:396`, `value="full"`), the admin's "Acts for" / "Shared key's role" (`:399`, `:402`), and each card's add-grant "Access" (`:533`, `value="read"`). What *survives*: `open_grid`, `show_all?`, `api_token` (assigns) and the typed "Name" text input. Also worth knowing: `projects_for/1` uses `list_projects(viewer: me)`, which excludes sub-projects by default and `admin_all`-visibility projects — so the page can only ever grant top-level, membership-visible projects (consistent with a personal key actually working, but the moduledoc's "those they can see" overstates it for admins).

## 6. Anything else

- **Dead code:** `ApiKeys.effective_role/2` (`api_keys.ex:352-360`), `ApiKeys.get_for_project/2` (`:437-448`) and `ApiKeyPanel.personal_attrs/2` (`api_key_panel.ex:82`) have no callers left in `lib/` — V24 superseded all three.
- **Stale/misleading docs:** `api_keys.ex:4` "drive one project over the JSON API" and `:23-25` "the project's whole list is for whoever may `manage_modules`" (the list page is now Projects → API keys; `list_for_project` feeds only ProjectMove's preview); `schemas/api_key.ex:11` cites `ApiKeys.effective_role/2` as the personal-key mechanism; `hours_controller.ex:8-9` (finding 1).
- **`Json.scope_project` swallows a malformed `project` param:** `json.ex:115-117` `_-> {:ok, conn}` — `POST /tasks` with `"project": {}` creates in the HOME project instead of answering 422.
- **`ApiKeys.move/3` silently destroys the destination grant:** `api_keys.ex:623-626` deletes any grant at `to_uuid` before moving the source grant — a tailor-made narrower grant at the destination is replaced wholesale by the moved one, with no log of the loss.

---

## Top findings

1. **LEAK — `GET /hours` reads time data in sub-projects outside the key's reach** (`hours_controller.ex:29` + `hours.ex:117`, no reach filter; `include_subprojects` defaults true). A `time:read`-only grant on a parent with `inherit: false` — or an empty "no access" grant on the child — still gets the child's minutes, worker/day breakdowns and task titles. The moduledoc asserts the opposite.
2. **Removed member keeps API access to the project they were removed from** via an inherited grant (`api_keys.ex:397-400` deletes only that project's grant; `access_for` then falls up to the ancestor's `inherit: true` grant). UI says denied, API says allowed.
3. **Shared-key edit powers outlive the admin role** — `set_preset`/`set_grid`/`set_role`/`toggle_inherit`/`rotate`/`revoke` need only `editable?` (minter), while only create-shared and add-grant are admin-gated (`api_keys_live.ex:112-117` vs `:99-104`, `:128`).
4. **Interaction linking wrongly refused for the exact multi-grant shape V24 enables** — the pre-gate `ApiKey.scope?(key, provider.scopes().read)` (`tasks_controller.ex:578`) checks the current project's view and defeats the ancestor walk its own error message advertises.
5. **`GET /people` is site-wide behind any single project's `people:read`** and checks only the home view (`people_controller.ex:16,23`) — whole-staff directory via one narrow grant; wrongly refused for a key whose `people` scope lives on a non-home grant.
6. **Membership read on the grant's project, never the target's** (`api_keys.ex:274-280`) — a team-grant removal on the ancestor bricks every call with `membership_ended` for a person who is a full member of the target, with the page showing only "No access here".
7. **Page state loss** — every unsubmitted select (add-a-project, new-key form's four) resets on any grant edit that runs `load()`; hardcoded `value=""`/`"read"`/`"full"` with no round-trip (`api_keys_live.ex:392-402, 527, 533`).
8. **Migration edges** — the backfill's per-key replay guard can resurrect a stale-scopes grant for a key stranded at "home set, zero grants" by a crash (`schema.ex:1170-1172`); `down_v24` reverts keys to mint-time scopes after any V24 grant edit.
9. **Dead code / stale docs** — `ApiKeys.effective_role/2`, `get_for_project/2`, `personal_attrs/2`; `api_keys.ex` moduledoc still describes the one-project model; `scope_project` silently ignores a non-binary `project` param; `move/3` silently deletes the destination grant.

The core resolution machinery — `access_for`'s nearest-grant walk, `view`/`rescope`/`still_allowed`, the resolve-before-check ordering in every controller, and the migration's scope translation — is built and wired correctly; every finding above is a bypass or a refusal at its edges, not in the main path.
