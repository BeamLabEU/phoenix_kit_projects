# Follow-up — PR #6 (embed support + ETA refactor + Phase 2 sweep)

**Date:** 2026-05-13
**Reviewer artifacts:** Post-merge read of [issue #5][i5] +
[PR #6][pr6] against the merged tree on `main` (`14e97d7`). Skill
gate: `elixir:phoenix-thinking` (Iron Law on `mount/3` queries, embed
contract via `live_render`).

[i5]: https://github.com/BeamLabEU/phoenix_kit_projects/issues/5
[pr6]: https://github.com/BeamLabEU/phoenix_kit_projects/pull/6

## Issue #5 coverage — verdict

Substantially over-delivered against the original ask. The issue
requested a single `mount(:not_mounted_at_router, ...)` clause on
`ProjectShowLive`; PR #6 made **all 9 LVs** embeddable, added shared
`Web.Helpers` plumbing (`resolve_live_action/3`, `resolve_action_params/2`,
`navigate_after_save/2`), an open-redirect guard with 5 attack-vector
tests, 28 `live_isolated/3` contract tests, and the per-LV diagnosis
in `dev_docs/embedding_audit.md`.

Issue author's three "things to verify":

- **`Paths.*` push_navigate from a nested LV** — pinned by embed
  tests that assert `{:error, {:live_redirect, %{to: ...}}}` shapes
  (`embedding_test.exs:205, 290, 323, 365`).
- **Comments drawer + PubSub scoping** — `topic_project(uuid)` is
  per-project (`pub_sub.ex:43`); two embeds of the same project on
  one page each have their own socket subscription. Library-level
  `topic_tasks()` is global — see [`Skipped`](#skipped) below for the
  framework-wide rationale.
- **Unique `id` per `live_render` embed** — documented in
  `embedding_audit.md` as the embedder's responsibility, which is the
  right call: PhoenixKit can't reliably derive a unique DOM id from
  inside a nested LV.

## Fixed (Batch 1 — 2026-05-13)

- **Dialyzer error — unreachable `safe_internal_path?/1` catch-all
  clause** (`lib/phoenix_kit_projects/web/helpers.ex:325` on the
  pre-fix tree). The defensive `defp safe_internal_path?(_), do: false`
  was unreachable because the only caller (`navigate_after_save/2` at
  line 305-307) already narrows the value to a non-empty binary via
  the outer `case` head, so Dialyzer's `pattern_match_cov` warning
  was correct — the function can only ever be invoked with
  `is_binary(path) and path != ""`. Dropped the catch-all; added a
  short comment above the surviving clause explaining the call-site
  guarantee so a future reader doesn't put the clause back.

  This was actively blocking `mix precommit` — the `quality.ci`
  alias includes `mix dialyzer` and exits non-zero on this warning.
  Resolved by deletion, not by `@dialyzer {:nowarn_function, ...}`,
  because the catch-all was dead code rather than a Dialyzer false
  positive.

- **`mix precommit` workflow now auto-formats before checking**
  (`mix.exs:49-54`). Prepended `"format"` to the `precommit` alias so
  the pre-commit run rewrites any unformatted files before
  `quality.ci`'s `format --check-formatted` verifies. Two files that
  were caught unformatted by the pre-fix workflow
  (`broadcasts_test.exs:46-50`, `mix.exs:49`) are now clean on the
  tree. `quality.ci` keeps `format --check-formatted` for CI use,
  where the check should fail rather than auto-fix.

## Surfaced but not fixed

- **Iron Law tension — DB queries run twice per page load on Tier
  1/2 LVs.** Commit `c538526` explicitly removed the
  `connected?(socket)` gate on `OverviewLive`, `ProjectsLive`,
  `TemplatesLive`, and `TasksLive` to eliminate empty-content
  pop-in on first paint, and `ProjectShowLive.mount/3` runs
  `Projects.get_project/1` + `load_assignments/1` +
  `load_comment_counts/1` unconditionally (`project_show_live.ex:41-90`).
  Mount fires twice (HTTP render + WebSocket connect), so every
  visit doubles those queries. The comment at lines 34-40 correctly
  explains *why* the queries had to move into mount (Phoenix LV
  refuses to mount a LV exporting `handle_params/3` via
  `live_render`), but doesn't address the doubled-query cost.

  The standard escape valve is `assign_async/3` — first paint gets
  a skeleton placeholder, the WebSocket-connected mount kicks off
  the data load asynchronously, no double query, no pop-in.
  Deferred rather than fixed here because (a) it's a refactor of
  shipped UX, not a defect, and (b) the workspace doesn't have
  measured evidence the doubled queries are a problem at current
  scale. Worth revisiting if any of the dashboard pages start
  showing up in slow-query logs.

## Skipped (with rationale)

- **PubSub `topic_tasks()` and `topic_all()` are not tenant-scoped.**
  `pub_sub.ex:17-31` already documents this as a framework-wide
  deferred gap: no PhoenixKit module currently threads a tenant key
  through PubSub topics, and the right shape (`"projects:org:<id>:all"`)
  requires core to expose a per-tenant `Scope` first. Not
  introduced by PR #6 and not solvable inside `phoenix_kit_projects`
  alone — left to the framework-wide partition work the module
  comment calls out.

- **`resolve_action_params/2` hardcodes the session-key allowlist**
  (`helpers.ex:277`). It pulls `["id", "project_id", "template"]` —
  exhaustive for the four form LVs that exist today. A future form
  LV with a different session-key set would need to extend the list.
  Skipped rather than parametrised because (a) it's three keys and
  three callers, (b) speculative generalisation here would hide the
  embedder-facing contract (which session keys each form LV expects),
  and (c) the keyset is the kind of thing the embedding audit
  already documents per-LV.

## Verification

- `mix precommit` — clean on the post-fix tree (format ✓ /
  compile --warnings-as-errors ✓ / deps.unlock --check-unused ✓ /
  format --check-formatted ✓ / credo --strict 0 issues / dialyzer
  0 issues).
- `mix test` — 408/408 still green; no test touched by the
  helpers.ex change.
