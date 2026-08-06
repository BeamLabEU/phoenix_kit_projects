# PR #34 review — Raise the core floor to 1.7.231 and bound it

- **PR:** [#34](https://github.com/BeamLabEU/phoenix_kit_projects/pull/34) — `timujinne/fix/core-version-floor` → `main`
- **Merge:** `5cd6483` (1 commit, `6a2a765`)
- **Author:** Timujeen · merged by ddon
- **Reviewer:** Claude (Opus 5), post-merge
- **Scope:** 2 files, +23 / −18. `mix.exs`: `pk_dep(:phoenix_kit, ">= 1.7.189")`
  → `pk_dep(:phoenix_kit, "~> 1.7.231")` plus a rewritten rationale comment.
  `mix.lock`: `phoenix_kit` 1.7.216 → 1.7.232, and routine transitive bumps
  (`etcher`, `leaf`, `mdex`, `mdex_native`, `oban`, `ranch`, `req`, `swoosh`,
  `tesla`) that came along with the regenerated lock.
- **Verdict:** The core claim is **correct and verified**, and the fix is real —
  the declared floor did permit a core without `UrlState`, and the lock actually
  pinned one. But the regenerated lock left `main` unable to pass the repo's own
  `mix precommit` gate, and three documentation defects ride along. All four
  fixed here. No code behaviour changed by this PR, and none needed changing.

## Verification of the PR's claims

Checked against the sibling core checkout (`../phoenix_kit`), not the PR
description:

| Claim | Verdict |
|---|---|
| `ProjectsLive` / `TasksLive` / `TemplatesLive` all `use PhoenixKitWeb.Live.UrlState` | ✅ all three, `web/{projects,tasks,templates}_live.ex` |
| `UrlState` first shipped in 1.7.231 | ✅ added by `ae9164c6` (2026-08-04); `git tag --contains` → first tag `v1.7.231` |
| 1.7.231 is a *sufficient* floor, not just a necessary one | ✅ every follow-up `url_state.ex` commit — including `c9d78952` "Add a history mode", which is the `mode: :history` these three LVs pass — is also contained in `v1.7.231`. Nothing the module uses needs 1.7.232. |
| The old `>= 1.7.189` permitted a core without `UrlState` | ✅ and `mix.lock` resolved 1.7.216, so a fresh `mix deps.get` produced a tree this module cannot compile against |
| `~>` matches how the ecosystem pins core | ✅ `~> 1.7.NNN` is the dominant form across the sibling `phoenix_kit_*` modules |

Also cross-checked the other core surface PR #33 introduced: `<.search_toolbar>`
with `value` / `on_submit` / `loading_indicator` / `placeholder` / `class` — all
five attrs exist on `Core.TableDefault.search_toolbar/1` as of `v1.7.231`. So the
floor covers the whole of PR #33, not just the module it names.

## Findings

### 1. BUG - HIGH — the regenerated lock left `mix precommit` failing on `main`

`mix precommit` aborts at its `deps.unlock --check-unused` step:

```
** (Mix) Unused dependencies in mix.lock file:
  * :ex_ast  * :glob_ex  * :igniter  * :owl
  * :rewrite  * :sourceror  * :spitfire  * :text_diff
```

Cause is this PR's core bump, not anything the author wrote by hand. Core
1.7.216 declared `{:igniter, "~> 0.7", optional: false}`; 1.7.232 declares it
**`optional: true`**. `igniter` therefore leaves the resolved tree, taking its
seven transitive deps (`ex_ast`, `glob_ex`, `owl`, `rewrite`, `sourceror`,
`spitfire`, `text_diff`) with it — and `mix deps.get` adds and updates lock
entries but never prunes orphans, so all eight stayed behind.

Worth stressing how this hides: the alias is ordered `format` →
`compile --warnings-as-errors` → `deps.unlock --check-unused` → `hex.audit` →
`quality.ci`. The abort happens at step three, so **credo and dialyzer never
ran at all** on the merged tree. "The gate is red" understates it; the gate was
not reaching the checks it exists for.

**Fixed** with `mix deps.unlock --unused` (8 lines out of `mix.lock`, no version
changes). The full gate is green afterwards.

### 2. BUG - LOW — the comment's stated rationale does not describe the constraint it justifies

`mix.exs:96-99` (as merged) explained the switch to `~>` as guarding against
"a future 2.0". `~> 1.7.231` does not mean that. In Hex's requirement syntax the
trailing element is the one allowed to move, so `~> 1.7.231` is
`>= 1.7.231 and < 1.8.0` — it excludes **1.8.0**, not merely 2.0. A reader
following the comment would believe core 1.8.x resolves here; it will fail
resolution instead.

Two ways to reconcile it. Widening to `"~> 1.7 and >= 1.7.231"` would make the
code match the comment, and two sibling modules do pin that way — but the
majority pin `~> 1.7.NNN`, and the stricter bound is the *safer* of the two for
exactly the reason the commit gives (fail as a resolution conflict here, not as a
compile error downstream). **Fixed by correcting the comment, keeping
`~> 1.7.231`**: it now states the real window, says core minors are not assumed
compatible, and says a 1.8 core needs a deliberate re-pin.

### 3. IMPROVEMENT - MEDIUM — the "superseded floors" list dropped the floor it was replacing

The rewritten comment enumerates the earlier floors 1.7.231 subsumes —
V125/V127/V128 and 1.7.184's `Checkbox` attrs — but omits **1.7.189**, which is
the requirement this PR actually deleted. That floor exists for a reason:
`f93d919` raised it for `PhoenixKit.SchemaPrefix`, "which the previous commit
applies to every table-backed schema in this module". Losing it from the record
means the next person to consider lowering the floor has no idea 1.7.189 is a
hard bound.

**Fixed** — `PhoenixKit.SchemaPrefix` / 1.7.189 restored to the list, and the
`mode: :history` dependency named explicitly alongside `UrlState` (it is the
narrower of the two requirements and the one a reader would otherwise have to
rediscover).

### 4. IMPROVEMENT - MEDIUM — `AGENTS.md` still documents floors two hundred patch releases stale

A PR that moves the pin owns the prose that quotes it. Two places contradicted
`mix.exs` after the merge:

- `AGENTS.md` "Cross-repo schema dependency" — "shipped in `1.7.128`, which this
  module **now pins as its floor** (`~> 1.7.128`)".
- `AGENTS.md` "⚠️ Cross-repo release ordering" — "This module pins `phoenix_kit
  ~> 1.7.121`; the feature can't run until core releases V125 (≥1.7.122) and this
  pin is bumped. **Projects CI stays red until then**." Core is at 1.7.232; V125
  shipped long ago. The warning was describing a resolved situation as live.

**Fixed** — both now reference the current floor, and the release-ordering block
is demoted from a live ⚠️ blocker to the standing pattern for the *next*
cross-repo schema change.

Two adjacent staleness bugs corrected while in there. Both blocks told the reader
to hand-edit a temporary `{:phoenix_kit, path: ...}` into `mix.exs`, which
`pk_dep/3` replaced with `PHOENIX_KIT_PATH=../phoenix_kit`. And "Versioning &
Releases" still claimed the version "appears in two places that must stay in
sync" — `lib/phoenix_kit_projects.ex` has read `Mix.Project.config()[:version]`
at compile time for some time now, precisely so it *can't* drift, and a release
checklist that sends you editing a second file that no longer holds a literal is
worse than no checklist.

### 5. NITPICK — unrelated lock churn rides along

Nine transitive dependencies moved in a PR whose subject is the core floor. Not
harmful in itself — `mix.lock` is not consumed by anything installing this
package from Hex — and the bumps are the unavoidable by-product of regenerating
the lock against the new core. Left as-is. Note though that it is exactly this
"just lock churn, skim it" framing that let finding #1 through: the eight
orphaned entries were indistinguishable from the other nine at a glance.

## Not fixed, deliberately

- **No test locks the floor.** A version requirement is asserted by resolution,
  not by ExUnit; a test that re-parses `Mix.Project.config[:deps]` and compares
  strings would restate the constant rather than verify it, and would need
  editing on every legitimate bump. The real gate is `mix deps.get` +
  `mix compile --warnings-as-errors` against the floor, which the release gate
  already runs.
