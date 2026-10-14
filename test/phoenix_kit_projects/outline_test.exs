defmodule PhoenixKitProjects.OutlineTest do
  @moduledoc """
  `PhoenixKitProjects.Outline`: the typed list's one write (`sync/4`), the
  tick rules (`settle/3` through `Projects.update_assignment_status/2`),
  moving a branch, and the held tasks a removed line leaves behind.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Ledger, Outline, Projects}
  alias PhoenixKitProjects.Schemas.Assignment

  defp project do
    fixture_project(%{"name" => "Outline #{System.unique_integer([:positive])}"})
  end

  defp task(project, title) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{}
      )

    a
  end

  # The project's list as {title, depth, status}, in order.
  defp listed(project) do
    project.uuid
    |> Projects.list_assignments()
    |> Outline.walk()
    |> Enum.map(fn {a, depth} -> {a.task.title, depth, a.status} end)
  end

  defp line(text, depth \\ 0, id \\ nil),
    do: %{"id" => id, "tmp" => text, "text" => text, "depth" => depth}

  describe "sync/4" do
    test "new lines become tasks, nested by their indent" do
      p = project()

      {:ok, %{created: created}} =
        Outline.sync(p.uuid, [line("Buy"), line("Milk", 1), line("Eggs", 1), line("Call")], [])

      assert map_size(created) == 4

      assert listed(p) == [
               {"Buy", 0, "todo"},
               {"Milk", 1, "todo"},
               {"Eggs", 1, "todo"},
               {"Call", 0, "todo"}
             ]

      # Every task has a number from the moment it exists.
      assert Enum.all?(Map.values(created), &is_integer(&1.number))
    end

    test "blank lines are not tasks, and a jump of two levels is one" do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [line("A"), line("   "), line("B", 3)], [])
      assert listed(p) == [{"A", 0, "todo"}, {"B", 1, "todo"}]
    end

    test "a changed line renames its task; the order follows the lines" do
      p = project()
      a = task(p, "First")
      b = task(p, "Second")

      {:ok, %{renamed: renamed}} =
        Outline.sync(p.uuid, [line("Second", 0, b.uuid), line("First, renamed", 0, a.uuid)], [
          a.uuid,
          b.uuid
        ])

      assert renamed == [a.uuid]
      assert listed(p) == [{"Second", 0, "todo"}, {"First, renamed", 0, "todo"}]
    end

    test "a plain task whose line is gone is deleted; one carrying work is held" do
      p = project()
      plain = task(p, "Plain")
      logged = task(p, "Logged")
      keep = task(p, "Keep")

      {:ok, _} = Ledger.log_time(p, 30, assignment_uuid: logged.uuid)

      {:ok, summary} =
        Outline.sync(p.uuid, [line("Keep", 0, keep.uuid)], [plain.uuid, logged.uuid, keep.uuid])

      assert summary.removed == [plain.uuid]
      assert summary.held == [logged.uuid]
      assert Projects.get_assignment(plain.uuid) == nil
      assert %Assignment{review_status: "removed"} = Projects.get_assignment(logged.uuid)
      assert listed(p) == [{"Keep", 0, "todo"}]
      assert [%{uuid: uuid}] = Outline.held(p.uuid)
      assert uuid == logged.uuid
    end

    test "a held task named by a line is back — the cut pasted elsewhere" do
      p = project()
      a = task(p, "Moved")
      _ = Projects.update_assignment_form(a, %{"description" => "carries words"})
      b = task(p, "Other")

      {:ok, %{held: [held]}} = Outline.sync(p.uuid, [line("Other", 0, b.uuid)], [a.uuid, b.uuid])
      assert held == a.uuid

      {:ok, %{revived: [revived]}} =
        Outline.sync(p.uuid, [line("Other", 0, b.uuid), line("Moved", 1, a.uuid)], [b.uuid])

      assert revived == a.uuid
      assert listed(p) == [{"Other", 0, "todo"}, {"Moved", 1, "todo"}]
      assert Projects.get_assignment(a.uuid).number == a.number
    end

    test "a task the browser never knew of is kept, in its place" do
      p = project()
      a = task(p, "Known")
      fresh = task(p, "Added by someone else")

      {:ok, summary} = Outline.sync(p.uuid, [line("Known", 0, a.uuid), line("Mine")], [a.uuid])

      assert summary.removed == []
      assert Enum.map(listed(p), &elem(&1, 0)) == ["Known", "Added by someone else", "Mine"]
      assert Projects.get_assignment(fresh.uuid)
    end

    test "a sub-project row is never removed by a list" do
      p = project()
      {:ok, %{assignment: link}} = Projects.create_subproject(p.uuid, %{"name" => "Child"})
      {:ok, summary} = Outline.sync(p.uuid, [], [link.uuid])
      assert summary.removed == []
      assert Projects.get_assignment(link.uuid)
    end

    test "an id from another project is a new line, not that task" do
      p = project()
      other = task(project(), "Elsewhere")
      {:ok, %{created: created}} = Outline.sync(p.uuid, [line("Elsewhere", 0, other.uuid)], [])
      assert map_size(created) == 1
      assert Projects.get_assignment(other.uuid).project_uuid != p.uuid
    end
  end

  describe "the tick rules" do
    setup do
      p = project()

      {:ok, _} =
        Outline.sync(
          p.uuid,
          [line("Parent"), line("One", 1), line("Two", 1), line("Deep", 2)],
          []
        )

      by_title = Map.new(Projects.list_assignments(p.uuid), &{&1.task.title, &1})
      {:ok, p: p, t: by_title}
    end

    test "ticking a task ticks everything under it", %{p: p, t: t} do
      {:ok, _} = Projects.complete_assignment(t["Parent"], nil)
      assert Enum.all?(listed(p), fn {_, _, status} -> status == "done" end)
    end

    test "the last subtask ticked ticks its parent, level by level", %{p: p, t: t} do
      {:ok, _} = Projects.complete_assignment(t["One"], nil)
      assert {"Parent", 0, "todo"} in listed(p)

      {:ok, _} = Projects.complete_assignment(t["Deep"], nil)
      assert {"Two", 1, "done"} in listed(p)
      assert {"Parent", 0, "done"} in listed(p)
    end

    test "a project can keep a parent open when its subtasks are done", %{p: p, t: t} do
      {:ok, p} =
        Projects.update_project(p, %{
          "settings" => Map.put(p.settings || %{}, "outline", %{"complete_parent" => false})
        })

      for title <- ["One", "Deep"], do: {:ok, _} = Projects.complete_assignment(t[title], nil)
      assert {"Parent", 0, "todo"} in listed(p)
    end

    test "reopening a subtask reopens what it sits under; unticking a parent touches nothing below",
         %{p: p, t: t} do
      {:ok, _} = Projects.complete_assignment(t["Parent"], nil)
      {:ok, _} = Projects.reopen_assignment(Projects.get_assignment(t["Deep"].uuid))

      statuses = Map.new(listed(p), fn {title, _, status} -> {title, status} end)
      assert statuses["Deep"] == "todo"
      assert statuses["Two"] != "done"
      assert statuses["Parent"] != "done"
      assert statuses["One"] == "done"

      {:ok, _} = Projects.complete_assignment(Projects.get_assignment(t["Parent"].uuid), nil)
      {:ok, _} = Projects.reopen_assignment(Projects.get_assignment(t["Parent"].uuid))
      assert {"One", 1, "done"} in listed(p)
    end

    test "the project counts the tasks with nothing under them", %{p: p, t: t} do
      {:ok, _} = Projects.complete_assignment(t["One"], nil)
      summary = Projects.project_summary(p)
      assert summary.total == 2
      assert summary.done == 1
    end
  end

  describe "move/3 and delete" do
    test "a branch moves whole, and nothing goes under itself" do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [line("A"), line("A1", 1), line("B")], [])
      t = Map.new(Projects.list_assignments(p.uuid), &{&1.task.title, &1})

      {:ok, _} = Outline.move(t["A"], t["B"].uuid, :last)
      assert listed(p) == [{"B", 0, "todo"}, {"A", 1, "todo"}, {"A1", 2, "todo"}]

      assert {:error, :cycle} =
               Outline.move(Projects.get_assignment(t["B"].uuid), t["A1"].uuid, :last)
    end

    test "the database refuses a parent in another project" do
      p = project()
      a = task(p, "Here")
      there = task(project(), "There")

      assert {:error, cs} = Projects.update_assignment_form(a, %{"parent_uuid" => there.uuid})
      assert cs.errors[:parent_uuid]
    end

    test "deleting a task deletes what is under it" do
      p = project()

      {:ok, _} =
        Outline.sync(p.uuid, [line("Top"), line("Under", 1), line("Deeper", 2), line("Next")], [])

      top = Enum.find(Projects.list_assignments(p.uuid), &(&1.task.title == "Top"))

      {:ok, _} = Projects.delete_assignment(top)
      assert listed(p) == [{"Next", 0, "todo"}]
    end

    test "a held task can be restored, with what is held under it" do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [line("Keep"), line("Held"), line("Held child", 1)], [])
      rows = Map.new(Projects.list_assignments(p.uuid), &{&1.task.title, &1})
      _ = Projects.update_assignment_form(rows["Held child"], %{"description" => "work"})

      {:ok, summary} =
        Outline.sync(
          p.uuid,
          [line("Keep", 0, rows["Keep"].uuid)],
          Enum.map(Map.values(rows), & &1.uuid)
        )

      assert Enum.sort(summary.held) == Enum.sort([rows["Held"].uuid, rows["Held child"].uuid])

      {:ok, _} = Outline.restore(Projects.get_assignment(rows["Held"].uuid))
      assert {"Held child", 1, "todo"} in listed(p)
    end
  end
end
