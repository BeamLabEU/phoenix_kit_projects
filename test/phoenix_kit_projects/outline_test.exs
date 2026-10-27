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
               {"Buy", 0, "waiting"},
               {"Milk", 1, "waiting"},
               {"Eggs", 1, "waiting"},
               {"Call", 0, "waiting"}
             ]

      # Every task has a number from the moment it exists.
      assert Enum.all?(Map.values(created), &is_integer(&1.number))
    end

    test "blank lines are not tasks, and a jump of two levels is one" do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [line("A"), line("   "), line("B", 3)], [])
      assert listed(p) == [{"A", 0, "waiting"}, {"B", 1, "waiting"}]
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
      assert listed(p) == [{"Second", 0, "waiting"}, {"First, renamed", 0, "waiting"}]
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
      assert listed(p) == [{"Keep", 0, "waiting"}]
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
      assert listed(p) == [{"Other", 0, "waiting"}, {"Moved", 1, "waiting"}]
      assert Projects.get_assignment(a.uuid).number == a.number
    end

    test "a parent's line removed while its subtask's line stays: the subtask survives" do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [line("Parent"), line("Child", 1)], [])
      [parent, child] = Projects.list_assignments(p.uuid)

      {:ok, summary} =
        Outline.sync(p.uuid, [line("Child", 0, child.uuid)], [parent.uuid, child.uuid])

      assert summary.removed == [parent.uuid]
      assert listed(p) == [{"Child", 0, "waiting"}]
    end

    test "malformed lines are skipped, never a crash" do
      p = project()
      long = String.duplicate("x", 600)

      {:ok, %{created: created}} =
        Outline.sync(
          p.uuid,
          [
            "not a map",
            %{"text" => %{"nested" => true}},
            %{"text" => "  Café 🎨\t—  日本  ", "depth" => "0"},
            %{"text" => long, "depth" => -3},
            %{"text" => "Under", "depth" => "1"},
            %{"text" => "Nil depth", "depth" => nil}
          ],
          []
        )

      # No `tmp` on these lines, so nothing to report back — but made.
      assert created == %{}
      [cafe, longest, under, nil_depth] = listed(p)
      assert cafe == {"Café 🎨 — 日本", 0, "waiting"}
      assert String.length(elem(longest, 0)) == 500
      assert under == {"Under", 1, "waiting"}
      assert nil_depth == {"Nil depth", 0, "waiting"}
    end

    test "too many lines, or a project that is gone, is an error" do
      p = project()
      lines = for i <- 1..2001, do: line("L#{i}")
      assert {:error, :too_many_lines} = Outline.sync(p.uuid, lines, [])
      assert {:error, :not_found} = Outline.sync(Ecto.UUID.generate(), [line("x")], [])
    end

    test "a new line arrives ticked only when ticking is allowed" do
      p = project()
      ticked = %{"text" => "Done already", "done" => true}
      {:ok, _} = Outline.sync(p.uuid, [ticked], [], allow_done: false)
      assert listed(p) == [{"Done already", 0, "waiting"}]
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
      assert {"Parent", 0, "waiting"} in listed(p)

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
      assert {"Parent", 0, "waiting"} in listed(p)
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

  describe "a status changed through the form" do
    test "ticking the last task there completes the project; reopening clears the stamps" do
      p =
        fixture_project(%{
          "name" => "Form #{System.unique_integer([:positive])}",
          "start_mode" => "immediate"
        })

      a = task(p, "Only one")

      {:ok, done} = Projects.update_assignment_form(a, %{"status" => "done"})
      assert done.completed_at
      assert done.progress_pct == 100
      assert Projects.get_project(p.uuid).completed_at

      {:ok, reopened} = Projects.update_assignment_form(done, %{"status" => "todo"})
      assert reopened.completed_at == nil
      assert reopened.progress_pct == 0
      assert Projects.get_assignment(a.uuid).completed_at == nil
      assert Projects.get_project(p.uuid).completed_at == nil
    end
  end

  describe "move/3 and delete" do
    test "a branch moves whole, and nothing goes under itself" do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [line("A"), line("A1", 1), line("B")], [])
      t = Map.new(Projects.list_assignments(p.uuid), &{&1.task.title, &1})

      {:ok, _} = Outline.move(t["A"], t["B"].uuid, :last)
      assert listed(p) == [{"B", 0, "waiting"}, {"A", 1, "waiting"}, {"A1", 2, "waiting"}]

      assert {:error, :cycle} =
               Outline.move(Projects.get_assignment(t["B"].uuid), t["A1"].uuid, :last)
    end

    test "the database refuses a parent in another project, and the form cannot set one" do
      p = project()
      a = task(p, "Here")
      there = task(project(), "There")

      # Not castable: a place in the list goes through Outline.move/3.
      {:ok, unchanged} = Projects.update_assignment_form(a, %{"parent_uuid" => there.uuid})
      assert unchanged.parent_uuid == nil

      result =
        a
        |> Ecto.Changeset.change(parent_uuid: there.uuid)
        |> Ecto.Changeset.check_constraint(:parent_uuid,
          name: :phoenix_kit_project_assignments_parent_project
        )
        |> PhoenixKit.RepoHelper.repo().update()

      assert {:error, cs} = result
      assert cs.errors[:parent_uuid]
    end

    test "nothing goes under a sub-project row" do
      p = project()
      a = task(p, "Task")
      {:ok, %{assignment: link}} = Projects.create_subproject(p.uuid, %{"name" => "Child"})

      assert {:error, :subproject} = Outline.move(a, link.uuid, :last)

      {:ok, _} =
        Outline.sync(p.uuid, [line("Child", 0, link.uuid), line("Task", 1, a.uuid)], [])

      assert Projects.get_assignment(a.uuid).parent_uuid == nil
    end

    test "moving the last open subtask out ticks the parent it leaves" do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [line("Parent"), line("Done", 1), line("Open", 1)], [])
      t = Map.new(Projects.list_assignments(p.uuid), &{&1.task.title, &1})
      {:ok, _} = Projects.complete_assignment(t["Done"], nil)

      {:ok, _} = Outline.move(Projects.get_assignment(t["Open"].uuid), nil, :last)
      assert Projects.get_assignment(t["Parent"].uuid).status == "done"
    end

    test "deleting a task deletes what is under it" do
      p = project()

      {:ok, _} =
        Outline.sync(p.uuid, [line("Top"), line("Under", 1), line("Deeper", 2), line("Next")], [])

      top = Enum.find(Projects.list_assignments(p.uuid), &(&1.task.title == "Top"))

      {:ok, _} = Projects.delete_assignment(top)
      assert listed(p) == [{"Next", 0, "waiting"}]
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
      assert {"Held child", 1, "waiting"} in listed(p)
    end
  end
end
