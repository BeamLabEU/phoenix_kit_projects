defmodule PhoenixKitProjects.Integration.ReorderTest do
  @moduledoc """
  Integration tests for the four reorder context fns:

    - `Projects.reorder_tasks/2`
    - `Projects.reorder_projects/2`
    - `Projects.reorder_templates/2`
    - `Projects.reorder_assignments/3`

  Covers the rejection paths that the LV layer surfaces as flash
  messages — `:too_many_uuids` past the `@reorder_max_uuids` cap and
  `:wrong_scope` when the caller mixes templates with projects (or
  vice versa) or passes assignment uuids from the wrong project.

  The `:ok` happy-path assertions are paired with the corresponding
  activity-log action atoms (`task.reordered`, `project.reordered`,
  `template.reordered`, `assignment.reordered`) so a future typo in
  the action string surfaces here, not silently in the audit feed.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.Projects

  setup do
    actor_uuid = Ecto.UUID.generate()
    {:ok, actor_uuid: actor_uuid}
  end

  describe "reorder_tasks/2" do
    test "happy path writes positions in submitted order and logs `task.reordered`",
         %{actor_uuid: actor_uuid} do
      t1 = fixture_task()
      t2 = fixture_task()
      t3 = fixture_task()

      assert :ok = Projects.reorder_tasks([t3.uuid, t1.uuid, t2.uuid], actor_uuid: actor_uuid)

      positions =
        Projects.list_tasks()
        |> Enum.filter(&(&1.uuid in [t1.uuid, t2.uuid, t3.uuid]))
        |> Map.new(&{&1.uuid, &1.position})

      # T3 became first (position 1), T1 second, T2 third.
      assert positions[t3.uuid] < positions[t1.uuid]
      assert positions[t1.uuid] < positions[t2.uuid]

      assert_activity_logged("task.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"count" => 3}
      )
    end

    test "rejects payloads over the cap with `:too_many_uuids` and logs `task.reorder_rejected`",
         %{actor_uuid: actor_uuid} do
      # Synthetic uuids — never touch the DB; the size guard fires
      # before any query.
      bloat = for _ <- 1..1001, do: Ecto.UUID.generate()

      assert {:error, :too_many_uuids} = Projects.reorder_tasks(bloat, actor_uuid: actor_uuid)

      assert_activity_logged("task.reorder_rejected",
        actor_uuid: actor_uuid,
        metadata_has: %{"reason" => "too_many_uuids", "count" => 1001}
      )
    end

    test "stale uuids reorder silently (no audit row, no error)" do
      stale = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      assert :ok = Projects.reorder_tasks(stale)
      refute_activity_logged("task.reordered")
    end
  end

  describe "reorder_projects/2" do
    test "happy path writes positions and logs `project.reordered`",
         %{actor_uuid: actor_uuid} do
      p1 = fixture_project()
      p2 = fixture_project()

      assert :ok = Projects.reorder_projects([p2.uuid, p1.uuid], actor_uuid: actor_uuid)

      positions =
        Projects.list_projects()
        |> Enum.filter(&(&1.uuid in [p1.uuid, p2.uuid]))
        |> Map.new(&{&1.uuid, &1.position})

      assert positions[p2.uuid] < positions[p1.uuid]

      assert_activity_logged("project.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"count" => 2}
      )
    end

    test "rejects a template uuid as `:wrong_scope`",
         %{actor_uuid: actor_uuid} do
      project = fixture_project()
      template = fixture_template()

      assert {:error, :wrong_scope} =
               Projects.reorder_projects([project.uuid, template.uuid], actor_uuid: actor_uuid)

      assert_activity_logged("project.reorder_rejected",
        actor_uuid: actor_uuid,
        metadata_has: %{"reason" => "wrong_scope"}
      )
    end

    test "rejects payloads over the cap with `:too_many_uuids`",
         %{actor_uuid: actor_uuid} do
      bloat = for _ <- 1..1001, do: Ecto.UUID.generate()

      assert {:error, :too_many_uuids} = Projects.reorder_projects(bloat, actor_uuid: actor_uuid)

      assert_activity_logged("project.reorder_rejected",
        actor_uuid: actor_uuid,
        metadata_has: %{"reason" => "too_many_uuids"}
      )
    end
  end

  describe "reorder_templates/2" do
    test "happy path writes positions and logs `template.reordered`",
         %{actor_uuid: actor_uuid} do
      t1 = fixture_template()
      t2 = fixture_template()

      assert :ok = Projects.reorder_templates([t2.uuid, t1.uuid], actor_uuid: actor_uuid)

      positions =
        Projects.list_templates()
        |> Enum.filter(&(&1.uuid in [t1.uuid, t2.uuid]))
        |> Map.new(&{&1.uuid, &1.position})

      assert positions[t2.uuid] < positions[t1.uuid]

      assert_activity_logged("template.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"count" => 2}
      )
    end

    test "rejects a real-project uuid as `:wrong_scope`",
         %{actor_uuid: actor_uuid} do
      template = fixture_template()
      project = fixture_project()

      assert {:error, :wrong_scope} =
               Projects.reorder_templates([template.uuid, project.uuid], actor_uuid: actor_uuid)

      assert_activity_logged("template.reorder_rejected",
        actor_uuid: actor_uuid,
        metadata_has: %{"reason" => "wrong_scope"}
      )
    end
  end

  describe "reorder_assignments/3" do
    test "happy path writes positions and logs `assignment.reordered`",
         %{actor_uuid: actor_uuid} do
      project = fixture_project()
      [a1, a2] = two_assignments(project.uuid)

      assert :ok =
               Projects.reorder_assignments(project.uuid, [a2.uuid, a1.uuid],
                 actor_uuid: actor_uuid
               )

      positions =
        Projects.list_assignments(project.uuid)
        |> Map.new(&{&1.uuid, &1.position})

      assert positions[a2.uuid] < positions[a1.uuid]

      assert_activity_logged("assignment.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"count" => 2}
      )
    end

    test "rejects payloads over the cap with `:too_many_uuids`",
         %{actor_uuid: actor_uuid} do
      project = fixture_project()
      bloat = for _ <- 1..1001, do: Ecto.UUID.generate()

      assert {:error, :too_many_uuids} =
               Projects.reorder_assignments(project.uuid, bloat, actor_uuid: actor_uuid)

      assert_activity_logged("assignment.reorder_rejected",
        actor_uuid: actor_uuid,
        metadata_has: %{"reason" => "too_many_uuids"}
      )
    end

    test "rejects assignment uuids from a different project as `:not_in_project`",
         %{actor_uuid: actor_uuid} do
      project_a = fixture_project()
      project_b = fixture_project()
      [a_in_b, _] = two_assignments(project_b.uuid)

      assert {:error, :not_in_project} =
               Projects.reorder_assignments(project_a.uuid, [a_in_b.uuid],
                 actor_uuid: actor_uuid
               )

      assert_activity_logged("assignment.reorder_rejected",
        actor_uuid: actor_uuid,
        metadata_has: %{"reason" => "not_in_project"}
      )
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp two_assignments(project_uuid) do
    Enum.map(1..2, fn _ ->
      task = fixture_task()

      {:ok, a} =
        Projects.create_assignment(%{
          "project_uuid" => project_uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      a
    end)
  end
end
