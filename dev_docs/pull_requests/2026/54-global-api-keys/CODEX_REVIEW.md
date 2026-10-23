# Codex review of V24 (global API keys), first round

`codex exec` (gpt-5.6), `--cd` on a snapshot of the branch, read-only, 2026-10-16. Brief: REVIEW_BRIEF.md, round 1. How each finding was resolved: FOLLOW_UP.md.

Static review only; I did not edit files or run `mix`/tests.

## 1. LEAKS

Found multiple leaks.

### A. `/hours` ignores per-child grants

> `project_uuids: Hours.project_uuids(project.uuid, opts.include_subprojects),`

[hours_controller.ex:29](lib/phoenix_kit_projects/web/api/hours_controller.ex:29)

`Hours.project_uuids/2` blindly expands the subtree:

> `if include_subprojects?, do: Projects.subtree_uuids(project_uuid), else: [project_uuid]`

[hours.ex:117](lib/phoenix_kit_projects/hours.ex:117)

Failing input:

- Tree: `P -> C`
- Grant on `P`: `["time:read"]`, `inherit: false`
- Alternatively, `inherit: true` on `P` plus a nearer empty grant on `C`
- `C` contains 120 minutes of entries
- Request: `GET /api/projects/v1/hours?project=P` with the default `include_subprojects=true`

Result: `C`’s time is included even though `access_for(key, C)` is `:no_access`. No child grant or child `time:read` check occurs.

### B. Task reads leak time, usage, and extension data

> `(totals || Map.get(Ledger.totals_for_assignments([a.uuid]), a.uuid))`

[json.ex:299](lib/phoenix_kit_projects/web/api/json.ex:299)

> `interactions: interactions || interaction_uuids(a),`

[json.ex:347](lib/phoenix_kit_projects/web/api/json.ex:347)

Yet the list requires only:

> `{:ok, conn} <- Json.require_scope(conn, "tasks:read"),`

[tasks_controller.ex:61](lib/phoenix_kit_projects/web/api/tasks_controller.ex:61)

Failing input:

- Grant scopes: only `["tasks:read"]`
- A task has 30 minutes, 5,000 tokens, 20 cost cents, and a linked CRM interaction
- Request: `GET /api/projects/v1/tasks`

Result: the response exposes `totals.minutes`, `totals.tokens`, `totals.cost_cents`, and interaction UUIDs without `time:read`, `usage:read`, or `interactions:read`.

### C. Single-task reads leak notes

> `latest = TaskNotes.latest(a.uuid)`

[json.ex:365](lib/phoenix_kit_projects/web/api/json.ex:365)

> `latest_agent_note: latest.agent && TaskNotes.to_json(latest.agent),`

[json.ex:372](lib/phoenix_kit_projects/web/api/json.ex:372)

`GET /tasks/:id` checks only `tasks:read`.

Failing input:

- Grant scopes: `["tasks:read"]`, no `notes:read`
- Task contains a confidential agent note
- Request: `GET /api/projects/v1/tasks/<task_uuid>`

Result: the task detail returns direction, outcomes, summaries, and the latest agent note.

### D. `/briefing` bypasses several independent areas

It requires only `tasks:read`, but returns:

> `project_notes: Enum.map(notes, &brief_note/1),`

[briefing_controller.ex:116](lib/phoenix_kit_projects/web/api/briefing_controller.ex:116)

> `events: upcoming_events(project)`

[briefing_controller.ex:118](lib/phoenix_kit_projects/web/api/briefing_controller.ex:118)

It also exposes linked interaction UUIDs on task rows at line 289.

Failing input:

- Grant scopes: only `["tasks:read"]`
- Project contains project notes and upcoming events
- Request: `GET /api/projects/v1/briefing`

Result: project notes and event details are returned without `notes:read` or `events:read`.

### E. Project serialization leaks child-project details past an inheritance stop

> `subprojects: Enum.map(Projects.child_projects(p.uuid), &subproject/1)`

[json.ex:447](lib/phoenix_kit_projects/web/api/json.ex:447)

Failing input:

- `P -> C`
- Key has `project:read` on `P`, `inherit: false`, or an empty direct grant on `C`
- Request: `GET /api/projects/v1/project?project=P`

Result: UUID, key, name, description, workflow state, completion, and archive state of `C` are returned despite no access to `C`.

Checked, sound: the task/note/comment/time/usage paths derived from a task UUID do call `TasksController.fetch/2`, which resolves and rescopes to the assignment’s actual project before the area check. Entry correction similarly resolves `entry.project_uuid` and rescopes before the exact `time:write`/`usage:write` check.

---

## 2. ORDER

Most controller actions correctly call `scope_project/2` before `require_scope/2`, and task-derived actions call `fetch/2` before checking their scope.

However, authentication itself requires usable access to the home project before any controller can resolve the requested target:

> `%{} = project <- home_project(key) || :no_project,`

> `{:ok, key} <- ApiKeys.resolve(key, project) do`

[auth.ex:35](lib/phoenix_kit_projects/web/api/auth.ex:35)

Failing input:

- Home `H` has a direct empty-scope grant, or a personal grant whose membership ended.
- Other project `O` has a valid `tasks:read` grant.
- Request: `GET /api/projects/v1/tasks?project=O`

Result: Auth returns `no_access`/`membership_ended` for `H`; the controller never resolves `O`. A valid global key is unusable everywhere because its default project became unusable.

The UI permits this state because `set_home/2` accepts any direct grant, including an empty one:

> `if Enum.any?(grants(key), &(&1.project_uuid == project_uuid)) do`

[api_keys.ex:215](lib/phoenix_kit_projects/api_keys.ex:215)

There is a second wrong refusal for ancestor interactions:

> `true <- ApiKey.scope?(key, provider.scopes().read) do`

[tasks_controller.ex:578](lib/phoenix_kit_projects/web/api/tasks_controller.ex:578)

Failing input:

- Task is in child `C`
- `C` grant has `tasks:write`, but no `interactions:read`
- Parent `P` grant has `interactions:read`
- The interaction belongs to `P`
- Request creates/updates the child task with that interaction UUID

Although lines 582–585 subsequently check the ancestor’s grant correctly, line 578 first demands `interactions:read` on `C`, so the legitimate ancestor lookup is never attempted.

No wrongly allowed target-project mutation was found from controller ordering; the identified ordering defects are wrong refusals plus the entry-existence oracle noted below.

---

## 3. RESOLUTION

Nearest-grant ordering itself is correct:

> `project_uuid |> Projects.parent_chain() |> Enum.reverse()`

[api_keys.ex:246](lib/phoenix_kit_projects/api_keys.ex:246)

`parent_chain/1` is root-first, so reversing yields immediate parent first. Empty scopes, `inherit: false`, current tree position after a move, personal-role weakening, and shared grant roles are checked, sound.

A concrete resolution error exists for templates. Shared-key resolution never checks the grant project’s lifecycle/type:

> `defp grant_role(%ApiKey{user_uuid: nil}, grant),`

> `do: {:ok, %{scopes: grant.scopes, role: grant.role, grant: grant}}`

[api_keys.ex:271](lib/phoenix_kit_projects/api_keys.ex:271)

That contradicts the project API page:

> `:template -> bounce(socket, gettext("Templates don't have API keys."))`

[project_api_live.ex:68](lib/phoenix_kit_projects/web/project_api_live.ex:68)

Failing input:

- Shared key with a direct full grant on template `T`—possible via `ApiKeys.put_grant/4`, direct DB insertion, or a pre-existing/migrated key
- Request: `POST /api/projects/v1/tasks?project=T`

Result: `access_for/2` accepts the grant and the JSON API can work inside the template despite the stated “templates don’t have API keys” rule.

Checked, sound:

- Empty nearest grant stops traversal.
- Nearest ancestor with `inherit: false` stops traversal.
- A personal key uses the membership/effective role on the grant source project, capped by grant role and manager.
- A shared key uses the grant role.
- Current ancestry is recomputed, so moving a project under a different parent changes inherited access.
- Archived projects remain accessible. This is consistent with this module’s documented “archive is a soft hide, not a permission/lifecycle freeze” semantics.
- A genuinely ended personal membership returns `membership_ended`; normal `Members.remove_member/3` also removes that project’s direct grant.

---

## 4. MIGRATION

The up migration does not keep exactly the same access for all valid V23 scope lists.

> `|| CASE WHEN 'time:write' = ANY(k.scopes) THEN ARRAY['time:read'] ELSE ARRAY[]::text[] END`

[migrations/schema.ex:1163](lib/phoenix_kit_projects/migrations/schema.ex:1163)

Failing input:

- V23 key scopes: `["time:write"]`
- Before V24, `ApiKey.scope?/2` was an exact membership test, so it could append time but could not list entries.
- Backfill creates `["time:write", "time:read"]`.

Result: after migration the key gains ledger-read access it did not have. The same expansion happens for `usage:write` and `project:write`.

Conversely, the new “write includes read” invariant is applied inconsistently. A V23 key with only `tasks:write` receives `status:write` and `notes:write`, but not `tasks:read`; `ApiAccess.level/2` displays that area as “write”/“Read and write,” while `require_scope("tasks:read")` still refuses it. Provider-specific `*:write` scopes have the same problem because the SQL cannot add their dynamic read counterparts.

The down migration is unsafe:

> `execute("DROP TABLE IF EXISTS #{p}phoenix_kit_project_api_key_grants")`

[migrations/schema.ex:1194](lib/phoenix_kit_projects/migrations/schema.ex:1194)

It drops the only authoritative per-home grant before copying its role/scopes back to `api_keys`.

Failing input:

- Shared key created on `H` as manager/full
- Grant on `O` is viewer/read-only
- `O` is later set as home
- Run `down_v24`

Result: `project_uuid=O` survives, but the old key columns still contain manager/full from `H`. Rolled-back V23 code gives manager/full access to `O`.

Another down failure:

> `execute("DELETE FROM #{p}phoenix_kit_project_api_keys WHERE project_uuid IS NULL")`

[migrations/schema.ex:1195](lib/phoenix_kit_projects/migrations/schema.ex:1195)

If the home project was deleted, V24 sets home to `NULL` while other grants may remain usable. Down deletes that still-usable key instead of choosing a surviving grant and restoring its scopes/role.

Checked, sound:

- V23 subproject reach is preserved by the grant’s `inherit DEFAULT true`.
- Revoked keys stay revoked; adding a grant does not make their tokens authenticate.
- A V23 key whose project had already been deleted cannot normally exist because the V23 FK was `ON DELETE CASCADE`.

---

## 5. THE PAGE

### A. A non-admin can mutate someone else’s key when they are its creator

> `(is_binary(me) and (key.user_uuid == me or key.created_by_uuid == me))`

[api_keys_live.ex:116](lib/phoenix_kit_projects/web/api_keys_live.ex:116)

Failing input:

- Personal key acts for Bob: `user_uuid=Bob`
- It was created by Alice: `created_by_uuid=Alice`
- Alice is not `admin_all`
- Alice sends forged LiveView events containing the key UUID

`with_key/3` loads the key globally and accepts Alice as editable even though `list_mine(Alice)` does not display it. Alice can change grants, home, scopes, rotate, or revoke Bob’s key.

This also lets Alice grant a project she cannot see if Bob can see it, because `add_grant` validates against `projects_for(key.user_uuid)`, i.e. Bob’s projects.

### B. Existing grants are not re-authorized

> `grant -> fun.(key, grant)`

[api_keys_live.ex:314](lib/phoenix_kit_projects/web/api_keys_live.ex:314)

Failing input:

- Alice created a legacy shared key
- It already has a grant on secret project `S`
- Alice no longer has visibility into `S`
- Alice forges `set_grid`, `set_preset`, `toggle_inherit`, `set_home`, or `remove_grant`

The handler checks only key editability and grant existence, not Alice’s current authority over `S`.

### C. A personal key’s hidden role cap is wire-editable

> `ApiKeys.put_grant(key, project_uuid, %{"scopes" => grant.scopes, "role" => role},`

[api_keys_live.ex:226](lib/phoenix_kit_projects/web/api_keys_live.ex:226)

Failing input: owner of a personal key sends forged `set_role` with `"manager"`. The UI hides the role selector for personal keys, but the handler does not require `key.user_uuid == nil`. Membership weakening prevents elevation beyond the person’s current role, so this is unauthorized hidden-state mutation rather than a direct privilege escalation.

Checked, sound:

- Creating a shared key is admin-only: `shared?` is true only when the submitted kind is shared and `socket.assigns.admin?`.
- Adding a grant through the normal path verifies the selected project against the key owner’s visible projects, or all non-template projects for an admin-managed shared key.
- Unknown/revoked keys are ignored.

### D. “Add a project” resets because its server value is always empty

> `value=""`

[api_keys_live.ex:527](lib/phoenix_kit_projects/web/api_keys_live.ex:527)

Changing another row triggers a LiveView event and re-render; the patched select is rendered with `value=""`, so the unsent project choice is discarded.

Other unsent state lost on re-render:

- New-key name: `value=""` at line 384.
- New-key preset: `value="full"` at line 396.
- New-key kind: `value="personal"` at line 399.
- New shared-key role: `value="member"` at line 402.
- Each add-grant preset: `value="read"` at line 533.
- A changed new-key project resets to `@new_project`, not the browser’s unsent selection.

---

## 6. OTHER WRONG, MISLEADING, OR DEAD CODE

### A. Upgrade invalidates existing idempotency records

V24 hashes new idempotency keys with the project:

> `do: :crypto.hash(:sha256, project_uuid <> ":" <> header) |> Base.encode16(case: :lower)`

[json.ex:257](lib/phoenix_kit_projects/web/api/json.ex:257)

But `v24_key_grants/2` never rewrites existing V17–V23 `phoenix_kit_project_api_idempotency.idempotency_key` rows.

Failing input:

- Before upgrade, `POST /time` with `Idempotency-Key: report-17` succeeds and stores raw `"report-17"`.
- After V24, the client retries the same request.
- Runtime looks for `sha256(project_uuid <> ":report-17")`, misses the old row, and records the time again.

Downgrading has the inverse problem: hashed V24 rows do not match V23’s raw headers.

### B. `ApiKeys.move/3` destroys an existing target grant

> `where: g.api_key_uuid == ^key.uuid and g.project_uuid == ^to_uuid`

> `|> RepoHelper.repo().delete_all()`

[api_keys.ex:624](lib/phoenix_kit_projects/api_keys.ex:624)

Failing input:

- Home `H` grant: full/manager
- Target `C` already has a direct empty-scope deny, or viewer/read-only grant
- `ApiKeys.move(key, C)` is invoked by project-move carry logic

Result: the carefully configured target grant is deleted, then the full home grant is moved onto `C`. This both contradicts “its grants elsewhere stay where they are” and can convert an explicit deny into full access.

With global keys, `ProjectMove` also assumes the home grant is the grant being carried; a key selected because of a grant on an ancestor may have an unrelated home.

### C. Entry amendment has an existence oracle

> `Enum.any?(PhoenixKitProjects.ApiKeys.grants(key), fn g ->`

[ledger_controller.ex:215](lib/phoenix_kit_projects/web/api/ledger_controller.ex:215)

The preliminary check uses the union of direct grant scopes. A key with a write scope on an unrelated project can cause an arbitrary entry UUID to be loaded before the target project’s exact scope is checked. Exact authorization eventually blocks the mutation, but differing `404`, policy `403`, and `scope_missing` responses can reveal whether an entry UUID exists in a reachable project.

### D. Extension `get`/`update` target binding is only a provider convention

> `{:ok, conn, provider} -> call(conn, provider, :get, [ctx(conn), id])`

[ext_controller.ex:29](lib/phoenix_kit_projects/web/api/ext_controller.ex:29)

The controller authorizes the selected/home project, then passes an arbitrary resource UUID to the provider. The provider behaviour does not explicitly require proving that the ID belongs to `ctx.project`.

Failing provider: `get(_ctx, id)` performs a global `Repo.get(id)`. A key granted only project `P` can retrieve an interaction belonging to `Q`. This is a trust-contract hole; the built-in controller cannot enforce “every UUID-derived request is checked against its actual project.”

### E. Stale/dead V23 concepts remain

The main `ApiKeys` and `ApiKey` module documentation still describes a key as belonging to one project with one stored role/scopes. `ApiKeys.effective_role/2` likewise operates on the key’s legacy stored role rather than a grant and is now referenced only by tests, not the API request path. It is misleading beside `access_for/2` and risky for future callers.

## Top findings

1. `/hours` leaks child-project ledger data across `inherit:false` and explicit nearest-grant denies.
2. Task and briefing serializers bypass the new area separation, exposing notes, time, usage, events, and interaction IDs under `tasks:read`.
3. `down_v24` can turn a viewer/read-only home grant into the key’s old manager/full authority, or delete a still-usable key.
4. V24’s new project-scoped idempotency hashes do not migrate old rows, so retries after upgrade can duplicate writes.
5. The global API-key LiveView has an IDOR-style creator authorization path and does not re-check authority over existing grant projects.
6. An unusable home blocks requests to otherwise valid target projects.
7. `ApiKeys.move/3` deletes the target grant—including explicit denies—and replaces it with the home grant.


## Post-merge recheck — 2026-10-23

Rechecked Claude's follow-up at `7286e44`: the rate limit precedes project /
account / grant resolution; refused calls are counted using the stored home;
page loading batches grants and project-key lists; deleting the home skips
empty grants. The related functional and query-count tests remain in the
suite. No additional access-control defect confirmed in this pass.

**BUG - MEDIUM (validation dependency, not attributed to this PR):** the full
`mix precommit` gate stopped at `mix hex.audit` because the locked
`plug_crypto 2.2.0` was subject to EEF-CVE-2026-105963 / GHSA-ffw9-w85g-f2vh
(secret key base exposed in stack-trace arguments when Plug.Crypto receives
wrongly typed arguments). `mix deps.update plug_crypto` resolved 2.2.1;
`mix.lock` changes only that package. No dependency requirements changed.

The previously noted per-project access walk in `GET /me` and the task
serializers remains a performance limitation for large project trees.
The unrelated empty translations also remain; this pass fills the five
missing translations of the setup instruction changed by #55.

See [PR #55's Codex review](../55-neutral-example-key/CODEX_REVIEW.md) for the
final validation results.
