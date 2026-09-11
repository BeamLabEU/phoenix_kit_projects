# FOLLOW_UP — PR #34: Core version floor

Triaged 2026-09-11 against current `main`. Reviewer: Claude
(`CLAUDE_REVIEW.md`).

## Fixed (pre-existing)

- ~~**BUG-HIGH — the regenerated lock left `mix precommit` failing on
  `main`.**~~ That specific failure is gone; `mix precommit` is clean today.
  **But see "Recurrence" below — the same class bit again.**
- ~~**BUG-LOW — the comment's rationale did not describe the constraint it
  justified.**~~ Resolved.
- ~~**IMPROVEMENT-MEDIUM — the "superseded floors" list dropped the floor it
  was replacing.**~~ Resolved.
- ~~**IMPROVEMENT-MEDIUM — `AGENTS.md` documented floors two hundred patch
  releases stale.**~~ Fixed. `AGENTS.md:14` now says `phoenix_kit ~> 2.0`,
  matching `mix.exs:141` (`pk_dep(:phoenix_kit, "~> 2.0")`), and points at the
  single source rather than restating a number that goes stale.

## Recurrence (found during this triage, fixed 2026-09-11)

The lock went out of sync again, in a way that is worse than the original
finding: `mix.exs` declared `phoenix_kit_templates` and `mix.lock` never
carried it, so a clean checkout stopped at *"the dependency is not locked"*
**before compiling anything**. Every gate in the playbook runs after
`deps.get`, so nothing in the pipeline can see this — only a fresh clone can.
Locked it (commit `ce2752d`), which also pulled `leaf` 0.6.1 → 0.7.0 and
`ranch` forward to the versions current requirements resolve to.

Worth a standing check: `git stash -u && mix compile` from a clean tree
answers "does this repo build for someone who just cloned it", and no other
step asks that question.

## Skipped (with rationale)

- **NITPICK — unrelated lock churn rides along.** Unchanged, and it recurred
  above: locking one missing dep necessarily moves whatever else the resolver
  now picks. Kept in its own commit so it can be dropped independently.

## Files touched

| File | Change |
|---|---|
| `mix.lock` | Lock `phoenix_kit_templates`; `leaf` 0.6.1 → 0.7.0, `ranch` 2.2.1 → 2.3.0 (commit `ce2752d`) |

## Verification

`mix precommit` clean; 1511 tests, 0 failures (2026-09-11).

## Open

None.
