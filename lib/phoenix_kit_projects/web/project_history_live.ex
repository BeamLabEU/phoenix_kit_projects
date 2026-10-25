defmodule PhoenixKitProjects.Web.ProjectHistoryLive do
  @moduledoc """
  A project's **History** tab: the project told as it happened —
  `PhoenixKitProjects.History` drawn by `Components.HistoryFeed`. Nested in
  the project page (`live_render`, lazily on first open, like the Timeline);
  reloads when anything in the project changes. Read-only, embeddable (no
  `handle_params/3`).

  Session: `"id"` (the project, required), `"current_user_uuid"`,
  `"locale"`, `"wrapper_class"`.

  The raw audit log stays on the project's ⋮ → Activity page.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  import PhoenixKitProjects.Web.Components.HistoryFeed, only: [history_feed: 1]

  alias PhoenixKitProjects.{Authz, History, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @per_page 100
  @reload_ms 400

  @filters %{
    "all" => [:activity, :comment, :note, :time],
    "changes" => [:activity],
    "comments" => [:comment, :note],
    "time" => [:time]
  }

  @impl true
  def mount(:not_mounted_at_router, %{"id" => id} = session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket =
      socket
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> assign(wrapper_class: Map.get(session, "wrapper_class", ""))

    with %Project{} = project <- Projects.get_project(id),
         true <- Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :view) do
      if connected?(socket),
        do: ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))

      {:ok,
       socket
       |> assign(project: project, filter: "all", shown: @per_page, reload_ref: nil)
       |> load()}
    else
      _ ->
        {:ok,
         assign(socket,
           project: nil,
           entries: [],
           total: 0,
           truncated: false,
           filter: "all",
           shown: 0
         )}
    end
  end

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       project: nil,
       entries: [],
       total: 0,
       truncated: false,
       filter: "all",
       shown: 0,
       wrapper_class: ""
     )}
  end

  defp load(socket) do
    %{entries: entries, total: total, truncated: truncated} =
      History.list(socket.assigns.project, kinds: Map.fetch!(@filters, socket.assigns.filter))

    assign(socket, entries: entries, total: total, truncated: truncated)
  rescue
    e ->
      Logger.warning("[Projects] history load failed: #{inspect(e.__struct__)}")
      assign(socket, entries: [], total: 0, truncated: false)
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) when is_map_key(@filters, filter) do
    {:noreply, socket |> assign(filter: filter, shown: @per_page) |> load()}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    {:noreply, assign(socket, shown: socket.assigns.shown + @per_page)}
  end

  # Any change in the project: reload once the burst settles (a tick can
  # move a dozen rows, each its own message).
  @impl true
  def handle_info({:projects, _event, _payload}, %{assigns: %{project: %Project{}}} = socket) do
    if ref = socket.assigns.reload_ref, do: Process.cancel_timer(ref)
    {:noreply, assign(socket, reload_ref: Process.send_after(self(), :reload, @reload_ms))}
  end

  def handle_info(:reload, socket) do
    {:noreply, socket |> assign(reload_ref: nil) |> load()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%= if @project do %>
        <div class="flex flex-wrap items-center gap-2 mb-3" id={"history-filters-#{@project.uuid}"}>
          <button
            :for={{key, label} <- [{"all", gettext("Everything")}, {"changes", gettext("Changes")}, {"comments", gettext("Comments")}, {"time", gettext("Time")}]}
            type="button"
            phx-click="filter"
            phx-value-filter={key}
            class={["btn btn-xs", if(@filter == key, do: "btn-primary", else: "btn-ghost")]}
          >
            {label}
          </button>
          <span class="text-xs text-base-content/50 ml-auto">
            {ngettext("1 line", "%{count} lines", @total)}
          </span>
        </div>

        <%= if @entries == [] do %>
          <.empty_state icon="hero-clock" title={gettext("Nothing has happened here yet.")} />
        <% else %>
          <.history_feed
            id={"project-history-#{@project.uuid}"}
            entries={Enum.take(@entries, @shown)}
            project={@project}
          />
          <div :if={length(@entries) > @shown} class="flex justify-center mt-3">
            <button type="button" phx-click="load_more" class="btn btn-ghost btn-sm">
              {gettext("Show older")}
            </button>
          </div>
          <p :if={@truncated and length(@entries) <= @shown} class="text-xs text-base-content/50 mt-3">
            {gettext("Older lines are not shown: this project's history is very long.")}
          </p>
        <% end %>
      <% end %>
    </div>
    """
  end
end
