# Multilang user-input content

How user-typed project/task/assignment text is stored, read back and edited
per language, on top of the gettext-based UI translation.

Rules for this live in [AGENTS.md](../../AGENTS.md) → Feature notes.

User-typed content (project name + description, task title +
description, assignment description) is translatable per language,
on top of the standard gettext-based UI translation. Driven by core's
**Languages module** — when 2+ languages are enabled there, the forms
auto-render `<.multilang_tabs>` and `<.translatable_field>`s from
`PhoenixKitWeb.Components.MultilangForm`; when disabled or only one
language, the forms degrade to the regular single-language layout
(no tabs, no skeletons).

## Storage shape

Each of the three project tables carries a `translations JSONB NOT NULL
DEFAULT '{}'::jsonb` column:

  * `phoenix_kit_projects.translations`            — `name`, `description`
  * `phoenix_kit_project_tasks.translations`       — `title`, `description`
  * `phoenix_kit_project_assignments.translations` — `description`

Primary-language values stay in their dedicated columns (`name`,
`title`, `description`); the JSONB only holds non-primary overrides:

```json
{
  "es-ES": {"name": "Proyecto", "description": "..."},
  "fr-FR": {"name": "Projet"}
}
```

This is the **"settings translations"** variant of
`<.translatable_field>` (per the component's docstring) — different
from the entity-data variant where everything goes inside a `data`
JSONB with a `_primary_language` marker. Projects has no per-record
custom fields, so the simpler primary-stays-in-columns shape applies.

## Read paths

Each schema exposes `localized_<field>/2` helpers with primary-fallback
semantics — `nil`/empty override → the primary column. Pass the
current locale (or `nil`):

```elixir
Project.localized_name(project, lang)
Project.localized_description(project, lang)
Task.localized_title(task, lang)
Task.localized_description(task, lang)
Assignment.localized_description(assignment, lang)
```

The current-content language for read paths comes from
`PhoenixKitProjects.L10n.current_content_lang/0`, which reads
`Gettext.get_locale(PhoenixKitWeb.Gettext)` — the locale the parent
app set from the URL prefix (`/bs/...` → `"bs"`). Activity-log
metadata always captures the **primary** column value
(`metadata.name = project.name`), not the localized one — audit
trails are locale-agnostic by design.

## Form mechanics

LVs that need multilang inputs:

1. `import PhoenixKitWeb.Components.MultilangForm`
2. Call `mount_multilang(socket)` in `mount/3` — adds
   `:multilang_enabled`, `:primary_language`, `:current_lang`,
   `:language_tabs`, `:show_multilang_tabs` and attaches the
   debounce hook. If the Languages module is off, all of these are
   defaults — the components no-op and inputs render as plain
   primary-language fields.
3. `handle_event("switch_language", %{"lang" => code}, socket)` →
   `handle_switch_language(socket, code)`. The component's 150 ms
   debounce handles rapid click-through.
4. In `validate` and `save`: pass the form params through
   `PhoenixKitProjects.Web.Helpers.merge_translations_attrs(attrs,
   in_flight_record, schema_module.translatable_fields())` before
   building the changeset. This:
     * strips Phoenix LV's `_unused_*` sentinel keys from the
       submitted `translations` map;
     * drops empty/`nil` overrides so cleared secondary fields
       fall back cleanly to the primary value;
     * deep-merges on top of the record's existing JSONB so other
       languages aren't clobbered;
     * preserves primary-language column values when a secondary-tab
       submission lacks them (the primary `<input>`s aren't in the
       DOM on secondary tabs, so a naive cast would treat them as
       nil and trigger `validate_required` failures).
5. `in_flight_record/3` uses `Ecto.Changeset.apply_changes/1` on the
   form's source so the user's already-typed primary values from
   prior `validate` events become the merge baseline. Needed for
   the "type EN-US, switch to BS, save" flow on `:new` records where
   `socket.assigns[:project]` is the pristine `%Project{}`.

## Form layout rule (load-bearing)

Translatable fields (`name`, `title`, `description`) go inside
`<.multilang_fields_wrapper>`. Non-translatable fields (start mode,
scheduled date, weekends, durations, assignee picker, status, deps)
must be **siblings outside the wrapper** — otherwise their state is
lost on every language switch (the wrapper keys its id on
`@current_lang`, so morphdom re-mounts everything inside on tab
change). `ProjectFormLive` and `TaskFormLive` use a two-card layout
(translatable card + settings card) inside one `<.form>`;
`AssignmentFormLive` has only one translatable field, so it renders
the tabs above the form and uses `<.translatable_field>` standalone
without a `multilang_fields_wrapper`.
