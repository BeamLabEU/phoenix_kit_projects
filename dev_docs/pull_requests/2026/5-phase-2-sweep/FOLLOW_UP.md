# Follow-up — PR #5 (embedding + ETA + Phase 2 sweep)

**Date:** 2026-05-13
**Reviewer artifacts:** Three parallel Explore agents (security + error
handling + async UX / translations + activity + tests / PubSub +
cleanliness + public API + senior-dev review) per `dev_docs/quality_sweep.md`
C12 prompts.

Phase 2 re-validation triage on `phoenix_kit_projects` — third pass on
the module (after the initial sweep in PR #2 and the V112 consumer
work in PR #4). C0 baseline captured in
`c0_baseline/*.yml` as accessibility-tree snapshots (Playwright MCP
`browser_take_screenshot` has 5s timeout issues; the snapshot YAML
captures class names + structure + console errors, which is
sufficient for the diff-against-baseline check the playbook calls
for). Test baseline: 407/407 green at sweep start.

The three agents reported a total of **5 findings**: 1
IMPROVEMENT-HIGH (security), 4 IMPROVEMENT-MEDIUM. Two were
actionable defects (fixed in this batch); three were consistency NITs
that conflict with established workspace convention and are surfaced
here for the record but deliberately skipped.

## Fixed (Batch 1 — 2026-05-13)

- **Agent 1, IMPROVEMENT-HIGH — open-redirect risk on
  `navigate_after_save/2`.** The helper shipped in the embed sweep
  (PR #5 commit `0e7f310`) accepted any non-empty string from
  `session["redirect_to"]` and `push_navigate`d to it unconditionally.
  An embedder who naively forwarded an unvalidated
  `params["return_to"]` from a request query string would let an
  attacker land `?return_to=https://evil.example.com` and have the
  form save redirect off-site. Fixed in
  `lib/phoenix_kit_projects/web/helpers.ex:291-316`:
  `navigate_after_save/2` now validates the override via
  `safe_internal_path?/1` — must start with `/`, must not start with
  `//` (protocol-relative URL), must not contain `://`. Invalid
  overrides silently fall back to the default path. Test coverage
  in `embedding_test.exs:213-243` exercises five injection vectors
  (`https://`, protocol-relative `//`, `javascript:`, mid-path
  `://`, empty string) and verifies each falls back cleanly.

- **Agent 3, IMPROVEMENT-MEDIUM — dead `archived` key in
  `project_payload/1`.** The PubSub broadcast payload built by
  `lib/phoenix_kit_projects/projects.ex:769-776` exposed
  `archived: not is_nil(p.archived_at)` but no subscriber reads the
  key — all `handle_info/2` clauses pattern-match on `{:projects,
  event, _payload}` and ignore the payload contents, re-fetching
  via `get_project/1` when archived state matters. Removed the
  key; broadcast payload is now `%{uuid, name, is_template}` —
  minimal, matches the "broadcast payload minimal" Phase 2
  convention. `broadcasts_test.exs:46-50` updated to match the new
  shape (the test had been pinning the dead key, which broke once
  the source was removed — exactly the kind of test rigor the
  remove was meant to surface).

## Skipped (with rationale)

- **Agent 3, IMPROVEMENT-MEDIUM — missing `@spec` on LiveView
  `handle_event/3` clauses.** Agent 3 flagged 26+ event handlers
  across the form LVs lacking `@spec`. Skipped: this matches the
  established workspace convention (core `phoenix_kit`'s own LVs
  don't spec `handle_event` either — see e.g.
  `phoenix_kit/lib/phoenix_kit_web/live/users/users.ex` where every
  `handle_event` ships without `@spec`). LV callbacks are framework
  contract functions with fixed shapes; the Phoenix ecosystem
  convention is `@spec` on context module public defs (which this
  module has — Agent 3 confirmed 68/73 in `projects.ex`), not on
  LV-internal event dispatchers. Worth revisiting only if the
  workspace convention shifts.

- **Agent 3, IMPROVEMENT-MEDIUM — missing `@spec` on Phoenix
  components.** Phoenix function components use `attr/3` + `slot/3`
  declarations as their type contract — the compiler checks attrs at
  call sites against those declarations. Adding `@spec` on top would
  be parallel rather than complementary. Agent 3 itself noted this
  is fine. Skipped.

- **Agent 2, IMPROVEMENT-MEDIUM — LV smoke tests use `metadata_has`
  (subset assertion) instead of exact-match metadata.** The agent
  noted that some activity-log assertions check
  `metadata_has: %{"project" => ...}` and could miss a regression
  that drops, say, the `"new_task"` key. Skipped as scoped — the
  `metadata_has` helper is the established API in
  `ActivityLogAssertions` across the entire workspace
  (locations / staff / hello_world / catalogue all use it). Changing
  to exact-match would force every test author to know the full
  metadata shape; brittle. The cleaner path forward (when the test
  rigor matters) is per-action explicit tests pinning the full
  metadata for non-trivial shapes — but that's a coverage-push
  exercise, not a sweep fix.

## Files touched

| File | Change | Batch |
|---|---|---|
| `lib/phoenix_kit_projects/web/helpers.ex` | Open-redirect guard on `navigate_after_save/2`; added `safe_internal_path?/1` private helper | Batch 1 |
| `lib/phoenix_kit_projects/projects.ex` | Removed dead `archived` key from `project_payload/1` | Batch 1 |
| `test/phoenix_kit_projects/web/embedding_test.exs` | Added 5-vector open-redirect rejection test | Batch 1 |
| `test/phoenix_kit_projects/integration/broadcasts_test.exs` | Updated `:project_created` payload pattern to match new minimal shape | Batch 1 |
| `dev_docs/pull_requests/2026/5-phase-2-sweep/FOLLOWUP.md` | This file | Batch 1 |
| `dev_docs/pull_requests/2026/5-phase-2-sweep/c0_baseline/*.yml` | C0 visual baseline — 9 admin pages captured as accessibility-tree snapshots | Batch 1 |

## Verification

- `mix format` — clean.
- `mix compile --warnings-as-errors --force` — clean.
- `mix credo --strict` — 691 mods/funs analyzed, 0 issues.
- `mix test` — **408/408** pass (was 407 pre-sweep; +1 for the
  open-redirect rejection test which uses a for-loop over 5
  injection vectors, counted as a single ExUnit test).
- Stale-ref greps: zero hits on `IO.inspect/puts/warn`,
  `# TODO/FIXME/HACK/XXX`, raw error strings (`{:error, "..."}`).
  One hit on the commented-code grep is a prose comment, not dead
  code (`project_form_live.ex:256`).
- Browser diff against C0 baseline: not re-run since the only
  externally-visible change is the PubSub broadcast payload (no
  rendered HTML touched). Subscribers that pattern-match on the
  full payload shape catch any regression via the test suite.

## Open

None.
