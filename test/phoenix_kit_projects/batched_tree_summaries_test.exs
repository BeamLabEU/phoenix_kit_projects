defmodule PhoenixKitProjects.BatchedTreeSummariesTest do
  @moduledoc """
  The batched forest read behind `Projects.project_tree_summaries/1` and
  `ScheduleLayout.trees/1` (the boss's #40 review: the dashboard widgets
  re-ran the Overview's per-node `list_assignments/1` on every refresh
  tick, per viewer). Two things are pinned: the batched shapes equal the
  per-project ones node for node, and the query count grows with the
  forest's DEPTH, never with the number of projects or nodes.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Projects, ScheduleLayout}

  # A root with tasks, a child with tasks, a grandchild with tasks — three
  # levels, mixed statuses, so every node contributes to the rolled-up
  # numbers.
  defp forest_root(label) do
    root = fixture_project(%{"name" => "Root #{label}", "start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(root)
    root = Projects.get_project!(root.uuid)
    add_tasks(root, ["#{label} r1", "#{label} r2"], "done")

    {:ok, %{child_project: child}} =
      Projects.create_subproject(root.uuid, %{"name" => "Child #{label}"})

    add_tasks(child, ["#{label} c1"], "in_progress")

    {:ok, %{child_project: grandchild}} =
      Projects.create_subproject(child.uuid, %{"name" => "Grandchild #{label}"})

    add_tasks(grandchild, ["#{label} g1", "#{label} g2", "#{label} g3"], "todo")

    Projects.get_project!(root.uuid)
  end

  defp add_tasks(project, titles, status) do
    for title <- titles do
      task =
        fixture_task(%{
          "title" => title,
          "estimated_duration" => 2,
          "estimated_duration_unit" => "hours"
        })

      {:ok, a} =
        Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

      if status != "todo" do
        {:ok, _} =
          a |> Ecto.Changeset.change(status: status) |> PhoenixKit.RepoHelper.repo().update()
      end
    end
  end

  defp count_queries(fun), do: PhoenixKitProjects.QueryCounter.count(fun)

  describe "project_tree_summaries/1" do
    test "equals the per-project summary, node for node, in input order" do
      roots = for label <- ~w(A B C), do: forest_root(label)

      batched = Projects.project_tree_summaries(roots)
      single = Enum.map(roots, &Projects.project_tree_summary/1)

      assert length(batched) == 3
      assert Enum.map(batched, & &1.project.uuid) == Enum.map(roots, & &1.uuid)

      for {b, s} <- Enum.zip(batched, single) do
        assert strip(b) == strip(s)
      end

      # The rolled-up numbers are the tree's, not just the root's.
      [a | _] = batched
      assert a.task_total == 2 and a.task_done == 2 and a.subproject_count == 1
      [child] = a.children
      assert child.task_in_progress == 1
      [grandchild] = child.children
      assert grandchild.task_todo == 3 and grandchild.children == []
    end

    test "a project with no assignments gets an empty node, and an unknown list is empty" do
      lonely = fixture_project(%{"name" => "Lonely"})

      assert [%{task_total: 0, subproject_count: 0, children: []}] =
               Projects.project_tree_summaries([lonely])

      assert Projects.project_tree_summaries([]) == []
      assert Projects.assignments_by_project([]) == %{}
    end

    test "the query count follows the depth, not the number of projects" do
      three = for label <- ~w(D E F), do: forest_root(label)
      six = three ++ for(label <- ~w(G H I), do: forest_root(label))

      {_, q_one} = count_queries(fn -> Projects.project_tree_summaries(Enum.take(three, 1)) end)
      {_, q_three} = count_queries(fn -> Projects.project_tree_summaries(three) end)
      {_, q_six} = count_queries(fn -> Projects.project_tree_summaries(six) end)

      # Three levels deep → three grouped reads (each with its preload
      # statements), however many roots: one root, three or six cost the
      # same. (The statements counted include Ecto's per-association
      # preloads, which is why a level is more than one.)
      assert q_one == q_three
      assert q_three == q_six
      assert q_six <= 3 * 5

      # The per-project walk is what the widgets used to pay: the same
      # statements per NODE — three nodes per root, so it grows with the
      # forest. Six roots must cost several times the batched read.
      {_, q_old} = count_queries(fn -> Enum.map(six, &Projects.project_tree_summary/1) end)
      assert q_old > 3 * q_six
    end
  end

  describe "corrupt links (a cycle in persisted data)" do
    # The linking guards never write these; a walk over persisted data must
    # still end (codex, 2026-09-05: the loader was bounded, the builder was
    # not — a self-link recursed forever).
    defp raw_link!(from, to) do
      %PhoenixKitProjects.Schemas.Assignment{
        project_uuid: from.uuid,
        child_project_uuid: to.uuid,
        status: "todo",
        review_status: "accepted",
        position: 99
      }
      |> PhoenixKit.RepoHelper.repo().insert!()
    end

    test "a self-link ends: the edge counts as a sub-project but is never descended" do
      a = fixture_project(%{"name" => "Self"})
      raw_link!(a, a)

      [node] = Projects.project_tree_summaries([Projects.get_project!(a.uuid)])
      assert node.subproject_count == 1
      assert node.children == []
      assert Map.keys(Projects.assignments_by_project([a.uuid])) == [a.uuid]
    end

    test "a two-cycle ends: A → B → A stops at the edge back to A" do
      a = fixture_project(%{"name" => "Cycle A"})
      b = fixture_project(%{"name" => "Cycle B"})
      raw_link!(a, b)
      raw_link!(b, a)

      [node_a] = Projects.project_tree_summaries([Projects.get_project!(a.uuid)])
      assert [%{children: []} = node_b] = node_a.children
      assert node_b.project.uuid == b.uuid
      assert node_b.subproject_count == 1

      by_project = Projects.assignments_by_project([a.uuid])
      assert Enum.sort(Map.keys(by_project)) == Enum.sort([a.uuid, b.uuid])

      # The schedule walk skips the edge back too — the layout would
      # otherwise chase a parent chain that loops and never return.
      {items, layout} = ScheduleLayout.tree(Projects.get_project!(a.uuid))
      assert length(items) == 2
      assert map_size(layout) == 2
    end
  end

  describe "assignments_by_project/1" do
    test "reaches every level of the forest with one batch per level, in list order" do
      root = forest_root("L")
      {_, one_root} = count_queries(fn -> Projects.assignments_by_project([root.uuid]) end)
      other = forest_root("M")

      {_, two_roots} =
        count_queries(fn -> Projects.assignments_by_project([root.uuid, other.uuid]) end)

      assert one_root == two_roots

      by_project = Projects.assignments_by_project([root.uuid])
      # The root, its child and the grandchild are all present.
      assert map_size(by_project) == 3
      root_rows = Map.fetch!(by_project, root.uuid)
      assert length(root_rows) == 3
      # Same order as list_assignments/1.
      assert Enum.map(root_rows, & &1.uuid) ==
               Enum.map(Projects.list_assignments(root.uuid), & &1.uuid)

      [link] = Enum.filter(root_rows, & &1.child_project_uuid)
      assert Map.has_key?(by_project, link.child_project_uuid)
    end
  end

  describe "ScheduleLayout.trees/1" do
    test "matches tree/1 item for item and span for span, in one batch per level" do
      roots = for label <- ~w(S T), do: forest_root(label)

      {batched, queries} = count_queries(fn -> ScheduleLayout.trees(roots) end)
      {_, one} = count_queries(fn -> ScheduleLayout.trees(Enum.take(roots, 1)) end)
      assert queries == one

      for {root, {items, layout}} <- Enum.zip(roots, batched) do
        {single_items, single_layout} = ScheduleLayout.tree(root)
        assert Enum.map(items, & &1.uuid) == Enum.map(single_items, & &1.uuid)
        assert layout == single_layout
        # Root tasks + the link + child task + the link + grandchild tasks.
        assert length(items) == 8
      end
    end
  end

  # The node minus the preloaded structs' incidental differences — the
  # numbers and the shape are what must agree.
  defp strip(node) do
    node
    |> Map.take([
      :task_total,
      :task_done,
      :task_in_progress,
      :task_todo,
      :subproject_count,
      :total,
      :progress_pct,
      :total_hours,
      :planned_end
    ])
    |> Map.put(:project_uuid, node.project.uuid)
    |> Map.put(:children, Enum.map(node.children, &strip/1))
  end
end
