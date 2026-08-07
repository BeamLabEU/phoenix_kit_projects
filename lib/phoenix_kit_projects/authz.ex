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

    * **v1**: site-permission based — module access meant "do everything".
    * **Members**: role + relationship terms — owner/manager/member/viewer
      from the members table, relationship grants (an assignee may
      `:update_status` on their own assignment), and the per-project
      "who can X" floors in `settings["authz"]`.
    * **The split (2026-08-07)**: the admin path is no longer bare module
      access. `projects` means "may enter the module"; the
      `projects.admin_all` SUB-permission means "administer projects you
      are not a member of". Before this, granting a role the module so its
      people could see their own projects handed them every project on the
      site — the resolver short-circuited on module access before
      membership was consulted.

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

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.Schemas.Project

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

  @admin_all_key "projects.admin_all"

  @visibilities ~w(private everyone)

  @doc """
  Project visibility — who can see it AT ALL, before any role question:

    * `"private"` (default) — the people and groups on the project, plus
      site admins.
    * `"everyone"` — anyone who can reach the Projects module. They come
      in as a VIEWER, so the same "who can do what" floors apply; being
      able to see a project is not being able to change it.

  Stored on the project (`settings["visibility"]`) and resolved by
  `effective_role/2`, so every surface that asks the resolver — the index,
  the counters, the page gates — honors it without its own special case.
  """
  @spec visibilities() :: [String.t()]
  def visibilities, do: @visibilities

  @spec visibility_of(map()) :: String.t()
  def visibility_of(project) do
    case project |> project_settings() |> Map.get("visibility") do
      v when v in @visibilities -> v
      _ -> "private"
    end
  end

  @doc "The sub-permission that grants power over projects you don't belong to."
  @spec admin_all_key() :: String.t()
  def admin_all_key, do: @admin_all_key

  # The site-admin path. This used to be bare module access, which made the
  # "projects" permission mean "do everything on every project" — checked
  # BEFORE membership, so a role granted the module purely to let its people
  # SEE their own projects silently got full power over all of them. It now
  # keys on the `projects.admin_all` sub-permission: the base key means "may
  # enter the module", this one means "administer projects you are not a
  # member of". Owner rides core's "*" wildcard, Admin is auto-granted the
  # sub-key at boot, and `PhoenixKitProjects.migrate_legacy/0` carries every
  # other role that already held the base key — so the split changes nobody's
  # access on an existing install, only what a NEW grant of "projects" means.
  # Deliberately NOT `Scope.can?/2`: that also requires the module to be
  # feature-ENABLED, which routes a settings read (DB-backed, ETS-cached)
  # into an authorization decision — a cache miss or DB blip rescues to
  # false and silently drops every admin mid-session. Module enablement is
  # already enforced where it belongs, at the tab/route layer. What is kept
  # from `can?/2` is the base-held rule: a dotted key is only effective
  # while its base is held, so an orphan row can't outlive a revoked grant.
  defp admin_override?(%Scope{} = scope) do
    Scope.has_module_access?(scope, @admin_all_key) and
      Scope.has_module_access?(scope, "projects")
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp admin_override?(_), do: false

  @doc """
  Does this subject hold `projects.admin_all` — the site-wide "administer
  projects you are not a member of" grant? Exposed so listing queries can
  skip narrowing for admins instead of re-deriving the rule.
  """
  @spec admin_all?(term()) :: boolean()
  def admin_all?(subject), do: admin_override?(subject)

  @doc "The user uuid behind a scope, a user struct, or a bare uuid."
  @spec subject_user_uuid_of(term()) :: binary() | nil
  def subject_user_uuid_of(subject), do: subject_user_uuid(subject)

  # ── Member resolution (Step 5) ──────────────────────────────────────
  #
  # role floor ∨ relationship grant, with the project's "who can X"
  # settings overrides. Fail-closed at every unknown.

  # Minimum role per action — the boss's default matrix (2026-08-05).
  # An action absent here resolves ONLY via admin override (fail-closed
  # for members) — extensions' custom permission_actions land as :member
  # floor when they declare them (future refinement).
  # Minimum role per action. The default is DELIBERATELY OPEN: once someone
  # is on a project — as a member or through a team, department, or site
  # role — they can do the work, and a project tightens what it cares about
  # in its own "who can do what" panel. A permission model nobody asked for
  # is friction, not safety.
  #
  # The exceptions are the actions that don't change work but change the
  # CONTAINER — settings, membership, modules, archiving, deletion. Those
  # stay with owners: "no restrictions on the work" is not the same as
  # "any viewer may delete the project", and there is no undo for the last
  # one. They are not overridable either.
  @role_floors %{
    view: :viewer,
    create_tasks: :viewer,
    edit_tasks: :viewer,
    delete_tasks: :viewer,
    assign_tasks: :viewer,
    update_status: :viewer,
    log_time: :viewer,
    comment: :viewer,
    upload_files: :viewer,
    set_health: :viewer,
    manage_members: :owner,
    manage_modules: :owner,
    edit_settings: :owner,
    archive_project: :owner,
    delete_project: :owner
  }

  # Per-project overridable floors — the "who can do what" rows. Every
  # WORK action is tunable now that the defaults are open: the panel's job
  # is to let a project restrict, so it has to cover the things a project
  # would want to restrict. The container-level actions above are not here
  # on purpose.
  @choices %{"anyone" => :viewer, "members" => :member, "managers" => :manager}

  @overridable Map.new(
                 ~w(create_tasks edit_tasks delete_tasks assign_tasks update_status
                    log_time comment upload_files set_health)a,
                 fn action -> {action, {Atom.to_string(action), @choices}} end
               )

  @role_rank %{owner: 0, manager: 1, member: 2, viewer: 3}

  defp member_can?(subject, project, action, record) do
    case subject_user_uuid(subject) do
      nil ->
        false

      user_uuid ->
        case effective_role(project, user_uuid) do
          nil ->
            # No role at all — but an assignee may still act on their OWN
            # task. Checked here rather than skipped so a task handed to
            # someone outside the project still works, as it always has.
            relationship_grant?(user_uuid, action, record)

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

  @doc """
  The role a user effectively holds on a project: the STRONGEST of their
  direct membership and every group grant that matches them (their teams,
  their departments, their site roles). Always an ATOM from `roles/0`, or
  nil when nothing matches.

  Additive by design — a group grant can raise someone's role, but a
  direct row never silently lowers what a group already gave them.
  Specificity-wins would make ADDING a grant a revocation. See
  `PhoenixKitProjects.Grants`.
  """
  @spec effective_role(map() | binary(), binary()) :: atom() | nil
  def effective_role(project, user_uuid) when is_binary(user_uuid) do
    direct = PhoenixKitProjects.Members.role_of(project, user_uuid)
    group = PhoenixKitProjects.Grants.group_role_of(project, user_uuid)

    # An "everyone" project hands every module-reacher a viewer seat. It is
    # the weakest possible role, so it can only ever ADD access — someone
    # who is also a manager through their team stays a manager.
    open = if visibility_of(project) == "everyone", do: :viewer

    # The two sources disagree on representation — memberships resolve to
    # atoms, grant rows are strings straight off the column — and
    # meets_floor?/2 ranks atoms, so normalize before comparing rather
    # than letting a string reach Map.fetch!/2.
    [direct, group, open]
    |> Enum.map(&to_role_atom/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      roles -> Enum.min_by(roles, &Map.fetch!(@role_rank, &1))
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def effective_role(_project, _user_uuid), do: nil

  defp to_role_atom(role) when is_atom(role) do
    if role in @roles, do: role
  end

  defp to_role_atom(role) when is_binary(role) do
    Enum.find(@roles, fn r -> Atom.to_string(r) == role end)
  end

  defp to_role_atom(_), do: nil

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
      %{
        action: action,
        settings_key: key,
        choices: Map.keys(choices) |> Enum.sort(),
        default: default_choice(action, choices)
      }
    end)
  end

  # Which choice string the action's DEFAULT floor corresponds to, so a UI
  # can show the inherited answer instead of inventing one — and so callers
  # can skip writing an override that changes nothing.
  defp default_choice(action, choices) do
    floor = Map.get(@role_floors, action)

    Enum.find_value(choices, fn {choice, role} -> if role == floor, do: choice end)
  end

  @doc """
  The choice a project currently resolves to for each overridable action —
  its stored override, or the default floor's choice when unset.
  """
  @spec current_overrides(map()) :: %{String.t() => String.t()}
  def current_overrides(project) do
    stored = project |> project_settings() |> Map.get("authz", %{})

    Map.new(overridable_actions(), fn %{settings_key: key, default: default} ->
      {key, Map.get(stored, key, default)}
    end)
  end

  @doc """
  Writes the per-project "who can X" floors (`settings["authz"]`).

  Only known action keys with known choice values are accepted; anything
  else is dropped rather than stored, and an unknown value would in any
  case resolve back to the default floor in `floor_for/2`.

  Like `Features.set_flags/3` this is an ATOMIC targeted merge, not a
  read-merge-write of the whole `settings` map: the column is shared with
  the features key, and writing a map built from a possibly-stale struct
  silently clobbers concurrent writes to its siblings.
  """
  @spec set_overrides(Project.t(), map(), keyword()) :: {:ok, Project.t()} | {:error, :not_found}
  def set_overrides(%Project{} = project, overrides, opts \\ []) when is_map(overrides) do
    valid = Map.new(@overridable, fn {_action, {key, choices}} -> {key, choices} end)

    accepted =
      overrides
      |> Enum.filter(fn {k, v} ->
        is_binary(k) and is_binary(v) and Map.has_key?(valid, k) and
          Map.has_key?(Map.fetch!(valid, k), v)
      end)
      |> Map.new()

    if accepted == %{} do
      {:ok, project}
    else
      query =
        from(p in Project,
          where: p.uuid == ^project.uuid,
          update: [
            set: [
              settings:
                fragment(
                  """
                  jsonb_set(
                    COALESCE(settings, '{}'::jsonb),
                    '{authz}',
                    COALESCE(settings->'authz', '{}'::jsonb) || ?::jsonb
                  )
                  """,
                  ^accepted
                ),
              updated_at: fragment("NOW()")
            ]
          ],
          select: p
        )

      {1, [updated]} = RepoHelper.repo().update_all(query, [])

      Activity.log("projects.permissions_changed",
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: "project",
        resource_uuid: project.uuid,
        metadata: %{"changed" => accepted}
      )

      {:ok, updated}
    end
  rescue
    e in [MatchError, Postgrex.Error] ->
      Logger.warning("[Projects.Authz] set_overrides failed: #{Exception.message(e)}")
      {:error, :not_found}
  end
end
