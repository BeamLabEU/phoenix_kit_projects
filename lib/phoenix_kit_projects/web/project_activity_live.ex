defmodule PhoenixKitProjects.Web.ProjectActivityLive do
  @moduledoc """
  Per-project **Activity** — the hub's native audit surface (P2b): core's
  activity log filtered to this project via the `resource_uuid` filter
  (`PhoenixKit.Activity.list/1`), paged with load-more. Read-only; guarded
  with `Code.ensure_loaded?` so a stripped Activity module degrades to an
  empty feed (the hello_world events pattern). Embeddable like every LV
  here.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKitProjects.{Authz, L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Crumbs
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @default_wrapper_class "flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6"
  @per_page 30

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
         true <-
           Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :view) || :forbidden do
      {:ok,
       socket
       |> assign(
         # Trail: Admin Panel / Projects / <parents…> / <project> / Activity —
         # the project is a linked crumb, the sub-page the leaf (see `Web.Crumbs`).
         page_title: gettext("Activity"),
         page_section: gettext("Projects"),
         page_section_path: Paths.projects(),
         page_crumbs:
           Crumbs.project(
             project,
             L10n.current_content_lang(),
             socket.assigns[:phoenix_kit_current_scope]
           ),
         project: project,
         page: 1,
         entries: [],
         has_more: false,
         total: 0
       )
       |> load_page()}
    else
      :not_found -> bounce(socket, gettext("Project not found."))
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
       entries: [],
       has_more: false,
       total: 0,
       page: 1,
       wrapper_class: socket.assigns[:wrapper_class] || @default_wrapper_class
     )
     |> put_flash(:error, message)
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  defp load_page(socket) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      result =
        PhoenixKit.Activity.list(
          resource_uuid: socket.assigns.project.uuid,
          page: socket.assigns.page,
          per_page: @per_page,
          preload: [:actor]
        )

      socket
      |> assign(
        entries: socket.assigns.entries ++ result.entries,
        total: result.total,
        page: socket.assigns.page + 1,
        has_more: result.page < result.total_pages
      )
    else
      socket
    end
  rescue
    e ->
      Logger.warning("[Projects] activity feed load failed: #{Exception.message(e)}")
      socket
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("load_more", _params, socket) do
    {:noreply, load_page(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%= if @project do %>
        <.page_header
          title={gettext("Activity")}
          description={
            gettext("Everything that happened in %{name}.",
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
        </.page_header>

        <%= if @entries == [] do %>
          <.empty_state icon="hero-clock" title={gettext("No activity recorded yet.")} />
        <% else %>
          <div class="flex flex-col divide-y divide-base-200 border border-base-200 rounded-box bg-base-100">
            <div :for={entry <- @entries} class="flex items-start gap-3 px-4 py-3">
              <.icon name="hero-bolt" class="w-4 h-4 mt-0.5 opacity-40 shrink-0" />
              <div class="min-w-0 grow">
                <div class="text-sm">
                  <span class="font-medium">{entry.action}</span>
                  <span :if={entry.actor} class="opacity-60">
                    · {entry.actor.email}
                  </span>
                </div>
                <div :if={entry.metadata != %{} and entry.metadata} class="text-xs opacity-50 truncate">
                  {inspect(entry.metadata, limit: 6)}
                </div>
              </div>
              <span class="text-xs opacity-50 shrink-0">
                {L10n.format_month_day_time(entry.inserted_at)}
              </span>
            </div>
          </div>

          <button
            :if={@has_more}
            type="button"
            class="btn btn-ghost btn-sm self-center"
            phx-click="load_more"
            phx-disable-with={gettext("Loading…")}
          >
            {gettext("Load more")} ({@total - length(@entries)})
          </button>
        <% end %>
      <% end %>
    </div>
    """
  end
end
