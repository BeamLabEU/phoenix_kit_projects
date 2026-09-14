# Quality sweep — PR #43 (dashboard places)

Run 2026-09-11 against the playbook in
`Elixir/dev_docs/quality_sweep.md`.

## Phase 1 — PR catch-up

Seven PR folders had no `FOLLOW_UP.md`; all seven now do, so every folder under
`dev_docs/pull_requests/2026/` is triaged (23/23).

| PR | Verdict |
|---|---|
| #31 admin-ui-overhaul | 3 BUGs already fixed; **1 still live** (`ilike` escaping duplicated between `projects.ex:145` and `assignees.ex:179-184`) |
| #32 ai-multilang-tabs | No findings; re-verified |
| #34 core-version-floor | All 4 resolved — **but the same class recurred**, see below |
| #35 public-portal-review-queue | The ✅ set plus `Features.gates/1` now resolved; **6 still live**, including the one this PR makes hotter |
| #36 core-slug-rule | No findings; re-verified |
| #38 nav-tabs-assignment-form | Resolved |
| #40 project-tabs-drawer-forms | 6 resolved; **2 still live** |

### The recurrence worth knowing about

PR #34 was about a lock left out of sync. It happened again, worse: `mix.exs`
declared `phoenix_kit_templates` and `mix.lock` never carried it, so a clean
checkout stopped at *"the dependency is not locked"* **before compiling
anything**. Every gate in the playbook runs after `deps.get`, so nothing in the
pipeline can see this — only a fresh clone can. Fixed in a commit of its own
(`ce2752d`) so it can be dropped independently.

`git stash -u && mix compile` answers "does this build for someone who just
cloned it", and no other step asks that question.

## Phase 2 — triage

Two `Explore` agents (this PR's surface is small; the module has had three
prior sweeps). **Two headline findings did not survive verification** —
recorded so they are not re-raised:

- *"`slug: "projects"` collides with this module's `projects/:id` and lights up
  the list tab on the dashboard page."* No. Slot URLs are built by the
  dashboards package as `dashboards/places/<slug>`, never under this module's
  path; `parent_tab` sets sidebar position only. Verified in code and in a
  browser.
- *"The `projects.project` slot is missing a `slug`."* It is a `:record_tab`,
  which generates no route at all.

### Fixed

| Finding | Fix |
|---|---|
| **The whole new slot surface had zero tests.** Three things could vanish silently: a typo'd `parent_tab` (core drops an unknown parent without an error), a `provides` kind drifting from the `viewer_context` clause head (every viewer bind then resolves to `nil` and renders "pick a project"), and the `context:` key on the widget's project field (drop it and one shared board quietly reverts to a copy per project) | New `test/phoenix_kit_projects/dashboard_slots_test.exs`, 7 tests, one per silent-break |
| **26 user-visible strings reached no catalogue at all**, while all seven locales sat at perfect parity with zero empty `msgstr` — a string absent from every catalogue is invisible to both parity and empty-scans by construction. Fixed the subset where anchoring alone makes translation work: 4 `%Tab{}` labels that carry a live `gettext_backend` hook (`Project Files/Activity/Members/Modules`) and 3 `permission_metadata/0` strings, plus a dead anchor pointing at a description rewritten long ago | Anchored in `Web.GettextManifest`, dead anchor dropped, 5 coincidentally-covered labels made intentional. 7 new msgids × 7 locales written by hand |
| **`phoenix_kit_dashboard_viewer_context/2` rescued silently.** A schema drift making it raise on every call would leave every shared board showing "pick a project" forever with nothing in the log | `Logger.warning`, mirroring `ext_tabs_for`'s handling |
| The `projects.project` description read "a dashboard tab inside a single project" — the opposite of what it is | Reworded in all 7 locales |

### Surfaced, not changed

- **`list_projects_for/2` still materialises full `%Project{}` structs to build
  a uuid list** (`projects.ex:889-896` → `Members.accessible_projects/1`).
  Flagged in PR #35 and **this PR makes it hotter**: the new
  `phoenix_kit_dashboard_viewer_context/2` calls it with `limit: 2`, but the
  `LIMIT` bounds the outer query only — the scoping step loads every accessible
  project first. Fix shape is a `Members.accessible_project_uuids/1` selecting
  `p.uuid`; left out because it touches a shared authorization path and wants
  its own change with its own equivalence test.
- **Deactivated users**: `Authz.subject_user_uuid/1` matches on the presence of
  a user struct; core ships `Scope.user_active?/1` and nothing in `lib/` calls
  it. In practice the dashboards side already filters — its embed identity runs
  `Auth.ensure_active_user/1` — so the exposure needs a caller that builds a
  scope some other way.
- 19 remaining i18n misses that anchoring alone cannot fix: `notification_types/0`
  (core renders them raw with no backend hook — an upstream change),
  `Features.presets/0` and `creation_blocks/0` (render sites bypass
  `translate_catalog/1`), and 4 `String.capitalize` humanized field names.
- The still-live items from PRs #31, #35 and #40 listed in their `FOLLOW_UP.md`.

## C14 — stale-ref sweep

`IO.inspect`/`puts` 0 · `TODO`/`FIXME`/`HACK`/`XXX` 0 · `Task.start(` 0 ·
commented-out code 0 (3 regex false positives on prose beginning "if") ·
`String.capitalize` 4, all on `Atom.to_string(field)` humanizations, never on
gettext output.

**i18n, code-vs-catalogue:** every `gettext_noop` literal in `lib/` diffed
against `default.pot` — 0 missing after the fixes; 0 fuzzy; 1 empty `msgstr`
per locale (the header).

## Verification

- 1511 tests + 7 added, 0 failures
- `mix precommit` clean in this repo
