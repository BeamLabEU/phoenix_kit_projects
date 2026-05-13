# Gettext i18n triage — phoenix_kit_projects

Source-of-truth for the bucket assignments made during the
"Translate UI text in projects module" effort (initiated 2026-05-13).
Each `gettext(...)` call site in `lib/` falls into one of three buckets:

- **A — already in core's `.po`.** Existing entry in
  `phoenix_kit/priv/gettext/en/LC_MESSAGES/default.po`. No action;
  module-backend files will re-translate them in their own `.po`
  (duplication accepted — cost is small).
- **B — generic, missing from core.** Push to core's `.pot` + per-locale
  `.po` files in a sibling PR. File stays on `PhoenixKitWeb.Gettext`.
- **C — projects-domain-specific.** Stays in this repo. File's
  `use Gettext, backend: ...` swaps to `PhoenixKitProjects.Gettext`.
  All msgids land in `phoenix_kit_projects/priv/gettext/`.

Bucketing is done **per file** — `use Gettext, backend: ...` is
file-scoped, so every `gettext`/`ngettext` call in a file resolves
against the same backend. Per-call routing via
`Gettext.gettext(BackendModule, "...")` is reserved for the (currently
zero) sites where a C-bucket file genuinely needs to pull a core string.

## Counts

- 432 raw `gettext` + 14 `ngettext` call sites in `lib/`
- 298 unique singular msgids + 10 unique plural pairs
- 17 overlap with core's existing `.po` (bucket A — no work)
- 16 new strings going to core (bucket B)
- ~291 unique msgids staying in this module (bucket C)

## Per-file decisions

### Bucket B files (stay on `PhoenixKitWeb.Gettext`)

| File | Calls | Rationale |
|------|-------|-----------|
| `lib/phoenix_kit_projects/l10n.ex` | 15 | Months `Jan`..`Dec` + 3 date format templates — domain-neutral, reusable across modules. |
| `lib/phoenix_kit_projects/web/components/sortable_table.ex` | 3 | `Title` / `Actions` / `Drag to reorder` — generic table chrome. |

### Bucket C files (swap to `PhoenixKitProjects.Gettext`)

All other 21 files with gettext calls. The `use Gettext` line in each
becomes `use Gettext, backend: PhoenixKitProjects.Gettext`:

- `lib/phoenix_kit_projects/errors.ex`
- `lib/phoenix_kit_projects/projects.ex`
- `lib/phoenix_kit_projects/schemas/assignment.ex`
- `lib/phoenix_kit_projects/schemas/dependency.ex`
- `lib/phoenix_kit_projects/schemas/project.ex`
- `lib/phoenix_kit_projects/schemas/task.ex`
- `lib/phoenix_kit_projects/schemas/task_dependency.ex`
- `lib/phoenix_kit_projects/web/assignment_form_live.ex`
- `lib/phoenix_kit_projects/web/components/derived_status_badge.ex`
- `lib/phoenix_kit_projects/web/components/page_header.ex`
- `lib/phoenix_kit_projects/web/components/running_card.ex`
- `lib/phoenix_kit_projects/web/components/tabs_strip.ex`
- `lib/phoenix_kit_projects/web/components/tier_pill.ex`
- `lib/phoenix_kit_projects/web/overview_live.ex`
- `lib/phoenix_kit_projects/web/project_form_live.ex`
- `lib/phoenix_kit_projects/web/project_show_live.ex`
- `lib/phoenix_kit_projects/web/projects_live.ex`
- `lib/phoenix_kit_projects/web/task_form_live.ex`
- `lib/phoenix_kit_projects/web/tasks_live.ex`
- `lib/phoenix_kit_projects/web/template_form_live.ex`
- `lib/phoenix_kit_projects/web/templates_live.ex`

`Gettext.dgettext(PhoenixKitWeb.Gettext, "errors", ...)` /
`dngettext(...)` calls in `project_show_live.ex` (Ecto changeset error
translation) stay pointed at core — the `errors` domain belongs to core
and the explicit call shape doesn't depend on the file-level backend.

## Bucket B — strings to add to core

To land in `phoenix_kit/priv/gettext/default.pot` + per-locale `.po`:

```text
msgid "Jan"
msgid "Feb"
msgid "Mar"
msgid "Apr"
msgid "May"
msgid "Jun"
msgid "Jul"
msgid "Aug"
msgid "Sep"
msgid "Oct"
msgid "Nov"
msgid "Dec"
msgid "%{month} %{day}, %{year}"
msgid "%{month} %{day}, %{year} at %{time}"
msgid "%{month} %{day} %{time}"
msgid "Title"
```

Translations in `et` and `ru` should be filled (matches core's
existing ~98% coverage for those two). `de`/`es`/`fr`/`it`/`pl` stay as
empty msgstrs — consistent with how the rest of core is stubbed for
those languages today (`fill rate: de 4%, es 11%, fr 4%, it 4%, pl 4%`).

## Bucket A — overlap (no work, will be re-translated in module)

These 17 msgids appear in both core and projects:

```text
—, Actions, Add, Archived, Cancel, Close, Comments, Completed,
days, Description, Done, Drag to reorder, Edit, Name, Person,
Save, Status
```

`Actions` and `Drag to reorder` are referenced from `sortable_table.ex`
(a B file) so they're served by core directly. The other 15 are
referenced from C files and will be re-translated in
`phoenix_kit_projects/priv/gettext/`. Duplication cost: trivial.

## Language coverage targets

| Language | Module `.po` | Core bucket-B additions |
|----------|--------------|-------------------------|
| `de` | full (Claude) | stubs (match core's existing pattern) |
| `es` | full (Claude) | stubs |
| `et` | full (Claude) | full |
| `fr` | full (Claude) | stubs |
| `it` | full (Claude) | stubs |
| `pl` | full (Claude) | stubs |
| `ru` | full (Claude) | full |

Module-side full translation across all 7 languages is what Max asked
for in the kickoff (`Claude fills msgstrs in this session`). Core-side
stays consistent with the existing coverage pattern so the bucket-B
sibling PR doesn't accidentally become "translate 1300 strings in 5
new languages."
