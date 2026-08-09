# CLAUDE Review — PR #35: Public issue portal, review queue, and the list/board rework

**Reviewer:** Claude (Opus 5)
**Date:** 2026-08-09
**PR:** [BeamLabEU/phoenix_kit_projects#35](https://github.com/BeamLabEU/phoenix_kit_projects/pull/35)
**Merge commit:** `fc053b1`
**Author:** Max Don (mdon)
**Size:** 142 files, +39,241 / −5,697
**Phase:** post-merge deep review (Phase 1's surface pass is `PINCER_REVIEW.md`
beside this file, by a different agent — not amended here)

---

## Summary

The security architecture in this PR is genuinely good. The two-stage event
interceptor on the hub, the portal's ordered abuse gates, the whitelisted public
DTO, the uniform-failure discipline and the `public` / `board_published_at` split
are all correct and, more importantly, correctly *reasoned about in the comments*
— the code says why, so the next person cannot quietly undo it.

What the review found is mostly the seams between the new subsystems and the ones
that were already here: an event that got a feature gate but not a permission gate,
an optional-dependency seam that the authorization layer doesn't actually honour,
and a review queue that is held out of the lists but not out of the numbers.

One finding blocks the release outright and is not a code defect in this PR's
sense: **the merged tree does not compile against its own dependency pin.**

Findings are ordered by severity. Six are fixed in this branch; the rest are
recorded with a fix shape and an explicit reason for leaving them.

---

## BUG - CRITICAL — the merged tree does not compile against its declared core

**Where:** `mix.exs` (`pk_dep(:phoenix_kit, "~> 1.7.231")`), `mix.lock`,
`lib/phoenix_kit_projects/web/portal_live.ex`,
`lib/phoenix_kit_projects/web/components.ex`

`PortalLive` imports `PhoenixKitWeb.Components.Core.MentionText` and calls
`PhoenixKit.Mentions.Token.to_string/4`. Neither exists in any **published**
`phoenix_kit`. The lockfile resolves 1.7.236 from Hex; that release has no
`lib/phoenix_kit/mentions.ex` and no `core/mention_text.ex`.

```
$ mix compile --force
error: module PhoenixKitWeb.Components.Core.MentionText is not loaded and could not be found
  └─ lib/phoenix_kit_projects/web/task_form_live.ex:6
     … (every LV that `use PhoenixKitProjects.Web.Components`)
== Compilation error in file lib/phoenix_kit_projects/web/portal_live.ex ==
```

It only builds with `PHOENIX_KIT_PATH=../phoenix_kit`, and the local core tree is
stamped `1.7.236` too — the same version number as the Hex release, without the
Mentions API in it. So the version pin cannot express the requirement even in
principle right now.

**Consequences:** CI is red on `main`. `mix hex.publish` would ship a package that
no consumer can compile. A `mix compile` that appears to succeed in a working
checkout is a stale `_build` — `--force` is what tells the truth.

**Not fixed here.** The fix is in another repo: core publishes the Mentions API,
then this module's floor moves to that release. Until then **do not release.**
Phase 1 flagged the same dependency (as "PR #692") but recorded it as a
release-time concern; it is also why the test suite cannot compile today.

---

## BUG - HIGH — `AssignmentFormLive` had no authorization gate at all ✅ fixed

**Where:** `lib/phoenix_kit_projects/web/assignment_form_live.ex`

The LV that **creates and edits a project's tasks** gated on nothing. Its only two
`Authz.can?` calls are the portal `toggle_board_published` / `toggle_portal_public`
handlers; `apply_action(:new, …)` and `apply_action(:edit, …)` loaded any project
uuid, and `save_new/2`, `save_edit/2`, `save_with_new_task/3`,
`save_new_subproject/2` write with no check either.

This is the sweep that produced the rest of the PR's gates, stopping one file
short. Its siblings all got one:

| LV | Gate |
|---|---|
| `ProjectShowLive` | `template_or_viewable?/2` at mount |
| `ProjectGanttLive`, `ProjectCalendarLive` | `template_or_viewable?/2` at mount |
| `ProjectFilesLive`, `ProjectActivityLive` | `Authz.can?(…, :view)` at mount |
| `ProjectMembersLive` / `ProjectModulesLive` | `:manage_members` / `:manage_modules`, mount **and** per event |
| `ProjectFormLive(:edit)` | `:edit_settings`, refusal shaped as not-found |
| **`AssignmentFormLive`** | **none** |

`ProjectFormLive(:edit)` even carries the reasoning verbatim — "Any project uuid
used to load straight into the edit form… a refusal is shaped like not-found so
the form can't be used to probe for existence." The same sentence applies here and
the check wasn't written.

**Impact.** Since this PR's permission split, holding `projects` means only "may
enter the module" — a population the PR's own comments say "legitimately includes
contractors". Any such user could go to
`/admin/projects/list/<any-project-uuid>/assignments/new` and create tasks in a
private project they belong to nothing of, and
`/admin/projects/list/<uuid>/assignments/<uuid>/edit` to edit existing ones. The
project's `settings["authz"]` floors for `create_tasks` / `edit_tasks` were never
consulted. The hub not rendering an "Add task" link is not a control — the form is
its own route.

**Fix applied:** a `permitted_project/3` helper resolving `:create_tasks` on `:new`
and `:edit_tasks` on `:edit`, exempting templates the same way
`template_or_viewable?/2` does (library objects have no membership rows), and
returning `nil` on refusal so the existing not-found branch handles it unchanged —
same shape, same flash, same emit-mode `:closed`.

**Behaviour note for hosts:** an embed that mounts this form without
`session["current_user_uuid"]` is now refused rather than degrading to anonymous.
That is the decision the PR already took for `ProjectShowLive` (which is the parent
of any embed flow reaching this form, and already refuses unidentified embeds) and
for `ext_tab_can_write/2` ("a fail-open authz branch should not exist at all"). It
is a real contract change for a host that embedded the form directly without
passing identity.

**Tests:** `hub_permission_enforcement_test.exs` — a new block covering a
non-member on both `:new` and `:edit`, the paired positive case, and a member
refused by a `create_tasks: "managers"` floor. `embedding_test.exs` /
`embedding_emit_test.exs` — the AssignmentFormLive blocks now bridge identity the
way the `ProjectShowLive` blocks already did, plus a stranger-refused case in each
mode (emit has to emit `:closed`, or the host holds a dead modal open).

---

## BUG - HIGH — `confirm_start_project` had a feature gate and no permission gate ✅ fixed

**Where:** `lib/phoenix_kit_projects/web/project_show_live.ex`

`"confirm_start_project"` was listed in `@gated_events` (`:lifecycle`) and absent
from `@event_actions`, and its handler called `do_start_project/2` with no inline
`Authz.can?`. So on any project with the lifecycle feature on — the default — any
`:viewer` could send the event and start the project.

Starting is not a small act. `Projects.start_project/2` stamps `started_at`,
**cements the status catalog into local rows** (after which the source can never
be changed again — see `Statuses.lock_status_source/2`), and flips
`derived_status/2` to `:running` for every dashboard, tier pill and filter on the
site. Compare `archive_project`, the structurally identical container-level
action, which *is* in `@event_actions` at the owner floor.

This is exactly the failure mode the interceptor's own comment says it exists to
design out — "a handler that forgets to check is the failure mode being designed
out, so the check cannot live in the handlers" — reached by forgetting a table row
instead of a handler line.

**Fix applied:** `"confirm_start_project" => :edit_settings` in `@event_actions`
(owner floor, non-overridable — the same class as archiving).

**Test:** `hub_permission_enforcement_test.exs` — "a viewer cannot start the
project — the lifecycle flag is not a permission", plus the paired positive case
so the deny isn't blanket.

---

## BUG - HIGH — team and department grants silently evaporate without `phoenix_kit_staff` ✅ fixed

**Where:** `lib/phoenix_kit_projects/grants.ex`,
`lib/phoenix_kit_projects/web/project_members_live.ex`

This PR makes `phoenix_kit_staff` **optional** and writes the rule into AGENTS.md:

> **Cross-module people lookups**: NEVER call `PhoenixKitStaff.*` directly (staff
> is optional) — go through `PhoenixKitProjects.People`

`Grants` — the module that resolves *indirect authorization* — did exactly that:

```elixir
from(tm in PhoenixKitStaff.Schemas.TeamMembership, where: tm.team_uuid == ^team_uuid)
from(t in PhoenixKitStaff.Schemas.Team, where: t.department_uuid == ^dept_uuid)
with true <- Code.ensure_loaded?(PhoenixKitStaff.Staff),
     person when not is_nil(person) <- PhoenixKitStaff.Staff.get_person_by_user_uuid(...)
```

The staff **tables** are core-owned (V100) and present on every install — that is
the entire premise of the seam, and `People.{Person,Team,Department,TeamMembership}`
are the shadow schemas built for this. But these call sites reach for the optional
**package's** schemas, so on a site without it:

- `staff_subjects/1`'s `Code.ensure_loaded?` guard returns `[]` — the person is on
  no team, as far as the resolver is concerned;
- `team_uuids/1`, `department_uuids/2` and `subject_reach/2` raise into their own
  `rescue` and answer `[]` / `0`;
- therefore `Grants.group_role_of/2` → `nil` → `Authz.effective_role/2` sees only
  the direct membership row.

**Every team- and department-based grant stops granting**, silently, on data that
is sitting right there in the database. People lose access to projects they
legitimately hold, and the Members panel reports the blast radius of those grants
as 0. Nothing errors; the resolver just quietly answers "no".

`ProjectMembersLive` had the milder version of the same bug: grant rows rendered
with no group name and the "grant access to" picker offered no groups at all.

**Fix applied:** both modules now go through `PhoenixKitProjects.People` and its
shadow schemas — `People.get_person_by_user_uuid/2`, `People.Team`,
`People.TeamMembership`, `People.Department`. The shadow schemas already map every
column these queries touch, so the change is mechanical.

### …and the gate that was supposed to catch it does nothing ✅ fixed

`WITHOUT_STAFF=1 mix deps.get && WITHOUT_STAFF=1 mix compile --warnings-as-errors`
is described as the seam's compile gate in **four** places — AGENTS.md, the
`mix.exs` dep comment ("`WITHOUT_STAFF=1 mix compile` drops it entirely, which is
the seam's compile gate proving no stray hard reference sneaks back in"),
`People`'s inline comment, and `people_seam_test.exs`'s docstring.

**Nothing reads the variable.** `mix.exs` never calls
`System.get_env("WITHOUT_STAFF")`; `pk_dep/3` only knows about `<APP>_PATH`.
`optional: true` governs a *consumer's* dependency closure — it does not remove
the dep from this package's own build. So the gate compiled with
`phoenix_kit_staff` installed and passed unconditionally, which is precisely how
the two direct references above got in and stayed.

**Fix applied:** `pk_dep/3` returns `nil` for a dropped dep (via a new
`dropped_dep?/1`) and `deps/0` compacts the list, so `WITHOUT_STAFF=1` genuinely
removes the package. Verified: the gate now runs for real (see Gate below) — and
it fails on the unfixed tree, which is the point.

---

## BUG - MEDIUM — pending submissions are out of the lists but in all the numbers ✅ fixed

**Where:** `lib/phoenix_kit_projects/projects.ex`

`Assignment.review_status` says what the queue is for:

> "pending" is a request from a stranger that nobody has agreed to yet — it is NOT
> work, so it stays out of the plan, the counts and every view until somebody
> decides.

`list_assignments/1` honours that. Nothing else did. The aggregates read the
`Assignment` table directly, so a stranger's unreviewed portal report immediately:

| Read path | What the stranger's submission did |
|---|---|
| `project_summaries/1` — status counts | added a `todo` to the dashboard breakdown |
| `project_summaries/1` — progress sum | grew the denominator and dragged `progress_pct` down |
| `project_summaries/1` — `batched_planned_hours/2` | entered the planned-hours sum |
| `assignment_status_counts/0` | inflated the workload widget |
| `assignment_counts_for_projects/1` | inflated the projects list's task column |
| `task_usage/1` | inflated the task library's "Uses" column |
| `available_dependencies/2` | **offered an unreviewed stranger's title as a dependency in the admin UI** |

The last row is the one that matters most: it puts attacker-supplied text into a
staff-facing picker before anybody has reviewed it.

`decide_completion/1` and `project_tree_summary/1` were already safe — both go
through `list_assignments/1`.

**Fix applied:** a shared `accepted_only/1` query filter (mirroring the existing
`exclude_subprojects/1`), applied to all seven read paths above.

**Tests:** `projects_context_test.exs` — a new "pending submissions stay out of the
measurements" block covering summaries, per-project counts, task usage, the
dependency picker, and that accepting the submission puts it back in every count.

---

## BUG - MEDIUM — anonymous portal submissions write to the site-wide task library

**Where:** `lib/phoenix_kit_projects/portal.ex` → `create_submission/6`

```elixir
with {:ok, task} <- Projects.create_task(%{"title" => title, "description" => description}),
     {:ok, assignment} <- Projects.create_assignment(%{...}, review: :pending),
```

The review queue holds the **assignment**. The `Task` it points at is a row in
`phoenix_kit_project_tasks` — the *reusable template library*, which is:

- listed at `/admin/projects/tasks` for the whole site, with no provenance marker
  (`Task` has no `source` column; `Assignment` does);
- offered in every project's "pick an existing task" dropdown, on every project,
  not just the one with a portal;
- broadcast on `projects:tasks` via `:task_created`, so every open Tasks list
  reloads on each submission;
- position-numbered by `next_task_position/0`, so each one walks the library's
  manual ordering forward.

So the thing the review queue is holding back is the assignment, while the
attacker-controlled title and description are already visible site-wide, before
any human decision. "A person approves it" — the stated argument for accepting
anonymous input at all — is not true of the library row.

**Not fixed.** The fix is a `source` column on `Task` plus a sweep of every
task-library read (`list_tasks/1`, `count_tasks/1`, `list_tasks_with_deps/1`, the
assignment-form picker, `task_usage/1`). This module now owns its own migration
chain (`Migrations.Schema`, currently V14), so a V15 is available in-repo and the
change is tractable — but it is a schema change plus a read sweep, which is a
change of the same size as the finding and deserves its own PR rather than a
post-merge patch. Recording it so the limitation is on the record rather than
discovered in an abuse report.

---

## BUG - MEDIUM — the permission interceptor can't see sub-project tasks

**Where:** `lib/phoenix_kit_projects/web/project_show_live.ex` — `authz_record/3`

```elixir
defp authz_record(event, %{"uuid" => uuid}, socket) when is_binary(uuid) do
  if event in @record_param_events do
    Enum.find(socket.assigns[:assignments] || [], &(&1.uuid == uuid))
  end
end
```

The record is resolved from `assigns[:assignments]` — this project's own accepted
rows. But the handlers behind the gate accept a **wider** set: `scoped_assignment/2`
also admits a task belonging to an expanded sub-project's child project
(`displayed_child_task?/2`), which is the documented behaviour ("Child-task events
work because `scoped_assignment/2` accepts any displayed assignment").

Two consequences when a child task is acted on from the parent's page:

1. **The relationship grant can't fire.** `authz_record/3` returns `nil`, so
   `Authz.can?(…, record: nil)` cannot match the assignee — the person the work was
   handed to is refused on their own task whenever the floor sits above their role.
   That is precisely the case `hub_permission_enforcement_test.exs` calls "the case
   that makes a blanket deny wrong", working for top-level tasks and not for
   nested ones.
2. **The wrong project's floors are consulted.** `can?/5` is always passed
   `socket.assigns.project` — the parent. A child project with tighter
   `settings["authz"]` floors, or different membership, never gets them applied
   through this path.

**Not fixed.** Correcting it means threading the record's *own* project into
`can?/5` and giving `authz_record/3` the same widened lookup, which changes the
authorization result for every nested-task event — a behaviour change that wants
its own test matrix and a decision from the author about which project's floors
*should* govern a child task shown on a parent's page. Patching it blind, in a
post-merge sweep, is how a permission model acquires a rule nobody chose.

---

## IMPROVEMENT - HIGH — `Features.gates/1` costs ~15+ queries per call

**Where:** `lib/phoenix_kit_projects/features.ex`

`gates/1` folds over 15 gate keys and calls `on?/2` for each. Every `on?/2`:

- rebuilds `catalog()` from scratch (walks the extension Registry, flat-maps and
  reduces every extension's flags) — 15 times per `gates/1` call;
- calls `Extensions.enabled?/3`, which runs a `ProjectModule` row query;
- recurses through `flag.requires`, repeating both.

`gates/1` runs on every `ProjectShowLive` mount and again on every
`:project_features_changed` / `:project_modules_changed` broadcast.
`ProjectMembersLive.relevant_authz_actions/1` does the same shape a second time
(`Features.on?` per catalog entry **and** `Extensions.enabled?` per extension type).

**Fix shape:** load the project's `ProjectModule` rows once, compute `catalog()`
once, and resolve the whole gate map against those two in memory — the public
`on?/2` signature doesn't have to change, only `gates/1` stops going through it.
Not applied: it's a pure optimization on the module's hottest read path and
deserves a before/after measurement rather than being folded into a correctness
patch.

---

## IMPROVEMENT - MEDIUM — `list_projects_for/2` loads everything to build a uuid list

**Where:** `lib/phoenix_kit_projects/projects.ex` — `maybe_scope_to_viewer/2`

The docstring says:

> Filtering happens IN SQL (a uuid set from one grants query), not by loading
> everything and rejecting in memory.

Half true. `maybe_scope_to_viewer/2` calls `Members.accessible_projects/1`, which
runs three queries and materialises **full `%Project{}` structs** for every
accessible project, and then keeps only `&1.uuid`. The narrowing is in SQL; the
uuid set is not.

It matters most on the mention typeahead:
`ResourceLinks.accessible_project_uuids/1` calls `list_projects_for/2` and maps to
uuids — per keystroke.

**Fix shape:** a `Members.accessible_project_uuids/1` selecting `p.uuid` only
(the name is already used privately in `resource_links.ex` for a different
concept), with `accessible_projects/1` built on top of it. Not applied for the
same reason as the previous item.

---

## BUG - LOW — `suggest_public_slug/1` used `:rand` ✅ fixed

**Where:** `lib/phoenix_kit_projects/schemas/portal.ex`

The fallback for a name that slugifies to empty or reserved was
`"board-#{:rand.uniform(9999)}"`. `:rand` is per-process seeded and reproducible.
This value is only a suggestion the admin edits — but it reaches
`slug_for_mode/3`'s `suggested_public_slug/1` on the "switch to public without an
explicit slug" path, where it becomes the board's actual address with no human in
the loop. One source for slug bytes is cheaper to keep true than a rule about
which callers matter.

**Fix applied:** `:crypto.strong_rand_bytes(2) |> :binary.decode_unsigned()`.

---

## BUG - LOW — portal attachments never reach the project's Files tab

**Where:** `lib/phoenix_kit_projects/portal.ex` — `store_one_attachment/2`

`Storage.store_file/2` is called with `user_uuid: <project owner>` and **no
folder**, and `Attachments.attach_files/2` is never called on the portal path
(`Whiteboards` and `ProjectFilesLive` are its only callers). So a submitted
screenshot is homeless: reachable only through `PortalSubmission.file_uuids` — the
review dialog (`review_images/1`) and, on a public board, `board_images/2`.

Phase 1 recorded this as fixed ("wires portal file UUIDs into the project folder so
core's orphan collector can find them"). That wiring is not in the code.

Nothing leaks and nothing is stranded on the delete path —
`delete_attachments_for/1` is correctly called from `delete_assignment/1`. But a
**rejected** submission is deliberately kept rather than deleted, so its images
stay in storage forever, owned by the project owner, visible on no surface.

**Not fixed:** one line (`Attachments.attach_files(project.uuid, file_uuids)`)
would put them in the project folder, but that also makes anonymous uploads appear
in the project's Files tab as ordinary project files, which is a product decision
about what that tab means — not a call to make in a review.

---

## NITPICK — per-IP portal rate buckets are keyed per project

**Where:** `lib/phoenix_kit_projects/portal.ex` — `check_rate/2`

```elixir
{"pkp_portal:m:#{project_uuid}:#{bucket}", @per_ip_minute},
{"pkp_portal:d:#{project_uuid}:#{bucket}", @per_ip_day},
```

The moduledoc says "5/min + 30/day per peer bucket". Including `project_uuid` in
the IP keys means one address gets a *fresh* 5/min + 30/day allowance on every
board it can reach. The per-project 100/day ceiling still caps each board, so the
total is bounded by (boards × 100/day) rather than by anything about the IP.

Either drop `project_uuid` from the two IP keys, or say "per peer bucket, per
board" in the doc. Left alone: which one is right is a policy choice.

---

## IMPROVEMENT - MEDIUM — AGENTS.md now contradicts the code in three load-bearing places

This PR changed AGENTS.md only for the staff-optional seam. Three statements are
now actively wrong, and they are the kind future-me reads as authoritative:

1. **"## Database — Migrations live in `phoenix_kit` core as versioned `VNN`.
   Current migration: **V101**"** and **"What this module does NOT have → **No own
   migrations**"**. This PR adds `PhoenixKitProjects.Migrations.Schema`, a
   module-owned chain at V14 with its own `pkp_schema:<N>` marker, discovered by
   core's `mix phoenix_kit.update`. That is a significant architectural change and
   the doc denies it outright.
2. **"## Permissions — `permission: \"projects\"` on all tabs. Mount guards; events
   trust the mount check."** That is the exact model this PR replaced. Events no
   longer trust the mount check — `@event_actions` + `Authz.can?/5` is the point of
   the whole change.
3. The **file-layout tree** lists none of the ~25 new modules (`authz`, `portal`,
   `members`, `grants`, `extensions/`, `features`, `ledger`, `invoicing`,
   `whiteboards`, `people/`, `migrations/`, …).

Also: `mix.exs` still declares `plt_add_apps: [:phoenix_kit, :phoenix_kit_staff]`
while `:phoenix_kit_staff` is now optional — dialyzer will not find the PLT app on
a `WITHOUT_STAFF` build.

**Not fixed:** rewriting the architecture sections of a 1,400-line convention doc
is the author's call, not a reviewer's — the three items above are flagged so the
next change lands against the real shape.

---

## Verified as correct (spot-checks that found nothing)

Recording these so a later reader knows they were looked at rather than skipped:

- **The two-stage interceptor covers every mutating handler.** Enumerated all 36
  `gated_handle_event/3` clauses against `@gated_events` / `@event_actions`;
  `confirm_start_project` (above) was the only mutation with no permission term.
  `save_health`, `save_work_entry` and `generate_invoice` self-check inline, as
  documented.
- **`board_move` cannot corrupt the plan.** `reposition_from_drop/3` takes only the
  anchor from the client's partial `ordered_ids` and rebuilds the order from the
  server's complete list; `fromStatus` is ignored; the status write is delegated to
  the same handlers the buttons use.
- **`review_submission` is scoped to this project's queue**, not looked up by uuid
  alone — correct, since `scoped_assignment/2` can no longer vouch for a pending row.
- **`ProjectMembersLive` and `ProjectModulesLive` re-check per event**
  (`with_authz/2`), not only at mount. `revoke_grant` is scoped to the project's own
  loaded grants.
- **`PortalHeaders` fails closed by construction** — the restrictive headers are the
  default branch and only a confirmed `public` board relaxes robots; OG previews are
  gated on the same confirmation, so a capability slug never gets an unfurlable URL.
- **Portal mention typeahead** scopes `#` through the same `issues_query/1` the board
  renders from and `@` to commenters on *this* issue, with `on_this_board?/2`
  re-checking the issue belongs to the portal even though the LV already did.
- **Tokens are assembled server-side** via `Token.to_string/4`, so a title containing
  `|` or `]` cannot forge a mention.
- **The submit guard chain is correctly ordered** — honeypot → fill-time → rate limit
  → validate → *then* the attachment thunk, so a caller about to be refused never
  costs an image re-encode.
- **`Authz.set_overrides/3` and `Features.set_flags/3` use targeted `jsonb_set`
  merges**, not read-merge-write of the shared `settings` column — correct, and the
  reason is in the comment.
- **`decide_completion/1`** goes through `list_assignments/1`, so a pending
  submission cannot block a project from completing.

---

## Gate

Run with `PHOENIX_KIT_PATH=../phoenix_kit` — see the CRITICAL finding; the pinned
Hex core cannot compile this tree.

| Step | Result |
|---|---|
| `mix format --check-formatted` | clean |
| `mix compile --force --warnings-as-errors` | clean |
| `mix credo --strict` | clean (2,877 mods/funs) |
| `mix dialyzer` | passed |
| `mix test` | 230 tests, 0 failures, **1,168 excluded** |
| `WITHOUT_STAFF=1 mix compile --warnings-as-errors` | clean — and now real |

The staff-optional gate was run both ways. On the fixed tree it is green; swapping
`grants.ex` back to its merged state makes it fail with exactly the references the
fix removed:

```
warning: PhoenixKitStaff.Schemas.TeamMembership.__schema__/1 is undefined
         (module PhoenixKitStaff.Schemas.TeamMembership is not available…)
  └─ lib/phoenix_kit_projects/grants.ex:219: PhoenixKitProjects.Grants.subject_reach/2
  └─ lib/phoenix_kit_projects/grants.ex:335: PhoenixKitProjects.Grants.team_uuids/1
warning: PhoenixKitStaff.Schemas.Team.__schema__/1 is undefined …
```

**Testing caveat, stated plainly:** this environment has **no PostgreSQL**, so the
1,168 integration + LiveView tests are auto-excluded — the documented behaviour
("`mix test` never hard-fails on a missing DB"). Every test added or changed with
these fixes is DB-backed, which means:

> **None of the new tests in this branch have been executed.** They compile, and
> they are modelled on the passing tests beside them, but they need a run against a
> real database before this is trusted.

That applies to the 13 new/changed tests across `projects_context_test.exs`,
`hub_permission_enforcement_test.exs`, `embedding_test.exs` and
`embedding_emit_test.exs`.

---

## Verdict

Ship the fixes; **do not release.** The tree does not compile against its own
dependency pin. The release unblocks in this order:

1. core publishes the Mentions API (`PhoenixKit.Mentions`,
   `PhoenixKitWeb.Components.Core.MentionText`);
2. `pk_dep(:phoenix_kit, …)` here moves to that release;
3. `mix test` runs green against a real PostgreSQL, including the new tests;
4. then version bump, CHANGELOG, publish, tag.

No version bump or CHANGELOG entry was written for this work: the CHANGELOG dates
each heading with its release date, and stamping one today for a version that
cannot be published would be a false record.

Of the findings not fixed here, two are worth a follow-up issue before the portal
is switched on for a real public board: **the task-library write** (an anonymous
stranger's text reaching a site-wide admin surface with no review) and **the
sub-project permission gap** (an assignee locked out of their own nested task,
governed by the wrong project's floors).
