defmodule PhoenixKitProjects.Web.ProjectsSettingsLive do
  @moduledoc """
  Projects module settings (global, under the core Settings area).

  Two workflow-status defaults:

    * **Default status list** — the entity a project's "Shared default"
      resolves to (`projects_default_status_entity_uuid`). Nothing is
      auto-created; the admin picks it here (or generates a starter list).
    * **Show translated status titles** — the global default for displaying
      status titles in the viewer's locale (each project can override on its
      form; translations are always captured regardless).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.Statuses
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @default_wrapper_class "flex flex-col w-full px-4 py-6 gap-4"

  @impl true
  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)
    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    available? = Statuses.available?()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Project settings"),
       wrapper_class: wrapper_class,
       statuses_available: available?,
       status_entities: if(available?, do: Statuses.list_status_source_entities(), else: []),
       default_status_entity_uuid: Statuses.global_default_status_entity_uuid(),
       use_status_translations: Statuses.global_use_status_translations?()
     )
     |> WebHelpers.assign_embed_state(session)}
  end

  @impl true
  def handle_event("select_default_status_entity", %{"entity_uuid" => uuid}, socket) do
    uuid = if uuid in [nil, ""], do: nil, else: uuid
    Statuses.set_default_status_entity(uuid)

    Activity.log("projects.default_status_entity_set",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "projects_settings",
      metadata: %{"entity_uuid" => uuid}
    )

    {:noreply,
     socket
     |> assign(default_status_entity_uuid: uuid)
     |> put_flash(:info, gettext("Default status list updated."))}
  end

  def handle_event("generate_default_status_list", _params, socket) do
    case Statuses.create_default_status_entity(actor_uuid: Activity.actor_uuid(socket)) do
      {:ok, entity} ->
        Statuses.set_default_status_entity(entity.uuid)

        Activity.log("projects.status_entity_provisioned",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "projects_settings",
          metadata: %{"entity_name" => entity.name, "scope" => "global_default"}
        )

        {:noreply,
         socket
         |> assign(
           status_entities: Statuses.list_status_source_entities(),
           default_status_entity_uuid: entity.uuid
         )
         |> put_flash(:info, gettext("Default status list created."))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not create the default status list."))}
    end
  end

  def handle_event("toggle_status_translations", _params, socket) do
    new_value = not socket.assigns.use_status_translations

    PhoenixKit.Settings.update_boolean_setting_with_module(
      "projects_use_status_translations",
      new_value,
      "projects"
    )

    Activity.log("projects.status_translations_toggled",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "projects_settings",
      metadata: %{"enabled" => new_value}
    )

    {:noreply,
     socket
     |> assign(use_status_translations: new_value)
     |> put_flash(:info, gettext("Settings saved."))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <.page_header
        title={gettext("Project settings")}
        description={gettext("Defaults for the projects module.")}
      />

      <div class="card bg-base-100 shadow">
        <div class="card-body gap-4">
          <h2 class="card-title text-base">{gettext("Workflow statuses")}</h2>

          <p :if={not @statuses_available} class="text-xs text-base-content/50">
            {gettext("The entities module is not enabled, so workflow statuses are currently unavailable.")}
          </p>

          <%!-- Default status list: the entity a project's "Shared default"
               draws from. Pick any entity, or generate a starter list. --%>
          <form
            :if={@statuses_available}
            phx-change="select_default_status_entity"
            class="flex flex-col gap-2"
          >
            <.select
              name="entity_uuid"
              label={gettext("Default status list")}
              value={@default_status_entity_uuid}
              options={@status_entities}
              prompt={gettext("None")}
            />
            <button
              type="button"
              phx-click="generate_default_status_list"
              phx-disable-with={gettext("Generating…")}
              class="btn btn-ghost btn-sm gap-1 self-start"
            >
              <.icon name="hero-sparkles" class="w-4 h-4" />
              {gettext("Generate default")}
            </button>
          </form>

          <label :if={@statuses_available} class="flex items-start gap-3 cursor-pointer">
            <input
              type="checkbox"
              class="checkbox checkbox-sm mt-0.5"
              checked={@use_status_translations}
              phx-click="toggle_status_translations"
            />
            <span class="flex flex-col">
              <span class="text-sm font-medium">
                {gettext("Show translated status titles by default")}
              </span>
              <span class="text-xs text-base-content/60">
                {gettext(
                  "When on, status titles display in the viewer's language where a translation exists. Each project can override this on its form. Translations are always saved regardless."
                )}
              </span>
            </span>
          </label>
        </div>
      </div>
    </div>
    """
  end
end
