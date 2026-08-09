# Phase 1 Review — PR #35: Public issue portal, review queue, and list/board rework

**Reviewer:** Pincer 🦀  
**Date:** 2026-08-09  
**PR:** BeamLabEU/phoenix_kit_projects#35  
**Author:** Max Don (mdon)  
**Additions:** +39,241 / **Deletions:** -5,697  
**Phase:** 1 (surface sanity check — not yet merged)

---

## Sanity Check Pass

### Suspicious files / artifacts
None. All changed files are legitimate source code (`.ex`, `.exs`, `.po`, `.pot`,
`mix.exs`, AGENTS.md, README.md, plan docs). No swap files, crash dumps, build
artifacts, or secrets are introduced by this PR.

**Pre-existing note (not from this PR):** `erl_crash.dump` sits in the repo root
and should be gitignored. Not a blocker.

### Dependency changes (`mix.exs`)
One change: `phoenix_kit_staff` is made **optional**.

```elixir
- pk_dep(:phoenix_kit_staff, "~> 0.3"),
+ pk_dep(:phoenix_kit_staff, "~> 0.3", optional: true),
```

The rationale is sound and well-documented in the code: staff tables are owned by
core (V100), not by this package; marking it optional opens a staff-optional seam.
The `WITHOUT_STAFF=1 mix compile` gate proves no stray hard reference sneaks back in.
The `~> 0.3` floor is preserved, so the semantic-versioning guarantee holds when
staff IS installed.

**Also noted:** The module's `extra_applications` list drops `:phoenix_kit_staff`
(it was never safe to list an optional dep there — this is a correct fix).

### Core dependency requirement
This PR calls `PhoenixKit.Mentions`, `PhoenixKitWeb.Components.Core.MentionText`, and
`User.display_name/1` — APIs that ship in **phoenix_kit PR #692**, which is
unreleased to Hex. The PR correctly documents this. **PR #692 must merge first.**
This is a hard compile-time blocker for release, not a code defect.

---

## Security Fixes Review

The PR claims to fix six security issues. All six are real and the fixes look
correct.

### 1. Event interceptor: feature gate mistaken for permission gate ✅ Fixed
**Where:** `project_show_live.ex` — the hub's `handle_event/3` dispatcher.

**Before:** The interceptor checked `fx[gate]` ("is this feature on?") and never
`Authz.can?`. Any project member (or any user who could open the page) could fire
any mutating event regardless of their role.

**After:** A two-stage interceptor:
1. `@gated_events` → `fx[gate]` (feature presence)  
2. `@event_actions` → `Authz.can?(scope, project, action, record)` (permission)

The design is correct: one table, one interceptor, fail-closed. A handler that
forgets its own check is the failure mode being designed out. The record-threading
for relationship grants (assignees may move their own tasks) is properly wired via
`@record_param_events`.

**Handlers that self-check instead of going through `@event_actions`** — `save_work_entry`,
`generate_invoice`, `save_health` — all contain inline `Authz.can?` calls. Verified.

### 2. `settings["authz"]` silently dropped ✅ Fixed
**Where:** `schemas/project.ex` — the settings whitelist.

**Before:** The per-project "who can do what" floors lived in `settings["authz"]`,
but `"authz"` was absent from the changeset's allowed settings keys. Every save
of the project schema silently deleted the floors — a template clone or settings
update quietly reverted all authz overrides to the defaults.

**After:** `"authz" => &is_map/1` added to the allowed settings map alongside
`"features"` and `"visibility"`. Values are re-validated at read time by
`Authz.current_overrides/1`.

### 3. Delete without authorization ✅ Fixed
**Where:** `projects_live.ex` — `handle_event("delete", ...)`.

**Before:** Existence check only — any client event naming any project UUID deleted it.

**After:** `delete_if_permitted/2` calls `Authz.can?(scope, project, :delete_project)`
before acting. The same opaque error is returned for "not found" and "not permitted"
so the handler can't be used to probe which projects exist.

### 4. Project listing scope ✅ Fixed
**Where:** `projects_live.ex` — `load_projects/1`.

**Before:** `Projects.list_projects` returned every project on the site to anyone
with module access. After the permission split, that population includes contractors
who should only see their own projects.

**After:** `Projects.list_projects_for(scope, ...)` and
`Projects.count_projects_for(scope, ...)` scope the query to the viewer. Admins
with `projects.admin_all` still see everything.

### 5. Mention tokens built client-side ✅ Fixed
**Where:** `portal_live.ex` — `handle_event("pk_mention_search", ...)`.

**Before:** The mention typeahead returned candidate data and the client assembled
the `user:<uuid>|display name` token. A record named `x] @[user:<ceo>|see this`
could forge a mention pointing anywhere.

**After:** Tokens are built server-side via `PhoenixKit.Mentions.Token.to_string/4`
and the result is sent to the client as a pre-assembled opaque string.

### 6. Portal attachments invisible to orphan detection ✅ Fixed
**Where:** PR adds `Attachments` module and wires portal file UUIDs into the
project folder so core's orphan collector can find them. The `PortalSubmission`
schema stores `file_uuids` which link to core storage files; the folder
relationship ensures orphan detection reaches them.

### Bonus: Mention visibility (six of eight types failed OPEN) ✅ Fixed
**Where:** `resource_links.ex` — `visible_resource_uuids/2` and `search_resources/2`.

**Before:** The `ResourceLinks` implementation returned all resources (or all that
matched a query) without consulting `Authz`. A mention typeahead could list the
titles of private projects.

**After:** `search_resources/2` narrows through `list_projects_for/2`;
`visible_resource_uuids/2` uses `accessible_project_uuids/1`. Both go through
`Authz`, the same resolver the project pages use.

---

## New Surface: Public Portal

The portal surface is the largest new addition. Key security properties verified:

| Property | Implementation | Status |
|----------|---------------|--------|
| Slug entropy | `16 |> :crypto.strong_rand_bytes() |> Base.url_encode64()` (~22 chars) | ✅ |
| Uniform failure | Unknown slug, disabled ext, capability off → same `:error` | ✅ |
| Rate limiting | 5/min + 30/day per IP bucket, 100/day per project; limiter failure DENIES | ✅ |
| IP source | Peer data only, never XFF | ✅ |
| IPv6 bucketing | /64 prefix (per-address buckets would be free space) | ✅ |
| Honeypot | Hidden field; non-empty = silent reject (same shape as `:invalid`) | ✅ |
| Min fill time | 3 s default; overridable via app env for test | ✅ |
| Image handling | Re-encoded via `ImageProcessor.sanitize`; format forced from sniffed type; 40MP cap from header before `convert`; output capped at `@attachment_max_bytes` | ✅ |
| Attachment cost timing | Re-encode runs AFTER honeypot + fill-time + rate-limit gates | ✅ |
| Review queue | Submissions land as `public: false`, `review_status: "pending"` | ✅ |
| Public vs. secret separation | `board_published_at` required for public board; `public == true` alone is not enough | ✅ |
| Response header privacy | `PortalHeaders` plug: `no-referrer` + `x-robots-tag: noindex` for link/members boards; relaxed only for confirmed public board | ✅ |
| OG previews | Only for public boards; capability slugs never get an unfurlable image URL | ✅ |
| Portal-side authz | `can?(context: :public)` hard-wired to false (pre-wired; documented) | ✅ |
| Slug rotation | Broadcasts `:portal_rotated`; live sessions downgrade immediately | ✅ |

### Notable portal design choices that look correct

**Existence oracle prevention:** `needs_sign_in?/2` returns `true` for ALL anonymous
visitors regardless of the board type. Offering a sign-in link only on members boards
would confirm whether a slug maps to a real board. The uniform offer costs nothing and
reveals nothing.

**Two-conversation namespace:** Portal discussion uses `"project_assignment"` as the
resource type, not `"assignment"`. These are explicitly different conversations — staff
internal notes vs. public replies — and converging the strings would merge them.

**Mention typeahead on portal:** Scoped strictly to what the board already shows.
`#` → issues via the same `issues_query/1` the board renders from. `@` → people
who have already commented on THIS issue only (not the site directory). Candidates
blocked for viewers who may not comment (the composer is hidden, but hidden ≠ absent
from the event handler).

---

## Issues Found

### MEDIUM — `confirm_start_project` not in `@event_actions`

**File:** `lib/phoenix_kit_projects/web/project_show_live.ex`

`confirm_start_project` is listed in `@gated_events` (feature gate: `:lifecycle`)
but is **absent from `@event_actions`**, and its handler calls `do_start_project/2`
with no inline `Authz.can?` check.

Result: any project member — including a `:viewer` — can set the project's
`started_at` by sending this event, as long as the lifecycle feature is on. The
action is not in the `@actions` vocabulary, so there is no role floor for it.

Compare: `archive_project` (a structurally similar container-level action) is in
`@event_actions` with `:archive_project`, which resolves to owner-only. Starting a
project is at least a manager-level act — it is an announcement that the team has
committed — and should be gated equivalently.

**Fix:** Either add `"confirm_start_project" => :edit_settings` (or a new
`:start_project` action at `:manager` floor) to `@event_actions`, or add an
inline `Authz.can?(scope, project, :edit_settings)` guard in the handler.

### LOW — `suggest_public_slug/1` uses weak randomness

**File:** `lib/phoenix_kit_projects/schemas/portal.ex:130`

The fallback when the project name resolves to an empty or reserved slug is
`:rand.uniform(9999)`. This is only a UI suggestion (the admin edits it before
accepting), never an actual capability slug. The real slug uses
`:crypto.strong_rand_bytes(16)`. No security impact, but worth replacing with
`:crypto.strong_rand_bytes(2) |> :binary.decode_unsigned()` for consistency.

### LOW — Missing test coverage for `portal_live` event guard

The portal's `handle_event("pk_mention_search", ...)` refuses when the viewer
may not comment (`may_comment?` gate). There is no integration test asserting that
an anonymous viewer cannot call this event on a `submit_access: "members"` board
and enumerate issue titles. The PR test suite covers the authz module and grants
well; this gap is narrow but worth a ticket.

### INFORMATIONAL — Peer data host configuration requirement

Rate limiting per IP requires the host endpoint to declare
`websocket: [connect_info: [:peer_data, ...]]`. Without it, all submissions share
one bucket (fail-closed, just stricter). The code and module doc both document this
clearly. A deployment checklist item, not a code issue.

---

## Verdict

**Request Changes (one medium blocker)**

The PR is very high quality. The security thinking throughout is sound, the portal's
abuse-resistance layers are well-ordered, the authz model is coherent, and the
event interceptor redesign correctly moves permission enforcement out of individual
handlers and into a single chokepoint. The fixes to the pre-existing security bugs
are all real and correctly implemented.

The one blocker before merge:

1. **`confirm_start_project` needs a permission gate** — a viewer should not be able
   to start a project.

The low-severity items and the core PR #692 dependency are not blockers for review,
but PR #692 must merge before this can be released to Hex.

---

*Phase 2 (deep review with Mistral vibe) will follow after merge approval.*
