# Code Review: PR #4 — V112 schema consumers, dashboard prioritization, components, phase-2 sweep

**Reviewer:** Claude (Opus 4.7 1M) — review performed with the `elixir`, `phoenix-thinking`, `elixir-thinking`, and `ecto-thinking` skill packs loaded.
**Date:** 2026-05-11
**PR:** https://github.com/BeamLabEU/phoenix_kit_projects/pull/4 (merged)
**State:** MERGED — review captured post-merge for the dev_docs trail
**Scope:** 5357 additions / 942 deletions across 48 files, 12 commits across four buckets: V112 schema consumers, dashboard + math, phase-2 re-validation, and component extraction + UI polish.

---

## Overall

A confident, well-paced PR. The four buckets are each cleanly motivated and the commit sequence reads bottom-up through the module — schema first, context next, dashboard math, then UI. The component extraction in `9026acb` is exactly the kind of move that should happen *after* the call sites have stabilized, not before: every component is born with named callers, typed `attr`s, and a `:values` constraint where applicable.

Two non-trivial things landed cleanly:

1. **`clone_template/2` now opens the outer transaction at `:serializable`** (`projects.ex:1123-1131`) — this closes PR #2 review finding #1 verbatim, including the comment that documents *why* the inner `add_dependency/2` `isolation:` would otherwise be silently dropped. Receipts-on-fixes like this are excellent.
2. **The closure-pull cycle-edge fix** (`c1525b6`, `projects.ex:1538`) is the kind of bug that only surfaces under exactly the right diamond: a `not child.cycle?` guard in `wire_closure_dependencies/3` is now the only thing between a perfectly valid template-dep graph and a rolled-back insert. The accompanying integration test (`closure_pull_test.exs:127-149`) pins it.

The PR also gets the harder parts of the V112 surface right: `derived_status/2` is a clean priority `cond`, `Project.translations` is a tightly-validated JSONB pattern with primary-column fallback, `Assignment.changeset/2` deliberately omits `completed_by_uuid`/`completed_at` so form params can't trojan a fake completion (`assignment.ex:99-120` — distinct `changeset/2` and `status_changeset/2`, with the `_form` smell suffix on the form-only updater).

Findings below are real but none block; the PR is already merged. Three findings predate this PR (systemic patterns the module inherits) and the rest are new in PR #4. Severity is calibrated against what the realistic call profile costs, not theoretical edge cases.

---

## BUG - LOW

### 1. `do_topo/5` can drop a diamond-dep descendant when one of its ancestors is excluded

**File:** `lib/phoenix_kit_projects/projects.ex:1483-1510`

`topological_insertion_order/2` does a DFS of the closure tree and tracks `seen` to dedup tasks that appear under multiple parents. When an ancestor is excluded, the function adds the current task's uuid to `seen` and short-circuits without recursing:

```elixir
ancestor_excluded? or MapSet.member?(excluded, task.uuid) ->
  # Skip this task; the cascade ensures descendants are also
  # excluded so we don't recurse into them.
  {acc, MapSet.put(seen, task.uuid)}
```

This is correct for a strict tree. But the closure tree allows shared descendants: if task `D` has two parents `P1` (excluded) and `P2` (not excluded) and the DFS visits `P1`'s subtree first, `D` gets added to `seen` without contributing an insert. When the traversal later reaches `P2`'s subtree, the `MapSet.member?(seen, task.uuid) -> {acc, seen}` guard at line 1492-1493 returns early and `D` is silently dropped — even though `P2`'s subtree should have included it.

To trigger it in practice you need a diamond in the `TaskDependency` graph (`A→B`, `A→C`, both `B→D` and `C→D`) AND the user must explicitly untick `B` while keeping `C`. The cascade model handles single-parent skips correctly; only shared descendants where one parent is excluded are at risk.

**Fix:** in the excluded branch, *don't* add to `seen`. Add to a separate `excluded_seen` if dedup of skips is needed for performance, but `seen` should mean "this task contributed an insert (or its insert was correctly skipped from every reachable path)."

```elixir
ancestor_excluded? or MapSet.member?(excluded, task.uuid) ->
  {acc, seen}  # don't poison `seen` from an excluded path
```

The risk is data-shape-dependent (most workflows are trees or near-trees), but the fix is one line.

**Severity rationale:** LOW. Diamond template-dep graphs are not the common case, the user has to explicitly pick the pattern that exposes it, and the user-visible failure mode is "I unticked B and expected D to still come in via C, but it didn't." No data corruption. Worth fixing the next time `do_topo/5` is touched. No integration test in `closure_pull_test.exs` covers diamonds; consider adding one alongside the fix.

---

## BUG - LOW

### 2. `reorder_tasks/2` cap check fires before dedup, so a 1100-uuid list that dedupes to 200 is rejected

**File:** `lib/phoenix_kit_projects/projects.ex:212-216`

The function head guard checks `length(ordered_uuids) > @reorder_max_uuids` against the raw input before `dedupe_uuids/1` runs:

```elixir
def reorder_tasks(ordered_uuids, opts)
    when is_list(ordered_uuids) and length(ordered_uuids) > @reorder_max_uuids do
  log_reorder_rejected("task", :too_many_uuids, length(ordered_uuids), opts)
  {:error, :too_many_uuids}
end
```

A pathological client (or a buggy front-end emitting dragstart events on every reorder pass-through) could submit 1500 uuids that dedupe to a legitimate 100. The function rejects with `:too_many_uuids` and audits the rejection.

This is almost certainly *intentional* — the cap is meant to flag clients that are misbehaving, not to be lenient with them — but the docstring at `projects.ex:191-207` doesn't say so explicitly. The same pattern applies symmetrically to `reorder_projects`, `reorder_templates`, and `reorder_assignments`.

**Fix:** Either dedup first then cap, or document that the cap applies to the raw input as a "client misbehavior" signal. The latter is cheaper and matches the apparent intent.

**Severity rationale:** LOW. No realistic UI hits this; the cap is a DoS guard, not a real-user constraint.

---

## IMPROVEMENT - HIGH

### 3. Database queries in `mount/3` across the module (pre-existing, not new in PR #4)

**Files:**
- `lib/phoenix_kit_projects/web/overview_live.ex:15-25` — `reload/1` runs ~7 queries in mount
- `lib/phoenix_kit_projects/web/projects_live.ex:15-29` — `list_projects` in mount
- `lib/phoenix_kit_projects/web/templates_live.ex:15-20` — `load_templates` in mount
- `lib/phoenix_kit_projects/web/project_show_live.ex:20-62` — `get_project`, `load_assignments`, `load_comment_counts` all in mount
- `lib/phoenix_kit_projects/web/assignment_form_live.ex:21+` — `get_project`, `list_assignments`, `list_tasks`, `task_closure`, etc.
- `lib/phoenix_kit_projects/web/project_form_live.ex:15-37` — `list_templates`, `get_project` in mount
- `lib/phoenix_kit_projects/web/task_form_live.ex:17+` — `get_task`, `list_task_dependencies` in mount
- `lib/phoenix_kit_projects/web/template_form_live.ex:12+` — `get_project` in mount

The Phoenix LiveView lifecycle calls `mount/3` *twice* — once for the disconnected HTTP render, then again over WebSocket. Every database query in mount runs both times, doubling the load on the dashboard's first paint.

`TasksLive` is the only LV in this PR that gets it right: mount is empty, `handle_params/3` does the loading (`tasks_live.ex:17-23`). The pattern from that file generalizes; every other LV in the module is paying the duplicate-query cost.

This is **pre-existing** (PR #2 review finding #1 explicitly flagged it and chose to defer), but PR #4 adds another ~3 mount-time queries to `ProjectShowLive` (`load_comment_counts`) and several to `AssignmentFormLive` (`task_closure`, the multilang options load) without addressing the underlying issue.

**Why this matters now:** `OverviewLive.mount` is the dashboard landing page. With the V112 changes it now runs `list_active_projects`, `list_recently_completed_projects`, `list_upcoming_projects`, `list_setup_projects`, `project_summaries` (which itself fans out to assignments + tasks), `count_tasks`, `count_projects`, `count_templates`, `list_assignments_for_user`, and `assignment_status_counts` — twice. Even on a small dataset this is the most visible page in the module.

**Fix sketch:** Per `phoenix-thinking` Iron Law, move every `Projects.*` call out of `mount/3` and into `handle_params/3`. Mount sets up subscriptions and empty assigns (`active_summaries: nil`, plus a `loading: true` flag). `handle_params/3` calls `reload/1`. The skeleton renders during the disconnected mount; data lands when the socket connects. Optionally use `assign_async/3` so the LV renders immediately and the data streams in once the queries return.

**Severity rationale:** HIGH because it's the most-trafficked page and the regression-per-query cost is exactly 2x. Not blocking because it's pre-existing and the dashboard is administrative (not customer-facing), but should be the next quality-sweep item.

---

## IMPROVEMENT - MEDIUM

### 4. `translations` JSONB has no validation in the changesets

**Files:**
- `lib/phoenix_kit_projects/schemas/project.ex:84-91`
- `lib/phoenix_kit_projects/schemas/task.ex:107-119`
- `lib/phoenix_kit_projects/schemas/assignment.ex:105-120`

`translations` is cast as `:map` with default `%{}` and validated by nothing. The `@type translations_map` doc-comments the expected shape:

```
%{optional(String.t()) => %{optional(String.t()) => String.t()}}
```

But the changeset accepts *any* map. `Helpers.merge_translations_attrs/3` (line 68) does light cleanup — stripping `_unused_` keys and empty strings — before the cast, but a programmatic caller (the seed scripts, or a future migration that touches this column) can persist garbage.

The reads are defensive (`Project.localized_field/3` pattern-matches `%{} = lang_map` before reaching for the value), so the failure mode is silent fallback to the primary column. That's not a *crash*, it's *invisible data loss* — exactly the kind of thing that bites months later when someone notices a multilang rollout doesn't surface.

**Fix sketch:** Add a `validate_translations_shape/1` private helper that runs after `cast/3`:

```elixir
defp validate_translations_shape(changeset) do
  case get_change(changeset, :translations) do
    nil -> changeset
    map when is_map(map) ->
      if valid_translations_shape?(map),
        do: changeset,
        else: add_error(changeset, :translations, "invalid shape")
  end
end

defp valid_translations_shape?(map) do
  Enum.all?(map, fn
    {lang, fields} when is_binary(lang) and is_map(fields) ->
      Enum.all?(fields, fn {k, v} -> is_binary(k) and is_binary(v) end)
    _ -> false
  end)
end
```

Bonus: validate that `lang` keys conform to the locale list (`L10n.supported_langs/0`) so a typo'd `"es_ES"` vs `"es-ES"` doesn't silently shadow the override.

**Severity rationale:** MEDIUM. No user-facing bug today (the form layer is the only writer and it cleans inputs first), but the contract relies on call-site discipline that won't survive a future seeds.exs or data backfill.

---

## IMPROVEMENT - MEDIUM

### 5. `topological_insertion_order/2` appends with `++` — O(n²) for deep closures

**File:** `lib/phoenix_kit_projects/projects.ex:1508`

```elixir
{acc ++ [task.uuid], seen}
```

Appending to the tail of a list with `acc ++ [x]` walks the whole list each time. For a closure of N tasks this is O(N²) traversal. Today's closures are small (a handful of tasks pulled in via the assignment form), but this is on the save path for a UX flow described as "this task pulls in N more dependent tasks." A workflow with 50 transitive prereqs is plausible, and the perf isn't observable until it suddenly is.

**Fix:** Build the list in reverse and `Enum.reverse/1` once at the end. The function already returns the list — `topological_insertion_order/2` returns `acc`, so the change is contained:

```elixir
defp topological_insertion_order(tree, excluded) do
  {acc_rev, _seen} = do_topo(tree, excluded, false, MapSet.new(), [])
  Enum.reverse(acc_rev)
end
```

and inside `do_topo/5`:

```elixir
{[task.uuid | acc], seen}
```

**Severity rationale:** MEDIUM. Not a bug, but it's on a write path and the cost is asymptotic. Easy fix.

---

## IMPROVEMENT - LOW

### 6. Diamond-dep coverage gap in `closure_pull_test.exs`

**File:** `test/phoenix_kit_projects/integration/closure_pull_test.exs`

The new test file covers an impressive matrix: happy chain, exclusion cascade, reuse-of-pre-existing, cycle terminator, error shape, and rollback. The one shape *not* covered is the diamond — two parents sharing a descendant. That's exactly the shape that exposes finding #1 above, and also the shape most likely to trip up future changes to `wire_closure_dependencies/3`.

**Fix:** Add a `chain_of_diamond/0` fixture and two test cases:

```
    D
   / \
  B   C
   \ /
    A    (A is the user's pick — depends on B and C, which both depend on D)
```

- Happy path: pick `A`, no exclusions → 4 assignments land, deps wired both `A→B`, `A→C`, `B→D`, `C→D`.
- Exclude `B`: `A`, `C`, `D` land (D reachable via C); deps `A→C`, `C→D` wired; `A→B` and `B→D` not wired.

The second case is exactly what would fail today per finding #1.

---

## IMPROVEMENT - LOW

### 7. `dedupe_uuids/1` has no test coverage for the duplicate-input contract

**File:** `lib/phoenix_kit_projects/projects.ex:32-43`, `test/phoenix_kit_projects/integration/reorder_test.exs`

The docstring promises "order preserved, last occurrence kept." The integration tests in `reorder_test.exs` exercise the four reorder fns but never submit a list with duplicates, so the dedup contract is unverified. A regression here (e.g. switching to last-write-loses) would only surface from a real user dragging the same item twice in one batched event — rare but real.

**Fix:** One assertion per `describe` block:

```elixir
test "duplicate uuids dedup last-write-wins (last position kept)" do
  t1 = fixture_task()
  t2 = fixture_task()

  assert :ok = Projects.reorder_tasks([t1.uuid, t2.uuid, t1.uuid])
  positions = ...
  # Expect t1 at position 2 (its second occurrence), t2 at position 1.
end
```

Or — if dedup is considered an implementation detail and not a contract — narrow the docstring to "duplicates are deduped (order unspecified)" and skip the test.

---

## NIT / STYLE

### 8. `OverviewLive`'s `mount` reads `socket.assigns[:phoenix_kit_current_user]` defensively but the on-mount path is always authenticated

**File:** `lib/phoenix_kit_projects/web/overview_live.ex:18-22`

```elixir
user_uuid =
  case socket.assigns[:phoenix_kit_current_user] do
    %{uuid: uuid} -> uuid
    _ -> nil
  end
```

If the route is wrapped in an authenticated `live_session`, the `_ -> nil` fallback is unreachable. If it's not authenticated, you almost certainly want to redirect rather than silently render an empty "My assignments" list. Worth checking whether this fallback is a bug-cover or a real branch — the `elixir-thinking` skill notes that `_ -> nil` catch-alls "silently swallow unexpected cases."

### 9. `TabsStrip.phx_value/2` dynamically builds a `phx-value-*` attr map

**File:** `lib/phoenix_kit_projects/web/components/tabs_strip.ex:55`

```elixir
defp phx_value(attr, value), do: %{"phx-value-#{attr}" => value}
```

This works but is unusual; most components hard-code the attr name. Given `value_attr` is essentially always `"mode"` at the one call site, consider inlining and dropping the indirection. Not a blocker — just one fewer thing to grep when the next reader wonders what's dynamic.

### 10. `assignment_form_live.ex:262-265` comment is slightly misleading

> "Uses a list (not a MapSet) so the rendered order mirrors the user's add order, and `--` strips dupes if the same uuid is added twice."

The dedup is actually done by `if dep_uuid in current` (line 270), not by `--`. Tiny doc drift; not load-bearing.

---

## Observations (positive)

These are worth calling out so they don't get refactored away by accident:

- **`Assignment.changeset/2` vs `status_changeset/2`** (`assignment.ex:101-120`) — the separation is the correct fix for the OWASP "Mass Assignment" concern, and the `_form` smell suffix on the corresponding updater (`projects.ex:1603`) is a load-bearing comment. Don't unify them.
- **`comment_counts_for_assignments/1` rescue shape** (`projects.ex:159-187`) — narrowed to `UndefinedFunctionError + Postgrex.Error + DBConnection.OwnershipError + :exit`. This is the canonical "optional sibling module" pattern; ditto `load_comment_counts` in `project_show_live.ex:571-580`.
- **`list_assignments_for_user/1` deliberate rescue** (`projects.ex:956-994`) — comment explicitly tells future readers not to "clean it up by narrowing." The dashboard tolerates a staff outage; that's the design.
- **`recompute_project_completion/1` transaction wrap** (`projects.ex:1232-1249`) — the idempotency-under-concurrent-status-change reasoning is correct and the comment captures it.
- **The two-pass position write** (`projects.ex:237-262` and parallel functions) — the negatives-then-positives pattern future-proofs against a `UNIQUE(project_uuid, position)` index without paying for one today. Forward-compatible design choice that costs one extra `update_all` per reorder.
- **`load_comment_counts/1` runs only when `comments_enabled?`** — the check happens once at mount and is reused on every `:comments_updated` round-trip rather than re-detecting the module each time. Right tradeoff for a count-only sibling.

---

## Did the PR description match the diff?

Yes, with no surprises. Twelve commits accounted for, four buckets all delivered, the gated 1.7.107 hex dependency note is accurate, and the AGENTS.md updates land in step (web file layout includes `components/`, the `use Web.Components` aggregator is documented, the deferred per-user `work_schedule` design is pinned to the "does NOT have" list). The component extraction comment ("aggregator only imports — adding a new component is `add file → add import` and done") matches `web/components.ex` line-for-line.

---

## Recommendations for next sweep

In priority order:

1. **Finding #3** — `mount/3` → `handle_params/3` refactor across `OverviewLive`, `ProjectShowLive`, `AssignmentFormLive`, `ProjectFormLive`, `TaskFormLive`, `TemplateFormLive`, `ProjectsLive`, `TemplatesLive`. `TasksLive` is the reference implementation. This is the single largest perf win available and is the only systemic Phoenix-thinking violation in the module.
2. **Finding #4** — `translations` shape validation. One private helper per schema, ~20 lines total.
3. **Finding #1 + Finding #6** — the diamond-dep fix and its integration test. One-line code change + one new fixture.
4. **Finding #5** — `topological_insertion_order/2` reverse-then-prepend rewrite. Trivial.
5. **Findings #2, #7, #8, #9, #10** — docstring/test nits that can ride along with whatever next touches the file.

None are merge-blocking. None require a coordinated change with the core `phoenix_kit` package. Everything is local to this module.
