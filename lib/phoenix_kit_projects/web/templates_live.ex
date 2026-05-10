defmodule PhoenixKitProjects.Web.TemplatesLive do
  @moduledoc "List project templates."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitProjects.{Activity, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_templates())
    {:ok, assign(socket, page_title: gettext("Project Templates")) |> load_templates()}
  end

  defp load_templates(socket), do: assign(socket, templates: Projects.list_templates())

  @impl true
  def handle_info({:projects, _event, _payload}, socket) do
    {:noreply, load_templates(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[TemplatesLive] unexpected handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("reorder_templates", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    moved_id = params["moved_id"]

    case Projects.reorder_templates(ordered_ids, actor_uuid: Activity.actor_uuid(socket)) do
      :ok ->
        {:noreply,
         socket
         |> push_event("sortable:flash", %{uuid: moved_id, status: "ok"})
         |> load_templates()}

      {:error, :too_many_uuids} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Too many templates to reorder at once."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_templates()}

      {:error, :wrong_scope} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Template list changed; please try again."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_templates()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not reorder templates."))
         |> push_event("sortable:flash", %{uuid: moved_id, status: "error"})
         |> load_templates()}
    end
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Projects.get_project(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Template not found."))}

      template ->
        case Projects.delete_project(template) do
          {:ok, _} ->
            Activity.log("projects.template_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "project_template",
              resource_uuid: template.uuid,
              metadata: %{"name" => template.name}
            )

            {:noreply,
             socket |> put_flash(:info, gettext("Template deleted.")) |> load_templates()}

          {:error, _} ->
            Activity.log_failed("projects.template_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "project_template",
              resource_uuid: template.uuid,
              metadata: %{"name" => template.name}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete template."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Project Templates")}</h1>
          <p class="text-sm text-base-content/60">{gettext("Blueprint projects that can be cloned.")}</p>
        </div>
        <.link navigate={Paths.new_template()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New template")}
        </.link>
      </div>

      <%= if @templates == [] do %>
        <div class="text-center py-16 text-base-content/60">
          <.icon name="hero-document-duplicate" class="w-12 h-12 mx-auto mb-2 opacity-40" />
          <p>{gettext("No templates yet.")}</p>
          <.link navigate={Paths.new_template()} class="link link-primary text-sm">{gettext("Create your first")}</.link>
        </div>
      <% else %>
        <% lang = L10n.current_content_lang() %>
        <div class="card bg-base-100 shadow">
          <div class="card-body p-0">
            <table class="table">
              <thead>
                <tr>
                  <th class="w-8"></th>
                  <th>{gettext("Name")}</th>
                  <th>{gettext("Weekends")}</th>
                  <th class="text-right">{gettext("Actions")}</th>
                </tr>
              </thead>
              <tbody
                id="templates-list-body"
                phx-hook="SortableGrid"
                data-sortable="true"
                data-sortable-event="reorder_templates"
                data-sortable-items=".sortable-item"
                data-sortable-handle=".pk-drag-handle"
              >
                <tr :for={t <- @templates} class="hover sortable-item" data-id={t.uuid}>
                  <td class="pk-drag-handle cursor-grab text-base-content/40 hover:text-base-content align-middle" title={gettext("Drag to reorder")}>
                    <.icon name="hero-bars-3" class="w-4 h-4" />
                  </td>
                  <td class="align-middle">
                    <.link navigate={Paths.template(t.uuid)} class="link link-hover font-medium">
                      {Project.localized_name(t, lang)}
                    </.link>
                    <% desc = Project.localized_description(t, lang) %>
                    <div :if={desc} class="text-xs text-base-content/60 truncate max-w-md">
                      {desc}
                    </div>
                  </td>
                  <td class="align-middle">
                    <span class={"badge badge-xs #{if t.counts_weekends, do: "badge-info", else: "badge-ghost"}"}>
                      {if t.counts_weekends, do: gettext("yes"), else: gettext("no")}
                    </span>
                  </td>
                  <td class="align-middle">
                    <div class="flex items-center justify-end gap-1">
                      <.link navigate={Paths.edit_template(t.uuid)} class="btn btn-ghost btn-xs">
                        <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                      </.link>
                      <button
                        type="button"
                        phx-click="delete"
                        phx-value-uuid={t.uuid}
                        phx-disable-with={gettext("Deleting…")}
                        data-confirm={gettext("Delete template \"%{name}\"?", name: Project.localized_name(t, lang))}
                        class="btn btn-ghost btn-xs text-error"
                      >
                        <.icon name="hero-trash" class="w-3.5 h-3.5" />
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
