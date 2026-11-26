defmodule PhoenixKitProjects.KimiReviewRrQ3EffectiveRolesTest do
  @moduledoc """
  Re-review probe (night 2026-11-26, Q3): `Authz.effective_roles/2` (the
  batched resolver `ApiKeys.grant_roles/2` now uses, with
  `Members.roles_of/2`) must agree with `Authz.effective_role/2` (the
  per-project resolver it replaced) for EVERY project, over direct members,
  group grants (team / department / site role), "everyone" projects with
  and without the module key, and inactive users.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Users.{Auth, RolePermission, Roles}
  alias PhoenixKitProjects.{Authz, Grants, Members, Projects}
  alias PhoenixKitProjects.Test.{Access, Repo}
  alias PhoenixKitStaff.{Departments, Staff, Teams}

  defp user do
    {:ok, u} =
      Auth.register_user(%{
        "email" => "er-#{System.unique_integer([:positive])}@example.com",
        "password" => "ErPass123!"
      })

    u
  end

  # The FIRST account registered in a database is made Owner (core's
  # `ensure_first_user_is_owner`), which holds "*" — a module key. Every
  # test here wants plain accounts, so a sacrificial user goes first.
  setup do
    _sacrificial_owner = user()
    :ok
  end

  defp staffed_user do
    u = user()
    n = System.unique_integer([:positive])
    {:ok, dept} = Departments.create(%{"name" => "ERDept-#{n}"})
    {:ok, team} = Teams.create(%{"name" => "ERTeam-#{n}", "department_uuid" => dept.uuid})

    {:ok, person} =
      Staff.create_person(%{
        "user_uuid" => u.uuid,
        "name" => "ER Person #{n}",
        "employment_type" => "full_time"
      })

    {:ok, _} = Staff.add_team_person(team.uuid, person.uuid)
    %{user: u, person: person, team: team, department: dept}
  end

  # The module key ("projects") through a site role, without admin_all.
  defp grant_module_key!(u) do
    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{"name" => "ERProjects-#{n}"})
    {:ok, _} = Roles.assign_role(u, role.name)

    Repo.insert!(%RolePermission{
      role_uuid: role.uuid,
      module_key: "projects"
    })

    u
  end

  defp assert_agreement(projects, u, label) do
    batch = Authz.effective_roles(projects, u.uuid)

    for project <- projects do
      single = Authz.effective_role(project, u.uuid)

      assert batch[project.uuid] == single,
             "#{label}: batch #{inspect(batch[project.uuid])} != single #{inspect(single)} " <>
               "on project #{project.uuid}"
    end

    # And the map answers for every project asked (no missing keys).
    assert Map.keys(batch) |> Enum.sort() == projects |> Enum.map(& &1.uuid) |> Enum.sort()
  end

  test "batch and single resolvers agree over every access path" do
    p_direct = fixture_project(%{"name" => "ER direct"})
    p_group = fixture_project(%{"name" => "ER group"})
    p_mixed = fixture_project(%{"name" => "ER mixed"})
    p_open = fixture_project(%{"name" => "ER open", "settings" => %{"visibility" => "everyone"}})
    p_none = fixture_project(%{"name" => "ER none"})

    projects =
      Enum.map([p_direct, p_group, p_mixed, p_open, p_none], &Projects.get_project!(&1.uuid))

    # 1. Direct member, two roles on two projects.
    direct = user()
    {:ok, _} = Members.add_member(p_direct, direct.uuid, role: "member")
    {:ok, _} = Members.add_member(p_mixed, direct.uuid, role: "viewer")

    # 2. Group grants only: team on one project, department on another,
    #    site role on a third.
    %{user: group} = staffed = staffed_user()
    {:ok, _} = Grants.grant(p_group, "team", staffed.team.uuid, "manager")
    {:ok, _} = Grants.grant(p_mixed, "department", staffed.department.uuid, "viewer")

    {:ok, site_role} =
      Roles.create_role(%{"name" => "ERRole-#{System.unique_integer([:positive])}"})

    {:ok, _} = Roles.assign_role(group, site_role.name)
    {:ok, _} = Grants.grant(p_direct, "role", site_role.uuid, "member")

    # 3. Direct AND group on the same project (strongest must win), plus an
    #    open project.
    %{user: mixed, team: mixed_team} = staffed_user()
    {:ok, _} = Members.add_member(p_mixed, mixed.uuid, role: "viewer")
    {:ok, _} = Grants.grant(p_mixed, "team", mixed_team.uuid, "manager")

    # 4. Module key, no rows anywhere: the open seat answers.
    module_user = user() |> grant_module_key!()

    # 5. No key, no rows: nothing, not even the open project.
    plain = user()

    # 6. Inactive direct member WITH the module key: the membership still
    #    resolves, the open seat must not.
    inactive = user() |> grant_module_key!()
    {:ok, _} = Members.add_member(p_direct, inactive.uuid, role: "manager")
    {:ok, _} = Auth.update_user_status(inactive, %{"is_active" => false})
    inactive = Auth.get_user(inactive.uuid)

    # 7. Module key AND a group grant on the open project (group beats the
    #    open seat's viewer).
    %{user: open_group, team: open_team} = staffed_user()
    grant_module_key!(open_group)
    {:ok, _} = Grants.grant(p_open, "team", open_team.uuid, "manager")

    for {u, label} <- [
          {direct, "direct"},
          {group, "group"},
          {mixed, "mixed"},
          {module_user, "module_user"},
          {plain, "plain"},
          {inactive, "inactive"},
          {open_group, "open_group"}
        ] do
      assert_agreement(projects, u, label)
    end

    # Spot-check the expectations themselves, so the agreement above is
    # about the RIGHT answers and not two shared bugs.
    assert Authz.effective_role(p_direct, direct.uuid) == :member
    assert Authz.effective_role(p_mixed, direct.uuid) == :viewer
    assert Authz.effective_role(p_group, group.uuid) == :manager
    assert Authz.effective_role(p_mixed, group.uuid) == :viewer
    assert Authz.effective_role(p_direct, group.uuid) == :member
    assert Authz.effective_role(p_mixed, mixed.uuid) == :manager
    assert Authz.effective_role(p_open, module_user.uuid) == :viewer
    assert Authz.effective_role(p_direct, module_user.uuid) == nil
    assert Authz.effective_role(p_open, plain.uuid) == nil
    assert Authz.effective_role(p_direct, inactive.uuid) == :manager
    assert Authz.effective_role(p_open, inactive.uuid) == nil
    assert Authz.effective_role(p_open, open_group.uuid) == :manager
  end

  test "an everyone project answers nil for a module-less user in both forms" do
    open = fixture_project(%{"settings" => %{"visibility" => "everyone"}})
    project = Projects.get_project!(open.uuid)
    u = user()

    assert Authz.effective_roles([project], u.uuid) == %{project.uuid => nil}
    assert Authz.effective_role(project, u.uuid) == nil

    Access.grant_projects!(u)

    assert Authz.effective_roles([project], u.uuid) == %{project.uuid => :viewer}
    assert Authz.effective_role(project, u.uuid) == :viewer
  end

  test "an empty project list and a non-binary user are safe" do
    assert Authz.effective_roles([], Ecto.UUID.generate()) == %{}
    assert Authz.effective_roles([], nil) == %{}

    project = fixture_project()
    assert Authz.effective_roles([project], nil) == %{project.uuid => nil}
    assert Authz.effective_role(project, nil) == nil
  end
end
