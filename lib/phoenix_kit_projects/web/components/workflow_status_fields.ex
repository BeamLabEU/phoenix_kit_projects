defmodule PhoenixKitProjects.Web.Components.WorkflowStatusFields do
  @moduledoc """
  The shared "Workflow status" form section (V125), reused by every form that
  edits a project-like record: `ProjectFormLive`, `TemplateFormLive`, and
  `AssignmentFormLive`'s sub-project mode. A sub-project and a template are both
  projects, so they get the same status-source picker a project has.

  The component renders the section; the module's plain functions
  (`available?/0`, `entity_options/0`, `preview_for/1`, `mode_string/1`,
  `apply_mode/3`, `selected_entity_uuid/1`) are the shared logic so each LV's
  mount/validate/save stays a thin delegation. The "Generate default" button
  emits `generate_default_statuses` — each LV owns that handler (it knows which
  form to update).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitProjects.Web.Components.DerivedStatusBadge

  alias PhoenixKitProjects.{Paths, Statuses}
  alias PhoenixKitProjects.Schemas.Project

  attr(:statuses_available, :boolean, default: false)
  attr(:field, :any, required: true, doc: "the `status_entity_uuid` form field")
  attr(:status_entities, :list, default: [])
  attr(:status_preview, :list, default: [])
  attr(:status_translation_mode, :string, default: "")

  attr(:locked, :boolean,
    default: false,
    doc:
      "true once the project has started — its statuses were cemented at start " <>
        "(`started_at` is the freeze boundary), so the source can no longer change"
  )

  def workflow_status_fields(assigns) do
    ~H"""
    <div
      :if={@statuses_available}
      class="border-t border-base-300 mt-6 pt-6 flex flex-col gap-2"
    >
      <h3 class="text-sm font-semibold text-base-content/80">
        {gettext("Workflow status")}
      </h3>
      <.select
        field={@field}
        label={gettext("Custom Status")}
        options={@status_entities}
        prompt={gettext("Use global default")}
        disabled={@locked}
      />
      <p :if={@locked} class="text-xs text-base-content/60 flex items-center gap-1">
        <.icon name="hero-lock-closed" class="w-3 h-3" />
        {gettext("Frozen at start — a running project's status list can't be changed.")}
      </p>
      <button
        :if={!@locked}
        type="button"
        phx-click="generate_default_statuses"
        phx-disable-with={gettext("Generating…")}
        class="btn btn-ghost btn-sm gap-1 self-start"
      >
        <.icon name="hero-sparkles" class="w-4 h-4" />
        {gettext("Generate default")}
      </button>
      <div :if={@status_preview != []} class="flex flex-col gap-1">
        <span class="text-xs text-base-content/60">
          {gettext("Statuses from this list:")}
        </span>
        <div class="flex flex-wrap gap-1">
          <.workflow_status_badge :for={s <- @status_preview} status={s} />
        </div>
      </div>
      <.select
        name="status_translation_mode"
        label={gettext("Translated status titles")}
        value={@status_translation_mode}
        options={[
          {gettext("Use global default"), ""},
          {gettext("Show translated"), "true"},
          {gettext("Show original"), "false"}
        ]}
      />
      <.link navigate={Paths.settings()} class="link link-hover text-xs text-base-content/60">
        {gettext("Change the defaults here")}
      </.link>
    </div>
    """
  end

  # ── Shared logic (delegated to from each LV) ──────────────────────

  @doc "True when the optional entities module backs the status feature."
  def available?, do: Statuses.available?()

  @doc "Grouped status-source entity options for the `<.select>`."
  def entity_options, do: Statuses.list_status_source_entities()

  @doc "The status rows the given entity (nil = shared default) would supply."
  def preview_for(nil), do: Statuses.shared_catalog_statuses()
  def preview_for(uuid) when is_binary(uuid), do: Statuses.list_catalog_statuses(uuid)

  @doc ~s|The 3-way translated-titles control value ("true"/"false"/"") for a record.|
  def mode_string(record) do
    case Project.status_translation_override(record) do
      true -> "true"
      false -> "false"
      _ -> ""
    end
  end

  @doc "The `status_entity_uuid` currently in the form (`nil` = shared default)."
  def selected_entity_uuid(field) do
    case field.value do
      v when v in [nil, ""] -> nil
      v -> to_string(v)
    end
  end

  @doc """
  Folds the translated-titles 3-way choice into the `settings` JSONB on `attrs`,
  preserving the record's other settings. `""` removes the per-record override
  (inherit the global default).
  """
  def apply_mode(attrs, params, record) do
    base = record.settings || %{}

    settings =
      case Map.get(params, "status_translation_mode") do
        "true" -> Map.put(base, "use_status_translations", true)
        "false" -> Map.put(base, "use_status_translations", false)
        _ -> Map.delete(base, "use_status_translations")
      end

    Map.put(attrs, "settings", settings)
  end
end
