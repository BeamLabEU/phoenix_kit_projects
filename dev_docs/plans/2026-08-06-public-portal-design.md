# Public portal — design for review (2026-08-06)

**Status: AWAITING MAX'S SIGN-OFF — no code until approved.** This is the
security-sensitive piece deliberately excluded from unsupervised work;
you asked for the design first. The external panel reviews the security
model after your read (their findings get folded in before code).

## What it is

The per-project **public face**: issue submission and status visibility
for people with NO account — Jira Service-Desk-shaped, sized for this
module. In the catalog since planning; off by default everywhere.

## Product surface (v1)

Per project, three independently-toggleable public capabilities
(extension "portal", default_enabled false, plus per-capability config):

1. **Submit an issue** — a public form (title, description, optional
   email for updates). Creates an assignment in a dedicated "Inbox"
   status (triage), NOT directly into the team's flow.
2. **Public issue list** — read-only list of issues the team chose to
   expose (per-assignment `public` flag, default false — nothing leaks
   by being created), showing title + status category + dates. No
   assignees, no estimates, no internal notes, no ledger — ever.
3. **Status page** — the project's health + progress summary (the strip,
   sans money/AI figures).

Explicit non-goals for v1: public comments, attachments from anonymous
users (spam/abuse magnet), voting, email round-trip threading.

## URL + access model

- Routes ride core's `public_routes/1` contract (locale-prefixed, like
  publishing's public side): `/:locale/portal/:portal_slug`.
- `portal_slug`: a RANDOM 10+ char token generated at enablement, NOT
  the project name — possession of the link is the access grant
  (Basecamp's client-access precedent). Regenerable ("rotate link") to
  revoke. Optional second factor later (passcode) — not v1.
- Every public read scopes through ONE context module
  (`Portal.public_view/1`) that whitelists fields — the LVs never touch
  Projects.* directly, so a refactor can't accidentally widen the
  surface (the lesson from the extension-tab visibility gap).

## Abuse posture

- Submission rate-limited per IP via core's `PhoenixKit.Users.RateLimiter`
  backend (already running for auth), keyed `portal:{project}:{ip}` —
  panel to advise on limits (draft: 5/min, 30/day).
- Honeypot field + minimum-fill-time check (no CAPTCHA dependency v1).
- Size caps: title 200, description 5000; HTML stripped via core's
  hardened sanitizer at render (store raw, sanitize out).
- Submitted email: stored ONLY for the notify-on-status-change feature,
  never rendered publicly; deleted with the issue.
- All submissions land as `source: "portal"` assignments in the Inbox
  status with an activity row (actor nil, metadata carries IP hash) —
  the triage queue is the moderation point. A "block this IP" list per
  project if the panel thinks v1 needs it.

## Data model (chain V8)

- `portal_slug` + `portal_settings` JSONB on the project row (which
  capabilities are on, rotate history), OR a `phoenix_kit_project_portals`
  table (slug UNIQUE, project FK, settings) — table preferred: slug
  lookups are the public entry and deserve their own index + the row
  doubles as the enablement record.
- `assignments.public` boolean default false; `assignments.source`
  varchar default "internal" ("portal" for submissions).
- Submitter email on a separate `portal_submissions` row (assignment FK,
  email, ip_hash, inserted_at) so PII lives in ONE deletable place.

## Authz interaction

- The `:public` context in `Authz.can?/5` already hard-fails everything —
  the portal NEVER consults Authz; it consults only the whitelisting
  Portal context. Admin/member surfaces manage the flags (publish an
  issue = flipping `public` on an assignment, gated `:edit_tasks`).
- The Inbox status: a dedicated slug in the project's status set,
  auto-provisioned when the portal extension enables (via the existing
  Statuses machinery); triage = normal status moves.

## Rollout

1. Panel security review of THIS doc (after your read).
2. V8 + Portal context + tests (incl. hostile-input battery).
3. Public LVs behind `public_routes/1`, browser-verified.
4. Feature announcement in the report; portal stays default-off.

## Questions for you

1. Slug-only access OK for v1, or do you want the optional passcode now?
2. Should submitted issues notify project members (the events-notify
   pipeline is being built anyway) — or a per-project "notify these
   members on new portal issue" list?
3. Is the per-assignment `public` flag the right exposure model, or do
   you want a per-STATUS rule ("everything in Done is public")?
