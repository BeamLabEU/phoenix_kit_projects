defmodule PhoenixKitProjects.Authz do
  @moduledoc """
  The hub's authorization vocabulary and single resolver.

  Defined BEFORE enforcement threading (2026-08-05 panel amendment #3) so
  every call site binds to one stable signature whose internals deepen as
  later layers land — call sites are never rewritten.

  ## The intersection

  A project action is allowed iff every applicable term passes:

      site permission ∧ project role ∧ relationship grant ∧ extension enabled ∧ feature flag

  `can?/5` resolves the first three terms; extension/flag gating composes at
  the call site via `PhoenixKitProjects.Extensions.enabled?/3` and (Step 3)
  `Features.on?/2` — they answer "is this capability present on this
  project", which is orthogonal to "may this caller use it".

  ## Resolution stages (implementation honesty)

    * **Tonight (v1)**: site-permission based — the resolver mirrors the
      status quo: a scope with admin access to the `projects` module may do
      everything; anyone else nothing. Fail-closed on nil/malformed input.
    * **Step 5 (members)**: role + relationship terms — owner/manager/
      member/viewer from the members table, relationship grants (assignee
      may `:update_status` on their own assignment, etc.), "who can X"
      per-project settings. The v1 admin path remains as the
      `projects.view_all`-style admin override.

  ## Vocabulary (frozen)

  Roles: `:owner > :manager > :member > :viewer` (`roles/0`, ordered).

  Actions (`actions/0`): `:view`, `:create_tasks`, `:edit_tasks`,
  `:delete_tasks`, `:assign_tasks`, `:update_status`, `:log_time`,
  `:comment`, `:upload_files`, `:manage_members`, `:manage_modules`,
  `:edit_settings`, `:set_health`, `:archive_project`, `:delete_project`.
  Extensions may declare additional action keys via `permission_actions`;
  unknown actions resolve fail-closed for non-admin callers.

  ## Context

  `opts[:context]` is `:admin` (default) or `:public` — the future
  public-portal surface resolves under `:public`, where the admin override
  does NOT apply (a site admin browsing the public portal is a visitor).
  Threaded now so portal work is additive, not a refactor.
  """

  alias PhoenixKit.Users.Auth.Scope

  @roles [:owner, :manager, :member, :viewer]

  @actions [
    :view,
    :create_tasks,
    :edit_tasks,
    :delete_tasks,
    :assign_tasks,
    :update_status,
    :log_time,
    :comment,
    :upload_files,
    :manage_members,
    :manage_modules,
    :edit_settings,
    :set_health,
    :archive_project,
    :delete_project
  ]

  @doc "Project roles, strongest first."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc "The frozen action vocabulary."
  @spec actions() :: [atom()]
  def actions, do: @actions

  @doc """
  May `subject` perform `action` on `project` (optionally about `record`)?

  `subject` is a `%Scope{}` (admin surfaces) — later stages also accept a
  bare user for member-facing surfaces. `record` carries the relationship
  term's object (an assignment for `:update_status`, a member row for
  `:manage_members` edge cases); pass nil when the action has no object.

  Fail-closed: nil subject, unknown project, or an unrecognized action for
  a non-admin subject all resolve false.
  """
  @spec can?(term(), map() | binary() | nil, atom(), map() | nil, keyword()) :: boolean()
  def can?(subject, project, action, record \\ nil, opts \\ [])

  def can?(nil, _project, _action, _record, _opts), do: false

  def can?(subject, project, action, record, opts) when is_atom(action) do
    context = Keyword.get(opts, :context, :admin)

    case context do
      :admin ->
        not is_nil(project) and
          (admin_override?(subject) or member_can?(subject, project, action, record))

      # The portal (future) never honors the admin override; until its
      # membership/visibility terms land, public resolution is a hard no.
      :public ->
        false

      # Any unrecognized context is a hard no — fail-closed means FALSE,
      # never a CaseClauseError crashing the caller (panel R2-3).
      _other ->
        false
    end
  end

  def can?(_subject, _project, _action, _record, _opts), do: false

  # The site-admin path — core's ensure_admin on_mount already required the
  # "projects" module permission to reach any admin page; the resolver
  # re-derives it so off-router (embedded) callers get the same answer.
  # Admin-area users see and manage everything (the transitional state until
  # a member-facing surface exists; a future `projects.view_all`-style
  # sub-permission can narrow this).
  defp admin_override?(%Scope{} = scope) do
    Scope.has_module_access?(scope, "projects")
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp admin_override?(_), do: false

  # ── Member resolution (Step 5) ──────────────────────────────────────
  #
  # role floor ∨ relationship grant, with the project's "who can X"
  # settings overrides. Fail-closed at every unknown.

  # Minimum role per action — the boss's default matrix (2026-08-05).
  # An action absent here resolves ONLY via admin override (fail-closed
  # for members) — extensions' custom permission_actions land as :member
  # floor when they declare them (future refinement).
  @role_floors %{
    view: :viewer,
    create_tasks: :member,
    edit_tasks: :manager,
    delete_tasks: :manager,
    assign_tasks: :manager,
    update_status: :manager,
    log_time: :manager,
    comment: :member,
    upload_files: :member,
    manage_members: :owner,
    manage_modules: :owner,
    edit_settings: :owner,
    set_health: :manager,
    archive_project: :owner,
    delete_project: :owner
  }

  # Per-project overridable floors — the "who can X" dropdowns
  # (settings["authz"]): a couple of high-traffic actions where teams
  # legitimately differ, NOT a Jira scheme editor.
  @overridable %{
    assign_tasks: {"assign_tasks", %{"managers" => :manager, "members" => :member}},
    create_tasks: {"create_tasks", %{"managers" => :manager, "members" => :member}},
    update_status: {"update_status", %{"managers" => :manager, "members" => :member}}
  }

  @role_rank %{owner: 0, manager: 1, member: 2, viewer: 3}

  defp member_can?(subject, project, action, record) do
    case subject_user_uuid(subject) do
      nil ->
        false

      user_uuid ->
        case PhoenixKitProjects.Members.role_of(project, user_uuid) do
          nil ->
            false

          role ->
            meets_floor?(role, floor_for(project, action)) or
              relationship_grant?(user_uuid, action, record)
        end
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp floor_for(project, action) do
    default = Map.get(@role_floors, action)

    case Map.get(@overridable, action) do
      nil ->
        default

      {settings_key, choices} ->
        override =
          project
          |> project_settings()
          |> Map.get("authz", %{})
          |> Map.get(settings_key)

        Map.get(choices, override, default)
    end
  end

  defp meets_floor?(_role, nil), do: false

  defp meets_floor?(role, floor) do
    Map.fetch!(@role_rank, role) <= Map.fetch!(@role_rank, floor)
  end

  # Relationship grants: the ASSIGNEE of a task may move its status and log
  # time on it, whatever their project role (Jira's "Current assignee"
  # precedent). The record is the assignment; the staff person resolves to
  # a core user via `person.user_uuid` (nil-safe at every hop).
  defp relationship_grant?(user_uuid, action, record)
       when action in [:update_status, :log_time] do
    assignee_user_uuid(record) == user_uuid
  end

  defp relationship_grant?(_user_uuid, _action, _record), do: false

  defp assignee_user_uuid(%{assigned_person: %{user_uuid: user_uuid}})
       when is_binary(user_uuid),
       do: user_uuid

  defp assignee_user_uuid(_), do: nil

  defp subject_user_uuid(%Scope{user: %{uuid: uuid}}) when is_binary(uuid), do: uuid
  defp subject_user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp subject_user_uuid(uuid) when is_binary(uuid), do: uuid
  defp subject_user_uuid(_), do: nil

  defp project_settings(%{settings: settings}) when is_map(settings), do: settings
  defp project_settings(_), do: %{}

  @doc """
  The overridable "who can X" catalog for the settings UI:
  `[{action, settings_key, [{label_choice, value}]}]`-shaped data.
  """
  @spec overridable_actions() :: [map()]
  def overridable_actions do
    Enum.map(@overridable, fn {action, {key, choices}} ->
      %{action: action, settings_key: key, choices: Map.keys(choices) |> Enum.sort()}
    end)
  end
end
