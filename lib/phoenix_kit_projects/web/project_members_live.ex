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

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.{Authz, Extensions, Features, Grants, L10n, Members, Paths, Projects}
  # Shadow schemas over the core-owned staff tables, not the optional
  # package's — see the same note in `PhoenixKitProjects.Grants`. Here the
  # symptom was milder but the same shape: without the staff package the
  # grant rows rendered with no team or department NAME, and the picker
  # offered no groups to grant to at all.
  alias PhoenixKitProjects.People
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Schemas.Project
  alias PhoenixKitProjects.Web.Components.AccessPanel
  alias PhoenixKitProjects.Web.Crumbs
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
         # Trail: Admin Panel / Projects / <parents…> / <project> / Members —
         # the project is a linked crumb, the sub-page the leaf (see `Web.Crumbs`).
         page_title: gettext("Members"),
         page_section: gettext("Projects"),
         page_section_path: Paths.projects(),
         page_crumbs:
           Crumbs.project(
             project,
             L10n.current_content_lang(),
             socket.assigns[:phoenix_kit_current_scope]
           ),
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

  defp do_add_grant(socket, type, uuid, role) do
    case Grants.grant(socket.assigns.project, type, uuid, role,
           actor_uuid: Activity.actor_uuid(socket)
         ) do
      {:ok, _} ->
        {:noreply, socket |> load_members() |> put_flash(:info, gettext("Access granted."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not grant access."))}
    end
  end

  defp allowed?(socket, project) do
    Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :manage_members)
  end

  defp load_members(socket) do
    project_uuid = socket.assigns.project.uuid

    project = socket.assigns.project

    assign(socket,
      members: Members.list_members(project_uuid),
      grants: decorate_grants(Grants.list_grants(project_uuid)),
      subject_options: subject_options(),
      visibility: Authz.visibility_of(project),
      authz_choices: Authz.current_overrides(project),
      authz_actions: relevant_authz_actions(project)
    )
  end

  # The same filtering the creation form does, resolved from what the
  # project actually has enabled: a floor for a capability this project
  # turned off is a question with no meaning.
  # Two reads (the flag map, the extension map) where it was one per flag
  # and one per extension — on every mount and members broadcast.
  defp relevant_authz_actions(project) do
    AccessPanel.visible_actions(
      Authz.overridable_actions(),
      Features.flags(project),
      Extensions.enabled_map(project.uuid)
    )
  end

  # A grant row carries only a subject uuid — it has no foreign key,
  # because it points into three different tables, two of them in an
  # optional package. Resolve each to a display name here, and mark the
  # ones whose subject has since been deleted rather than hiding them: an
  # invisible grant that still resolves is worse than a labelled orphan.
  # Labels in one read per subject type and reaches in a fixed number of
  # grouped reads — it was two to four reads per grant, on every mount
  # and members broadcast (the 2026-09-05 N+1 audit).
  defp decorate_grants(grants) do
    labels = subject_labels(grants)
    reaches = Grants.subject_reaches(grants)

    Enum.map(grants, fn grant ->
      key = {grant.subject_type, grant.subject_uuid}
      Map.merge(grant, %{subject_label: Map.get(labels, key), reach: Map.get(reaches, key, 0)})
    end)
  end

  defp subject_labels(grants) do
    by_type =
      grants
      |> Enum.map(&{&1.subject_type, &1.subject_uuid})
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    teams = People.names_by_uuid(:team, Map.get(by_type, "team", []))
    departments = People.names_by_uuid(:department, Map.get(by_type, "department", []))

    %{}
    |> Map.merge(Map.new(teams, fn {uuid, name} -> {{"team", uuid}, name} end))
    |> Map.merge(Map.new(departments, fn {uuid, name} -> {{"department", uuid}, name} end))
    |> Map.merge(role_names(Map.get(by_type, "role", [])))
  end

  # Core has no batched role lookup; roles on a project are one or two, and
  # one bad lookup must not blank the others.
  defp role_names(uuids) do
    Map.new(uuids, fn uuid -> {{"role", uuid}, role_name(uuid)} end)
  end

  defp role_name(uuid) do
    case Roles.get_role_by_uuid(uuid) do
      %{name: name} -> name
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The options a grant can point at. Staff is optional, so a site without
  # it simply offers site roles.
  # {kind, group label, [{name, uuid}]} — empty kinds drop out, so a site
  # without the staff package simply offers site roles.
  defp subject_options do
    [
      {"team", gettext("Teams"), staff_options(People.Team)},
      {"department", gettext("Departments"), staff_options(People.Department)},
      {"role", gettext("Site roles"), role_options()}
    ]
    |> Enum.reject(fn {_kind, _label, options} -> options == [] end)
  end

  defp role_options do
    Roles.list_roles() |> Enum.map(&{&1.name, &1.uuid})
  rescue
    _ -> []
  end

  defp staff_options(schema) do
    RepoHelper.repo().all(schema)
    |> Enum.map(&{&1.name, &1.uuid})
    |> Enum.sort_by(&elem(&1, 0))
  rescue
    _ -> []
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

  def handle_event("add_grant", %{"subject" => subject} = params, socket) do
    with_authz(socket, fn ->
      role = Map.get(params, "role", "viewer")

      # "team:<uuid>" — the kind travels with the choice, so there is no
      # separate type field a caller could mismatch against the uuid.
      case String.split(subject, ":", parts: 2) do
        [type, uuid] when type in ~w(team department role) and byte_size(uuid) > 0 ->
          do_add_grant(socket, type, uuid, role)

        _ ->
          {:noreply, put_flash(socket, :error, gettext("Choose a group first."))}
      end
    end)
  end

  def handle_event("revoke_grant", %{"uuid" => uuid}, socket) do
    with_authz(socket, fn ->
      # Scoped to THIS project: a grant uuid arriving by client event must
      # not be able to revoke a grant on some other project.
      if Enum.any?(socket.assigns.grants, &(&1.uuid == uuid)) do
        Grants.revoke(uuid, actor_uuid: Activity.actor_uuid(socket))
        {:noreply, socket |> load_members() |> put_flash(:info, gettext("Access removed."))}
      else
        {:noreply, put_flash(socket, :error, gettext("Access not found."))}
      end
    end)
  end

  # Visibility and the work floors, written the same way creation writes
  # them: two targeted jsonb merges, never a read-merge-write of the whole
  # settings map (it is shared with the feature flags).
  def handle_event("save_access", params, socket) do
    with_authz(socket, fn ->
      project = socket.assigns.project

      with {:ok, project} <- save_visibility(project, params),
           {:ok, project} <- save_overrides(project, params) do
        Activity.log("projects.project_access_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"visibility" => Authz.visibility_of(project)}
        )

        {:noreply,
         socket
         |> assign(project: project)
         |> load_members()
         |> put_flash(:info, gettext("Access updated."))}
      else
        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update access."))}
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

  defp save_visibility(project, %{"visibility" => value}) when is_binary(value),
    do: Projects.set_visibility(project, value)

  defp save_visibility(project, _params), do: {:ok, project}

  # Only the rows this project actually SHOWED are written. A floor whose
  # capability is off isn't on the form, and re-saving must not invent one
  # — nor drop a stored floor for a capability that is merely hidden right
  # now, which is why this takes the visible keys rather than replacing the
  # whole map.
  defp save_overrides(project, %{"authz" => submitted}) when is_map(submitted) do
    case Map.take(submitted, socket_visible_keys(project)) do
      empty when map_size(empty) == 0 -> {:ok, project}
      floors -> Authz.set_overrides(project, floors)
    end
  end

  defp save_overrides(project, _params), do: {:ok, project}

  defp socket_visible_keys(project) do
    project |> relevant_authz_actions() |> Enum.map(& &1.settings_key)
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
          <label class="fieldset grow max-w-xs">
            <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Email")}</span>
            <input
              type="email"
              name="email"
              value={@add_email}
              placeholder={gettext("person@example.com")}
              class="input input-sm"
              required
            />
          </label>
          <label class="fieldset w-36">
            <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Role")}</span>
            <.role_select name="role" value={@add_role} />
          </label>
          <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Adding…")}>
            <.icon name="hero-user-plus" class="w-4 h-4" /> {gettext("Add")}
          </button>
        </form>

        <%!-- Access. Everything here was settable only while CREATING the
             project, which meant a visibility or floor chosen wrongly at
             minute one could never be changed. It belongs on this page
             because this is where every other "who can reach this" answer
             already lives. --%>
        <div class="card border border-base-200 bg-base-100">
          <div class="card-body gap-3 py-3 px-4">
            <div>
              <h2 class="text-sm font-semibold">{gettext("Access")}</h2>
              <p class="text-xs opacity-60">
                {gettext("Who can see this project, and what they're allowed to do in it.")}
              </p>
            </div>

            <form id="access-form" phx-submit="save_access" class="flex flex-col gap-4">
              <AccessPanel.access_panel
                authz_choices={@authz_choices}
                authz_actions={@authz_actions}
                visibility={@visibility}
                ownership_note={false}
              />
              <div>
                <button type="submit" class="btn btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>
                  {gettext("Save access")}
                </button>
              </div>
            </form>
          </div>
        </div>

        <%!-- Group access. The other half of "who works here": a role held
             by a team, a department, or a site role, so inviting Design or
             letting contractors look is one row instead of a person-by-
             person chore that drifts when people change team. --%>
        <div class="card border border-base-200 bg-base-100">
          <div class="card-body gap-3 py-3 px-4">
            <div>
              <h2 class="text-sm font-semibold">{gettext("Groups with access")}</h2>
              <p class="text-xs opacity-60">
                {gettext("Everyone in the group gets this role here, including people who join it later.")}
              </p>
            </div>

            <form id="add-grant-form" phx-submit="add_grant" class="flex flex-wrap items-end gap-2">
              <%!-- ONE select, grouped by kind. Three selects sharing a
                   field name would need JS (or a CSS reveal) to keep
                   exactly one enabled; an optgroup needs neither, and the
                   value carries its own kind so the server never has to
                   trust a separate type field. --%>
              <label class="fieldset grow max-w-sm">
                <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Group")}</span>
                <label class="select select-sm">
                  <select name="subject">
                    <option value="">{gettext("Choose a team, department, or role…")}</option>
                    <optgroup :for={{kind, label, options} <- @subject_options} label={label}>
                      <option :for={{name, uuid} <- options} value={"#{kind}:#{uuid}"}>
                        {name}
                      </option>
                    </optgroup>
                  </select>
                </label>
              </label>

              <label class="fieldset w-36">
                <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Role")}</span>
                <label class="select select-sm">
                  <select name="role">
                    <option value="viewer">{gettext("Viewer")}</option>
                    <option value="member">{gettext("Member")}</option>
                    <option value="manager">{gettext("Manager")}</option>
                  </select>
                </label>
              </label>

              <button type="submit" class="btn btn-primary btn-sm gap-1">
                <.icon name="hero-user-group" class="w-4 h-4" /> {gettext("Grant")}
              </button>
            </form>

            <p class="text-xs opacity-50">
              {gettext("Groups can't own a project — ownership stays with a person.")}
            </p>

            <div :if={@grants != []} class="divide-y divide-base-200 border-t border-base-200">
              <div :for={grant <- @grants} class="flex items-center gap-3 py-2">
                <.icon name={grant_icon(grant.subject_type)} class="w-4 h-4 opacity-60 shrink-0" />
                <div class="min-w-0 grow">
                  <div class="text-sm font-medium truncate">
                    {grant.subject_label || gettext("(deleted group)")}
                  </div>
                  <%!-- Blast radius: how many accounts this reaches TODAY,
                       plus the part people forget — that it keeps applying
                       to accounts that join the group later. --%>
                  <div class="text-xs opacity-50">
                    {grant_kind_label(grant.subject_type)} ·
                    {ngettext("%{count} person now", "%{count} people now", grant.reach,
                      count: grant.reach
                    )} · {gettext("and anyone added later")}
                  </div>
                </div>
                <span class="badge badge-ghost badge-sm shrink-0">{grant.role}</span>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs btn-circle text-error"
                  phx-click="revoke_grant"
                  phx-value-uuid={grant.uuid}
                  data-confirm={gettext("Remove this group's access?")}
                  aria-label={gettext("Remove access")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>
        </div>

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

  defp grant_icon("team"), do: "hero-user-group"
  defp grant_icon("department"), do: "hero-building-office"
  defp grant_icon(_), do: "hero-identification"

  defp grant_kind_label("team"), do: gettext("Team")
  defp grant_kind_label("department"), do: gettext("Department")
  defp grant_kind_label(_), do: gettext("Site role")

  attr(:name, :string, required: true)
  attr(:value, :string, required: true)

  defp role_select(assigns) do
    ~H"""
    <label class="select select-sm">
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
