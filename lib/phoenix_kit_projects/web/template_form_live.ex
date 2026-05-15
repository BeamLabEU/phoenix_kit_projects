defmodule PhoenixKitProjects.Web.TemplateFormLive do
  @moduledoc "Create or edit a project template."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Activity, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  # Default wrapper class for the standalone admin page. Embedders can
  # override via `live_render(... session: %{"wrapper_class" => "..."})`.
  @default_wrapper_class "flex flex-col mx-auto max-w-xl px-4 py-6 gap-4"

  @impl true
  def mount(params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    wrapper_class = Map.get(session, "wrapper_class", @default_wrapper_class)
    redirect_to = Map.get(session, "redirect_to")
    live_action = WebHelpers.resolve_live_action(socket, session)
    resolved_params = WebHelpers.resolve_action_params(params, session)

    # `apply_action/3` loads the project on `:edit`; runs at the tail of
    # `mount/3` (not `handle_params/3`) so the LV stays embeddable via
    # `live_render`. See dev_docs/embedding_audit.md.
    socket =
      socket
      |> assign(
        wrapper_class: wrapper_class,
        embed_redirect_to: redirect_to,
        live_action: live_action
      )
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.attach_open_embed_hook()
      |> apply_action(live_action, resolved_params)

    {:ok, socket}
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
        # Render-safe placeholders for emit mode (see ProjectFormLive
        # for the rationale — in emit mode `close_or_navigate` doesn't
        # navigate, so the LV's render runs and needs these assigns).
        socket
        |> assign(
          page_title: "",
          project: %Project{is_template: true},
          live_action: :edit
        )
        |> assign_form(Projects.change_project(%Project{is_template: true}))
        |> put_flash(:error, gettext("Template not found."))
        |> WebHelpers.close_or_navigate(Paths.templates())

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

  # Fail-closed catch-all: emit-session lacking `"id"` for :edit lands
  # here. Render placeholders + flash, then close.
  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(
      page_title: "",
      project: %Project{is_template: true},
      live_action: :edit
    )
    |> assign_form(Projects.change_project(%Project{is_template: true}))
    |> put_flash(:error, gettext("Template not found."))
    |> WebHelpers.close_or_navigate(Paths.templates())
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

  def handle_event("cancel", _params, socket) do
    {:noreply, WebHelpers.close_or_navigate(socket, Paths.templates())}
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
         |> WebHelpers.navigate_after_save(Paths.template(project.uuid),
           kind: :template,
           record: project,
           action: :create,
           # Emit-mode chain: close the form, open the template-show so
           # the user can add tasks (matches the navigate-mode flow).
           next: {PhoenixKitProjects.Web.ProjectShowLive, %{"id" => project.uuid}}
         )}

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
         |> WebHelpers.navigate_after_save(Paths.template(project.uuid),
           kind: :template,
           record: project,
           action: :update
         )}

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
    <div class={@wrapper_class}>
      <.page_header title={@page_title}>
        <:back_link>
          <.smart_link
            navigate={Paths.templates()}
            emit={{PhoenixKitProjects.Web.TemplatesLive, %{}}}
            embed_mode={@embed_mode}
            class="link link-hover text-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Templates")}
          </.smart_link>
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
              <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
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
