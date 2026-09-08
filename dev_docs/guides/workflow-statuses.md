# Workflow statuses (entities-backed, cement-at-start)

How a project's user-defined status vocabulary is sourced, cemented at
start, localized and displayed.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Feature notes.

A user-defined **workflow status** (Backlog → In Progress → Blocked →
Done, etc.), orthogonal to the computed `Project.derived_status/2` and the
`archived_at` soft-hide.

**Available on every project-like record.** Since a sub-project and a template
are both projects, they get the same status-source picker. The form section
(Custom Status select + "Generate default" + status preview + "Translated
status titles") lives in the shared `Web.Components.WorkflowStatusFields`
component, with its logic (`available?/0`, `entity_options/0`, `preview_for/1`,
`mode_string/1`, `apply_mode/3`, `selected_entity_uuid/1`) reused by
`ProjectFormLive` (inline), `TemplateFormLive`, and `AssignmentFormLive`'s
sub-project mode. Each LV owns its `generate_default_statuses` handler (it knows
which form to update). The current-status value picker on `ProjectShowLive`
isn't gated on `is_template`, so templates + opened sub-projects show it too; a
template's chosen list + current status flow to cloned projects via
`inherit_status_slug_in_tx/2`.

The vocabulary is configured through the **optional**
`phoenix_kit_entities` module and **cemented locally** when a project
starts. Lives in `PhoenixKitProjects.Statuses` (mirrors `Translations`'
optional-dep scaffolding) + `Schemas.ProjectStatus`.

## Two layers

- **Catalog (entities).** Status lists are entities. The admin **generates**
  a default list (`Statuses.create_default_status_entity/0`) — named
  `project_statuses`, auto-incrementing to `project_statuses_2`, `_3`, … so
  generating again always makes a fresh list (e.g. after editing the last
  one) rather than reusing it — seeded with the default vocabulary. One is
  designated the **global default** via the Settings page (see below).
  Per-project custom entities the user owns are named
  `project_status_<32-hex-uuid>`; all are tagged
  `settings["source"] = "phoenix_kit_projects"`. Templates and
  not-yet-started projects read the chosen catalog **live**.
- **Cemented (local).** `start_project/2` snapshots the chosen catalog
  into `phoenix_kit_project_statuses` rows (in the same transaction). The
  running project then uses its own frozen, independently-editable copy —
  later catalog edits don't touch it. Same template→instance philosophy
  as Assignment-copies-Task.

  "Frozen" means it **stops following the live catalog**, NOT read-only.
  The cemented rows remain editable through the context as a deliberate
  escape hatch (there is no UI for it): `Statuses.add_project_status/2`,
  `update_project_status_row/2`, `remove_project_status/2`,
  `get_project_status/2`. So a started project's statuses can still be
  changed via the API "in case it's really wanted" — pinned by the
  "local CRUD post-start" test in `statuses_test.exs`.

`started_at` is the cement boundary (`derived_status` → `:running` iff
`started_at`). The selected status is `current_status_slug` on the
project — a stable identity that resolves against the live catalog
pre-start and the local rows post-start. It is **server-owned**: written
only via `Statuses.set_current_status/3` →
`Projects.set_current_status_slug/2` (the dedicated
`Project.current_status_changeset/2`), never the form changeset.
`status_entity_uuid` (which catalog list; nil = shared) is form-castable
**only before start** — see the source lock below.

## Choosing / changing the status source (incl. existing projects)

Any entity can serve as a status source — each of its data **records** is a
status, the record's built-in **`title`** is the label, and an optional
**`color`** field on records drives the badge colour. No marker field is
required. `Statuses.list_status_source_entities/0` returns entities grouped
for a picker (`[{"Status lists", …}, {"Other entities", …}]`, the
`settings["source"] = "phoenix_kit_projects"` catalogs first).

**Where the source is chosen.** The status-source picker lives ONLY on the
new/edit project forms (`ProjectFormLive`) — NOT on `ProjectShowLive`. The
show page only displays the current-status value picker, and only once the
project's list has statuses; it has no source selector. The picker is the
shared `<.workflow_status_fields>` component (form-bound to
`status_entity_uuid`, "Use global default" prompt + grouped) with a
**"Generate default"** button beside it and a live **preview** of the
selected list's statuses — the **same component** projects, templates and
sub-projects (`AssignmentFormLive`) all render, so the section never diverges.

**The source is a pre-start choice — frozen after start.** Since statuses
cement at `started_at`, a started project's source can no longer change. The
component takes `locked={Statuses.started?(project)}`: once started the
`<.select>` is `disabled`, the "Generate default" button is hidden, and a
"Frozen at start" hint shows. The lock is keyed on `started?` (NOT on whether
a custom entity is selected), so a started project on the **global default**
(nil `status_entity_uuid`) locks too. Server-side mate: every `save(:edit)`
runs `attrs = Statuses.lock_status_source(attrs, project)`, which strips
`status_entity_uuid` for started projects — so even a crafted submit past the
disabled control can't change the frozen source. (`set_status_entity/3` +
`recement_project_statuses/1` remain as a programmatic "cement on select" API,
exercised only by `statuses_test.exs`; no UI reaches them.)

**The "Shared default" is admin-chosen, not auto-created.** A project with no
`status_entity_uuid` resolves to the global default entity stored in the
`projects_default_status_entity_uuid` setting (picked on the projects Settings
page — `/admin/settings/projects` — or generated there). Nothing is
auto-provisioned on read; if no default is set, the project has no statuses.
`Statuses.global_default_status_entity_uuid/0` / `set_default_status_entity/1`
read/write the setting; `resolve_catalog_entity_uuid/1` uses it.

**Statuses are title-only for colour** (none seeded; badges render neutral), but
the cemented row uses JSONB: `phoenix_kit_project_statuses` has
`label`(primary)/`slug`/`position` + `data` JSONB (`{"color"}` + future per-status
attrs) + `translations` JSONB (label i18n, workspace shape).
`ProjectStatus.color/1` reads `data["color"]`.

**Titles are localized.** Reads resolve the label to the current content locale
(`L10n.current_content_lang/0`, the process Gettext locale the host sets from the
URL prefix) — no LV signature changes. Catalog reads pass `lang:` to
`EntityData.list_by_entity/2` so the entities module resolves each record's title;
`cement_project_statuses/2` captures the **primary** title as `label` plus every
enabled non-primary language's title into the row's `translations` JSONB (via
per-language catalog reads + `Languages.enabled_languages/0`), and
`ProjectStatus.localized_label/2` resolves cemented rows on read — so a started
project stays localized independent of the catalog.

**Display toggle (global + per-project override).** Translations are always
captured; *displaying* them is gated. `Statuses.use_status_translations?/1`
resolves: per-project override → global setting → `true`. The global default is
the `projects_use_status_translations` setting
(`Settings.get_boolean_setting(_, true)`). The per-project override is a tri-state
in the project's `settings` JSONB (`use_status_translations` = true/false/absent;
absent = inherit global) — `Project.status_translation_override/1` reads it (the
schema stays pure; resolution-with-global lives in `Statuses`). The project form
exposes a 3-way "Translated status titles" control (Default / Show translated /
Show original) that folds into `settings`. The **global** toggle lives in the core
Settings area (`/admin/settings/projects`, a global-settings tab via
`settings_tabs/0` → `Web.ProjectsSettingsLive`, alongside
Comments/Posts/Entities), which writes the global default via
`PhoenixKit.Settings` (default `true`).

## Optional dependency

`{:phoenix_kit_entities, optional: true}` — loadable in this package's own
test build, kept out of host closures. Every `Statuses` function degrades
gracefully when entities is absent/disabled (`available?/0` gates
everything; reads → `[]`/`nil`, provisioning →
`{:error, :entities_not_available}`, cement → no-op). UI surfaces guard on
a `:statuses_available` assign and hide cleanly.

## Schema

- `phoenix_kit_projects.status_entity_uuid` — FK
  `phoenix_kit_entities(uuid) ON DELETE SET NULL`.
- `phoenix_kit_projects.current_status_slug` — varchar.
- `phoenix_kit_project_statuses` — the cemented copy (`project_uuid` FK
  cascade, `label`/`slug`/`position` + `data` JSONB (per-status attrs e.g.
  `{"color"}`) + `translations` JSONB (label i18n), provenance
  `source_entity_data_uuid` with no FK). Unique `(project_uuid, slug)`.

## Host wiring — "Used by N projects" count

Projects is a library and can't self-register OTP config. To power the
entities admin's reverse-reference hint, the host app adds:

```elixir
config :phoenix_kit_entities,
  reverse_references: [{"project_status", &PhoenixKitProjects.Statuses.reverse_reference_count/1}]
```

Informational only (never a delete-blocker). Counts projects/templates
currently *sourcing* from a catalog entity — started projects no longer
reference it (cemented), which is the intended semantics.
