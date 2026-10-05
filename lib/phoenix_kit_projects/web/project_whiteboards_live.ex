defmodule PhoenixKitProjects.Web.ProjectWhiteboardsLive do
  @moduledoc """
  The **Whiteboards** extension tab (Step 11): board list + canvas, rendered
  by the projects hub via `live_render` with the extension-tab session
  contract (see `PhoenixKitHelloWorld.Web.ProjectHelloTabLive` for the
  contract reference). Mounts off-router only; no `handle_params/3`.

  Drawing itself is core's `MediaCanvasViewer` LiveComponent — annotation
  persistence, palettes, and tools all live there; this LV only manages
  board rows and hands the component either a **board** (a file-less
  board since V16: `Whiteboards.viewer_board/1`, drawn on an empty
  canvas with shapes anchored to the board's uuid) or a curated file map
  (`Whiteboards.viewer_file/1`, for a board over a real image or one made
  by the old white-PNG bridge).

  Authorization: the hub renders extension tabs inside surfaces it has
  already authorized (the admin show page / an authorized host embed), and
  the tab session carries no scope — so, per the extension-tab contract,
  this LV scopes every query by the session's project and does not re-run
  `Authz` per event (same trust model as every contributed tab).
  Board creation and deletion are identity-gated: no `current_user_uuid`
  in the session, no writes (an unattributable actor on the activity row
  is not an audit trail) — and write-gated on the session's `"can_write"`,
  which the HOST resolves from its scope against this extension's
  declared write action (final panel: mutations must not ride the
  view-only trust model). `can_write` also reaches the canvas as
  `can_annotate`: a viewer without it sees every board locked — no
  drawing tools, no pencil, and core refuses its shape changes — since
  the drawing surface is the third write, and it used to ride the same
  view-only trust (the sweep, 2026-09-05).

  Phoenix-first: the board list, create, and delete all work without JS;
  the canvas needs core's Fresco/Etcher hooks (already shipped by
  `phoenix_kit.js`) and renders the background image server-side either way.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext

  # A destructive action that asks through core's confirm modal.
  import PhoenixKitProjects.Web.Components.ConfirmAction, only: [confirm_action_modal: 1]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{L10n, Projects, Whiteboards}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Web.Components.ConfirmAction
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
       can_write: session["can_write"] == true,
       boards: (project && Whiteboards.list_for_project(project.uuid)) || [],
       selected: nil,
       viewer_file: nil,
       viewer_board: nil,
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
  # A destructive action asks first through core's confirm modal
  # (`Components.ConfirmAction`); only these events may be put behind it.
  def handle_event("request_confirm", params, socket),
    do: {:noreply, ConfirmAction.request(socket, params, ~w(delete_board))}

  def handle_event("confirm_action_cancel", _params, socket),
    do: {:noreply, ConfirmAction.clear(socket)}

  def handle_event("confirm_action_ok", _params, socket) do
    case ConfirmAction.take(socket) do
      {nil, socket} -> {:noreply, socket}
      {%{event: event, params: params}, socket} -> handle_event(event, params, socket)
    end
  end

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

      not socket.assigns.can_write ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to change whiteboards."))}

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
               gettext("Could not create the whiteboard.")
             )}
        end
    end
  end

  def handle_event("open_board", %{"uuid" => uuid}, socket) do
    {:noreply, select_board(socket, uuid)}
  end

  def handle_event("close_board", _params, socket) do
    {:noreply, assign(socket, selected: nil, viewer_file: nil, viewer_board: nil)}
  end

  def handle_event("delete_board", %{"uuid" => uuid}, socket) do
    %{project: project, current_user: user} = socket.assigns

    # Same identity gate as create: a session whose user did not resolve
    # must not destroy a board (and, file-less, its drawings) with a nil
    # actor on the activity row.
    with true <- socket.assigns.can_write,
         %{uuid: actor_uuid} <- user,
         %{} = board <- project && Whiteboards.get(project.uuid, uuid),
         :ok <- Whiteboards.delete(board, actor_uuid: actor_uuid) do
      selected = socket.assigns.selected

      socket =
        if selected && selected.uuid == uuid,
          do: assign(socket, selected: nil, viewer_file: nil, viewer_board: nil),
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
        assign(socket,
          selected: board,
          viewer_board: Whiteboards.viewer_board(board),
          viewer_file: if(board.file_uuid, do: Whiteboards.viewer_file(board.file_uuid))
        )
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

          <%= cond do %>
            <% @viewer_board -> %>
              <div class="h-[70vh] min-h-[420px] rounded-lg overflow-hidden border border-base-200 bg-base-200/40">
                <.live_component
                  module={MediaCanvasViewer}
                  id={"project-whiteboard-canvas-#{@selected.uuid}"}
                  board={@viewer_board}
                  current_user={@current_user}
                  parent_id={"project-whiteboards-#{@project.uuid}"}
                  viewer_only={true}
                  can_annotate={@can_write}
                />
              </div>
            <% @viewer_file -> %>
              <div class="h-[70vh] min-h-[420px] rounded-lg overflow-hidden border border-base-200 bg-base-200/40">
                <.live_component
                  module={MediaCanvasViewer}
                  id={"project-whiteboard-canvas-#{@selected.file_uuid}"}
                  file={@viewer_file}
                  current_user={@current_user}
                  parent_id={"project-whiteboards-#{@project.uuid}"}
                  viewer_only={true}
                  can_annotate={@can_write}
                />
              </div>
            <% true -> %>
              <div class="alert alert-warning text-sm">
                {gettext("The background file for this whiteboard is missing.")}
              </div>
          <% end %>
        <% true -> %>
          <div class="flex items-center justify-between gap-2">
            <p class="text-sm text-base-content/60">
              {gettext("Freeform boards — draw, mark up, and pin images with the annotation tools.")}
            </p>
            <button
              :if={@can_write}
              type="button"
              class="btn btn-primary btn-sm"
              phx-click="open_new_board"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New whiteboard")}
            </button>
          </div>

          <%= if @boards == [] do %>
            <.empty_state icon="hero-paint-brush" title={gettext("No whiteboards yet.")}>
              <:cta>
                <button
                  :if={@can_write}
                  type="button"
                  class="link link-primary text-sm"
                  phx-click="open_new_board"
                >
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
                      :if={@can_write}
                      type="button"
                      {ConfirmAction.ask("delete_board",
                        uuid: board.uuid,
                        title: gettext("Remove whiteboard"),
                        message: gettext("Remove \"%{name}\"? The drawing stays in the project files.", name: board.name),
                        confirm: gettext("Remove")
                      )}
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

          <.modal
            :if={@new_modal_open}
            show
            on_close="close_new_board"
            id={"whiteboard-new-#{@project.uuid}"}
            max_width="sm"
            close_guard={:input}
          >
            <:title>{gettext("New whiteboard")}</:title>
            <form id={"new-whiteboard-form-#{@project.uuid}"} phx-submit="create_board" class="flex flex-col gap-3">
              <.input
                id={"whiteboard-name-#{@project.uuid}"}
                name="name"
                value=""
                label={gettext("Name")}
                required
                maxlength="160"
                class="input-sm"
                placeholder={gettext("e.g. Sprint sketches")}
              />
              <.select
                id={"whiteboard-size-#{@project.uuid}"}
                name="size"
                label={gettext("Size")}
                value={size_options() |> List.first() |> elem(0)}
                class="select-sm"
                options={for {key, label} <- size_options(), do: {label, key}}
              />
              <div class="modal-action">
                <.button type="button" variant="ghost" size="sm" phx-click="close_new_board">
                  {gettext("Cancel")}
                </.button>
                <.button type="submit" size="sm" phx-disable-with={gettext("Creating…")}>
                  {gettext("Create")}
                </.button>
              </div>
            </form>
          </.modal>
      <% end %>
      <.confirm_action_modal confirm={assigns[:confirm_action]} />
    </div>
    """
  end
end
