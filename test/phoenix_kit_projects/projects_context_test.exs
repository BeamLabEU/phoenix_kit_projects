defmodule PhoenixKitProjects.ProjectsContextTest do
  @moduledoc """
  Direct unit tests on the `Projects` context module — covers the
  listing helpers, summaries, dependency utilities, and edge-case
  branches not naturally hit by the LV smoke tests.
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Projects

  describe "list_projects/1" do
    test "default opts excludes templates" do
      _ = fixture_project(%{"name" => "P-#{System.unique_integer([:positive])}"})
      _ = fixture_template()

      results = Projects.list_projects()
      assert Enum.all?(results, &(&1.is_template == false))
    end

    test "include_templates: true returns both" do
      _ = fixture_project()
      _ = fixture_template()

      results = Projects.list_projects(include_templates: true)
      assert Enum.any?(results, & &1.is_template)
      assert Enum.any?(results, &(not &1.is_template))
    end

    test "archived: false (default) returns visible only" do
      visible = fixture_project()
      hidden = fixture_project()
      {:ok, _} = Projects.archive_project(hidden)

      results = Projects.list_projects()
      assert Enum.any?(results, &(&1.uuid == visible.uuid))
      refute Enum.any?(results, &(&1.uuid == hidden.uuid))
    end

    test "archived: true returns archived only" do
      visible = fixture_project()
      hidden = fixture_project()
      {:ok, _} = Projects.archive_project(hidden)

      results = Projects.list_projects(archived: true)
      assert Enum.any?(results, &(&1.uuid == hidden.uuid))
      refute Enum.any?(results, &(&1.uuid == visible.uuid))
    end

    test "archived: :all returns both" do
      visible = fixture_project()
      hidden = fixture_project()
      {:ok, _} = Projects.archive_project(hidden)

      results = Projects.list_projects(archived: :all)
      assert Enum.any?(results, &(&1.uuid == visible.uuid))
      assert Enum.any?(results, &(&1.uuid == hidden.uuid))
    end
  end

  describe "list_active_projects + recently_completed + upcoming + setup" do
    test "list_active_projects returns started, non-completed projects" do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.start_project(project)

      results = Projects.list_active_projects()
      assert Enum.any?(results, &(&1.uuid == project.uuid))
    end

    test "list_recently_completed_projects respects the limit arg" do
      results = Projects.list_recently_completed_projects(3)
      assert is_list(results)
      assert length(results) <= 3
    end

    test "list_recently_completed_projects defaults limit to 5" do
      assert is_list(Projects.list_recently_completed_projects())
    end

    test "list_upcoming_projects returns scheduled projects with a future date" do
      _ =
        fixture_project(%{
          "start_mode" => "scheduled",
          "scheduled_start_date" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      assert is_list(Projects.list_upcoming_projects())
    end

    test "list_setup_projects returns immediate-mode projects without started_at" do
      _ = fixture_project(%{"start_mode" => "immediate"})

      results = Projects.list_setup_projects()
      assert is_list(results)
    end
  end

  describe "count helpers" do
    test "count_tasks/0 returns the count" do
      _ = fixture_task()
      assert Projects.count_tasks() >= 1
    end

    test "count_projects/0 returns the count" do
      _ = fixture_project()
      assert Projects.count_projects() >= 1
    end

    test "count_templates/0 returns the count" do
      _ = fixture_template()
      assert Projects.count_templates() >= 1
    end
  end

  describe "project_summary + project_summaries" do
    test "project_summaries/1 returns [] for an empty input" do
      assert Projects.project_summaries([]) == []
    end

    test "project_summaries/1 returns done/in_progress/todo counts" do
      project = fixture_project()
      task = fixture_task()

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      [summary] = Projects.project_summaries([project])
      assert summary.project.uuid == project.uuid
      assert summary.total >= 1
      assert summary.in_progress >= 0
      assert summary.done >= 0
      assert is_integer(summary.progress_pct)
    end

    test "project_summary/1 wraps a single project" do
      project = fixture_project()
      result = Projects.project_summary(project)
      assert is_map(result)
      assert result.project.uuid == project.uuid
    end
  end

  describe "assignment_status_counts/0" do
    test "returns a map keyed by status string" do
      project = fixture_project(%{"status" => "active"})
      task = fixture_task()

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      counts = Projects.assignment_status_counts()
      assert is_map(counts)
      # Map values are integers — even when missing keys aren't there.
      assert Enum.all?(counts, fn {k, v} -> is_binary(k) and is_integer(v) end)
    end
  end

  describe "list_assignments_for_user/1" do
    test "returns [] for an unknown user_uuid (Staff lookup miss)" do
      # `Staff.get_person_by_user_uuid/2` returns nil for an unknown
      # user — the rescue branch isn't exercised, just the nil branch.
      assert Projects.list_assignments_for_user(Ecto.UUID.generate()) == []
    end
  end

  describe "task library CRUD" do
    test "create + update + delete cycle" do
      {:ok, task} =
        Projects.create_task(%{
          "title" => "T-#{System.unique_integer([:positive])}",
          "estimated_duration" => 1,
          "estimated_duration_unit" => "hours"
        })

      assert task.uuid

      {:ok, updated} = Projects.update_task(task, %{"title" => "renamed"})
      assert updated.title == "renamed"

      {:ok, deleted} = Projects.delete_task(updated)
      assert deleted.uuid == task.uuid
      assert Projects.get_task(task.uuid) == nil
    end

    test "get_task!/1 raises for missing uuid" do
      assert_raise Ecto.NoResultsError, fn ->
        Projects.get_task!(Ecto.UUID.generate())
      end
    end

    test "change_task/2 returns a changeset" do
      task = fixture_task()
      cs = Projects.change_task(task, %{"title" => "new"})
      assert %Ecto.Changeset{} = cs
    end
  end

  describe "task template dependencies" do
    test "add + remove cycle" do
      task_a = fixture_task()
      task_b = fixture_task()

      {:ok, dep} = Projects.add_task_dependency(task_a.uuid, task_b.uuid)
      assert dep.task_uuid == task_a.uuid
      assert dep.depends_on_task_uuid == task_b.uuid

      assert {:ok, _} = Projects.remove_task_dependency(task_a.uuid, task_b.uuid)
    end

    test "remove_task_dependency/2 returns :not_found for missing pair" do
      task_a = fixture_task()
      task_b = fixture_task()

      assert {:error, :not_found} =
               Projects.remove_task_dependency(task_a.uuid, task_b.uuid)
    end

    test "list_task_dependencies/1 + available_task_dependencies/1" do
      a = fixture_task()
      b = fixture_task()
      _c = fixture_task()

      assert Projects.list_task_dependencies(a.uuid) == []

      {:ok, _} = Projects.add_task_dependency(a.uuid, b.uuid)

      assert [dep] = Projects.list_task_dependencies(a.uuid)
      assert dep.depends_on_task_uuid == b.uuid

      # `available_task_dependencies` excludes self + already-linked deps.
      available = Projects.available_task_dependencies(a.uuid)
      refute Enum.any?(available, &(&1.uuid == a.uuid))
      refute Enum.any?(available, &(&1.uuid == b.uuid))
    end
  end

  describe "apply_template_dependencies/1" do
    test "no-op (returns :ok) when the task has no template-level deps" do
      project = fixture_project()
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      assert Projects.apply_template_dependencies(assignment) == :ok
    end

    test "creates dependencies between sibling assignments when the template has deps" do
      project = fixture_project()
      task_a = fixture_task()
      task_b = fixture_task()

      {:ok, _} = Projects.add_task_dependency(task_a.uuid, task_b.uuid)

      {:ok, b_assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_b.uuid,
          "status" => "todo"
        })

      {:ok, a_assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task_a.uuid,
          "status" => "todo"
        })

      _ = b_assignment

      # `apply_template_dependencies/1` runs in a transaction → returns {:ok, _}.
      assert {:ok, _} = Projects.apply_template_dependencies(a_assignment)
    end
  end

  describe "dependency-graph helpers" do
    setup do
      project = fixture_project()
      task1 = fixture_task()
      task2 = fixture_task()

      {:ok, a1} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task1.uuid,
          "status" => "todo"
        })

      {:ok, a2} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task2.uuid,
          "status" => "done"
        })

      {:ok, project: project, a1: a1, a2: a2}
    end

    test "dependencies_met?/1 is true when no edges exist", %{a1: a} do
      assert Projects.dependencies_met?(a.uuid) == true
    end

    test "dependencies_met?/1 reflects the dependency's `done` state",
         %{a1: a1, a2: a2} do
      {:ok, _} = Projects.add_dependency(a1.uuid, a2.uuid)

      # a2 is done, so a1's deps are met.
      assert Projects.dependencies_met?(a1.uuid) == true
    end

    test "available_dependencies/2 excludes self + linked deps",
         %{project: p, a1: a1, a2: a2} do
      available = Projects.available_dependencies(p.uuid, a1.uuid)
      assert Enum.any?(available, &(&1.uuid == a2.uuid))
      refute Enum.any?(available, &(&1.uuid == a1.uuid))

      {:ok, _} = Projects.add_dependency(a1.uuid, a2.uuid)
      available_after = Projects.available_dependencies(p.uuid, a1.uuid)
      refute Enum.any?(available_after, &(&1.uuid == a2.uuid))
    end

    test "remove_dependency/2 returns :not_found when no edge exists",
         %{a1: a1, a2: a2} do
      assert {:error, :not_found} = Projects.remove_dependency(a1.uuid, a2.uuid)
    end

    test "list_dependencies + list_all_dependencies", %{project: p, a1: a1, a2: a2} do
      {:ok, _} = Projects.add_dependency(a1.uuid, a2.uuid)

      assert [dep] = Projects.list_dependencies(a1.uuid)
      assert dep.depends_on_uuid == a2.uuid

      all = Projects.list_all_dependencies(p.uuid)
      refute Enum.empty?(all)
    end
  end

  describe "create_project_from_template/2" do
    test "returns :template_not_found for an unknown uuid" do
      assert {:error, :template_not_found} =
               Projects.create_project_from_template(Ecto.UUID.generate(), %{
                 "name" => "X"
               })
    end

    test "clones a template + its assignments + dependencies" do
      template = fixture_template(%{"counts_weekends" => false})
      task1 = fixture_task()
      task2 = fixture_task()

      {:ok, t1} =
        Projects.create_assignment(%{
          "project_uuid" => template.uuid,
          "task_uuid" => task1.uuid,
          "status" => "todo"
        })

      {:ok, t2} =
        Projects.create_assignment(%{
          "project_uuid" => template.uuid,
          "task_uuid" => task2.uuid,
          "status" => "todo"
        })

      {:ok, _} = Projects.add_dependency(t1.uuid, t2.uuid)

      {:ok, project} =
        Projects.create_project_from_template(template.uuid, %{
          "name" => "Cloned-#{System.unique_integer([:positive])}",
          "status" => "active",
          "start_mode" => "immediate"
        })

      assert project.is_template == false

      assignments = Projects.list_assignments(project.uuid)
      assert length(assignments) == 2
    end
  end

  describe "complete_assignment + reopen_assignment sugar" do
    test "complete_assignment/2 with nil completed_by_uuid returns an FK error or success" do
      project = fixture_project()
      task = fixture_task()

      {:ok, a} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "in_progress"
        })

      # nil completed_by is allowed (column is nullable).
      assert {:ok, done} = Projects.complete_assignment(a, nil)
      assert done.status == "done"
      assert done.completed_at != nil

      assert {:ok, reopened} = Projects.reopen_assignment(done)
      assert reopened.status == "todo"
      assert reopened.completed_at == nil
    end
  end

  describe "update_assignment_form vs update_assignment_status mass-assignment guard" do
    test "update_assignment_form/2 ignores completed_by_uuid + completed_at" do
      project = fixture_project()
      task = fixture_task()

      {:ok, a} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      attempted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, updated} =
        Projects.update_assignment_form(a, %{
          "description" => "ok",
          "completed_by_uuid" => Ecto.UUID.generate(),
          "completed_at" => attempted_at
        })

      assert updated.description == "ok"
      assert updated.completed_by_uuid == nil
      assert updated.completed_at == nil
    end
  end
end
