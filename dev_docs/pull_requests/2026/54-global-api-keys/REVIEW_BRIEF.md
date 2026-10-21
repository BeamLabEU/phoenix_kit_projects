# Briefs

## Round 1 — codex and zai (code)

```
You are reviewing BUILT CODE in the current directory (read-only: do not edit files; do not run the test suite or mix). phoenix_kit_projects is an Elixir/Phoenix LiveView project tracker with a JSON API (`/api/projects/v1`) that outside AI agents drive with bearer keys.

WHAT CHANGED (schema V24, "global API keys"): a key used to belong to one project. Now a key has GRANTS — one row per (key, project) in `phoenix_kit_project_api_key_grants` holding scopes per area (none / read / write for project, tasks, status, notes, comments, time, usage, events, people, plus extension areas like CRM `interactions`), a role for shared keys, and `inherit` (covers sub-projects). The nearest grant up the project tree decides; empty scopes = no access; an ancestor grant with inherit=false gives no access below it. A personal key (user_uuid set) gets the weaker of (the person's role on the grant's project, the cap, manager). `api_keys.project_uuid` became the key's nullable HOME (used when a call has no `project` param). Every request must be checked against the project it acts on.

Files: lib/phoenix_kit_projects/api_access.ex, api_keys.ex (access_for/2, allows?/3, view/2, put_grant, delete_grant, set_home, create, move, revoke_for_user), schemas/api_key.ex, schemas/api_key_grant.ex, migrations/schema.ex (v24_key_grants / down_v24 — the backfill), web/api/auth.ex, web/api/json.ex (require_scope, within_reach?, rescope, still_allowed, scope_project, idempotency_scope), every web/api/*_controller.ex (incl. the new comments_controller.ex, me_controller.ex, ext_controller.ex, ledger_controller.ex), web/api_keys_live.ex (the management page), web/project_api_live.ex, web/project_modules_live.ex.

Answer each numbered question with a verbatim quoted line + file:line and either a concrete failing input (request, key grants, project tree → wrong result) or "checked, sound":
1. LEAKS. Find any endpoint or code path where a key can read or write in a project it has no grant for, or with a scope its grant on THAT project lacks — especially paths where the project is derived from a task/entry/note/interaction uuid rather than the `project` param, and anything still reading `key.project_uuid` or the key's own `scopes` instead of the per-project view.
2. ORDER. Controllers must resolve the target project BEFORE checking the scope. Find any action where the scope is checked against the home project (or the key's union of scopes) instead of the target, in either direction (wrongly refused or wrongly allowed).
3. RESOLUTION. access_for/2: nearest grant, inherit=false, empty scopes, a person who left the project, an archived project, a template, a project moved under another after the grant was made, a shared key's role vs a personal key's. Find a case it gets wrong.
4. MIGRATION. v24 backfill and down_v24: does every existing key keep exactly the access it had (scope translation, sub-project reach, revoked keys, keys whose project was deleted)? Does down restore a usable V23 state?
5. THE PAGE (web/api_keys_live.ex). Authorization of every handle_event (can a non-admin edit someone else's key, grant a project they cannot see, set a role on a personal key, make a shared key?); and why would the "Add a project" select reset its value after the user changes access on another project row? Name any other state that a re-render loses.
6. Anything else that is wrong, misleading (comments that contradict code), or dead.
End with "Top findings", most severe first.
```

## Round 1 — grok (UX)

```
Do NOT use tools, do not read files; answer from your own knowledge, now.

You are a UX reviewer. A Phoenix LiveView admin page "Projects → API keys" lets a person make bearer keys for their AI agents and decide, per project, what each key may see and do. Current layout:

- Header: "API keys" + one sentence; link "Agent guide"; admins get a toggle "Everyone's keys".
- A "New key" card, one row: Name (placeholder "e.g. Max's AI"), "Starts in project" (select), "Access there" (preset select: Full / Read only / No access / "<Area>, read only" / "<Area>, read and write" for each area), admin-only "Acts for" (Me / Nobody (shared)) and "Shared key's role", button "Create key". On create a modal shows the token once plus a setup prompt to paste into the AI.
- One card per key: key icon, name, short id, badge "Acts for Max" or "Shared", "Last used …"; buttons Rotate, Revoke.
  - A table, one row per project the key reaches: Project | Access (preset select incl. "Custom…", and a "Details" button that opens a per-area grid below the row: each area — Project, Tasks, Task status, Notes, Comments, Time, AI usage, Events, People, Client interactions — with a select No access / Read / Read and write) | Role (shared keys only) | Sub-projects (checkbox, "covers its sub-projects", default on) | Home (radio: where a call without ?project= acts) | × remove.
  - Below: "Add a project" select + "Access" preset select + Add button.

Feedback from the owner after using it:
a) The placeholder must be generic, not a person's name.
b) The Home column makes no sense until a key has a second project.
c) Sub-projects should simply be on; nobody wants it off — if it must stay, it belongs in an extra customization panel.
d) He picked a project in "Add a project", then changed access on another row, and the add form's fields reset.
e) "Go ahead and do a full review and make improvements."

Answer in numbered points:
1. For a–c, propose the concrete UI you would ship (what is shown, where, labels).
2. The preset list is long (3 global + 2 per area ≈ 23 options). Better design for picking access per project? Consider a compact per-area summary ("Tasks: write · Comments: read · …") vs a matrix vs presets.
3. Is "Home" the right concept and word for the default project? Alternatives?
4. What is confusing or missing for a first-time user making their first key for an AI agent? What should the token/setup modal emphasise?
5. Top 5 changes, most valuable first, each one sentence.
Keep it under 700 words.
```

## Round 2 — codex re-review of the fixes

```
Read-only re-review (do not edit files; do not run mix). You reviewed this repo an hour ago (V24 global API keys) and found: /hours leaking sub-projects; task/briefing serializers exposing time, usage, notes, events, interactions under tasks:read; Json.project listing unreachable sub-projects; an unusable home blocking every call; the ancestor interaction pre-gate; templates reachable; the migration's write-without-read, down_v24 restoring the wrong role/scopes, unrenamed idempotency rows; the page's creator IDOR, grants not re-authorized, set_role on personal keys, lost form state; ApiKeys.move deleting the target grant.

The fixes are in FIXES.diff at the repo root (the working tree already contains them). Answer each with a verbatim quoted line + file:line and either a concrete failing input or "checked, sound":
1. Json.put_view/may? (process dictionary, set in Auth and in still_allowed/1): is there any request path where the view is stale — set for one project while the response serializes tasks of another (scope_project to the same project, fetch of a task in a child, ledger own_entry, side lookups that only rescope)? Any serializer of task/notes/time data still not gated?
2. Auth.home_view + Json.require_scope's pk_home_refused + rescope clearing it: can a request with a refused home act at home anyway (a controller that never calls require_scope, require_action with role "viewer", /me, ext_controller, RefText writer)?
3. ProjectMove carry_grant + key_from: correct nearest ancestor, authorization, and behaviour when the key already has a grant on the moved project?
4. Migration: the new write→read SQL, the idempotency rename (sha256 of project_uuid::text || ':' || key, hex — must equal Json.idempotency_scope/2 in Elixir), down_v24's two UPDATEs. Any SQL error or wrong row?
5. api_keys_live.ex: editable?, with_grant's allowed_project check, set_role guard, set_home via with_grant, the draft forms. Anything an ordinary (non-admin) user can still do to a key or project they should not, or any state still lost on re-render?
End with "Top findings".
```
