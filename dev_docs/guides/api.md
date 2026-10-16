# The projects API (`/api/projects/v1`)

The JSON API an outside agent drives projects with — one key can reach several,
with its own access in each: read and create tasks, move them through their
lifecycle, talk in their discussions, set a project's workflow status, and
report the minutes, tokens and cost of its work into the work ledger. Built
2026-10-05 for the boss's case — "I run an AI model elsewhere, it does a task,
it must reach in and submit its token usage and time, and control the tasks."
Designed with a panel round (grok, zai, codex); the decisions below are theirs
where marked.

The agent-facing contract is **generated from one table of endpoints**
(`Web.Api.Docs.endpoints/0`) and served without a key as
`GET /api/projects/v1/llms.txt` (Markdown an LLM reads whole) and
`GET /api/projects/v1/openapi.json`. Change the table, and both documents
follow; never write an endpoint the table does not list.

## Keys live on Projects → API keys, and hold a grant per project

`phoenix_kit_project_api_keys` (chain V17, `user_uuid` in V18) holds the
credential; `phoenix_kit_project_api_key_grants` (V24) holds what it may do,
one row per project it reaches. A key has a **name** (what the agent is
called) and a **home project** (`project_uuid`: where a call without
`project` acts; nullable since V24, `ON DELETE SET NULL`). Each grant carries:

- **scopes** — per **area**, none / read / write (`ApiAccess`; write includes
  read): `project`, `tasks`, `status` (write only), `notes`, `comments`,
  `time`, `usage`, `events` (read only), `people` (read only), plus each
  extension API provider's pair (`interactions:read` / `interactions:write`
  for the CRM's client interactions). Max, 2026-10-16: *"every setting that we
  already have in the project should also be for the api permissions"*. An
  empty list is "no access here".
- **role** — the cap: `manager`, `member` or `viewer`, never owner.
- **inherit** — whether it also covers the project's sub-projects.

`ApiKeys.access_for/2` decides what a key may do in a project: the **nearest
grant up the tree** wins — the project's own, else its parent's, and so on; a
grant above with `inherit: false`, or a nearest grant with no scopes, means no
access, and nothing further up is consulted. A key is one of two kinds
(`ApiKey.kind/1`):

- **personal** — `user_uuid` names the person it acts for. In each project it
  acts with the weakest of the grant's cap, that person's CURRENT role on the
  **grant's** project (sub-projects usually have no members of their own) and
  manager. Demotion applies on the next call; once the person is off the
  grant's project, that grant answers `membership_ended`. Leaving a project
  deletes only that project's grant (`Members.remove_member/3` →
  `ApiKeys.revoke_for_user/3` → `delete_grant/3`); the key's other grants
  live on.
- **shared** — no person: a CI runner, "ANDI agent". The grant's role is the
  authority.

Keys are made, rotated, revoked and given access only on **Projects → API
keys** (`Web.ApiKeysLive`): the person's own keys, and — for those allowed —
shared ones; a key's row opens a grid of projects × areas, with presets to
fill it quickly. `?project=<uuid>` preselects a project for a new key. A
project's own pages only show: **Your API key** (`/projects/:id/api`,
`Web.ProjectApiLive`) lists the viewer's own keys that reach the project —
its access there, where that comes from (set on this project, or from a
project above), home project, last use, expiry, and **Copy setup prompt** —
and the **API access** section on Modules & Features lists every key that
reaches it. Both link to the API keys page.

`created_by_uuid` (the minter) and `user_uuid` are provenance, not FKs: the row
is audit history once the person is gone.

The token is `pkp_<key_id>_<secret>`. `key_id` is public (unique index, the
lookup), the secret is 32 random bytes and only its SHA-256 is stored; the
token is shown once, at creation and at **rotation**, which replaces the secret
on the same row so the key's ledger history stays one agent. **Revoke** ends it
everywhere. `last_used_at` is touched at most once a minute. `expires_at` is
optional. The **setup prompt** (`ApiKeyPanel.setup_prompt/3`) names the home
project, the base URL, the agent guide and OpenAPI links and the token (or its
place), and tells the agent to start with `GET /me`, pass `project=<KEY>` for
any other project, and never assume one project's access from another's.

**Before V24** (2026-10-05 → 10-16) a key belonged to one project and reached
it and everything nested under it with one role and one scope set; members
minted personal keys on Your API key and owners minted shared keys on Modules
& Features. The V24 migration gave every existing key exactly the grant it
had, translating its scopes so every token works as before: `tasks:read` →
also `project`, `notes`, `time`, `usage`, `events` and `people` read;
`tasks:write` → also `status:write`, `notes:write`; `time:write` →
`time:read`; `usage:write` → `usage:read`; `project:write` → `project:read`.

## The key is its own principal

- **Authorisation:** `Authz.can_role?(project, key.role, action)` — the role
  floors the project configures (its "who can do what" overrides included),
  nothing else: no membership lookup, no admin override, no relationship grant.
  Plus the scope, plus the project's feature gates (`Features.gates/1`): tasks
  calls need `tasks`, ledger calls need `ledger`, the workflow status needs
  `statuses`.
- **Attribution:** ledger entries the key reports are `actor_kind: "ai_agent"`,
  `actor_uuid: key.uuid`, `source: "ai"`. Activity entries for task changes
  carry `actor_uuid: ApiKey.accountable_uuid(key)` — the person the key acts
  for, else its minter — with `metadata.via = "api"`, `metadata.api_key` and
  `metadata.api_key_name`, so the feed can tell the agent from the person.
  `/me` returns `acting_for` (`{uuid, name}`, null for a shared agent), the
  key's `kind`, and the role it acts with right now; the setup prompt tells the
  agent whom it acts for. (Core's activity actor renders
  as a user; a key uuid there would read "User 1a2b…".)
- **Agent time** is `kind: "time"` by an `ai_agent` actor, never billable
  (`billable` from the agent is ignored) — `Ledger.totals_for_project/1` splits
  it out as `ai_minutes`, and invoicing already bills human actors only. Panel
  2:1 for one kind split by actor over a new kind.

## Reach: every project a grant covers

A key reaches every project where `access_for/2` finds a grant with scopes —
its home, the other projects it was given, and (through `inherit`) what is
nested under them (Max, 2026-10-05: *"ideally the api would be able to control
everything in its project and everything in the children projects as well"*;
2026-10-15: *"make API key stuff more global"*). `GET /me` lists them as
`projects` — `key`, `uuid`, `name`, `role`, `scopes`, `access` (area →
none / read / write) and `source` (`direct` or `{inherited_from}`).

Project-level calls take a `project` param, a uuid or a key
(`Json.scope_project/2`; 404 outside reach): `GET /project`, `POST
/project/status`, `GET /briefing`, `GET`/`POST /tasks`, `POST /time`, `POST
/usage`, `POST /subprojects`, the notes, hours, entries and events reads, and
the `/ext/…` lists and creates. Task-level calls need nothing:
`TasksController.fetch/2` finds a task anywhere within reach — a ref like
`ANDI-42` names its own project. Either way the request is **rescoped**:
`Json.rescope/2` puts the key as it acts THERE (`ApiKeys.view/2`: that
project's role and scopes) in `pk_api_key`, with that project's gates and
floors. `Json.require_scope/2` remembers each scope it checked in
`pk_required`, and `Json.still_allowed/1` re-checks all of them after a move.
**Order matters:** select the project (`scope_project` / `fetch`) first, then
`require_scope` — the other way round, the home project's access would
authorise a call in another project; `still_allowed` is the backstop.

`GET /project` carries `parent_uuid` and `subprojects` (direct children);
`POST /subprojects` creates one through `Projects.create_subproject/2`
(feature `subprojects`, action `create_tasks`, scope `tasks:write`, activity
`projects.subproject_created` with the API metadata), at most seven levels
down. The agent guide's "Projects and access" section teaches the model, its
"Sub-projects" section the pattern: one sub-project per piece of work, tasks
created with `project` set to it.

## Short names: keys and refs

A project has a **key** (`ANDI`) and a task a **number** in its project; together
they are the task's **ref**, `ANDI-42` (`PhoenixKitProjects.Refs`, chain V22;
Max for the boss, 2026-10-10: *"everything uses the UUID, which is very not user
friendly… kind of like Jira style"*). The uuid stays the identity; a ref is a
locator on top of it.

- `Projects.get_project/1` and `get_assignment/1` take a uuid or a ref, so every
  path param resolves either (`TasksController.fetch/2` — resolve first, then
  hold the result to the key's reach, so a foreign ref is the same 404 as an
  unknown one) and so does `project` (`Json.scope_project/2`).
- `Json.task/4` answers `ref`, `number` and — for a sub-project row —
  `parent_ref`: there `ref` is the CHILD's key, so an agent that takes the row's
  ref logs against the child and not against the linking row (grok's point on the
  design panel). `Json.project/1` answers `key`.
- A key can be renamed; the registry (`phoenix_kit_project_keys`) keeps every key
  a project has had and never hands one on, a deleted project's included. The
  agent guide says: store uuids, show refs.

## What a project's settings decide for an agent

Two keys in the project's `settings` JSONB (the form's edit card, chain V19 for
the task columns): **`completion`** — `auto` (the default: the last open row
done completes the project and the completion climbs) or `manual` (ongoing
work: never completes on its own, every task done is `caught_up`, an ongoing
child never completes its parent; copied to new sub-projects) — and
**`agents`** — `take_started_task`, `edit_foreign_text`, `delete_tasks`
(`none` | `own` | `any`), `amend_own_ledger`, read back as `agent_policy` on
`/me` and `/project`. Tasks carry who created and who started them (a person
and/or a key), `waiting_on`, `origin`, labels by name, and their place in the
project's outline — tasks sit under tasks (`parent_task`, `depth`, `subtasks:
{done, total}`; `parent` on create and update, `POST /tasks/{id}/move`,
`POST /tasks/batch` for many lines at once, `GET /tasks?parent=`). Completing
a task completes what is under it; the last subtask done completes its parent
unless the project turned that off; reopening a subtask reopens its parents;
`DELETE` of a task with subtasks needs `cascade=true`;
`GET /briefing` is the recovery read, `POST`/`GET /notes` the project's own
notes, `updated_since` the poll. AGENTS.md ("What the first agent on the API
asked for") has the map from each ask to its code.

**Short refs in text.** Write `#ANDI-42` (or `#ANDI` for a project) in a
description or a note and it is stored as a link to that task: the text comes
back as `#[project_task:uuid|ANDI-42]`, the stored form, which points at the
uuid and so survives a renamed key or a moved project. A ref that names nothing,
or a project outside the key's reach, stays the text it was (so writing a ref
never says whether something the key cannot open exists).
`PhoenixKitProjects.RefText`.

Records link by **mention token** (`#[type:uuid|label]` in a task's
description — the forms' own way): `interaction:` on a task, `tasks:` on an
interaction, read back as `interactions` / `tasks`. The ledger is readable
(`GET /entries`, `GET /tasks/{id}/entries`), events too (`GET /events`), and
the briefing carries the client's latest interactions, what is planned with
the client (`client.planned`) and the next calendar events.

**A plan with the client is an interaction** (CRM V9), not a calendar event:
`status: "planned"` on `POST /ext/interactions`, then the same record is
moved, logged (`status: "happened"`) or cancelled by `PATCH`. An extension
may also put its dated things on the project's Calendar tab, read-only
(`calendar: {module, fun}` in its declaration → `Extensions.calendar_items/3`;
`Extensions.calendar_changed/1` tells open pages to read again) — the CRM
does, for the project's interactions.

## The calls

`GET /me` is the entry point (key, `home_project` — `project` is kept as
its alias for older agents — features on, `allowed_actions` there, every
project reached as `projects` with its `access`, docs URLs). Tasks: `GET /tasks[?status=]`, `POST /tasks` (a one-off task at the
bottom of the plan, `ad_hoc: true`), `GET /tasks/:id`, `PATCH /tasks/:id`
(content and plan fields, never status; title/description only on an ad-hoc
task — a shared library task answers 409 `library_task`),
`POST /tasks/:id/transition {status}` with `start` / `complete` / `reopen` as
aliases through the same path (panel: one state machine, aliases must not
drift). Ledger: `POST /tasks/:id/time`, `POST /time` (minutes), `POST
/tasks/:id/usage`, `POST /usage` (tokens, cost_cents, model). Project:
`GET /project`, `POST /project/status {slug}` — workflow statuses belong to the
project, not to tasks, which have only todo / in_progress / done. Discussion:
`GET /tasks/:id/comments`, `POST /tasks/:id/comments {content, parent?}`
(`CommentsController`, V24) — the thread people write under a task, apart from
the agent's notes; `comments:read` / `comments:write`, the `:view` /
`:comment` floors, the comments module switched on, `Idempotency-Key`
required on a post, written as the person the key acts for (else its maker)
and labelled with the key's name.

Which scope each call needs is the `scope` column of `Docs.endpoints/0`, kept
equal to the controller's `require_scope`. In short: `project:read` /
`:write` — `GET /project` / `POST /project/status`; `tasks:read` — task
lists, a task, the briefing; `tasks:write` — create, update, move, batch,
delete, sub-projects, task ↔ interaction links; `status:write` — start,
complete, reopen, transition; `notes:*` — task and project notes; `time:read`
— `/entries`, `/tasks/:id/entries`, `/hours`; `time:write` / `usage:write` —
the ledger appends and corrections of each kind; `events:read`;
`people:read`.

Every error is `{"error": {"code", "message", "details"?}}` with a stable code;
messages are English and locale-free on purpose (a machine contract).

## Idempotency

`phoenix_kit_project_api_idempotency` stores `{status, body}` under
(key, `Idempotency-Key` header) — the header is scoped per project (stored as
sha256 of `project_uuid:header`, V24), so the same header sent to two projects
is two requests; a replay answers the stored response with an
`Idempotent-Replayed: true` header. **Required** on the ledger POSTs (appends
nobody can undo), honoured on task create and transitions. Panel: the one
thing to block v1 on. A retry that arrives while the first request with that key
is still running answers 409 `in_progress` and runs nothing. "Still running" is
a database fact, not a timer: the request pins a connection and holds a Postgres
session advisory lock on (key, header) while it works, so a slow call is never
mistaken for a dead one. If the request dies (a crash, a kill, the node going
down) its connection closes, Postgres drops the lock, and the next retry takes
the key over and runs the work — never two runs side by side, never a key stuck
for ever. The one window no scheme closes: a request that died *after* its
work committed and *before* its answer was stored is run again by the retry, so
after a crash an agent that cares should check what the first attempt did. The
connection must be session-stable — a transaction-pooling proxy (PgBouncer's
transaction mode) between the app and Postgres would make the lock meaningless.

## Records an extension puts on the API

`/ext/<resource>`: an extension declares `api: Module` on its extension map
and implements `PhoenixKitProjects.Extensions.ApiProvider`; this module
serves list / get / create / update under its own checks (the provider's
scopes, the extension on the project, the provider's action at the member
floor) and the provider's `docs/0` rows join the generated docs. The CRM's
`/ext/interactions` (a project's meetings, calls, messages: type, subject,
body, when, duration, parties, the planned event they are the record of) is
the first.

## Task notes

`TaskNotes` (see AGENTS.md "Task notes"): `POST /tasks/:id/notes` takes
`summary` (required, ≤ 240), `content`, `outcome`, `next_steps`, `refs`
(≤ 20 of `{type, id, url?, label?}`), `usage` (`tokens`, `cost_cents`,
`minutes`, `model`, `occurred_at`; needs `usage:write`, the ledger gate and
the `log_time` floor) — `Idempotency-Key` required. The note is a comment
on `project_task_notes`; its usage is ledger rows in the same transaction,
linked both ways. `GET /tasks/:id/notes` lists them oldest first with
`direction` / `latest_agent_note` / `latest_human_note` first; `GET
/tasks/:id` carries `direction`, `last_outcome`, `latest_agent_note`,
`display_summary` and `totals`. A key cannot write a `redirect`; a person
does, from the notes drawer. Notes need the comments module switched on
(`403 feature_disabled`, feature `notes`); a key with nobody behind it (no
person acted for and no minter) cannot write notes (`403 forbidden`).

## Rate limit

`Web.Api.RateLimit`: a fixed window per key on core's Hammer ETS backend (the
one the portal's limiter shares), applied in `Web.Api.Auth` right after the
key is known — before any controller, so a refused call is never stored as an
idempotent reply. Default 300 calls per 60 s;
`config :phoenix_kit_projects, :api_rate_limit, limit: 300, window_ms: 60_000`,
`limit: nil` switches it off. Every authenticated response carries
`X-RateLimit-Limit` / `X-RateLimit-Remaining`; over the limit is 429
`rate_limited` with `Retry-After` (seconds) and the same figure in `details`.
A limiter failure denies, as the house rule for abuse controls says. The
docs print the live figure, so an agent reads what applies on this site.

## Who a task is for

`assignee` on a task is who it is for: `{kind, uuid, name}` with kind
`person`, `team` or `department`, or null. On create and PATCH it takes
`"me"` (the staff person of the user a personal key acts for; a 422 for a
shared agent), a person's uuid, `{"team": uuid}` or `{"department": uuid}`;
null clears it and leaving it out changes nothing. One assignee at a time,
as in the form. It needs the `assignees` feature (403 `feature_disabled`)
and the `assign_tasks` action, checked only when the field is sent, so a
plain create still works with the feature off. `GET /people?q=` lists who
a task can be for, by uuid and name and never by email. `GET
/tasks?assignee=me|none|<person uuid>` filters; the briefing rows carry
`assignee` and `assigned_to_me`, and `counts.assigned_to_me`. `/me` gives
`acting_for.person_uuid`. A sub-project row answers its nested project's
assignee. Nothing is assigned by default: an agent passes `"me"`.

## A task's own dates

`start_date` and `end_date` on a task are calendar days (`YYYY-MM-DD`), both
optional, either alone, the end never before the start; null or an empty
string clears one. They are not moments: no time and no zone. A dated task
sits on those days in the calendar and the timeline; an undated one is still
placed by its duration and its place in the order. `overdue` is true once the
end date has passed and the task is not done; the briefing counts those in
`counts.overdue`, and `GET /tasks?due_before=<day>&status=open` lists what is
owed by a day. A value that is not a day is a 422 with nothing written.

## When the work happened

The four ledger POSTs take an optional `occurred_at` (ISO 8601, any offset,
truncated to the second, at most 5 minutes ahead of the server's clock). It is
stored as the entry's `ended_at` and echoed as `occurred_at`; `inserted_at`
stays the receipt time (`recorded_at`). A task's `totals` are lifetime;
`GET /hours` is the period read.

## Hours for a period

`GET /hours?from=2026-10-01&to=2026-10-31&group_by=person` sums the logged
time of the project — and, unless `include_subprojects=false`, of everything
nested under it — for a period: `totals` (`minutes` is people's time,
`ai_minutes` an agent's, `billable_minutes`, `tokens`, `cost_cents`,
`entries`, `people`) and `groups`, by `person` (the default), `task` or
`day`. `from` / `to` are days (UTC; `to` is included) or ISO 8601 instants;
either may be left out. `worker` narrows to one or more `worker.key`s as a
`group_by=person` answer names them, `billable` to billable time or the rest.
An entry counts on the day the work was done (`occurred_at`), else the day it
was recorded. A person with both an account and a staff record is one line.
It is the read behind the Hours tab (`PhoenixKitProjects.Hours`); scope
`time:read`, like `GET /entries`.

## Not in v1

- **Webhooks** on task events (the module already broadcasts them on PubSub) —
  so an agent can be handed a task instead of polling. Logged as an idea in
  AGENTS.md on 2026-10-05; Max: skip for now.
- **A running timer** for people.
- **Agent as a member kind** (assignable, mentionable) if agents must outlive
  people as first-class participants — the key principal is the step before it.

## Testing

`test/phoenix_kit_projects/web/api_test.exs` drives the controllers through
the test router (which mirrors `Web.Routes.generate/1`'s API scope) with
`Phoenix.ConnTest`; `test/phoenix_kit_projects/api_keys_test.exs` covers the
credential lifecycle. Both run against the test database like every
integration test here.
