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

  describe "handle_user_deletion/1 — the before_user_delete hook" do
    test "logs member_removed per membership with reason=user_deleted",
         %{project: project, owner: owner, other: other} do
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")
      {:ok, _} = Members.add_member(project, other.uuid, role: "viewer")

      assert :ok = Members.handle_user_deletion(other.uuid)

      assert_activity_logged("projects.member_removed",
        resource_uuid: project.uuid,
        metadata_has: %{"reason" => "user_deleted", "role" => "viewer"}
      )

      # The hook only pre-logs — the CASCADE delete removes the row when core
      # actually deletes the user, so the membership itself is untouched here.
      assert Members.role_of(project, other.uuid) == :viewer
    end

    test "sole-owner departure promotes the best remaining member",
         %{project: project, owner: owner, other: other} do
      manager = user_fixture()
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")
      {:ok, _} = Members.add_member(project, other.uuid, role: "viewer")
      {:ok, _} = Members.add_member(project, manager.uuid, role: "manager")

      pubsub = PhoenixKitProjects.PubSub
      pubsub.subscribe(pubsub.topic_project(project.uuid))

      assert :ok = Members.handle_user_deletion(owner.uuid)

      assert Members.role_of(project, manager.uuid) == :owner
      assert Members.role_of(project, other.uuid) == :viewer

      assert_activity_logged("projects.ownership_succeeded",
        resource_uuid: project.uuid,
        target_uuid: manager.uuid,
        metadata_has: %{"from_role" => "manager"}
      )

      # Live member UIs re-render through the same channel every other
      # membership mutation uses (the panel's staleness find).
      project_uuid = project.uuid
      assert_receive {:projects, :project_members_changed, %{uuid: ^project_uuid}}, 500
    end

    test "equal-role tiebreak is CHRONOLOGICAL seniority, not struct term order",
         %{project: project, owner: owner} do
      # Dates chosen so DateTime term order disagrees with chronology:
      # the newer membership (Feb 1) has the smaller day field, and struct
      # comparison reads day before month before year.
      older = user_fixture()
      newer = user_fixture()
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")
      {:ok, older_m} = Members.add_member(project, older.uuid, role: "member")
      {:ok, newer_m} = Members.add_member(project, newer.uuid, role: "member")

      backdate = fn m, dt ->
        m
        |> Ecto.Changeset.change(inserted_at: dt)
        |> PhoenixKit.RepoHelper.repo().update!()
      end

      backdate.(older_m, ~U[2026-01-15 12:00:00Z])
      backdate.(newer_m, ~U[2026-02-01 12:00:00Z])

      assert :ok = Members.handle_user_deletion(owner.uuid)

      assert Members.role_of(project, older.uuid) == :owner
      assert Members.role_of(project, newer.uuid) == :member
    end

    test "other owners exist → no remediation", %{project: project, owner: owner, other: other} do
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")
      {:ok, _} = Members.add_member(project, other.uuid, role: "owner")

      assert :ok = Members.handle_user_deletion(owner.uuid)

      assert Members.role_of(project, other.uuid) == :owner
      refute_activity_logged("projects.ownership_succeeded", resource_uuid: project.uuid)
    end

    test "sole owner of a memberless project → owner_departed flag",
         %{project: project, owner: owner} do
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")

      assert :ok = Members.handle_user_deletion(owner.uuid)

      assert_activity_logged("projects.owner_departed", resource_uuid: project.uuid)
    end
  end

  describe "V9 creator→owner backfill" do
    test "seats the creator from the activity log; memberless-only; idempotent",
         %{owner: owner} do
      # A "legacy" project: created with an activity trail but NO members
      # (fixture_project takes the no-actor path, so seed the entry).
      legacy = fixture_project()

      PhoenixKitProjects.Activity.log("projects.project_created",
        actor_uuid: owner.uuid,
        resource_type: "project",
        resource_uuid: legacy.uuid
      )

      # A project that ALREADY has members must be untouched.
      seated = fixture_project()
      other_user = user_fixture()
      {:ok, _} = Members.add_member(seated, other_user.uuid, role: "viewer")

      PhoenixKitProjects.Activity.log("projects.project_created",
        actor_uuid: owner.uuid,
        resource_type: "project",
        resource_uuid: seated.uuid
      )

      run_backfill()

      assert Members.role_of(legacy, owner.uuid) == :owner
      assert Members.role_of(seated, owner.uuid) == nil
      assert Members.role_of(seated, other_user.uuid) == :viewer

      # Idempotent: a re-run adds nothing (legacy now has a member).
      run_backfill()
      assert length(Members.list_members(legacy.uuid)) == 1
    end

    defp run_backfill do
      PhoenixKit.RepoHelper.repo().query!(
        """
        INSERT INTO phoenix_kit_project_members
          (uuid, project_uuid, user_uuid, role, inserted_at, updated_at)
        SELECT public.uuid_generate_v7(), pr.uuid, creator.actor_uuid, 'owner', NOW(), NOW()
        FROM phoenix_kit_projects pr
        JOIN LATERAL (
          SELECT e.actor_uuid
          FROM phoenix_kit_activities e
          WHERE e.resource_uuid = pr.uuid
            AND e.action IN ('projects.project_created', 'projects.project_created_from_template')
            AND e.actor_uuid IS NOT NULL
          ORDER BY e.inserted_at ASC
          LIMIT 1
        ) creator ON true
        WHERE pr.is_template = false
          AND EXISTS (
            SELECT 1 FROM phoenix_kit_users u WHERE u.uuid = creator.actor_uuid
          )
          AND NOT EXISTS (
            SELECT 1 FROM phoenix_kit_project_members m WHERE m.project_uuid = pr.uuid
          )
        """,
        []
      )
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

    test "the admin override covers a site admin, not a bare module-reacher",
         %{project: project} do
      admin =
        PhoenixKitProjects.LiveCase.fake_scope(permissions: ["projects", "projects.admin_all"])

      assert Authz.can?(admin, project, :manage_members)

      # The split: reaching the module is not administering every project.
      reacher = PhoenixKitProjects.LiveCase.fake_scope(permissions: ["projects"])
      refute Authz.can?(reacher, project, :manage_members)
    end
  end
end
