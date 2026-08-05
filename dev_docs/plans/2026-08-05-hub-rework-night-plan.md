# Projects Hub Rework — Night Plan (2026-08-05)

Boss vision: `phoenix_kit_projects` becomes a **hub** — a project is a lean
container; capabilities plug into individual projects as per-project-enabled
extensions. Site : modules :: project : extensions. Tasks stay IN this module
(boss call, 2026-08-05 — no `phoenix_kit_tasks` split) and become the first
per-project toggle, ClickUp-ClickApps style.

All work tonight is **local commits only** — no pushes, no PRs, no version or
CHANGELOG changes, in any repo. Feature-module repos (all Max-maintained) may
receive local commits; **core `phoenix_kit` gets handoff docs only** (owner-AI
convention), pending Max's morning answer.

## Decisions already made (boss)

- No tasks extraction; per-project toggles instead
- Granular per-project feature flags — spectrum from "complex Jira" to
  "simple todo list" (even statuses/assignees/scheduling are flags)
- Work ledger built in: human time AND AI usage (tokens/cost) per task,
  AI agents as first-class assignable actors
- Public-facing tracker (portal) — in the catalog, NOT tonight (security
  work, not for an unsupervised run)
- Per-project authz: role grants (owner/manager/member/viewer) +
  relationship grants (assignee can update status); "who can X" dropdowns,
  not a Jira scheme editor
- Whiteboards extension on core Fresco/Etcher/Annotations (blank-image
  bridge v1; Max will ask the developer to make the stack image-optional)

## Defaults I'm assuming (contained, reversible)

1. Enablement storage: uuid-keyed rows, toggle semantics, unique
   (project_uuid, module_key) — instance-ready (relax the constraint later)
2. Flags default to **preserving current behavior** for existing projects;
   presets apply to new projects only
3. Members are admin-area-scoped for now (member-facing non-admin surface
   needs a core routes change — deferred with handoff doc)
4. Board view built in-module (no third standalone lib)
5. Statuses keep the entities-backed system; semantic categories layered on
   top rather than replacing it

## Night order (each step = local commit(s), individually green)

| # | Step | Repo(s) |
|---|------|---------|
| 0 | Baseline: suite run, C0 screenshots, this doc | projects |
| 1 | Migration protocol adoption (`Migrations.Schema` V1 baseline + marker) | projects |
| 2 | P1a extension contract + `phoenix_kit_project_modules` + registry | projects |
| 3 | P1b feature flags + presets + Modules & Features panel | projects |
| 4 | P1c enforcement threading (fail-closed, forged-event tests) — MILESTONE | projects |
| 4.5 | Reference extension provider | hello_world |
| 5 | P2a members + roles + `Members.can?/4` + "who can X" | projects |
| 6 | P2b files / activity / health tabs — MILESTONE | projects |
| 7 | `notification_types/0` + `target_uuid` threading | projects |
| 7.5 | Extensions wave 1: CRM Client, Locations Sites, Comments bridge | projects, crm, locations |
| 8 | P3 staff → optional (guards; native user-assignee only if going well) | projects |
| 9 | Board view + priorities/labels | projects |
| 10 | Work ledger + ai metadata-attribution (no migration — metadata map) | projects, ai |
| 11 | Whiteboards (Fresco/Etcher on blank background files) | projects |
| 12 | Project events (hub-side table + phoenix_live_calendar render) | projects |
| 13 | Publishing Docs tab (linked group, list + link-out) | projects (+publishing if needed) |
| 14 | Bookings tab (linked service + embeddable widget) | projects |
| 15 | document_creator Documents tab (project_uuid stamping) | projects, document_creator |
| 16 | Entities Data tab (linked entity, records list) | projects |
| 17 | Billing read-only rollup tab | projects |
| 18 | Dashboards attempt (fallback: link tile) | projects (+dashboards if viable) |
| 19 | Saved views (stretch) | projects |
| F | Full-panel gate + fix round + night report | all touched |

Cut-line philosophy: every commit is individually green (`mix precommit`
unpiped + suite, `PHOENIX_KIT_PATH` where needed); whenever the night ends,
the result is a clean prefix of this list, not a construction site.

## Review cadence

- After each step: fast panel in background (zai, grok, kimi short-prompt,
  codex focused) — repo-anchored prompts, never diffs
- Milestones (post-4, post-6, final): deep codex review in background
- Final: full-panel review of the whole diff, maintainer framing
- Discipline: reproduce-before-fix on every claim; consensus is not
  evidence; CRITICAL findings on foundation layers gate downstream steps
- Findings land as explicit fix commits ("Address panel findings: <step>")

## Explicitly out of scope tonight

Public portal · pushes/PRs/versions · core repo commits (handoff docs
instead) · calendar/dashboards core-owned schema changes · staff
work_schedule · billing invoicing leg (rides the ledger later)

## Core suggestions (handoff docs to write during the night)

1. Annotation-change PubSub (live co-drawing for whiteboards)
2. File-less / virtual-canvas annotations (whiteboards without backing image)
3. Generalize authenticated module-route discovery (integration.ex hardcodes
   per module today, unlike `public_routes/1`) — unblocks the member-facing
   projects surface

## Known pre-existing issues (flagged, not chased)

- `seed_shared_status_entity!` settings-deadlock flake (on record, PR #31)
- Overview overdue-chip test can fail at local-midnight date boundaries —
  tonight's run crosses midnight; failures of that one test are environmental
