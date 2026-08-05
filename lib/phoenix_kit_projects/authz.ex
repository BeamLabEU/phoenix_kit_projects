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

  def can?(subject, project, action, _record, opts) when is_atom(action) do
    context = Keyword.get(opts, :context, :admin)

    case context do
      :admin -> admin_override?(subject) and not is_nil(project)
      # The portal (future) never honors the admin override; until its
      # membership/visibility terms land, public resolution is a hard no.
      :public -> false
    end
  end

  def can?(_subject, _project, _action, _record, _opts), do: false

  # v1: the status-quo gate — core's ensure_admin on_mount already required
  # the "projects" module permission to reach any admin page; the resolver
  # re-derives it so off-router (embedded) callers get the same answer.
  defp admin_override?(%Scope{} = scope) do
    Scope.has_module_access?(scope, "projects")
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp admin_override?(_), do: false
end
