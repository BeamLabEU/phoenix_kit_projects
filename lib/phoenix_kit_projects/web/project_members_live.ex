defmodule PhoenixKitProjects.Web.ProjectMembersLive do
  @moduledoc """
  Per-project **Members** — the hub's native people surface (P2a).

  Members are core users with a project role (owner/manager/member/viewer).
  Add by exact email (core account lookup), change roles inline, remove —
  all through `PhoenixKitProjects.Members`, which owns the last-owner guard
  and the target_uuid'd activity rows (so membership changes notify the
  affected user through core's channels).

  Gated on `Authz.can?(…, :manage_members)` at mount AND per event (this
  page writes authorization state). Embeddable like every LV here.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.{Authz, L10n, Members, Paths, Projects}
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  require Logger

  @default_wrapper_class "flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6"

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
         true <- not project.is_template || :template,
         true <- allowed?(socket, project) || :forbidden do
      if connected?(socket) do
        ProjectsPubSub.subscribe(ProjectsPubSub.topic_project(project.uuid))
      end

      {:ok,
       socket
       |> assign(
         page_title:
           gettext("%{name} · Members",
             name: Project.localized_name(project, L10n.current_content_lang())
           ),
         page_section: gettext("Projects"),
         page_section_path: Paths.projects(),
         project: project,
         add_email: "",
         add_role: "member"
       )
       |> load_members()}
    else
      :not_found -> bounce(socket, gettext("Project not found."))
      :template -> bounce(socket, gettext("Templates don't have members."))
      :forbidden -> bounce(socket, gettext("You don't have permission to manage members."))
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
       members: [],
       add_email: "",
       add_role: "member",
       wrapper_class: socket.assigns[:wrapper_class] || @default_wrapper_class
     )
     |> put_flash(:error, message)
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  defp allowed?(socket, project) do
    Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :manage_members)
  end

  defp load_members(socket) do
    assign(socket, members: Members.list_members(socket.assigns.project.uuid))
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("validate_add", params, socket) do
    {:noreply,
     assign(socket,
       add_email: Map.get(params, "email", ""),
       add_role: valid_role(Map.get(params, "role"))
     )}
  end

  def handle_event("add_member", %{"email" => email} = params, socket) do
    with_authz(socket, fn ->
      role = valid_role(Map.get(params, "role"))

      case find_user(email) do
        nil ->
          {:noreply, put_flash(socket, :error, gettext("No account with that email address."))}

        user ->
          case Members.add_member(socket.assigns.project, user.uuid,
                 role: role,
                 actor_uuid: Activity.actor_uuid(socket)
               ) do
            {:ok, _member} ->
              {:noreply,
               socket
               |> assign(add_email: "", add_role: "member")
               |> load_members()
               |> put_flash(:info, gettext("Member added."))}

            {:error, :last_owner} ->
              {:noreply, put_flash(socket, :error, last_owner_message())}

            {:error, reason} ->
              Logger.warning("[Projects] add_member failed: #{inspect(reason)}")
              {:noreply, put_flash(socket, :error, gettext("Could not add the member."))}
          end
      end
    end)
  end

  def handle_event("change_role", %{"user" => user_uuid, "role" => role}, socket) do
    with_authz(socket, fn ->
      case Members.change_role(
             socket.assigns.project,
             user_uuid,
             valid_role(role),
             Activity.actor_uuid(socket)
           ) do
        {:ok, _} ->
          {:noreply, load_members(socket)}

        {:error, :last_owner} ->
          {:noreply, socket |> load_members() |> put_flash(:error, last_owner_message())}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not change the role."))}
      end
    end)
  end

  def handle_event("remove_member", %{"user" => user_uuid}, socket) do
    with_authz(socket, fn ->
      case Members.remove_member(socket.assigns.project, user_uuid,
             actor_uuid: Activity.actor_uuid(socket)
           ) do
        {:ok, _} ->
          {:noreply, socket |> load_members() |> put_flash(:info, gettext("Member removed."))}

        {:error, :last_owner} ->
          {:noreply, put_flash(socket, :error, last_owner_message())}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not remove the member."))}
      end
    end)
  end

  defp with_authz(socket, fun) do
    if socket.assigns.project && allowed?(socket, socket.assigns.project) do
      fun.()
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to manage members."))}
    end
  end

  defp valid_role(role) when role in ~w(owner manager member viewer), do: role
  defp valid_role(_), do: "member"

  defp find_user(email) when is_binary(email) do
    Auth.get_user_by_email(String.trim(email))
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp find_user(_), do: nil

  defp last_owner_message,
    do: gettext("A project needs at least one owner — promote someone else first.")

  # ── PubSub ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:projects, :project_members_changed, _payload}, socket) do
    {:noreply, load_members(socket)}
  end

  def handle_info({:projects, _event, _payload}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%= if @project do %>
        <.page_header
          title={gettext("Members")}
          description={
            gettext("Who works in %{name} and what they can do.",
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

        <%!-- Add member --%>
        <form
          id="add-member-form"
          phx-submit="add_member"
          phx-change="validate_add"
          class="flex flex-wrap items-end gap-2"
        >
          <label class="form-control grow max-w-xs">
            <span class="label-text text-xs opacity-70 mb-1">{gettext("Email")}</span>
            <input
              type="email"
              name="email"
              value={@add_email}
              placeholder={gettext("person@example.com")}
              class="input input-bordered input-sm"
              required
            />
          </label>
          <label class="form-control w-36">
            <span class="label-text text-xs opacity-70 mb-1">{gettext("Role")}</span>
            <.role_select name="role" value={@add_role} />
          </label>
          <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Adding…")}>
            <.icon name="hero-user-plus" class="w-4 h-4" /> {gettext("Add")}
          </button>
        </form>

        <%!-- Member rows --%>
        <div class="card border border-base-200 bg-base-100">
          <div class="card-body py-2 px-4 divide-y divide-base-200">
            <%= if @members == [] do %>
              <p class="text-sm opacity-60 py-3">
                {gettext("No members yet — the project is visible to admins only.")}
              </p>
            <% end %>
            <div :for={member <- @members} class="flex items-center gap-3 py-2">
              <div class="avatar placeholder">
                <div class="bg-base-300 text-base-content rounded-full w-8 h-8 text-xs">
                  <span>{member.user && String.first(member.user.email || "?")}</span>
                </div>
              </div>
              <div class="min-w-0 grow">
                <div class="text-sm font-medium truncate">
                  {(member.user && member.user.email) || gettext("(deleted account)")}
                </div>
              </div>
              <form phx-change="change_role" class="shrink-0">
                <input type="hidden" name="user" value={member.user_uuid} />
                <.role_select name="role" value={member.role} />
              </form>
              <button
                type="button"
                class="btn btn-ghost btn-xs btn-circle text-error"
                phx-click="remove_member"
                phx-value-user={member.user_uuid}
                phx-disable-with="…"
                data-confirm={gettext("Remove this member from the project?")}
                aria-label={gettext("Remove member")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:name, :string, required: true)
  attr(:value, :string, required: true)

  defp role_select(assigns) do
    ~H"""
    <label class="select select-bordered select-sm">
      <select name={@name}>
        <option value="owner" selected={@value == "owner"}>{gettext("Owner")}</option>
        <option value="manager" selected={@value == "manager"}>{gettext("Manager")}</option>
        <option value="member" selected={@value == "member"}>{gettext("Member")}</option>
        <option value="viewer" selected={@value == "viewer"}>{gettext("Viewer")}</option>
      </select>
    </label>
    """
  end
end
