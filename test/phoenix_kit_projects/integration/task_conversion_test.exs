defmodule PhoenixKitProjects.Integration.TaskConversionTest do
  @moduledoc """
  Item 9: a task made a sub-project and back, in place — the row keeps
  its uuid, place, connections, comments, files and logged time; nothing
  is deleted, and the child project is archived on the way back.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Ledger, Outline, Projects, TaskConversion}
  alias PhoenixKitProjects.Schemas.{Assignment, Dependency, Project}

  defp task!(project, title, opts \\ []) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        Map.merge(
          %{"status" => Keyword.get(opts, :status, "todo"), "description" => opts[:description]},
          Keyword.get(opts, :attrs, %{})
        )
      )

    case Keyword.get(opts, :under) do
      nil -> Projects.get_assignment(a.uuid)
      parent -> elem(Outline.move(Projects.get_assignment(a.uuid), parent.uuid, :last), 1)
    end
  end

  setup do
    project = fixture_project(%{"start_mode" => "immediate", "name" => "Kitchen"})
    {:ok, _} = Projects.start_project(project)
    %{project: Projects.get_project!(project.uuid)}
  end

  test "a task becomes a sub-project and its subtasks the sub-project's tasks", %{project: p} do
    before = task!(p, "Measure")
    fit = task!(p, "Fit the worktop", description: "Oak, 40 mm")
    cut = task!(p, "Cut", under: fit)
    edge = task!(p, "Edge", under: cut)
    glue = task!(p, "Glue", under: fit)
    after_ = task!(p, "Clean up")
    {:ok, _} = Projects.add_dependency(fit.uuid, before.uuid)
    {:ok, _} = Projects.add_dependency(after_.uuid, fit.uuid)
    {:ok, _} = Ledger.log_time(p.uuid, 30, assignment_uuid: cut.uuid)

    assert {:ok, %{project: child, moved: 3}} = TaskConversion.to_subproject(fit)

    link = Projects.get_assignment(fit.uuid)
    assert link.child_project_uuid == child.uuid
    assert is_nil(link.task_uuid)
    assert link.position == fit.position
    assert child.name == "Fit the worktop"
    assert child.description == "Oak, 40 mm"

    # The connections hang off the row, so they are still there.
    deps = Repo.all(from(d in Dependency, select: {d.assignment_uuid, d.depends_on_uuid}))
    assert {fit.uuid, before.uuid} in deps
    assert {after_.uuid, fit.uuid} in deps

    # The subtasks are the child's, nested as they were, newly numbered.
    rows = Projects.list_assignments(child.uuid)
    assert Enum.map(rows, & &1.uuid) |> Enum.sort() == Enum.sort([cut.uuid, edge.uuid, glue.uuid])
    by = Map.new(rows, &{&1.uuid, &1})
    assert by[cut.uuid].parent_uuid == nil
    assert by[edge.uuid].parent_uuid == cut.uuid
    assert by[glue.uuid].parent_uuid == nil
    assert rows |> Enum.map(& &1.number) |> Enum.sort() == [1, 2, 3]

    # The logged time went with its task.
    [entry] = Ledger.list_entries(child.uuid)
    assert entry.assignment_uuid == cut.uuid

    # A new task in the child takes the next number, not one in use.
    new = task!(child, "Seal")
    assert new.number == 4
  end

  test "a sub-project becomes a task again and the project is archived", %{project: p} do
    first = task!(p, "Measure")
    fit = task!(p, "Fit the worktop")
    cut = task!(p, "Cut", under: fit)
    last = task!(p, "Clean up")
    {:ok, _} = Projects.add_dependency(last.uuid, fit.uuid)
    {:ok, %{project: child}} = TaskConversion.to_subproject(fit)
    seal = task!(child, "Seal", status: "done")

    link = Projects.get_assignment(fit.uuid)
    assert {:ok, %{moved: 2}} = TaskConversion.to_task(link)

    row = Projects.get_assignment(fit.uuid)
    assert is_nil(row.child_project_uuid)
    assert row.task.title == "Fit the worktop"

    rows = Projects.list_assignments(p.uuid)
    order = Enum.map(rows, & &1.uuid)
    assert order == [first.uuid, fit.uuid, cut.uuid, seal.uuid, last.uuid]
    by = Map.new(rows, &{&1.uuid, &1})
    assert by[cut.uuid].parent_uuid == fit.uuid
    assert by[seal.uuid].parent_uuid == fit.uuid
    assert by[seal.uuid].status == "done"
    numbers = Enum.map(rows, & &1.number)
    assert numbers == Enum.uniq(numbers)

    # Archived, never deleted; the connection is still on the row.
    assert %Project{archived_at: %DateTime{}} = Repo.get(Project, child.uuid)

    assert Repo.exists?(
             from(d in Dependency,
               where: d.assignment_uuid == ^last.uuid and d.depends_on_uuid == ^fit.uuid
             )
           )

    assert Repo.exists?(from(a in Assignment, where: a.uuid == ^cut.uuid))
  end

  test "a sub-project holding sub-projects of its own stays one", %{project: p} do
    fit = task!(p, "Fit")
    {:ok, %{project: child}} = TaskConversion.to_subproject(fit)
    {:ok, _} = Projects.create_subproject(child.uuid, %{"name" => "Deeper"})

    assert TaskConversion.to_task(Projects.get_assignment(fit.uuid)) ==
             {:error, :has_subprojects}

    assert TaskConversion.to_subproject(Projects.get_assignment(fit.uuid)) ==
             {:error, :not_a_task}
  end

  # A sub-project row cannot come back as a next occurrence (`Repeats`
  # copies a task), so the rule does not travel with the row: left on it,
  # the sub-project's finish would try to repeat and fail every time.
  test "a repeating task made a sub-project stops repeating", %{project: p} do
    weekly = task!(p, "Check in", attrs: %{"repeat_rule" => %{"every" => 1, "unit" => "week"}})
    assert weekly.repeat_rule == %{"every" => 1, "unit" => "week"}

    assert {:ok, _} = TaskConversion.to_subproject(weekly)
    assert Projects.get_assignment(weekly.uuid).repeat_rule == nil
  end
end
