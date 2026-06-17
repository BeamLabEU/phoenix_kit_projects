# Follow-up — PR #9 (emit-mode contract + PopupHostLive)

**Date:** 2026-05-19
**Reviewer artifact:** `CLAUDE_REVIEW.md` (Claude / Kimi Code CLI, 2026-05-15)
**Baseline at triage:** `main` post-`fa7d45a` (Phase 1 re-rebased onto v0.3.0)

Phase 1 triage of the Claude review on PR #9 (emit-mode contract
shipped via `<.smart_link>` / `<.smart_menu_link>` adapters + opinionated
`PopupHostLive` daisyUI modal-stack host). The review captured 1
BUG-MEDIUM, 1 IMPROVEMENT-HIGH, 1 IMPROVEMENT-MEDIUM, and 1 NITPICK,
all flagged as non-blocking. Every finding has been resolved in this
sweep batch.

## Fixed (Batch 1 — 2026-05-19)

- ~~**Finding #1 (BUG-MEDIUM) — missing `maybe_put_locale` in
  `ProjectShowLive`'s fail-closed mount.**~~ Fixed.
  `lib/phoenix_kit_projects/web/project_show_live.ex:36-46` — the
  `mount(:not_mounted_at_router, session, socket)` clause (no `"id"`
  in session) now calls `WebHelpers.maybe_put_locale(session)` as its
  first line, matching the contract every other LV's mount/3 honors.
  Previously the fail-closed "Project not found." flash rendered in
  English regardless of the host's locale; now it inherits the
  session locale just like the happy path. Inline comment explains
  the contract symmetry.

- ~~**Finding #2 (IMPROVEMENT-HIGH) — `Jason.encode!` render-time
  crash vector in `<.smart_link>` / `<.smart_menu_link>`.**~~ Fixed.
  `lib/phoenix_kit_projects/web/components/smart_link.ex:108-130` and
  `lib/phoenix_kit_projects/web/components/smart_menu_link.ex:90-112` —
  both components route through a new private `safe_encode_session/2`
  helper that wraps `Jason.encode/1` (non-bang) and falls back to
  `"{}"` with a logged warning on encode failure. The button still
  renders; the target LV's fail-closed `mount(:not_mounted_at_router,
  …)` clause handles the empty session by flashing not-found and
  closing the modal — same shape as a deliberately empty session.
  All current callers pass plain string-keyed maps so behaviour is
  unchanged; this is purely defensive against future misuse (a
  struct, atom value, or datetime in the session would otherwise
  crash the whole view on render). The two implementations are
  textually identical so failure shape doesn't depend on which
  navigation primitive rendered the button. `require Logger` added
  to both modules.

- ~~**Finding #3 (IMPROVEMENT-MEDIUM) — `:embed_close_on` dead
  assign.**~~ Fixed by stripping.
  `lib/phoenix_kit_projects/web/helpers.ex` — `decode_close_on/1`,
  the `close_on = …` line in `assign_embed_state/2`, and the
  `embed_close_on: close_on` keyword in the assign call all deleted.
  Docstring updated to drop the `"close_on"` session key and the
  `:embed_close_on` socket assign. `dev_docs/embedding_emit.md` also
  updated — the session-keys table no longer lists `"close_on"`, and
  the helper-API line for `assign_embed_state/2` drops the
  `:embed_close_on` mention. Removing dead-but-documented APIs is
  cheaper than maintaining them; when per-frame close-event opt-in
  is genuinely needed, the helper plus an `:embed_close_on` assign
  can be added back in <30 lines (the original implementation is
  preserved in this commit's history for reference).

- ~~**Finding #4 (NITPICK) — `@max_stack_depth` hard-coded but
  docstring claimed configurable.**~~ Fixed.
  `lib/phoenix_kit_projects/web/popup_host_live.ex:67-72, 91, 119-139,
  225-232, 310-315` — the cap is now `session["max_stack_depth"]`
  with a default of 5 (renamed `@default_max_stack_depth`) and an
  absolute upper bound of `@absolute_max_stack_depth` (20). Out-of-
  band values (nil, non-integer, ≤0, >20) clamp to the default and
  log a warning. The `:max_stack_depth` assign is read at the two
  enforcement sites (`handle_info :opened` and the `:saved` next-chain
  push) instead of the module attribute, so a host can legitimately
  request a deeper stack when needed. Moduledoc + the session
  contract table both updated to document the new key.

## Fixed (Batch 2 — 2026-05-19, Phase 2 quality sweep)

Phase 2 triage (three Explore agents per `agents.md:251-263`) surfaced
the following beyond the Claude-review findings of Batch 1. All
actionable items were resolved; the no-op items are recorded below
with rationale.

- ~~**Broad `rescue _` in `emit_telemetry/2`.**~~ Fixed.
  `lib/phoenix_kit_projects/web/helpers.ex:805-820` — narrowed the
  rescue clause from `_` to the exception shapes that
  `:telemetry.execute/3` and host-attached handlers can actually raise
  (`ArgumentError`, `KeyError`, `FunctionClauseError`, `RuntimeError`,
  `MatchError`). Bugs in this module's metadata construction now
  surface as crashes during development instead of being silently
  swallowed. `Logger.warning` records the raised exception for
  postmortem visibility. The "telemetry must never crash the embed
  flow" contract is preserved for the realistic-error shapes.

- ~~**Duplicated assignment-status helpers across
  `ProjectShowLive` + `OverviewLive`.**~~ Fixed by extraction.
  `lib/phoenix_kit_projects/web/components/assignment_status_badge.ex`
  (new) holds public `color/1`, `badge_class/1`, `label/1` functions
  plus an `<.assignment_status_badge>` component sugar. Mirrors the
  shape of `DerivedStatusBadge` (project-lifecycle) for assignment-
  lifecycle. `ProjectShowLive` (line 1135-1148 deleted; call sites at
  ~1455 + ~1473 switched) and `OverviewLive` (line 212-220 deleted;
  call site at ~387 switched to component) now share one source of
  truth. `Web.Components.__using__` imports the module so the
  component shorthand is available everywhere the others are.

- ~~**`OverviewLive.handle_info/2` catch-all.**~~ Verified present at
  `lib/phoenix_kit_projects/web/overview_live.ex:207-210` with the
  same shape as the other LVs — drops the message with a
  `Logger.debug` to avoid unmatched-message process crashes.

- **Project + Dependency schema test coverage gaps.** Added.
  `test/phoenix_kit_projects/schemas/project_test.exs` (new, 26
  tests) — covers required/length validation, `start_mode` enum,
  scheduled-date conditional requirement, translations shape guard,
  the `derived_status/2` priority cascade across all 7 lifecycle
  states, `planned_end_for/2` + `eta_from/3` zero-hour and weekend
  branches, plus `translatable_fields/0` + `start_modes/0` exposure.
  `test/phoenix_kit_projects/schemas/dependency_test.exs` (new) —
  required-field validation, valid-pair acceptance, self-reference
  rejection, and a guard against the self-ref check firing on
  half-built inputs. Pure changeset tests (no DB) — the DB-backed
  cycle-detection + cross-project rejection paths stay covered by
  `projects_context_test.exs`.

## Skipped (Batch 2 — with rationale)

- **`@spec` gaps on public functions in `projects.ex`.** None
  observed. The Phase 2 triage flagged ~10 gaps but every public
  function in `lib/phoenix_kit_projects/projects.ex` already has a
  preceding `@spec` — the false positives came from multi-line specs
  where the `def` line was >4 lines below the spec start. Verified by
  manual walk through all 70+ public defs.

- **Hardcoded `"done"` literal across the codebase.** The Phase 2
  triage suggested wrapping all sites in a `Assignment.done_status()`
  helper. The status field's allowed set is already enforced by
  `Assignment.@statuses` + `validate_inclusion/3`; the literal `"done"`
  appears in ~14 sites (filters, conditional UI rendering, completion
  setters, Map.get keys) and threading them through a wrapper adds
  verbosity without symbolic gain since the magic string is already
  centralized in the schema's enum list. Marking as a deliberate
  not-fix.

## Files touched (Batch 2)

| File | Change |
|---|---|
| `lib/phoenix_kit_projects/web/helpers.ex` | Narrow `emit_telemetry/2` rescue + `Logger.warning` |
| `lib/phoenix_kit_projects/web/components/assignment_status_badge.ex` | New — public `color/1` + `badge_class/1` + `label/1` + `<.assignment_status_badge>` component |
| `lib/phoenix_kit_projects/web/components.ex` | Import the new component module |
| `lib/phoenix_kit_projects/web/project_show_live.ex` | Drop local `status_color`/`badge_class`/`label` defps, alias the new component module, switch the two call sites |
| `lib/phoenix_kit_projects/web/overview_live.ex` | Drop local `status_badge_class`/`status_label` defps, switch call site to component |
| `test/phoenix_kit_projects/schemas/project_test.exs` | New — Project changeset + derived_status + planned_end coverage |
| `test/phoenix_kit_projects/schemas/dependency_test.exs` | New — Dependency changeset coverage |
| `test/phoenix_kit_projects/web/project_show_live_test.exs` | Update redirect assertion to `/admin/projects/list` (downstream of phoenix_kit PR #551 prefix-strip) |

## Verification (Batch 2)

- `mix test` (path-override mode against current local phoenix_kit) —
  531 tests, 0 failures.
- `mix compile` clean against the parent workspace.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_projects/web/project_show_live.ex` | Add `maybe_put_locale/1` to fail-closed mount (finding #1) |
| `lib/phoenix_kit_projects/web/components/smart_link.ex` | `require Logger` + `safe_encode_session/2` helper replacing `Jason.encode!` (finding #2) |
| `lib/phoenix_kit_projects/web/components/smart_menu_link.ex` | Same defensive pattern as smart_link (finding #2) |
| `lib/phoenix_kit_projects/web/helpers.ex` | Strip `decode_close_on/1`, `close_on` decode call, `:embed_close_on` assign, and the docstring entries (finding #3) |
| `lib/phoenix_kit_projects/web/popup_host_live.ex` | `@default_max_stack_depth` + `@absolute_max_stack_depth` + `decode_max_stack_depth/1` + session-driven cap at the two enforcement sites + moduledoc/contract updates (finding #4) |
| `dev_docs/embedding_emit.md` | Session-keys table and helper-API line track the dropped `:embed_close_on`; new `"max_stack_depth"` row added |
| `test/phoenix_kit_projects/paths_test.exs` | Update `@prefix` from `/en/admin/projects` to `/admin/projects` — downstream of phoenix_kit core's PR #551 which made admin URLs prefixless for the primary locale |

## Verification

- `mix compile` — clean (one pre-existing warning in `media_canvas_viewer.html.heex` unrelated to this PR).
- `mix test --exclude integration` — 505 tests, 0 failures (14 pre-existing failures in `paths_test.exs` fixed by the prefix update above).
- Chrome end-to-end on the parent app's `/projects-emit-demo` route — popup_host's spinner overlay still fades correctly, kebab dropdowns position correctly inside dialogs, no JS errors.

## Open

None.
