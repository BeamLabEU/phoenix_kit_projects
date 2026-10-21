# Codex re-review of the fixes

`codex exec` (gpt-5.6), same snapshot after the first round's fixes (FIXES.diff), 2026-10-16. Brief: REVIEW_BRIEF.md, round 2.

Static re-review only; I made no edits and did not run `mix`.

## 1. `Json.put_view/1` and serializers

The process-dictionary view propagation itself is checked, sound.

> `Json.put_view(key)`  
> [auth.ex:53](lib/phoenix_kit_projects/web/api/auth.ex:53)

> `put_view(key)`  
> [json.ex:184](lib/phoenix_kit_projects/web/api/json.ex:184)

Same-project requests retain the view installed by `Auth`; child-task fetches and ledger entry lookups call `rescope/2` followed by `still_allowed/1`. The briefing/interaction side lookups call only `rescope/2`, so they do not overwrite the primary serializer view. I found no in-request stale-view path.

Several serializer leaks remain:

- Notes expose usage without `usage:read` or `time:read`.

  > `usage: m["usage"],`  
  > [task_notes.ex:657](lib/phoenix_kit_projects/task_notes.ex:657)

  > `latest_agent_note: latest.agent && TaskNotes.to_json(latest.agent),`  
  > [json.ex:443](lib/phoenix_kit_projects/web/api/json.ex:443)

  Concrete failing input: grant only `["tasks:read", "notes:read"]`; store an agent note whose metadata contains `%{"usage" => %{"tokens" => 18_422, "cost_cents" => 7, "minutes" => 12}}`. `GET /tasks/:id` and `GET /tasks/:id/notes` return that usage.

- `/entries` and `/tasks/:id/entries` expose usage entries under `time:read`.

  > `entries: Enum.map(page, &Json.entry/1),`  
  > [ledger_controller.ex:87](lib/phoenix_kit_projects/web/api/ledger_controller.ex:87)

  > `amount: number(e.amount),`  
  > [json.ex:467](lib/phoenix_kit_projects/web/api/json.ex:467)

  Concrete failing input: grant only `["time:read"]`; add a `"tokens"` or `"cost"` entry with model metadata. `GET /entries` returns its kind, amount, model, note and note UUID without `usage:read`.

- `/hours` still cross-leaks child usage.

  > `|> Enum.filter(&(&1 == project.uuid or ApiKeys.allows?(key, &1, "time:read"))),`  
  > [hours_controller.ex:34](lib/phoenix_kit_projects/web/api/hours_controller.ex:34)

  > `|> Map.drop(if Json.may?("usage:read"), do: [], else: [:tokens, :cost_cents])`  
  > [hours_controller.ex:50](lib/phoenix_kit_projects/web/api/hours_controller.ex:50)

  Concrete failing input: home grant has `time:read + usage:read`; child’s nearer grant has `time:read` but no `usage:read`; child has token/cost entries. The child is included because of `time:read`, while usage visibility is decided from the home view, so child token/cost totals leak.

- An unreachable child is still disclosed through the parent’s task list.

  > `subproject: subproject_state(a),`  
  > [json.ex:391](lib/phoenix_kit_projects/web/api/json.ex:391)

  Concrete failing input: parent grants `tasks:read`; child has a direct empty grant. `GET /project` correctly omits the child, but `GET /tasks` still returns the parent-side subproject row, including the child UUID/name and its completion/caught-up state.

- Interaction IDs fail open when the provider disappears.

  > `_ -> true`  
  > [json.ex:329](lib/phoenix_kit_projects/web/api/json.ex:329)

  Concrete failing input: persist a task-interaction link, then remove/disable the provider. A `tasks:read` key receives the interaction UUID because no provider is treated as authorization success.

Normal provider-backed interaction checks and briefing event checks are otherwise checked, sound.

## 2. Refused home handling

Checked, sound.

> `{:ok, %{key | scopes: [], role: "viewer"}, reason}`  
> [auth.ex:98](lib/phoenix_kit_projects/web/api/auth.ex:98)

> `|> assign(:pk_home_refused, nil)`  
> [json.ex:169](lib/phoenix_kit_projects/web/api/json.ex:169)

A refused home receives empty scopes, so even viewer-permitted actions stop at `require_scope/2`. Rescoping successfully clears the refusal. `/me` has its explicit refused-home clause, every extension call goes through `require_scope/2`, and the RefText writer asks `ApiKeys.allows?/3`, which returns false for the refused home. I found no authenticated controller that can mutate or serialize home data using `require_action/2` alone.

## 3. `ProjectMove` grant carrying

Not sound.

- It offers/carries ancestor grants without proving that they actually reached the project.

  > `|> Enum.flat_map(fn a -> Enum.map(ApiKeys.list_for_project(a.uuid), &{&1, a.uuid}) end)`  
  > [project_move.ex:173](lib/phoenix_kit_projects/project_move.ex:173)

  Concrete failing input: parent `P` contains child `C`; key `K` has a non-empty grant on `P` with `inherit: false`. `K` cannot access `C` before the move, but `ProjectMove` offers it and copies that grant directly to `C`, giving it access after the move.

- Authorization filtering happens before nearest-source selection.

  > `|> Enum.filter(&Authz.can?(scope, &1, :manage_modules))`  
  > [project_move.ex:172](lib/phoenix_kit_projects/project_move.ex:172)

  Concrete failing input: `R → P → C`; `K` has full access on `R` and a narrower/empty grant on nearer `P`; mover can manage `R` but not `P`. Filtering removes `P`, so `key_from` chooses `R` and copies the shadowed, broader grant.

- Personal-key carrying can report success without preserving access.

  > `case Authz.effective_role(project, user_uuid) do`  
  > [api_keys.ex:292](lib/phoenix_kit_projects/api_keys.ex:292)

  Concrete failing input: Alice is a member of parent `P`, and her personal key reaches child `C` through `P`; Alice is not directly a member of `C`. Move `C` to the top and carry only the key. The new direct grant checks Alice’s role on `C`, returns `membership_ended`, yet the move reports one key carried.

Existing target-grant behavior is checked, sound:

> `Map.has_key?(by_project, to_uuid) ->`  
> `  {:ok, :kept}`  
> [api_keys.ex:595](lib/phoenix_kit_projects/api_keys.ex:595)

It preserves an existing stricter or empty grant without overwriting it.

## 4. Migration

The generic write-to-read expansion is checked, sound:

> `|| ARRAY(SELECT replace(w, ':write', ':read') FROM unnest(k.scopes) AS w`  
> [schema.ex:1168](lib/phoenix_kit_projects/migrations/schema.ex:1168)

The SQL and Elixir hashes are byte-equivalent for ordinary unscoped rows:

> `encode(sha256(convert_to(k.project_uuid::text || ':' || i.idempotency_key, 'UTF8')), 'hex')`  
> [schema.ex:1187](lib/phoenix_kit_projects/migrations/schema.ex:1187)

> `do: :crypto.hash(:sha256, project_uuid <> ":" <> header) |> Base.encode16(case: :lower)`  
> [json.ex:293](lib/phoenix_kit_projects/web/api/json.ex:293)

Remaining failures:

- Raw 64-character lowercase hexadecimal headers are mistaken for already-migrated rows.

  > `AND i.idempotency_key !~ '^[0-9a-f]{64}$'`  
  > [schema.ex:1191](lib/phoenix_kit_projects/migrations/schema.ex:1191)

  Concrete failing input: pre-V24 header `"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`. It is left unchanged; after upgrade the runtime hashes it, misses the old row, and repeats the write.

  This can also make the migration fail with a primary-key collision. For project `018f0000-0000-7000-8000-000000000001`, store rows `"retry"` and `24e141abc66a071e131883cd8da7968f19dd9e260586c616aa01a4c46656ff94`. The latter is skipped; renaming `"retry"` targets that occupied key.

- `down_v24` still broadens decomposed permissions.

  > `SELECT unnest(ARRAY['tasks:read','tasks:write','time:write','usage:write','project:write',`  
  > [schema.ex:1237](lib/phoenix_kit_projects/migrations/schema.ex:1237)

  Concrete failing input: V24 grant scopes only `["tasks:read"]`. The down migration restores `tasks:read`; V23 interpreted that scope as also carrying project, notes, time, usage, events and people reads—the expansion is documented by [schema.ex:1163](lib/phoenix_kit_projects/migrations/schema.ex:1163). Downgrade therefore grants more than the V24 row had.

- A V24 rollback cannot replay pre-upgrade idempotency headers: the up migration irreversibly hashes them, while `down_v24` never restores them. Concrete failing input: header `"retry"` stored before upgrade; upgrade hashes it, downgrade leaves the hash, and V23 looks up `"retry"` and repeats the write.

The two down `UPDATE`s select the home/fallback grant and then its matching role row correctly under the unique-grant invariant. I found no standalone SQL syntax error; the idempotency collision above is the concrete execution error.

## 5. `api_keys_live.ex`

Mutation authorization and draft preservation are checked, sound.

> `socket.assigns.admin? or (is_binary(me) and key.user_uuid == me)`  
> [api_keys_live.ex:144](lib/phoenix_kit_projects/web/api_keys_live.ex:144)

> `if grant && allowed?, do: fun.(key, grant), else: {:noreply, socket}`  
> [api_keys_live.ex:371](lib/phoenix_kit_projects/web/api_keys_live.ex:371)

> `%ApiKey{user_uuid: user} = _key, _grant when not is_nil(user) ->`  
> [api_keys_live.ex:271](lib/phoenix_kit_projects/web/api_keys_live.ex:271)

I found no crafted event by which an ordinary user can edit another user’s or a shared key, change a personal key’s role, or set home without a current, non-empty authorized grant. Removing a stale grant only reduces access.

Both draft forms survive `load/1` rerenders:

> `{:noreply, assign(socket, new_key: params)}`  
> [api_keys_live.ex:157](lib/phoenix_kit_projects/web/api_keys_live.ex:157)

> `{:noreply, update(socket, :add_drafts, &Map.put(&1, key_uuid, params))}`  
> [api_keys_live.ex:161](lib/phoenix_kit_projects/web/api_keys_live.ex:161)

One functional authorization-list defect remains: subprojects are never considered allowed projects.

> `|> Projects.list_projects()`  
> [api_keys_live.ex:106](lib/phoenix_kit_projects/web/api_keys_live.ex:106)

`list_projects/1` defaults to excluding subprojects. Concrete failing input: an ordinary user is a member of child `C`, or their key needs a direct deny/narrowing grant on `C`. `C` is absent from “Add a project”; a crafted add is rejected; and an existing direct grant on `C` cannot be edited or made home through `with_grant/4`—only removed.

## Top findings

- High: usage remains exposed through note and ledger-entry serializers; `/hours` uses the home usage scope for child totals.
- High: an explicitly unreachable child is still disclosed through the parent task serializer.
- High: `ProjectMove` can turn a non-inheriting or shadowed ancestor grant into new direct access; personal-key carrying may not preserve access.
- High: a raw 64-hex idempotency key is not migrated and can cause either duplicate writes or a migration-time PK collision.
- Medium: `down_v24` broadens legacy `tasks:read` and cannot restore idempotency replay semantics.
- Medium: the API-key page cannot create or edit direct subproject grants.
