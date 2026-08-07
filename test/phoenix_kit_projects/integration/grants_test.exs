defmodule PhoenixKitProjects.Integration.GrantsTest do
  @moduledoc """
  Indirect access grants — a project role held by a team, a department, or
  a site role — and the additive resolution rule the 2026-08-07 four-AI
  quorum settled on.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Users.{Auth, Roles}
  alias PhoenixKitProjects.{Authz, Grants, Members, Projects}
  alias PhoenixKitStaff.{Departments, Staff, Teams}

  setup do
    project = fixture_project(%{"name" => "Grants-#{System.unique_integer([:positive])}"})
    %{project: project}
  end

  defp user do
    {:ok, u} =
      Auth.register_user(%{
        "email" => "grant-#{System.unique_integer([:positive])}@example.com",
        "password" => "GrantPass123!"
      })

    u
  end

  # A user wired into the staff org chart: person → team → department.
  defp staffed_user do
    u = user()
    n = System.unique_integer([:positive])
    {:ok, dept} = Departments.create(%{"name" => "GDept-#{n}"})
    {:ok, team} = Teams.create(%{"name" => "GTeam-#{n}", "department_uuid" => dept.uuid})

    {:ok, person} =
      Staff.create_person(%{
        "user_uuid" => u.uuid,
        "name" => "Granted Person #{n}",
        "employment_type" => "full_time"
      })

    {:ok, _} = Staff.add_team_person(team.uuid, person.uuid)
    %{user: u, person: person, team: team, department: dept}
  end

  describe "team grants" do
    test "a team grant gives every member of that team the role", %{project: project} do
      %{user: u, team: team} = staffed_user()

      refute Authz.effective_role(project, u.uuid)
      refute Authz.can?(u.uuid, project, :view)

      {:ok, _} = Grants.grant(project, "team", team.uuid, "member", actor_uuid: nil)

      assert Authz.effective_role(project, u.uuid) == :member
      assert Authz.can?(u.uuid, project, :view)
      assert Authz.can?(u.uuid, project, :create_tasks)
      # ...but a member floor still stops manager-level work.
      refute Authz.can?(u.uuid, project, :delete_tasks)
    end

    test "revoking the grant removes the access", %{project: project} do
      %{user: u, team: team} = staffed_user()
      {:ok, grant} = Grants.grant(project, "team", team.uuid, "member")
      assert Authz.can?(u.uuid, project, :view)

      {:ok, _} = Grants.revoke(grant.uuid)
      refute Authz.effective_role(project, u.uuid)
      refute Authz.can?(u.uuid, project, :view)
    end

    test "someone outside the team is unaffected", %{project: project} do
      %{team: team} = staffed_user()
      outsider = user()

      {:ok, _} = Grants.grant(project, "team", team.uuid, "manager")
      refute Authz.can?(outsider.uuid, project, :view)
    end
  end

  describe "department grants" do
    test "reach people through the teams that belong to the department", %{project: project} do
      %{user: u, department: dept} = staffed_user()

      {:ok, _} = Grants.grant(project, "department", dept.uuid, "viewer")

      assert Authz.effective_role(project, u.uuid) == :viewer
      assert Authz.can?(u.uuid, project, :view)
      refute Authz.can?(u.uuid, project, :create_tasks)
    end
  end

  describe "site-role grants (the contractor case)" do
    test "a role grant lets everyone holding that role view, and nothing more",
         %{project: project} do
      u = user()
      {:ok, role} = Roles.create_role(%{name: "Contractor-#{System.unique_integer([:positive])}"})
      {:ok, _} = Roles.assign_role(u, role.name)

      refute Authz.can?(u.uuid, project, :view)

      {:ok, _} = Grants.grant(project, "role", role.uuid, "viewer")

      assert Authz.effective_role(project, u.uuid) == :viewer
      assert Authz.can?(u.uuid, project, :view)
      refute Authz.can?(u.uuid, project, :create_tasks)
      refute Authz.can?(u.uuid, project, :edit_tasks)
      refute Authz.can?(u.uuid, project, :manage_members)
    end

    test "one project can be an exception without touching the others", %{project: project} do
      # The owner's exact ask: a contractor views everything they are
      # granted, but may work on ONE project.
      u = user()

      {:ok, role} =
        Roles.create_role(%{name: "Contractor2-#{System.unique_integer([:positive])}"})

      {:ok, _} = Roles.assign_role(u, role.name)

      other = fixture_project(%{"name" => "Other-#{System.unique_integer([:positive])}"})
      {:ok, _} = Grants.grant(project, "role", role.uuid, "viewer")
      {:ok, _} = Grants.grant(other, "role", role.uuid, "viewer")

      # The exception is a direct membership on the one project.
      {:ok, _} = Members.add_member(project, u.uuid, role: "member")

      assert Authz.effective_role(project, u.uuid) == :member
      assert Authz.can?(u.uuid, project, :comment)

      assert Authz.effective_role(other, u.uuid) == :viewer
      refute Authz.can?(u.uuid, other, :comment)
    end
  end

  describe "additive resolution" do
    test "the strongest matching grant wins, whichever subject it came from",
         %{project: project} do
      %{user: u, team: team, department: dept} = staffed_user()

      {:ok, _} = Grants.grant(project, "department", dept.uuid, "viewer")
      {:ok, _} = Grants.grant(project, "team", team.uuid, "manager")

      assert Authz.effective_role(project, u.uuid) == :manager
    end

    test "a weaker DIRECT membership never demotes a stronger group grant",
         %{project: project} do
      # The failure case all four panelists named: adding a grant must
      # never be a revocation. Someone is a manager through their team; an
      # admin adds them explicitly as a viewer to "make sure they have
      # access" — and must not strip their rights.
      %{user: u, team: team} = staffed_user()

      {:ok, _} = Grants.grant(project, "team", team.uuid, "manager")
      {:ok, _} = Members.add_member(project, u.uuid, role: "viewer")

      assert Authz.effective_role(project, u.uuid) == :manager
      assert Authz.can?(u.uuid, project, :edit_tasks)
    end

    test "a direct membership still stands alone when no group matches",
         %{project: project} do
      u = user()
      {:ok, _} = Members.add_member(project, u.uuid, role: "manager")
      assert Authz.effective_role(project, u.uuid) == :manager
    end
  end

  describe "guards" do
    test "a group cannot be made owner", %{project: project} do
      %{team: team} = staffed_user()
      assert {:error, changeset} = Grants.grant(project, "team", team.uuid, "owner")

      assert "must be manager, member, or viewer — groups cannot own a project" in errors_on(
               changeset
             ).role
    end

    test "an unknown subject type is rejected", %{project: project} do
      assert {:error, changeset} = Grants.grant(project, "wizard", Ecto.UUID.generate(), "viewer")
      assert changeset.errors[:subject_type]
    end

    test "re-granting the same subject updates instead of duplicating", %{project: project} do
      %{user: u, team: team} = staffed_user()

      {:ok, _} = Grants.grant(project, "team", team.uuid, "viewer")
      {:ok, _} = Grants.grant(project, "team", team.uuid, "manager")

      assert length(Grants.list_grants(project.uuid)) == 1
      assert Authz.effective_role(project, u.uuid) == :manager
    end

    test "provenance explains why someone has access", %{project: project} do
      %{user: u, team: team} = staffed_user()
      {:ok, _} = Grants.grant(project, "team", team.uuid, "member")

      assert [{"team", subject_uuid, "member"}] = Grants.provenance(project, u.uuid)
      assert subject_uuid == team.uuid
    end

    test "a grant pointing at a deleted subject grants nothing", %{project: project} do
      {:ok, _} = Grants.grant(project, "team", Ecto.UUID.generate(), "manager")
      stranger = user()
      refute Authz.can?(stranger.uuid, project, :view)
    end
  end

  describe "read scoping" do
    test "the index lists only what the viewer can reach", %{project: project} do
      %{user: u, team: team} = staffed_user()
      other = fixture_project(%{"name" => "Unrelated-#{System.unique_integer([:positive])}"})

      scope = %PhoenixKit.Users.Auth.Scope{
        user: %{uuid: u.uuid, email: "x@y.z"},
        authenticated?: true,
        cached_roles: [],
        cached_permissions: MapSet.new(["projects"])
      }

      # Reaching the module is not seeing every project.
      assert Projects.list_projects_for(scope) == []
      assert Projects.count_projects_for(scope) == 0

      {:ok, _} = Grants.grant(project, "team", team.uuid, "viewer")

      names = Projects.list_projects_for(scope) |> Enum.map(& &1.name)
      assert project.name in names
      refute other.name in names
      assert Projects.count_projects_for(scope) == 1
    end

    test "a site admin still sees everything", %{project: project} do
      admin =
        PhoenixKitProjects.LiveCase.fake_scope(permissions: ["projects", "projects.admin_all"])

      names = Projects.list_projects_for(admin) |> Enum.map(& &1.name)
      assert project.name in names
    end

    test "accessible_projects merges memberships and grants, strongest role per project",
         %{project: project} do
      %{user: u, team: team} = staffed_user()

      {:ok, _} = Members.add_member(project, u.uuid, role: "viewer")
      {:ok, _} = Grants.grant(project, "team", team.uuid, "manager")

      assert [{listed, "manager"}] =
               Enum.filter(Members.accessible_projects(u.uuid), fn {p, _} ->
                 p.uuid == project.uuid
               end)

      assert listed.uuid == project.uuid
    end

    test "a nil scope reaches nothing" do
      assert Projects.list_projects_for(nil) == []
      assert Projects.count_projects_for(nil) == 0
    end
  end

  describe "the admin override is unchanged by grants" do
    test "a site admin still resolves without any grant", %{project: project} do
      scope =
        PhoenixKitProjects.LiveCase.fake_scope(permissions: ["projects", "projects.admin_all"])

      assert Authz.can?(scope, project, :manage_members)
    end
  end
end
