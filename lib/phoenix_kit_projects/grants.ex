defmodule PhoenixKitProjects.Grants do
  @moduledoc """
  Indirect project access — a project role held by a staff team, a staff
  department, or a site role instead of by one named person.

  This is the other half of `PhoenixKitProjects.Members`. Members answers
  "who is on this project"; Grants answers "which GROUPS may work here",
  so that inviting the Design team, or letting every contractor look, is
  one row rather than a person-by-person chore that drifts the moment
  somebody changes team.

  ## Resolution (the 2026-08-07 four-AI quorum's rules)

  A person's effective project role is the **strongest** role among every
  grant that matches them — their own membership row, their teams', their
  departments', and their site role's. Grants are purely additive:

      effective_role = max(member_row, team_grants, department_grants, role_grants)

  A more specific subject deliberately does NOT win when it grants less.
  Making specificity win turns *adding* a grant into a revocation: someone
  holds manager through their team, an admin adds them explicitly as a
  viewer to "make sure they have access", and silently strips their rights.
  To reduce access, remove the broad grant — never encode demotion as
  precedence.

  ## Subjects are resolved defensively

  `subject_uuid` has no foreign key: it points into staff teams, staff
  departments, or core roles, and staff is an OPTIONAL dependency that may
  not be installed. Every lookup here degrades to "matches nothing" rather
  than raising, so a half-installed site fails closed instead of crashing
  the resolver.

  Ownership is not grantable to a group — see the schema.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKitProjects.Activity
  # SHADOW schemas over the core-owned staff tables (core V100), NOT
  # `PhoenixKitStaff.Schemas.*`. Those tables exist on every install; the
  # staff PACKAGE is only the admin surface and is optional. Reaching for
  # the package's schemas meant every query here raised into its own
  # `rescue` wherever staff wasn't installed — so team and department
  # grants silently granted nothing, on data that was sitting right there.
  # A grant that quietly evaporates is worse than one that errors.
  alias PhoenixKitProjects.People
  alias PhoenixKitProjects.People.Team
  alias PhoenixKitProjects.People.TeamMembership
  alias PhoenixKitProjects.PubSub
  alias PhoenixKitProjects.Schemas.ProjectSubjectGrant

  @role_rank %{"owner" => 0, "manager" => 1, "member" => 2, "viewer" => 3}

  @doc "Every grant on a project, strongest role first."
  @spec list_grants(binary()) :: [ProjectSubjectGrant.t()]
  def list_grants(project_uuid) when is_binary(project_uuid) do
    RepoHelper.repo().all(from(g in ProjectSubjectGrant, where: g.project_uuid == ^project_uuid))
    |> Enum.sort_by(&{Map.get(@role_rank, &1.role, 9), &1.subject_type})
  rescue
    e ->
      Logger.warning("[Projects.Grants] list_grants failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Grants `role` on `project` to a subject, or updates the role if the
  subject already has a grant.
  """
  @spec grant(map() | binary(), String.t(), binary(), String.t(), keyword()) ::
          {:ok, ProjectSubjectGrant.t()} | {:error, term()}
  def grant(project, subject_type, subject_uuid, role, opts \\ []) do
    project_uuid = project_uuid(project)
    actor_uuid = Keyword.get(opts, :actor_uuid)

    attrs = %{
      project_uuid: project_uuid,
      subject_type: subject_type,
      subject_uuid: subject_uuid,
      role: role,
      granted_by_uuid: actor_uuid
    }

    existing =
      RepoHelper.repo().one(
        from(g in ProjectSubjectGrant,
          where:
            g.project_uuid == ^project_uuid and g.subject_type == ^subject_type and
              g.subject_uuid == ^subject_uuid
        )
      )

    result =
      case existing do
        nil ->
          %ProjectSubjectGrant{}
          |> ProjectSubjectGrant.changeset(attrs)
          |> RepoHelper.repo().insert()

        row ->
          row |> ProjectSubjectGrant.changeset(attrs) |> RepoHelper.repo().update()
      end

    with {:ok, grant} <- result do
      log("projects.grant_added", project_uuid, grant, actor_uuid)
      PubSub.broadcast_project(:project_grants_changed, %{uuid: project_uuid})
      {:ok, grant}
    end
  end

  @doc "Removes a grant."
  @spec revoke(binary(), keyword()) :: {:ok, ProjectSubjectGrant.t()} | {:error, term()}
  def revoke(grant_uuid, opts \\ []) when is_binary(grant_uuid) do
    actor_uuid = Keyword.get(opts, :actor_uuid)

    case RepoHelper.repo().get(ProjectSubjectGrant, grant_uuid) do
      nil ->
        {:error, :not_found}

      grant ->
        with {:ok, deleted} <- RepoHelper.repo().delete(grant) do
          log("projects.grant_removed", grant.project_uuid, deleted, actor_uuid)
          PubSub.broadcast_project(:project_grants_changed, %{uuid: grant.project_uuid})
          {:ok, deleted}
        end
    end
  end

  @doc """
  The strongest role a user holds on a project through GROUP grants alone
  (their direct membership is `Members.role_of/2`'s business), or nil.

  Returns a string role so it composes with the members table's values.
  """
  @spec group_role_of(map() | binary(), binary()) :: String.t() | nil
  def group_role_of(project, user_uuid) when is_binary(user_uuid) do
    subjects = subjects_for_user(user_uuid)

    if subjects == [] do
      nil
    else
      project_uuid = project_uuid(project)
      pairs = Enum.map(subjects, fn {type, uuid} -> dynamic_pair(type, uuid) end)

      RepoHelper.repo().all(
        from(g in ProjectSubjectGrant,
          where: g.project_uuid == ^project_uuid,
          select: {g.subject_type, g.subject_uuid, g.role}
        )
      )
      |> Enum.filter(fn {type, uuid, _role} -> {type, uuid} in pairs end)
      |> Enum.map(&elem(&1, 2))
      |> strongest()
    end
  rescue
    e ->
      Logger.warning("[Projects.Grants] group_role_of failed: #{Exception.message(e)}")
      nil
  end

  def group_role_of(_project, _user_uuid), do: nil

  @doc """
  Every project uuid a user can reach through GROUP grants alone, with the
  strongest role each grant gives them.

  Kept as ONE query over the user's resolved subjects rather than a
  per-project check, so a list view can scope in SQL instead of loading
  everything and filtering in memory — the N+1 the quorum flagged as the
  main tax of indirect grants.
  """
  @spec project_roles_for_user(binary()) :: %{binary() => String.t()}
  def project_roles_for_user(user_uuid) when is_binary(user_uuid) do
    case subjects_for_user(user_uuid) do
      [] ->
        %{}

      subjects ->
        types = subjects |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        uuids = Enum.map(subjects, &elem(&1, 1))

        RepoHelper.repo().all(
          from(g in ProjectSubjectGrant,
            where: g.subject_type in ^types and g.subject_uuid in ^uuids,
            select: {g.subject_type, g.subject_uuid, g.project_uuid, g.role}
          )
        )
        # The WHERE is a cross-product of types and uuids (SQL can't express
        # the pairs cheaply), so re-filter to the ACTUAL pairs before use —
        # otherwise a team uuid colliding with a department grant would
        # leak. Collisions are vanishingly unlikely with UUIDs, but "leaks
        # only on a collision" is not a property worth shipping.
        |> Enum.filter(fn {type, uuid, _p, _r} -> {type, uuid} in subjects end)
        |> Enum.reduce(%{}, fn {_t, _u, project_uuid, role}, acc ->
          Map.update(acc, project_uuid, role, &stronger_role(role, &1))
        end)
    end
  rescue
    e ->
      Logger.warning("[Projects.Grants] project_roles_for_user failed: #{Exception.message(e)}")
      %{}
  end

  def project_roles_for_user(_), do: %{}

  @doc """
  How many user accounts a grant would currently reach — the blast radius
  of "everyone with role X can see this". Counts CURRENT accounts; future
  ones matching the same subject gain access too, which the UI must say.
  """
  @spec subject_reach(String.t(), binary()) :: non_neg_integer()
  def subject_reach("role", role_uuid) when is_binary(role_uuid) do
    case Roles.get_role_by_uuid(role_uuid) do
      %{name: name} -> length(Roles.users_with_role(name))
      _ -> 0
    end
  rescue
    _ -> 0
  end

  def subject_reach("team", team_uuid) when is_binary(team_uuid) do
    RepoHelper.repo().aggregate(
      from(tm in TeamMembership, where: tm.team_uuid == ^team_uuid),
      :count
    )
  rescue
    _ -> 0
  end

  def subject_reach("department", dept_uuid) when is_binary(dept_uuid) do
    team_uuids =
      RepoHelper.repo().all(
        from(t in Team,
          where: t.department_uuid == ^dept_uuid,
          select: t.uuid
        )
      )

    if team_uuids == [] do
      0
    else
      RepoHelper.repo().aggregate(
        from(tm in TeamMembership, where: tm.team_uuid in ^team_uuids),
        :count
      )
    end
  rescue
    _ -> 0
  end

  def subject_reach(_type, _uuid), do: 0

  @doc """
  Why does this person have access? Returns every matching grant as
  `{subject_type, subject_uuid, role}`, so a UI can explain that removing
  someone's direct membership will not revoke their team's access.
  """
  @spec provenance(map() | binary(), binary()) :: [{String.t(), binary(), String.t()}]
  def provenance(project, user_uuid) when is_binary(user_uuid) do
    subjects = subjects_for_user(user_uuid)
    project_uuid = project_uuid(project)

    RepoHelper.repo().all(
      from(g in ProjectSubjectGrant,
        where: g.project_uuid == ^project_uuid,
        select: {g.subject_type, g.subject_uuid, g.role}
      )
    )
    |> Enum.filter(fn {type, uuid, _} -> {type, uuid} in subjects end)
  rescue
    _ -> []
  end

  def provenance(_project, _user_uuid), do: []

  @doc """
  The `{subject_type, subject_uuid}` pairs a user matches: their site
  roles, their staff teams, and the departments those teams belong to
  (plus their primary department).

  Every hop is optional — no staff person, no staff package, or an
  unreadable table all resolve to fewer pairs rather than an exception.
  """
  @spec subjects_for_user(binary()) :: [{String.t(), binary()}]
  def subjects_for_user(user_uuid) when is_binary(user_uuid) do
    role_subjects(user_uuid) ++ staff_subjects(user_uuid)
  rescue
    _ -> []
  end

  def subjects_for_user(_), do: []

  # ── Subject resolution ──────────────────────────────────────────────

  defp role_subjects(user_uuid) do
    case Auth.get_user(user_uuid) do
      nil ->
        []

      user ->
        user
        |> Roles.get_user_roles()
        |> Enum.map(&role_uuid_for_name/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&{"role", &1})
    end
  rescue
    _ -> []
  end

  defp role_uuid_for_name(name) when is_binary(name) do
    case Roles.get_role_by_name(name) do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp role_uuid_for_name(_), do: nil

  defp staff_subjects(user_uuid) do
    # The ONE doorway (`People`), not the optional package: the person row
    # is core-owned data, and gating on `Code.ensure_loaded?(PhoenixKitStaff)`
    # made "the admin UI for people isn't installed" mean "this person is on
    # no team" — which silently revoked every team and department grant.
    case People.get_person_by_user_uuid(user_uuid, preload: []) do
      nil ->
        []

      person ->
        teams = team_uuids(person.uuid)
        departments = department_uuids(person, teams)

        Enum.map(teams, &{"team", &1}) ++ Enum.map(departments, &{"department", &1})
    end
  rescue
    _ -> []
  end

  defp team_uuids(person_uuid) do
    RepoHelper.repo().all(
      from(tm in TeamMembership,
        where: tm.staff_person_uuid == ^person_uuid,
        select: tm.team_uuid
      )
    )
  rescue
    _ -> []
  end

  # A department grant reaches its people both ways: someone whose primary
  # department it is, and anyone on a team that belongs to it.
  defp department_uuids(person, team_uuids) do
    from_teams =
      if team_uuids == [] do
        []
      else
        RepoHelper.repo().all(
          from(t in Team,
            where: t.uuid in ^team_uuids and not is_nil(t.department_uuid),
            select: t.department_uuid
          )
        )
      end

    [Map.get(person, :primary_department_uuid) | from_teams]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp dynamic_pair(type, uuid), do: {type, uuid}

  defp stronger_role(a, b) do
    if Map.get(@role_rank, a, 9) < Map.get(@role_rank, b, 9), do: a, else: b
  end

  defp strongest([]), do: nil

  defp strongest(roles) do
    Enum.min_by(roles, &Map.get(@role_rank, &1, 9))
  end

  defp project_uuid(%{uuid: uuid}), do: uuid
  defp project_uuid(uuid) when is_binary(uuid), do: uuid
  defp project_uuid(_), do: nil

  defp log(action, project_uuid, grant, actor_uuid) do
    Activity.log(action,
      actor_uuid: actor_uuid,
      resource_type: "project",
      resource_uuid: project_uuid,
      metadata: %{
        "subject_type" => grant.subject_type,
        "subject_uuid" => grant.subject_uuid,
        "role" => grant.role
      }
    )
  rescue
    _ -> :ok
  end
end
