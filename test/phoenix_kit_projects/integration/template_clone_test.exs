defmodule PhoenixKitProjects.Integration.TemplateCloneTest do
  @moduledoc """
  Integration tests for `create_project_from_template/2`:

    - happy path copies all assignments and dependencies atomically
    - transaction rolls back if cloning fails partway
    - missing template returns `{:error, :template_not_found}`
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Project

  defp build_template do
    {:ok, template} =
      Projects.create_project(%{
        "name" => "Template #{System.unique_integer([:positive])}",
        "status" => "active",
        "start_mode" => "immediate",
        "is_template" => "true",
        "counts_weekends" => "false"
      })

    {:ok, t1} = Projects.create_task(%{"title" => "Setup #{System.unique_integer([:positive])}"})
    {:ok, t2} = Projects.create_task(%{"title" => "Build #{System.unique_integer([:positive])}"})

    {:ok, a1} =
      Projects.create_assignment(%{
        "project_uuid" => template.uuid,
        "task_uuid" => t1.uuid,
        "status" => "todo"
      })

    {:ok, a2} =
      Projects.create_assignment(%{
        "project_uuid" => template.uuid,
        "task_uuid" => t2.uuid,
        "status" => "todo"
      })

    {:ok, _} = Projects.add_dependency(a2.uuid, a1.uuid)

    %{template: template, tasks: [t1, t2], assignments: [a1, a2]}
  end

  describe "happy path" do
    test "clones assignments and dependencies into a new project" do
      %{template: template} = build_template()

      {:ok, project} =
        Projects.create_project_from_template(template.uuid, %{
          "name" => "Clone #{System.unique_integer([:positive])}",
          "status" => "active",
          "start_mode" => "immediate"
        })

      assert %Project{is_template: false} = project
      assert project.counts_weekends == template.counts_weekends

      new_assignments = Projects.list_assignments(project.uuid)
      assert length(new_assignments) == 2
      # All cloned assignments start in "todo" regardless of source state.
      assert Enum.all?(new_assignments, &(&1.status == "todo"))

      new_deps = Projects.list_all_dependencies(project.uuid)
      assert length(new_deps) == 1
    end

    test "returns :template_not_found when template uuid does not exist" do
      assert {:error, :template_not_found} =
               Projects.create_project_from_template(UUIDv7.generate(), %{
                 "name" => "Nope",
                 "status" => "active",
                 "start_mode" => "immediate"
               })
    end
  end

  describe "transaction rollback" do
    test "a duplicate-name project attrs causes rollback and leaves no orphans" do
      %{template: template} = build_template()

      # First clone succeeds.
      {:ok, _first} =
        Projects.create_project_from_template(template.uuid, %{
          "name" => "Clone-fixed",
          "status" => "active",
          "start_mode" => "immediate"
        })

      projects_before = Projects.count_projects()
      tasks_before = Projects.count_tasks()

      # Second clone tries to reuse the same project name → unique_constraint
      # error on the project insert → full rollback.
      {:error, %Ecto.Changeset{data: %Project{}} = cs} =
        Projects.create_project_from_template(template.uuid, %{
          "name" => "Clone-fixed",
          "status" => "active",
          "start_mode" => "immediate"
        })

      assert %{name: [_ | _]} = errors_on(cs)
      assert Projects.count_projects() == projects_before
      assert Projects.count_tasks() == tasks_before
    end
  end

  describe "V105 partial-index name uniqueness (template vs project)" do
    test "a template and a real project can share the same name" do
      shared_name = "Shared-#{System.unique_integer([:positive])}"

      assert {:ok, %Project{is_template: true}} =
               Projects.create_project(%{
                 "name" => shared_name,
                 "status" => "active",
                 "start_mode" => "immediate",
                 "is_template" => "true"
               })

      # Same name, real project — used to collide on the single global
      # `phoenix_kit_projects_name_index`. After V105 split it into two
      # partial indexes (one per `is_template` value), this insert
      # should succeed.
      assert {:ok, %Project{is_template: false}} =
               Projects.create_project(%{
                 "name" => shared_name,
                 "status" => "active",
                 "start_mode" => "immediate",
                 "is_template" => "false"
               })
    end

    test "two templates with the same name still collide" do
      shared_name = "Collide-tpl-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Projects.create_project(%{
          "name" => shared_name,
          "status" => "active",
          "start_mode" => "immediate",
          "is_template" => "true"
        })

      {:error, cs} =
        Projects.create_project(%{
          "name" => shared_name,
          "status" => "active",
          "start_mode" => "immediate",
          "is_template" => "true"
        })

      assert %{name: ["already taken" | _]} = errors_on(cs)
    end

    test "two real projects with the same name still collide" do
      shared_name = "Collide-proj-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Projects.create_project(%{
          "name" => shared_name,
          "status" => "active",
          "start_mode" => "immediate",
          "is_template" => "false"
        })

      {:error, cs} =
        Projects.create_project(%{
          "name" => shared_name,
          "status" => "active",
          "start_mode" => "immediate",
          "is_template" => "false"
        })

      assert %{name: ["already taken" | _]} = errors_on(cs)
    end
  end
end
