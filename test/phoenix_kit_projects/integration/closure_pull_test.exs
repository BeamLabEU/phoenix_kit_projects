defmodule PhoenixKitProjects.Integration.ClosurePullTest do
  @moduledoc """
  Integration tests for the closure-pull cascade — pulling a task
  with template dependencies into a project, with optional pruning.

  Covers:
    - happy path: a 3-task chain (T1 ← T2 ← T3) inserts in execution
      order (prerequisites first, picked task last) with assignment
      `position` matching insertion order
    - exclusion cascade: ticking off an intermediate task skips its
      entire subtree (the picked task can still land without its
      prerequisite, by the user's explicit choice)
    - reuse of pre-existing assignments: a closure task that already
      has an assignment in the project is wired into deps but not
      duplicated
    - cycle terminator: a cyclic dependency chain doesn't crash and
      the cycle node contributes no insert
    - error shape: an unknown root uuid returns `{:error, :task_not_found}`
    - rollback: a primary-pick that fails on `create_assignment`
      rolls back the whole transaction (no orphan extras)
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Projects

  describe "create_assignments_with_closure/4 — happy path" do
    test "inserts the chain in execution order (deepest first, root last)" do
      project = fixture_project()
      [t1, t2, t3] = chain_of_three()

      assert {:ok, %{root: root, extras: extras}} =
               Projects.create_assignments_with_closure(t3.uuid, project.uuid, %{
                 "status" => "todo"
               })

      # Root corresponds to the user's pick (T3).
      assert root.task_uuid == t3.uuid

      # Extras hold the prerequisites in insertion order.
      assert length(extras) == 2
      [first_extra, second_extra] = extras
      assert first_extra.task_uuid == t1.uuid
      assert second_extra.task_uuid == t2.uuid

      # Position math: T1 < T2 < T3.
      assignments = Projects.list_assignments(project.uuid)
      positions = Map.new(assignments, &{&1.task_uuid, &1.position})
      assert positions[t1.uuid] < positions[t2.uuid]
      assert positions[t2.uuid] < positions[root.task_uuid]

      # Dependencies wired: T2 depends on T1, T3 depends on T2.
      assert depends_on?(project.uuid, t2.uuid, t1.uuid)
      assert depends_on?(project.uuid, t3.uuid, t2.uuid)
    end
  end

  describe "create_assignments_with_closure/4 — exclusion cascade" do
    test "excluding a mid-chain task skips its entire subtree, root still inserted" do
      project = fixture_project()
      [t1, t2, t3] = chain_of_three()

      assert {:ok, %{root: root, extras: extras}} =
               Projects.create_assignments_with_closure(
                 t3.uuid,
                 project.uuid,
                 %{"status" => "todo"},
                 excluded_task_uuids: MapSet.new([t2.uuid])
               )

      # Root (T3) lands.
      assert root.task_uuid == t3.uuid

      # T2 excluded → T2's whole subtree (T1) skipped via cascade.
      assert extras == []

      # Only the one row exists.
      assert length(Projects.list_assignments(project.uuid)) == 1

      # Dep on T2 was not wired because T2 isn't part of the closure
      # insertion. Equally, T1 → T2 isn't wired (T1 was never inserted).
      refute depends_on?(project.uuid, t3.uuid, t2.uuid)
      refute depends_on?(project.uuid, t2.uuid, t1.uuid)
    end
  end

  describe "create_assignments_with_closure/4 — reuse of pre-existing assignments" do
    test "a closure task already in the project is wired but not duplicated" do
      project = fixture_project()
      [t1, t2, t3] = chain_of_three()

      # Pre-seed T1 as an assignment in the project. The closure pull
      # of T3 should find it via `existing_task_assignment_map/2`,
      # reuse the uuid for dep wiring, and skip the insert.
      {:ok, existing_t1_assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => t1.uuid,
          "status" => "todo"
        })

      assert {:ok, %{root: root, extras: extras}} =
               Projects.create_assignments_with_closure(t3.uuid, project.uuid, %{
                 "status" => "todo"
               })

      # Only T2 is freshly inserted as an extra; T1 was reused.
      assert length(extras) == 1
      [t2_assignment] = extras
      assert t2_assignment.task_uuid == t2.uuid

      # T1 still has just one assignment row — no duplicate.
      t1_rows =
        Projects.list_assignments(project.uuid)
        |> Enum.filter(&(&1.task_uuid == t1.uuid))

      assert length(t1_rows) == 1
      assert hd(t1_rows).uuid == existing_t1_assignment.uuid

      # Dep wiring still points at the pre-existing T1 uuid.
      assert depends_on?(project.uuid, t2.uuid, t1.uuid)
      assert depends_on?(project.uuid, root.task_uuid, t2.uuid)
    end
  end

  describe "create_assignments_with_closure/4 — cycle terminator" do
    test "a cycle in the dep chain doesn't crash; cycle nodes don't insert" do
      project = fixture_project()
      t1 = fixture_task()
      t2 = fixture_task()

      # T1 ← T2 ← T1 (cycle). `task_closure/2` records the second
      # visit of T1 as `cycle?: true`; `do_topo/5` terminates on
      # cycle nodes without contributing.
      {:ok, _} = Projects.add_task_dependency(t1.uuid, t2.uuid)
      {:ok, _} = Projects.add_task_dependency(t2.uuid, t1.uuid)

      assert {:ok, %{root: root, extras: extras}} =
               Projects.create_assignments_with_closure(t1.uuid, project.uuid, %{
                 "status" => "todo"
               })

      assert root.task_uuid == t1.uuid

      # T2 contributes once (it's a non-cycle node in T1's subtree).
      # T1's second visit as cycle terminator doesn't re-insert.
      assert length(extras) == 1
      assert hd(extras).task_uuid == t2.uuid
    end
  end

  describe "create_assignments_with_closure/4 — error shape" do
    test "unknown root uuid returns :task_not_found" do
      project = fixture_project()

      assert {:error, :task_not_found} =
               Projects.create_assignments_with_closure(
                 Ecto.UUID.generate(),
                 project.uuid,
                 %{"status" => "todo"}
               )

      # Nothing landed.
      assert Projects.list_assignments(project.uuid) == []
    end

    test "an invalid root attrs (bad status) rolls back the whole transaction" do
      project = fixture_project()
      [_t1, _t2, t3] = chain_of_three()

      assert {:error, %Ecto.Changeset{}} =
               Projects.create_assignments_with_closure(t3.uuid, project.uuid, %{
                 "status" => "not_a_real_status"
               })

      # No orphans — neither T1, T2, nor T3 should have an assignment.
      assert Projects.list_assignments(project.uuid) == []
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp chain_of_three do
    t1 = fixture_task()
    t2 = fixture_task()
    t3 = fixture_task()

    # T2 depends on T1; T3 depends on T2.
    {:ok, _} = Projects.add_task_dependency(t2.uuid, t1.uuid)
    {:ok, _} = Projects.add_task_dependency(t3.uuid, t2.uuid)

    [t1, t2, t3]
  end

  defp depends_on?(project_uuid, task_uuid, depends_on_task_uuid) do
    assignments = Projects.list_assignments(project_uuid)

    case Enum.find(assignments, &(&1.task_uuid == task_uuid)) do
      nil ->
        false

      a ->
        deps = Projects.list_dependencies(a.uuid)

        Enum.any?(deps, fn d ->
          case Enum.find(assignments, &(&1.uuid == d.depends_on_uuid)) do
            nil -> false
            target -> target.task_uuid == depends_on_task_uuid
          end
        end)
    end
  end
end
