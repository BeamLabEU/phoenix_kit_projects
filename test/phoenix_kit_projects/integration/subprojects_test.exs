defmodule PhoenixKitProjects.Integration.SubprojectsTest do
  @moduledoc """
  Integration tests for sub-projects (V126): an assignment that embeds a child
  project via `child_project_uuid` instead of a task template. Covers creation,
  the task/child XOR + single-parent constraints, top-level list exclusion,
  rolled-up progress/completion propagation, and recursive teardown.
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  describe "create_subproject/2" do
    test "creates a child project and a linking assignment with no task" do
      parent = fixture_project()

      assert {:ok, %{child_project: child, assignment: link}} =
               Projects.create_subproject(parent.uuid, %{"name" => "Phase 1"})

      assert child.name == "Phase 1"
      refute child.is_template
      assert link.project_uuid == parent.uuid
      assert link.child_project_uuid == child.uuid
      assert is_nil(link.task_uuid)
      assert Assignment.subproject?(link)
    end

    test "rejects a blank child name without creating anything" do
      parent = fixture_project()
      before = Projects.count_projects()

      assert {:error, _} = Projects.create_subproject(parent.uuid, %{"name" => ""})
      assert Projects.count_projects() == before
    end

    test "allows sub-projects on a template — the child is a sub-template" do
      template = fixture_template()

      assert {:ok, %{child_project: child}} =
               Projects.create_subproject(template.uuid, %{"name" => "Phase"})

      assert child.is_template
      # Sub-templates are embedded; they don't clutter the templates list.
      refute child.uuid in Enum.map(Projects.list_templates(), & &1.uuid)
    end

    test "returns :parent_not_found for an unknown parent" do
      assert {:error, :parent_not_found} =
               Projects.create_subproject(UUIDv7.generate(), %{"name" => "Orphan"})
    end
  end

  describe "templates with sub-projects" do
    test "instantiating a template deep-clones its sub-project subtree" do
      template = fixture_template()
      task = fixture_task()

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => template.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, %{child_project: subtemplate}} =
        Projects.create_subproject(template.uuid, %{"name" => "Setup"})

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => subtemplate.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      assert {:ok, project} =
               Projects.create_project_from_template(template.uuid, %{"name" => "Real project"})

      refute project.is_template

      # Two assignments on the instance: the cloned task + the cloned sub-project link.
      assignments = Projects.list_assignments(project.uuid)
      assert length(assignments) == 2
      link = Enum.find(assignments, & &1.child_project_uuid)
      assert link

      # The cloned child is a FRESH, real (non-template) project — not the sub-template.
      cloned_child = Projects.get_project(link.child_project_uuid)
      refute cloned_child.is_template
      assert cloned_child.uuid != subtemplate.uuid
      assert cloned_child.name == "Setup"
      # …carrying the sub-template's own task.
      assert length(Projects.list_assignments(cloned_child.uuid)) == 1
    end

    test "the deep-clone carries the sub-project's settings + translations, not just its structure" do
      template = fixture_template()

      # A nested sub-project has no instantiation form, so the clone must copy
      # these project-level fields from the source or they're silently lost.
      {:ok, %{child_project: _}} =
        Projects.create_subproject(template.uuid, %{
          "name" => "Setup",
          "settings" => %{"use_status_translations" => true},
          "translations" => %{"bs" => %{"name" => "Postavke"}}
        })

      {:ok, project} =
        Projects.create_project_from_template(template.uuid, %{"name" => "Real project"})

      [link] = Enum.filter(Projects.list_assignments(project.uuid), & &1.child_project_uuid)
      cloned_child = Projects.get_project(link.child_project_uuid)

      assert cloned_child.settings == %{"use_status_translations" => true}
      assert cloned_child.translations == %{"bs" => %{"name" => "Postavke"}}
    end
  end

  describe "constraints" do
    test "the changeset rejects an assignment that is both a task and a sub-project" do
      project = fixture_project()
      task = fixture_task()
      child = fixture_project()

      cs =
        Assignment.changeset(%Assignment{}, %{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "child_project_uuid" => child.uuid,
          "status" => "todo"
        })

      refute cs.valid?
      assert %{child_project_uuid: _} = errors_on(cs)
    end

    test "the changeset rejects an assignment that is neither a task nor a sub-project" do
      project = fixture_project()

      cs =
        Assignment.changeset(%Assignment{}, %{
          "project_uuid" => project.uuid,
          "status" => "todo"
        })

      refute cs.valid?
      assert %{task_uuid: _} = errors_on(cs)
    end

    test "a project rejects more than one assignee (V127 single-assignee guard)" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "Assigned",
          "start_mode" => "immediate",
          "counts_weekends" => false,
          "assigned_team_uuid" => UUIDv7.generate(),
          "assigned_person_uuid" => UUIDv7.generate()
        })

      refute cs.valid?
      assert %{assigned_team_uuid: _} = errors_on(cs)
    end

    test "a project can be a sub-project of at most one parent" do
      parent_a = fixture_project()
      parent_b = fixture_project()
      {:ok, %{child_project: child}} = Projects.create_subproject(parent_a.uuid, %{"name" => "X"})

      cs =
        Assignment.subproject_changeset(%Assignment{}, %{
          project_uuid: parent_b.uuid,
          child_project_uuid: child.uuid,
          status: "todo"
        })

      assert {:error, cs} = repo().insert(cs)
      assert %{child_project_uuid: _} = errors_on(cs)
    end
  end

  describe "top-level listing" do
    test "sub-projects are hidden from list_projects but their parent is shown" do
      parent = fixture_project()
      {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => "Sub"})

      uuids = Projects.list_projects() |> Enum.map(& &1.uuid)

      assert parent.uuid in uuids
      refute child.uuid in uuids
    end
  end

  describe "rollup + completion propagation" do
    test "completing the child's only task marks the parent's sub-project row done and completes the parent" do
      parent = fixture_project()

      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Build it"})

      task = fixture_task(%{"estimated_duration" => 3, "estimated_duration_unit" => "hours"})

      {:ok, child_task} =
        Projects.create_assignment(%{
          "project_uuid" => child.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      # Complete the child's task and recompute — propagation should climb.
      {:ok, _} = Projects.complete_assignment(child_task, nil)
      assert {:completed, _} = Projects.recompute_project_completion(child.uuid)

      reloaded_link = Projects.get_assignment(link.uuid)
      assert reloaded_link.status == "done"
      assert reloaded_link.progress_pct == 100

      reloaded_parent = Projects.get_project(parent.uuid)
      refute is_nil(reloaded_parent.completed_at)
    end

    test "the sub-project's rolled-up hours count toward the parent's planned hours" do
      parent = fixture_project()

      {:ok, %{child_project: child}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Heavy"})

      task = fixture_task(%{"estimated_duration" => 10, "estimated_duration_unit" => "hours"})

      {:ok, _} =
        Projects.create_assignment(%{
          "project_uuid" => child.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      # Sync the rollup onto the parent's linking row, then read the parent summary.
      Projects.recompute_project_completion(child.uuid)

      summary = Projects.project_summary(Projects.get_project(parent.uuid))
      assert_in_delta summary.total_hours, 10.0, 0.5
    end
  end

  describe "teardown" do
    test "removing the sub-project assignment deletes the child project tree" do
      parent = fixture_project()

      {:ok, %{child_project: child, assignment: link}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Doomed"})

      assert {:ok, _} = Projects.delete_assignment(Projects.get_assignment(link.uuid))

      assert is_nil(Projects.get_project(child.uuid))
      assert is_nil(Projects.get_assignment(link.uuid))
    end

    test "deleting the parent project recursively removes its sub-projects" do
      parent = fixture_project()

      {:ok, %{child_project: child}} =
        Projects.create_subproject(parent.uuid, %{"name" => "Nested"})

      {:ok, %{child_project: grandchild}} =
        Projects.create_subproject(child.uuid, %{"name" => "Deep"})

      assert {:ok, _} = Projects.delete_project(Projects.get_project!(parent.uuid))

      assert is_nil(Projects.get_project(parent.uuid))
      assert is_nil(Projects.get_project(child.uuid))
      assert is_nil(Projects.get_project(grandchild.uuid))
    end
  end

  describe "link_subproject/2" do
    test "nests an existing standalone project under a parent, keeping the child" do
      parent = fixture_project()
      child = fixture_project()

      assert {:ok, %{child_project: linked, assignment: link}} =
               Projects.link_subproject(parent.uuid, child.uuid)

      assert linked.uuid == child.uuid
      assert link.project_uuid == parent.uuid
      assert link.child_project_uuid == child.uuid
      assert is_nil(link.task_uuid)
      # The child still exists as its own row — only a link was added.
      refute is_nil(Projects.get_project(child.uuid))
    end

    test "rejects nesting a project into itself" do
      project = fixture_project()
      assert {:error, :self_link} = Projects.link_subproject(project.uuid, project.uuid)
    end

    test "rejects mixing a template and a real project" do
      template = fixture_template()
      project = fixture_project()

      assert {:error, :kind_mismatch} = Projects.link_subproject(template.uuid, project.uuid)
      assert {:error, :kind_mismatch} = Projects.link_subproject(project.uuid, template.uuid)
    end

    test "rejects a link that would create a cycle (nesting an ancestor)" do
      grandparent = fixture_project()
      child = fixture_project()
      {:ok, _} = Projects.link_subproject(grandparent.uuid, child.uuid)

      # child → grandparent would close the loop grandparent → child → grandparent.
      assert {:error, :would_create_cycle} =
               Projects.link_subproject(child.uuid, grandparent.uuid)
    end

    test "rejects a project already nested under another parent" do
      parent_a = fixture_project()
      parent_b = fixture_project()
      child = fixture_project()
      {:ok, _} = Projects.link_subproject(parent_a.uuid, child.uuid)

      assert {:error, :already_subproject} =
               Projects.link_subproject(parent_b.uuid, child.uuid)
    end

    test "returns :not_found for an unknown parent or child" do
      project = fixture_project()
      assert {:error, :not_found} = Projects.link_subproject(UUIDv7.generate(), project.uuid)
      assert {:error, :not_found} = Projects.link_subproject(project.uuid, UUIDv7.generate())
    end
  end

  describe "available_projects_to_link/1" do
    test "lists standalone same-kind projects, excluding self, ancestors, and sub-projects" do
      parent = fixture_project()
      candidate = fixture_project()
      already_nested = fixture_project()
      a_template = fixture_template()
      {:ok, _} = Projects.link_subproject(parent.uuid, already_nested.uuid)

      uuids = parent |> Projects.available_projects_to_link() |> Enum.map(& &1.uuid)

      assert candidate.uuid in uuids
      refute parent.uuid in uuids
      refute already_nested.uuid in uuids
      refute a_template.uuid in uuids
    end
  end

  describe "detach_subproject/1" do
    test "removes only the linking assignment and leaves the child intact" do
      parent = fixture_project()
      child = fixture_project()
      {:ok, %{assignment: link}} = Projects.link_subproject(parent.uuid, child.uuid)

      assert {:ok, _} = Projects.detach_subproject(link)

      assert is_nil(Projects.get_assignment(link.uuid))
      refute is_nil(Projects.get_project(child.uuid))
      # Detached child is a candidate to be nested again.
      assert child.uuid in Enum.map(Projects.available_projects_to_link(parent), & &1.uuid)
    end
  end
end
