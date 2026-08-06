defmodule PhoenixKitProjects.Web.MemberProjectsLive do
  @moduledoc """
  The member-facing projects surface — **My Projects** on the user
  dashboard (`/dashboard/projects`), the non-admin doorway into the hub.

  Registered via `user_dashboard_tabs/0` with a `live_view`, so core's
  authenticated route table generates the route (no admin permission
  involved — the page runs in the `:phoenix_kit_authenticated`
  live_session like My Orders / My Tickets).

  ## The membership gate (load-bearing)

  Embedded hub LVs trust their host (`session["current_user_uuid"]`, no
  internal authz on mount) — so THIS page is the authorization boundary:
  it only lists projects from the viewer's OWN membership rows
  (`Members.projects_for_user/1`), and `?open=` resolves against that
  same list — a foreign uuid simply doesn't open. Inside an opened
  project the normal `Authz.can?/4` membership floors apply to every
  event (owner > manager > member > viewer).

  ## Opening a project

  `?open=<uuid>` (patch, deep-linkable) swaps the list for the full
  project page: `PopupHostLive` with `ProjectShowLive` as the root view,
  so everything the project page opens (task forms, gantt, calendar)
  stacks in modals via the emit contract — no admin routes touched.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.LayoutHelpers, only: [dashboard_assigns: 1]

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitProjects.L10n
  alias PhoenixKitProjects.Members
  alias PhoenixKitProjects.Web.PopupHostLive

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:phoenix_kit_current_user]

    {:ok,
     assign(socket,
       page_title: gettext("My Projects"),
       current_user: user,
       memberships: (user && Members.projects_for_user(user.uuid)) || []
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    open =
      case params["open"] do
        uuid when is_binary(uuid) and uuid != "" ->
          # The gate: resolve against the viewer's own membership list only.
          Enum.find(socket.assigns.memberships, fn {p, _role} -> p.uuid == uuid end)

        _ ->
          nil
      end

    {:noreply,
     assign(socket,
       url_path: URI.parse(uri).path,
       open: open,
       page_title:
         case open do
           {p, _} -> p.name
           _ -> gettext("My Projects")
         end
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="container mx-auto flex flex-col gap-4">
        <%= if @open do %>
          <% {project, _role} = @open %>
          <div>
            <.link patch={Routes.path("/dashboard/projects")} class="btn btn-ghost btn-sm gap-1">
              <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("My Projects")}
            </.link>
          </div>
          {live_render(@socket, PopupHostLive,
            id: "member-project-host-#{project.uuid}",
            session: %{
              "pubsub_topic" => "pk_projects:member:#{@current_user.uuid}:#{project.uuid}",
              "current_user_uuid" => @current_user.uuid,
              "locale" => L10n.current_content_lang(),
              "root_view" => %{
                "lv" => "PhoenixKitProjects.Web.ProjectShowLive",
                "session" => %{"id" => project.uuid}
              }
            }
          )}
        <% else %>
          <div>
            <h1 class="text-2xl font-bold">{gettext("My Projects")}</h1>
            <p class="text-base-content/70 mt-1">
              {gettext("Projects you are a member of.")}
            </p>
          </div>

          <div :if={@memberships == []} class="card border border-dashed border-base-300 bg-base-100">
            <div class="card-body items-center text-center py-10">
              <.icon name="hero-briefcase" class="w-10 h-10 opacity-30" />
              <p class="text-sm opacity-70">
                {gettext("You are not a member of any project yet.")}
              </p>
            </div>
          </div>

          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <.link
              :for={{project, role} <- @memberships}
              patch={Routes.path("/dashboard/projects") <> "?open=#{project.uuid}"}
              class="card border border-base-200 bg-base-100 transition-shadow hover:shadow-md"
            >
              <div class="card-body gap-2 py-4">
                <div class="flex items-start justify-between gap-2">
                  <h2 class="card-title text-base">{project.name}</h2>
                  <span class="badge badge-ghost badge-sm shrink-0">{role_label(role)}</span>
                </div>
                <p :if={project.description} class="line-clamp-2 text-sm opacity-60">
                  {project.description}
                </p>
              </div>
            </.link>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end

  defp role_label("owner"), do: gettext("owner")
  defp role_label("manager"), do: gettext("manager")
  defp role_label("member"), do: gettext("member")
  defp role_label("viewer"), do: gettext("viewer")
  defp role_label(other), do: other
end
