# Hub Rework — Night Report (2026-08-05)

All work is **local commits only** — nothing pushed, no PRs, no version or
CHANGELOG changes anywhere. Every commit's tree passed
`PHOENIX_KIT_PATH=../phoenix_kit mix test` + `mix precommit` (suite grew
955 → 1056+ along the way). Read this top-to-bottom, then `git log
--oneline aa8e53a..HEAD` per repo.

## What exists now (the short version)

The projects module is a **hub**. A project is a container whose
capabilities are chosen per project:

- **Modules & Features panel** per project (header kebab → "Modules &
  features"): Level 1 = extensions (built-in Tasks/Files/Discussions +
  any module's contribution) with per-instance config forms; Level 2 =
  granular feature flags with a dependency matrix
  (disable-and-explain); presets (Simple to-do list / Standard / Full
  tracker) + a site default for new projects.
- **The extension contract is real and proven**: any module exports
  `phoenix_kit_project_extensions/0` (duck-typed one-way, the dashboards
  widget shape) and its tabs render as first-class view tabs on the
  project page via `live_render` + a session contract. Providers live in
  `hello_world` (the annotated reference), `crm` (Client tab),
  `locations` (Sites tab). Browser-verified: the Acme dev project shows
  **List / Board / Timeline / Calendar / Hello**.
- **Enforcement is fail-closed at the server**: every gated event runs
  through one dispatcher; forged events are refused; smuggled params are
  stripped at save time with save-time gate re-resolution.
- **Native hub layer**: Members (core users, owner/manager/member/viewer,
  last-owner guard, creator auto-owner), Files (core Storage,
  staff-pattern folder scoping), Activity (core feed per project),
  Health (the manual Basecamp-style "Needle").
- **Authorization**: `Authz.can?/5` = admin override ∨ (role floor ∨
  relationship grant [assignee may move their own task]) with per-project
  "who can X" overrides; `:public` context pre-wired fail-closed.
- **Notifications**: `notification_types/0` (membership/tasks/health
  toggles in core's prefs UI) + `target_uuid` threading, so member and
  assignee events reach users through core's channels automatically.
- **Board view**: kanban columns over the same task data (v1: status
  buttons move cards; drag is a follow-up).
- **Work ledger** (the boss's unified effort tracker): chain V4
  `phoenix_kit_project_work_entries` — actor can be a user, staff person,
  or AI AGENT; `kind` fixes the unit (time=minutes / tokens / cost=cents);
  append-only. Show page: effort strip (logged + billable time, AI tokens
  + $) in the schedule card, per-task logged chips, hours+minutes log
  modal behind a new `ledger` flag + `Authz :log_time` (manager floor,
  assignee relationship grant). `Ledger.record_ai/3` is the ready seam
  the phoenix_kit_ai attribution wave calls (ai-repo side deferred per
  panel advice).
- **Whiteboards** (chain V5): freeform Fresco/Etcher drawing boards as a
  built-in extension whose surface is a contributed TAB through the same
  pipeline external providers use (dogfoods the tab contract; default
  off). Each board = a server-generated solid-white PNG registered as a
  real Storage file (core's annotation persistence hard-FKs
  phoenix_kit_files) + core's `MediaCanvasViewer` doing all the drawing.
  The PNG is pure Elixir and SALTED (a tEXt uuid chunk) because
  `store_file` dedups per-user by content checksum — unsalted, same-size
  boards would collide onto one file sharing one annotation set.
  Browser-proven: created a board on Acme, drew a rectangle, the
  annotation row landed, and the drawing re-renders after reload.
- **Events** (chain V6): dated happenings that aren't tasks — meetings,
  milestones, reviews — as a built-in extension tab (default off):
  phoenix_live_calendar month grid (all-day bars, timed chips with HH:MM
  prefixes), server-rendered Upcoming list, create/detail modals, UTC
  frame. No notification fan-out yet (events carry no target_uuid —
  who an event notifies is a daylight product call).
- **Wave-2 provider tabs**: `phoenix_kit_entities` contributes a
  **Data** tab (config-links one entity per project, read-only records
  list w/ admin link-outs; unconfigured state lists entity uuids to
  copy) and `phoenix_kit_publishing` contributes a **Docs** tab
  (config-links a group by SLUG — groups are slug-keyed in that package;
  published entries + editor link-outs). Both follow the CRM/locations
  provider pattern with contract tests; both browser-verified on Acme.
  **Acme now renders NINE tabs** (List / Board / Timeline / Calendar /
  Events / Whiteboards / Data / Docs / Hello) — the hub thesis
  end-to-end.
- **Migrations are module-owned**: `PhoenixKitProjects.Migrations.Schema`
  (V1 baseline of the core-built shape, V2 enablement, V3 members,
  V4 work ledger, V5 whiteboards, V6 events) on core's
  `migration_module/0` protocol — no core releases in the loop.

## Commits (chronological)

**phoenix_kit_projects** (`aa8e53a..`): night plan doc · dep-lock float
(ai 0.16→0.17.1 — HEAD couldn't compile against its own lock) + brittle
attr-order test fix · migration protocol V1+V2 (`9add57a`) · target_uuid
misuse fix — 15 sites, a panel find (`e7f0af0`) · panel plan-amendments
doc · extension contract/registry/context + Authz vocabulary (`4a573eb`)
· flags + presets + Modules panel (`ae69b2a`) · enforcement threading
(`75c2d79`) · members + roles V3 + Authz deepening (`78f5445`) ·
Files/Activity/Health (`bd474ed`) · notification wiring (`48ef16d`) ·
extension-tab rendering + discussions bridge (`e937a3b`) · Board view
(`6bc04d3`) · panel-fix round (`9cf1abd`, see below) · work ledger V4
(`371cc31`) + its panel fix round (`c838bbc`, `99525c1`, `010adac`) ·
whiteboards V5 (`cc2013c`) + its panel round (`231c49d`, `8eb3fe1`) ·
events V6 (`c084e13`) + its panel round (`e739dc2`).

**phoenix_kit_entities**: Data tab provider (`5621688`).
**phoenix_kit_publishing**: Docs tab provider (`bdd7d8c`).

**phoenix_kit_hello_world**: reference provider + contract test
(`ddef65c`), AGENTS doc (`524c85f`). **phoenix_kit_crm**: Client provider
(`7a524d3`). **phoenix_kit_locations**: Sites provider (`9a41be8`).

**Dev environment**: parent dev DB carries chain V2–V6 (applied via
psql — the real path is `mix phoenix_kit.update`, which discovers
`migration_module/0`); dev showcase state: Acme has the hello_world
extension enabled, 1h30m logged time, a seeded AI tokens+cost pair
(245k tokens / $1.87) so the effort strip demonstrates itself, a
"Relaunch moodboard" whiteboard with a drawn rectangle, and a
"Relaunch go-live review" event on Aug 12.

## External-AI panel — findings & dispositions

Four review rounds ran (plan review pre-code; Steps 1, 2; P1 milestone).
Roster reality: zai + grok delivered consistently; codex delivered two
rounds then hit its usage limit (locked out until Aug 11); kimi
billing-capped; m2 402. Full compiled report in the session log.

**Adopted before code existed** (plan round): instance_key + config in
the enablement identity; the full contract surface up front; authz
vocabulary before enforcement; step-8 rescope; ledger wording; provider-
side 7.5 shape. **Confirmed + fixed during the night**: the
`target_uuid` entity-uuid misuse (ZAI); `enable_system` not refreshing
the registry (Grok); the project form's ungated `counts_weekends`
(compiler grounding).

**Step-10 round** (zai/gemini/grok on the ledger commit) — all three
dispositioned, three fix commits:
- Gemini + ZAI + Grok all caught the SAME real HIGH independently:
  `cost_cents: 0` is TRUTHY in Elixir, so a free/cached AI call built a
  zero-amount cost entry that failed validation AFTER the tokens row
  committed (orphan write, retry double-counts). Fixed (`c838bbc`):
  positive-amount filtering, all-or-nothing transaction,
  activity/broadcast after commit. Reproduced with failing tests first.
- ZAI/Grok LOW: the claimed authz behavior had no tests. Closed
  (`99525c1`): resolver-level floor/grant tests + an LV deny-path test
  with a real plain-member user.
- Grok MEDIUM (uniquely found): logging time on an EXPANDED sub-project
  child task attributed the entry to the parent project while the
  assignment belongs to the child. Fixed (`010adac`): attribute to the
  assignment's owning project; chips now resolve from the displayed
  assignment set. Parent-strip rollup of child effort = deliberate v1
  non-goal.

**Step-11 round** (zai/gemini/grok on the whiteboards commit) — full
three-way consensus, everything dispositioned:
- All three found the orphaned-background-file HIGH/MEDIUM: the blank
  PNG was stored BEFORE the board name was validated, so a whitespace
  name leaked one file row + blob per failed attempt. Fixed (`231c49d`):
  name validated before Storage is touched; residual insert failures
  best-effort delete the background. Reproduced-first.
- Grok + ZAI: the PNG writer materialized the full raw raster before
  compressing (~190 MB at the 8000×8000 API cap). Fixed (`8eb3fe1`):
  streamed zlib deflate, one row resident; pinned by an inflate-back
  equivalence test.
- Gemini's claim that `viewer_only={true}` makes the canvas read-only
  was REFUTED with direct browser evidence (drawing persisted and
  re-rendered); Grok and ZAI independently confirmed the flag is
  chrome-only. All three validated the PNG format internals (CRC
  endianness, IHDR, filter bytes, zlib wrapper, tEXt salt) and the V5
  DDL + version-aware down/1.

**Step-12 round** (zai/grok on the events commit; gemini timed out
mid-output): Grok found three real defects, ZAI independently confirmed
two — all fixed in `e739dc2`, reproduced-first: (1) Upcoming dropped
all-day events for their entire active day (midnight comparisons);
(2) a timed end WITHOUT an end date silently persisted open-ended;
(3) a PubSub delete left a stale detail panel open. Gemini's visible
HIGH (nil title crashes String.trim in update_change) was REFUTED
empirically — the new tests get a clean {:error, changeset}; both kept
as regression pins.

**The combined-report fix round** (last commit): version-aware `down/1`
(R1-1 HIGH — a plain `mix ecto.rollback` after an update dropped EVERY
projects table); fresh-project reload in the flag-change handler (R3-1
HIGH — open pages kept accepting gated mutations forever); the
sub-project save/validate/generate branch gated + stripped (R3-2 HIGH);
pending-dep gate (R3-3 HIGH); save-time fx re-resolution in both forms
(R3-4); status-mode fold gated (R3-5); enable/disable upsert on the
identity index (R2-1); enable preserves stored name and MERGES config
(R2-5/6); `can?` fail-closed on unknown context instead of crashing
(R2-3); marker query classoid anchor (R1-4); `validate_prefix!` at the
chain entries (R1-3).

**Accepted-as-documented / morning list** (not fixed tonight):
- R1-2: the IF-NOT-EXISTS baseline can stamp a DRIFTED marker-less table
  as current — mitigated by the pg_dump-derived baseline + the core ≥
  V128 contract; a shape-verify step would harden it.
- R1-5/R1-6: `rescue → 0` conflates errors with not-installed;
  replayed host migrations run the current chain (protocol design).
- R3-6: on a subprojects-off project the sub-project row's destructive
  Remove stays available while gentle Detach is refused — gate
  inconsistency, decide intent.
- R3-7: `default_gates/0` resolves `requires` one level deep — latent
  while all defaults are true.
- `Features.set_flags/3` read-modify-writes the whole settings map —
  same race shape as R2-1, needs the same treatment.

## Defaults I assumed (all reversible)

Instance-ready toggle rows (unique per project+ext+instance, v1 UI =
toggle) · flags default to preserving current behavior; presets write
explicit values; absence = inherit catalog default (frozen semantics) ·
members admin-scoped (member-facing surface needs the core
authenticated-routes generalization — deferred) · board built in-module
· `enabled_by`/`invited_by` are FK-less provenance (activity is the
audit trail) · extension toggles log in the CONTEXT (presets must audit
too — a deliberate deviation from the LV-layer convention).

## Deferred / not done (and why)

- **Step 8 (staff → optional)**: the designated clock-cut. Diffuse,
  regression-prone; nothing tonight blocks doing it next.
- **Wave-2 remainder** (designed, not built — the API scout's full map
  is in the session log):
  - *document_creator Documents tab (15)*: no clean per-project linkage
    exists — documents have no project field and no filtered list API;
    the honest v1 would config-link a taxonomy category. Deferred
    rather than shipping a stamping hack into `data`.
  - *billing rollup (17)*: no project linkage on any billing schema and
    no metadata query path; the plausible zero-schema design is
    CUSTOMER-scoped (config a billing_profile/user uuid + the existing
    list_user_* functions), pairing with the CRM Client tab. Needs your
    call on whether customer-scoped is the intended semantics.
  - *bookings tab (14)*: untouched per the hands-off rule (in-progress
    unpushed module).
  - *dashboards attempt (18)* and *saved views (19)*: out of night.
- **AI attribution's ai-repo side**: `Ledger.record_ai/3` is live and
  tested; wiring phoenix_kit_ai call sites to report usage into it is a
  daylight change to that repo (panel advice: don't thread another
  module's internals unsupervised). Display currency for cost cents is
  hardcoded `$` in v1.
- **Priorities/labels**: board shipped without them (chain V4 material).
- **Public portal**: excluded by plan (security work, not unsupervised).
- **Core suggestions** (not committed to core despite permission —
  each deserves its own daylight PR): annotation-change PubSub (live
  co-drawing), file-less canvas for Etcher, generalize authenticated
  module-route discovery (currently hardcoded per module in
  `integration.ex`, unlike `public_routes/1`), dashboards Registry has
  the same ensure_loaded discovery bug fixed here tonight. NEW from the
  whiteboards work (both reproduced on core's own media page, so they're
  core behaviors, not whiteboards bugs): (a) the jsdelivr lazy-loader
  can miss the FIRST-ever canvas mount — Etcher's toolbar is absent
  until a revisit; (b) drawn shapes persist with `creator_uuid` NULL
  (the adapter strips creator from the wire payload; `creator_attrs`
  evidently isn't applied on the shape-sync path).

## Morning list (small, concrete)

- Entities module suite has **18 pre-existing failures** at `0a8dcb3`
  (before tonight's change — verified by baseline run; likely stale
  local env vs the merged PR).
- Core: jsdelivr lazy-loader misses the FIRST-ever canvas mount;
  drawn shapes store `creator_uuid` NULL (both reproduced on core's own
  media page).
- Dashboards Registry has the same cold-VM `ensure_loaded` discovery bug
  fixed in the projects Registry tonight.
- Events: decide who an event should notify (no target_uuid yet);
  ledger cost display currency is hardcoded `$`.
- The Modules panel renders every config field as a text input —
  `:select` isn't implemented; provider tabs list candidates to copy
  as the workaround.
- Whiteboards: parent-strip rollup of child-project logged time is a
  deliberate v1 non-goal (data attributes to the owning project).
- Gettext: tonight's new strings need an extraction/po pass.

## How to review

1. This doc, then the plan doc + panel amendments
   (`2026-08-05-hub-rework-night-plan.md`).
2. `git log -p aa8e53a..HEAD` — commit messages carry the reasoning and
   the panel-find references.
3. Screenshots in the workspace root: `c0_night_*` (before) vs
   `step3_modules_panel*`, `step4_show_tasks_off`, `step6_activity_page`,
   `step75_hello_ext_tab` (after).
4. Live: `phoenix_kit_parent` on :4000 (running the final code) — the
   Acme project's kebab menu reaches every new surface.
