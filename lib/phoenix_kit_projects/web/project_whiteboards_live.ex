defmodule PhoenixKitProjects.Web.ProjectWhiteboardsLive do
  @moduledoc """
  The **Whiteboards** extension tab (Step 11): board list + canvas, rendered
  by the projects hub via `live_render` with the extension-tab session
  contract (see `PhoenixKitHelloWorld.Web.ProjectHelloTabLive` for the
  contract reference). Mounts off-router only; no `handle_params/3`.

  Drawing itself is core's `MediaCanvasViewer` LiveComponent over the
  board's background file — annotation persistence, palettes, and tools
  all live there; this LV only manages board rows and hands the component
  a curated file map (`Whiteboards.viewer_file/1`).

  Authorization: the hub renders extension tabs inside surfaces it has
  already authorized (the admin show page / an authorized host embed), and
  the tab session carries no scope — so, per the extension-tab contract,
  this LV scopes every query by the session's project and does not re-run
  `Authz` per event (same trust model as every contributed tab).
  Board creation is additionally identity-gated: no `current_user_uuid`
  in the session, no writes (the files table requires an owning user).

  Phoenix-first: the board list, create, and delete all work without JS;
  the canvas needs core's Fresco/Etcher hooks (already shipped by
  `phoenix_kit.js`) and renders the background image server-side either way.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{L10n, Projects, Whiteboards}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  require Logger

  @sizes [
    {"1920x1080", 1920, 1080},
    {"2560x1440", 2560, 1440},
    {"2048x2048", 2048, 2048}
  ]

  @impl true
  def mount(:not_mounted_at_router, session, socket) do
    WebHelpers.maybe_put_locale(session)

    project_uuid = session["project_uuid"]
    project = project_uuid && Projects.get_project(project_uuid)

    if connected?(socket) && project do
      ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
    end

    {:ok,
     assign(socket,
       project: project,
       current_user: load_user(session["current_user_uuid"]),
       boards: (project && Whiteboards.list_for_project(project.uuid)) || [],
       selected: nil,
       viewer_file: nil,
       new_modal_open: false
     )}
  end

  # ── PubSub ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:projects, event, _payload}, socket)
      when event in [:whiteboard_created, :whiteboard_updated, :whiteboard_deleted] do
    {:noreply, reload_boards(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("open_new_board", _params, socket) do
    {:noreply, assign(socket, new_modal_open: true)}
  end

  def handle_event("close_new_board", _params, socket) do
    {:noreply, assign(socket, new_modal_open: false)}
  end

  def handle_event("create_board", %{"name" => name} = params, socket) do
    %{project: project, current_user: user} = socket.assigns
    {width, height} = resolve_size(params["size"])

    cond do
      is_nil(project) ->
        {:noreply, socket}

      is_nil(user) ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to create a whiteboard."))}

      true ->
        case Whiteboards.create(project, name,
               width: width,
               height: height,
               actor_uuid: user.uuid
             ) do
          {:ok, board} ->
            {:noreply,
             socket
             |> assign(new_modal_open: false)
             |> reload_boards()
             |> select_board(board.uuid)}

          {:error, %Ecto.Changeset{}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Give the whiteboard a name (up to 160 characters).")
             )}

          {:error, reason} ->
            Logger.warning("[ProjectWhiteboardsLive] create failed: #{inspect(reason)}")

            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Could not create the whiteboard — is the Storage module set up?")
             )}
        end
    end
  end

  def handle_event("open_board", %{"uuid" => uuid}, socket) do
    {:noreply, select_board(socket, uuid)}
  end

  def handle_event("close_board", _params, socket) do
    {:noreply, assign(socket, selected: nil, viewer_file: nil)}
  end

  def handle_event("delete_board", %{"uuid" => uuid}, socket) do
    %{project: project, current_user: user} = socket.assigns

    with %{} = board <- project && Whiteboards.get(project.uuid, uuid),
         :ok <- Whiteboards.delete(board, actor_uuid: user && user.uuid) do
      selected = socket.assigns.selected

      socket =
        if selected && selected.uuid == uuid,
          do: assign(socket, selected: nil, viewer_file: nil),
          else: socket

      {:noreply, socket |> reload_boards() |> put_flash(:info, gettext("Whiteboard removed."))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Internals ───────────────────────────────────────────────────

  defp load_user(nil), do: nil

  defp load_user(uuid) do
    Auth.get_user(uuid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp reload_boards(socket) do
    case socket.assigns.project do
      nil -> socket
      project -> assign(socket, boards: Whiteboards.list_for_project(project.uuid))
    end
  end

  defp select_board(socket, uuid) do
    case socket.assigns.project && Whiteboards.get(socket.assigns.project.uuid, uuid) do
      nil ->
        socket

      board ->
        assign(socket, selected: board, viewer_file: Whiteboards.viewer_file(board.file_uuid))
    end
  end

  defp resolve_size(size) do
    case Enum.find(@sizes, fn {key, _w, _h} -> key == size end) do
      {_key, w, h} -> {w, h}
      nil -> {1920, 1080}
    end
  end

  defp size_options, do: Enum.map(@sizes, fn {key, w, h} -> {key, "#{w} × #{h}"} end)

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"project-whiteboards-#{(@project && @project.uuid) || "none"}"} class="flex flex-col gap-4">
      <%!-- Nested live_render LVs get no app layout, so flash must render
           inline or put_flash is silently invisible. --%>
      <div
        :if={Phoenix.Flash.get(@flash, :error)}
        class="alert alert-error text-sm py-2"
        phx-click="lv:clear-flash"
        phx-value-key="error"
        role="alert"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </div>
      <div
        :if={Phoenix.Flash.get(@flash, :info)}
        class="alert alert-success text-sm py-2"
        phx-click="lv:clear-flash"
        phx-value-key="info"
        role="status"
      >
        {Phoenix.Flash.get(@flash, :info)}
      </div>
      <%= cond do %>
        <% is_nil(@project) -> %>
          <div class="alert alert-warning text-sm">
            {gettext("Project not found.")}
          </div>
        <% @selected -> %>
          <div class="flex items-center gap-2">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="close_board">
              <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("All whiteboards")}
            </button>
            <h3 class="font-semibold truncate">{@selected.name}</h3>
            <span class="badge badge-ghost badge-sm ml-auto">
              {@selected.width} × {@selected.height}
            </span>
          </div>

          <%= if @viewer_file do %>
            <div class="h-[70vh] min-h-[420px] rounded-lg overflow-hidden border border-base-200 bg-base-200/40">
              <.live_component
                module={MediaCanvasViewer}
                id={"project-whiteboard-canvas-#{@selected.file_uuid}"}
                file={@viewer_file}
                current_user={@current_user}
                parent_id={"project-whiteboards-#{@project.uuid}"}
                viewer_only={true}
              />
            </div>
          <% else %>
            <div class="alert alert-warning text-sm">
              {gettext("The background file for this whiteboard is missing.")}
            </div>
          <% end %>
        <% true -> %>
          <div class="flex items-center justify-between gap-2">
            <p class="text-sm text-base-content/60">
              {gettext("Freeform boards — draw, mark up, and pin images with the annotation tools.")}
            </p>
            <button type="button" class="btn btn-primary btn-sm" phx-click="open_new_board">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New whiteboard")}
            </button>
          </div>

          <%= if @boards == [] do %>
            <.empty_state icon="hero-paint-brush" title={gettext("No whiteboards yet.")}>
              <:cta>
                <button type="button" class="link link-primary text-sm" phx-click="open_new_board">
                  {gettext("Create the first one")}
                </button>
              </:cta>
            </.empty_state>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
              <div
                :for={board <- @boards}
                class="card bg-base-100 border border-base-200 hover:border-primary/40 transition-colors"
              >
                <div class="card-body p-4 gap-2">
                  <button
                    type="button"
                    phx-click="open_board"
                    phx-value-uuid={board.uuid}
                    class="text-left font-medium link link-hover truncate"
                  >
                    <.icon name="hero-paint-brush" class="w-4 h-4 inline-block mr-1 opacity-60" />
                    {board.name}
                  </button>
                  <div class="flex items-center gap-2 text-xs text-base-content/60">
                    <span>{board.width} × {board.height}</span>
                    <span>·</span>
                    <span>{L10n.format_date(board.inserted_at)}</span>
                    <button
                      type="button"
                      phx-click="delete_board"
                      phx-value-uuid={board.uuid}
                      data-confirm={gettext("Remove \"%{name}\"? The drawing stays in the project files.", name: board.name)}
                      class="btn btn-ghost btn-xs text-error ml-auto"
                      title={gettext("Remove whiteboard")}
                    >
                      <.icon name="hero-trash" class="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <%= if @new_modal_open do %>
            <dialog open class="modal modal-open" phx-window-keydown="close_new_board" phx-key="Escape">
              <div class="modal-box max-w-sm">
                <h3 class="font-bold text-lg">{gettext("New whiteboard")}</h3>
                <form phx-submit="create_board" class="flex flex-col gap-3 mt-4">
                  <label class="form-control">
                    <span class="label-text text-xs opacity-70 mb-1">{gettext("Name")}</span>
                    <input
                      type="text"
                      name="name"
                      required
                      maxlength="160"
                      class="input input-bordered input-sm"
                      placeholder={gettext("e.g. Sprint sketches")}
                    />
                  </label>
                  <label class="form-control">
                    <span class="label-text text-xs opacity-70 mb-1">{gettext("Size")}</span>
                    <select name="size" class="select select-bordered select-sm">
                      <option :for={{key, label} <- size_options()} value={key}>{label}</option>
                    </select>
                  </label>
                  <div class="modal-action">
                    <button type="button" phx-click="close_new_board" class="btn btn-ghost btn-sm">
                      {gettext("Cancel")}
                    </button>
                    <button
                      type="submit"
                      phx-disable-with={gettext("Creating…")}
                      class="btn btn-primary btn-sm"
                    >
                      {gettext("Create")}
                    </button>
                  </div>
                </form>
              </div>
              <button
                type="button"
                phx-click="close_new_board"
                class="modal-backdrop"
                aria-label={gettext("Close")}
              >
              </button>
            </dialog>
          <% end %>
      <% end %>
    </div>
    """
  end
end
