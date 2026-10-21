# Claude (Sonnet 5.5) review — PR #54, after the merge (2026-10-21)

PR #54 (`mdon/global-api-keys`, merge `a987000`): API keys that reach several
projects through grants (V24), per-key usage counters (V25), the
Projects → API keys section, per-action API-key permissions. Read after codex,
zai and grok; this review does not repeat their findings (see `FOLLOW_UP.md`)
and looked at what the request path and the page cost, and at the edges of
the grant bookkeeping.

Read in full: `ApiKeys`, `Web.Api.Auth`, `ApiUsage`, `Json` (view / rescope /
idempotency), `ApiAccess.scopes/1`, the `ApiKeyGrant` / `ApiKey` changesets,
V24/V25 and `down_v24`, and every event handler in `ApiKeysLive` with the
authorization each one applies.

## Verified, no change needed

- **Authorization on the page's events.** Every mutation goes through
  `with_key/4` or `with_grant/4`, which re-read the key and re-check
  `may?/3` (admin, or the key's own person with that action's permission) or,
  for a project owner, that the grant is on a project they own. A non-admin
  posting `kind=shared` falls back to a personal key for themselves
  (`key_person/2`); `person_pick` / `person_search` are admin-only server-side;
  `set_role` on a personal key is a no-op and `ApiKeyGrant.changeset/2`
  validates the role against `ApiKey.roles/0` (never owner) and every scope
  against the known list.
- **Idempotency lease.** The advisory lock is session-level on a pinned
  connection, unlocked in an `after`, named per (key, project-scoped header),
  and a crash drops it with the connection; a pending row found while holding
  the lock is provably orphaned. No path runs the work twice side by side.
- **V24 up/down.** The retry-key rename is guarded on "key has no grant yet"
  and runs before the backfill, so a chain replay renames nothing twice; the
  backfill gives every write its read; `down_v25` runs before `down_v24`
  (the usage table references keys). The FK swap to `ON DELETE SET NULL` is
  drop-then-add, so it is replay-safe.
- **`access_for/2` semantics** match the docs: nearest grant wins, an empty
  nearest grant or `inherit: false` above stops the walk, templates refused.

## Fixed

- **IMPROVEMENT - HIGH — the rate limit ran after the expensive reads.**
  `Web.Api.Auth` resolved the home project, the person's account and
  permissions, and the nearest grant (`ApiKeys.resolve/2` → `access_for/2`:
  project, parent chain, grants) before `RateLimit.hit/1`, and V25 added a
  counter write ahead of it too. A key over its window therefore still cost
  about six statements plus the upsert per refused call, which is exactly the
  load a limit exists to shed. The limit is now taken straight after
  `authenticate/1`; a refused call costs the key lookup and one counter write
  (against the key's stored home, and uncounted for a key with none). The
  other order of everything else is unchanged. The rate limit had no test at
  all; `web/api_rate_limit_test.exs` covers the 429 (code, `retry-after`,
  counted as an error) and pins that a refused call reads less than a served
  one.
- **IMPROVEMENT - HIGH — the API keys page read per key, on mount and after
  every change.** `ApiKeysLive.load/1` ran `ApiKeys.grants/1` per key and
  `addable/3` ran `projects_for/1` (a full `Projects.list_projects` read) per
  editable key — and `Projects.list_projects` again for every shared key —
  then ran `list_for_project/1` per owned project for a non-admin. That breaks
  the "no per-item reads on a hot path" rule: with 8 more keys the mount went
  from 40 to 72 statements, and each Rotate / grid change repeated it. Now one
  `ApiKeys.grants_by_key/1`, one `list_for_projects/1`, and one project-options
  read per distinct person (`project_options/2`); the same page reads 34
  statements at 2 keys and at 10 (`batched_api_keys_page_test.exs`).
- **BUG - MEDIUM — `delete_grant/3` could move the home onto an empty grant.**
  It picked the oldest remaining grant, including one with no scopes ("no
  access"), while `set_home/2` and `down_v24` refuse exactly that. A key whose
  home was removed then answered 403 `no_access` to every call that names no
  project although it had working grants elsewhere. It now picks the oldest
  grant that opens something. Test in `api_key_grants_test.exs`.
- **NITPICK — a crafted `grid` param crashed the LiveView.** `ApiAccess.scopes/1`
  takes a map; `set_grid` passed whatever the client sent. The handler now
  guards `is_map(grid)` and a non-map falls to the catch-all no-op.

## Noted, not changed

- **IMPROVEMENT - MEDIUM — `GET /me` and the task lists walk per project.**
  `ApiKeys.reachable/1` calls `access_for/2` (project, parent chain, grants)
  for every project under an inheriting grant, and `Json.visible_row?/1` /
  `reachable?/1` do the same per sub-project row of a task list. A grant on a
  root with a few hundred sub-projects is a few thousand statements for one
  `/me`. Called once per agent session, so left; the fix is one pass that
  loads the key's grants once and resolves the nearest grant over the already
  fetched tree (`Projects.subtree_uuids/1` plus a parent map), not another
  query per project. Do it when a key with a large tree shows up.
- **IMPROVEMENT - MEDIUM — 450 untranslated strings in de, es, fr, it and pl**
  (30% of 1486 msgids; et and ru are complete, no fuzzy anywhere). The PR
  description says "other locales' new strings left empty"; the repo rule is
  to fill every locale from the code-vs-catalogue diff. Those locales render
  English for the API keys section until a translation pass.
- **NITPICK — new activity actions are undocumented.** `projects.api_key_access_set`
  and `projects.api_key_access_removed` are written by `put_grant/4` /
  `delete_grant/3` but not in AGENTS.md's action list; `rotate` / `revoke`
  log `resource_uuid: key.project_uuid`, which is nil once a key has lost its
  home.
- **NITPICK — usage rows are never pruned.** One row per key, project and day;
  the `day` index exists for it. Bounded and small; add a retention sweep if
  a site mints many keys.
- **NITPICK — the request view lives in the process dictionary**
  (`:pk_api_view`, `RefText` writer). Nothing outside the API reads it and
  every API request overwrites it in `Auth`, so a keep-alive connection
  cannot leak one key's view into another's call; clearing it in a
  `before_send` would make that structural.
- **NITPICK — `put_grant/4` is two statements without a transaction** (the
  grant, then "first grant becomes home"). A crash between them leaves a key
  with a grant and no home; `Auth.home_project/1` falls back to the first
  grant, so it is harmless.
