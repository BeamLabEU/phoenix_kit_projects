defmodule PhoenixKitProjects.Web.TemplateFormLive do
  @moduledoc "Create or edit a project template."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Project

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    project = %Project{is_template: true}

    socket
    |> assign(page_title: gettext("New template"), project: project, live_action: :new)
    |> assign_form(Projects.change_project(project))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Projects.get_project(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Template not found."))
        |> push_navigate(to: Paths.templates())

      project ->
        socket
        |> assign(
          page_title: gettext("Edit %{name}", name: project.name),
          project: project,
          live_action: :edit
        )
        |> assign_form(Projects.change_project(project))
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("validate", %{"project" => attrs}, socket) do
    attrs = Map.put(attrs, "is_template", "true")
    cs = socket.assigns.project |> Projects.change_project(attrs) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, cs)}
  end

  def handle_event("save", %{"project" => attrs}, socket) do
    attrs = Map.merge(attrs, %{"is_template" => "true", "start_mode" => "immediate"})
    save(socket, socket.assigns.live_action, attrs)
  end

  defp save(socket, :new, attrs) do
    case Projects.create_project(attrs) do
      {:ok, project} ->
        Activity.log("projects.template_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project_template",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Template created. Add tasks to it now."))
         |> push_navigate(to: Paths.template(project.uuid))}

      {:error, cs} ->
        Activity.log_failed("projects.template_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project_template",
          metadata: %{"name" => Map.get(attrs, "name") || Ecto.Changeset.get_field(cs, :name)}
        )

        {:noreply, assign_form(socket, cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Projects.update_project(socket.assigns.project, attrs) do
      {:ok, project} ->
        Activity.log("projects.template_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project_template",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Template updated."))
         |> push_navigate(to: Paths.template(project.uuid))}

      {:error, cs} ->
        Activity.log_failed("projects.template_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project_template",
          resource_uuid: socket.assigns.project.uuid,
          metadata: %{"name" => socket.assigns.project.name}
        )

        {:noreply, assign_form(socket, cs)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-xl px-4 py-6 gap-4">
      <.page_header title={@page_title}>
        <:back_link>
          <.link navigate={Paths.templates()} class="link link-hover text-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Templates")}
          </.link>
        </:back_link>
      </.page_header>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <.form for={@form} id="template-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-3">
            <.input field={@form[:name]} label={gettext("Name")} required />
            <.textarea field={@form[:description]} label={gettext("Description")} />
            <label class="flex items-center gap-2 cursor-pointer">
              <input type="hidden" name={@form[:counts_weekends].name} value="false" />
              <input
                type="checkbox"
                name={@form[:counts_weekends].name}
                value="true"
                checked={@form[:counts_weekends].value == true or @form[:counts_weekends].value == "true"}
                class="checkbox checkbox-sm"
              />
              <span class="text-sm">{gettext("Count weekends in schedule")}</span>
            </label>
            <div class="flex justify-end gap-2 mt-2">
              <.link navigate={Paths.templates()} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
              <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
