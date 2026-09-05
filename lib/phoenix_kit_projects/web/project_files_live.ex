defmodule PhoenixKitProjects.Web.ProjectFilesLive do
  @moduledoc """
  Per-project **Files** — the hub's native attachments surface (P2b),
  folder-scoped via `PhoenixKitProjects.Attachments` (core Storage; no
  module table). Upload/browse rides core's `MediaSelectorModal` scoped to
  the project folder; picked/uploaded files link into it, removal follows
  the sole-home-soft-trash convention.

  Gated on the built-in `files` extension (toggleable per project in the
  Modules panel) + `Authz.can?(…, :upload_files)` for mutations; viewing
  requires `:view`. Embeddable like every LV here.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.{Attachments, Authz, Extensions, L10n, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Crumbs
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  require Logger

  @default_wrapper_class "flex flex-col mx-auto max-w-4xl px-4 py-6 gap-6"

  # ── Mount ───────────────────────────────────────────────────────

  @impl true
  def mount(:not_mounted_at_router, %{"id" => id} = session, socket) do
    WebHelpers.maybe_put_locale(session)
    mount(%{"id" => id}, session, socket)
  end

  def mount(%{"id" => id}, session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket =
      socket
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()
      |> assign(wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class))

    with %Project{} = project <- Projects.get_project(id) || :not_found,
         true <- Extensions.enabled?(project, "files") || :files_off,
         true <- Authz.can?(scope(socket), project, :view) || :forbidden do
      if connected?(socket) do
        ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
      end

      {:ok,
       socket
       |> assign(
         # Trail: Admin Panel / Projects / <parents…> / <project> / Files —
         # the project is a linked crumb, the sub-page the leaf (see `Web.Crumbs`).
         page_title: gettext("Files"),
         page_section: gettext("Projects"),
         page_section_path: Paths.projects(),
         page_crumbs: Crumbs.project(project, L10n.current_content_lang()),
         project: project,
         show_picker: false,
         folder_uuid: Attachments.folder_uuid(project.uuid)
       )
       |> load_files()}
    else
      :not_found -> bounce(socket, gettext("Project not found."))
      :files_off -> bounce(socket, gettext("Files are turned off for this project."))
      :forbidden -> bounce(socket, gettext("You don't have permission to view this project."))
    end
  end

  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket
    |> WebHelpers.assign_embed_state(session)
    |> bounce(gettext("Project not found."))
  end

  defp bounce(socket, message) do
    {:ok,
     socket
     |> assign(
       project: nil,
       files: [],
       show_picker: false,
       folder_uuid: nil,
       wrapper_class: socket.assigns[:wrapper_class] || @default_wrapper_class
     )
     |> put_flash(:error, message)
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  defp scope(socket), do: socket.assigns[:phoenix_kit_current_scope]

  defp load_files(socket) do
    assign(socket, files: Attachments.list_files(socket.assigns.project.uuid))
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("open_picker", _params, socket) do
    with_upload_authz(socket, fn ->
      case Attachments.ensure_folder(socket.assigns.project.uuid) do
        {:ok, folder_uuid} ->
          {:noreply, assign(socket, folder_uuid: folder_uuid, show_picker: true)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not prepare the project folder."))}
      end
    end)
  end

  def handle_event("close_picker", _params, socket),
    do: {:noreply, assign(socket, show_picker: false)}

  def handle_event("remove_file", %{"uuid" => file_uuid}, socket) do
    with_upload_authz(socket, fn ->
      case Attachments.remove_file(socket.assigns.project.uuid, file_uuid) do
        :ok ->
          Activity.log("projects.file_removed",
            actor_uuid: Activity.actor_uuid(socket),
            resource_type: "project",
            resource_uuid: socket.assigns.project.uuid,
            metadata: %{"file_uuid" => file_uuid}
          )

          {:noreply, socket |> load_files() |> put_flash(:info, gettext("File removed."))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not remove the file."))}
      end
    end)
  end

  defp with_upload_authz(socket, fun) do
    if socket.assigns.project &&
         Authz.can?(scope(socket), socket.assigns.project, :upload_files) do
      fun.()
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to manage files here."))}
    end
  end

  # ── Modal results (plain-LV notify contract) ────────────────────

  @impl true
  def handle_info({:media_selected, file_uuids}, socket) when is_list(file_uuids) do
    if Authz.can?(scope(socket), socket.assigns.project, :upload_files) do
      Attachments.attach_files(socket.assigns.project.uuid, file_uuids)

      Activity.log("projects.file_added",
        actor_uuid: Activity.actor_uuid(socket),
        resource_type: "project",
        resource_uuid: socket.assigns.project.uuid,
        metadata: %{"count" => length(file_uuids)}
      )

      {:noreply,
       socket
       |> assign(show_picker: false)
       |> load_files()
       |> put_flash(:info, gettext("Files added."))}
    else
      {:noreply, assign(socket, show_picker: false)}
    end
  end

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, assign(socket, show_picker: false)}

  def handle_info({:projects, _event, _payload}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%= if @project do %>
        <.page_header
          title={gettext("Files")}
          description={
            gettext("Everything attached to %{name}.",
              name: Project.localized_name(@project, L10n.current_content_lang())
            )
          }
        >
          <:back_link>
            <.smart_link
              navigate={Paths.project(@project.uuid)}
              emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => @project.uuid}}}
              embed_mode={@embed_mode}
              class="btn btn-ghost btn-sm gap-1"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" />
              {gettext("Back to project")}
            </.smart_link>
          </:back_link>
          <:actions>
            <button type="button" class="btn btn-primary btn-sm" phx-click="open_picker">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add files")}
            </button>
          </:actions>
        </.page_header>

        <%= if @files == [] do %>
          <.empty_state icon="hero-paper-clip" title={gettext("No files yet.")}>
            <:cta>
              <button type="button" class="link link-primary text-sm" phx-click="open_picker">
                {gettext("Add the first file")}
              </button>
            </:cta>
          </.empty_state>
        <% else %>
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
            <div
              :for={file <- @files}
              class="card border border-base-200 bg-base-100 hover:shadow-sm transition-shadow"
            >
              <div class="card-body p-3 flex-row items-center gap-3">
                <.icon name={Attachments.file_icon(file)} class="w-8 h-8 opacity-60 shrink-0" />
                <div class="min-w-0 grow">
                  <div class="text-sm font-medium truncate" title={file.original_file_name}>
                    {file.original_file_name || file.file_name}
                  </div>
                  <div class="text-xs opacity-60">
                    {L10n.format_month_day_time(file.inserted_at)}
                  </div>
                </div>
                <a
                  :if={Attachments.download_url(file)}
                  href={Attachments.download_url(file)}
                  target="_blank"
                  rel="noopener"
                  class="btn btn-ghost btn-xs btn-circle"
                  aria-label={gettext("Open file")}
                >
                  <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
                </a>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs btn-circle text-error"
                  phx-click="remove_file"
                  phx-value-uuid={file.uuid}
                  phx-disable-with="…"
                  data-confirm={gettext("Remove this file from the project?")}
                  aria-label={gettext("Remove file")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <.live_component
          :if={@show_picker}
          module={MediaSelectorModal}
          id={"project-files-picker-#{@project.uuid}"}
          show={@show_picker}
          mode={:multiple}
          selected_uuids={[]}
          scope_folder_id={@folder_uuid}
          phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
        />
      <% end %>
    </div>
    """
  end
end
