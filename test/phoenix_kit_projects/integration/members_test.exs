defmodule PhoenixKitProjects.Integration.MembersTest do
  use PhoenixKitProjects.DataCase, async: false

  import PhoenixKitProjects.ActivityLogAssertions

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Authz, Features, Members, Projects}

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        email: "member-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  setup do
    PhoenixKitProjects.Extensions.Registry.refresh()
    {:ok, project: fixture_project(), owner: user_fixture(), other: user_fixture()}
  end

  describe "membership lifecycle" do
    test "add / role_of / change / remove with activity + target_uuid",
         %{project: project, owner: owner, other: other} do
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")

      {:ok, member} =
        Members.add_member(project, other.uuid, role: "viewer", actor_uuid: owner.uuid)

      assert member.role == "viewer"
      assert Members.role_of(project, other.uuid) == :viewer

      # The affected USER rides target_uuid — that's what makes core's
      # notification bridge deliver "you were added".
      assert_activity_logged("projects.member_added",
        resource_uuid: project.uuid,
        target_uuid: other.uuid,
        metadata_has: %{"role" => "viewer"}
      )

      {:ok, _} = Members.change_role(project, other.uuid, "manager", owner.uuid)
      assert Members.role_of(project, other.uuid) == :manager

      {:ok, _} = Members.remove_member(project, other.uuid, actor_uuid: owner.uuid)
      assert Members.role_of(project, other.uuid) == nil
      assert_activity_logged("projects.member_removed", resource_uuid: project.uuid)
    end

    test "the last owner can be neither demoted nor removed",
         %{project: project, owner: owner, other: other} do
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")

      assert {:error, :last_owner} = Members.change_role(project, owner.uuid, "member")
      assert {:error, :last_owner} = Members.remove_member(project, owner.uuid)

      # With a second owner both operations go through.
      {:ok, _} = Members.add_member(project, other.uuid, role: "owner")
      assert {:ok, _} = Members.change_role(project, owner.uuid, "member")
      assert Members.role_of(project, other.uuid) == :owner
    end

    test "re-adding an existing member routes through change_role",
         %{project: project, owner: owner} do
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")
      assert {:error, :last_owner} = Members.add_member(project, owner.uuid, role: "viewer")
    end

    test "creator gets the owner seat via create_project/2", %{owner: owner} do
      {:ok, project} =
        Projects.create_project(
          %{"name" => "Owner seed #{System.unique_integer([:positive])}"},
          actor_uuid: owner.uuid
        )

      assert Members.role_of(project, owner.uuid) == :owner
    end

    test "unknown user role_of is nil and add fails cleanly", %{project: project} do
      ghost = Ecto.UUID.generate()
      assert Members.role_of(project, ghost) == nil
      assert {:error, %Ecto.Changeset{}} = Members.add_member(project, ghost)
    end
  end

  describe "Authz member resolution" do
    setup %{project: project, owner: owner, other: other} do
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")
      {:ok, _} = Members.add_member(project, other.uuid, role: "member")
      :ok
    end

    test "role floors: member vs manager vs owner actions",
         %{project: project, owner: owner, other: other} do
      # Owner may do everything.
      assert Authz.can?(owner.uuid, project, :manage_members)
      assert Authz.can?(owner.uuid, project, :assign_tasks)

      # Member: create/comment yes; assign/manage no.
      assert Authz.can?(other.uuid, project, :view)
      assert Authz.can?(other.uuid, project, :create_tasks)
      refute Authz.can?(other.uuid, project, :assign_tasks)
      refute Authz.can?(other.uuid, project, :manage_members)
      refute Authz.can?(other.uuid, project, :update_status)
    end

    test "non-members resolve false for everything", %{project: project} do
      stranger = user_fixture()
      refute Authz.can?(stranger.uuid, project, :view)
      refute Authz.can?(stranger.uuid, project, :create_tasks)
    end

    test "who-can-X override lowers the assign floor to members",
         %{project: project, other: other} do
      refute Authz.can?(other.uuid, project, :assign_tasks)

      {:ok, _} =
        Features.set_flags(project, %{})

      # Write the authz override directly (the settings UI lands with the
      # Modules panel's who-can-X dropdowns).
      project =
        project
        |> Ecto.Changeset.change(
          settings: Map.put(project.settings || %{}, "authz", %{"assign_tasks" => "members"})
        )
        |> PhoenixKit.RepoHelper.repo().update!()

      assert Authz.can?(other.uuid, project, :assign_tasks)
    end

    test "log_time floors at manager with the assignee relationship grant",
         %{project: project, owner: owner, other: other} do
      # Plain member, no record: below the manager floor.
      refute Authz.can?(other.uuid, project, :log_time)
      # Owner clears the floor.
      assert Authz.can?(owner.uuid, project, :log_time)

      # The member logging on THEIR OWN task: relationship grant.
      own = %{assigned_person: %{user_uuid: other.uuid}}
      assert Authz.can?(other.uuid, project, :log_time, own)

      # Someone else's task or an unassigned one: refused.
      foreign = %{assigned_person: %{user_uuid: Ecto.UUID.generate()}}
      refute Authz.can?(other.uuid, project, :log_time, foreign)
      refute Authz.can?(other.uuid, project, :log_time, %{assigned_person: nil})
    end

    test "relationship grant: the assignee may update their task's status",
         %{project: project, other: other} do
      # A member (not manager) with an assignment resolved to their user.
      assignment = %{assigned_person: %{user_uuid: other.uuid}}
      assert Authz.can?(other.uuid, project, :update_status, assignment)

      # Someone else's assignment: still refused.
      foreign = %{assigned_person: %{user_uuid: Ecto.UUID.generate()}}
      refute Authz.can?(other.uuid, project, :update_status, foreign)

      # Unassigned record: refused (fail-closed).
      refute Authz.can?(other.uuid, project, :update_status, %{assigned_person: nil})
    end

    test "the admin override still covers admin-area scopes", %{project: project} do
      scope = PhoenixKitProjects.LiveCase.fake_scope(permissions: ["projects"])
      assert Authz.can?(scope, project, :manage_members)
    end
  end
end
