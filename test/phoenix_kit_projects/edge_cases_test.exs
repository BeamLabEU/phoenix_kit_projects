defmodule PhoenixKitProjects.EdgeCasesTest do
  @moduledoc """
  Edge-case coverage on the schemas the original sweep didn't pin:
  Unicode (CJK / emoji / RTL), SQL metacharacters in free-text fields,
  >255-char rejection on name/title fields, and the `recompute_project_completion/1`
  transaction wrapper. Per the post-Apr 2026 pipeline standard —
  happy-path bias is a forbidden test smell; every free-text field
  needs at least one weird-input round-trip.
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Project

  describe "Project.changeset/2 edge cases" do
    test "Unicode CJK + emoji + RTL round-trips through name" do
      # Use \u escapes to keep the source file free of bidirectional
      # formatting characters (Elixir 1.18+ rejects U+202E / U+202C
      # in source). The string still contains them at runtime.
      rtl_name = "プロジェクト \u202eOWASP\u202c 🎉"

      attrs = %{
        "name" => rtl_name,
        "is_template" => "false",
        "start_mode" => "immediate",
        "status" => "active"
      }

      assert {:ok, project} = Projects.create_project(attrs)
      assert project.name == rtl_name

      reread = Projects.get_project!(project.uuid)
      assert reread.name == rtl_name
    end

    test "SQL metacharacters in name are stored as literals" do
      sql_meta = "Robert'); DROP TABLE projects; --"

      assert {:ok, project} =
               Projects.create_project(%{
                 "name" => sql_meta,
                 "is_template" => "false",
                 "start_mode" => "immediate",
                 "status" => "active"
               })

      assert Projects.get_project!(project.uuid).name == sql_meta
    end

    test "rejects name >255 chars with a clean changeset error (no raise)" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => String.duplicate("x", 256),
          "is_template" => "false",
          "start_mode" => "immediate",
          "status" => "active"
        })

      refute cs.valid?
      assert "should be at most 255 character(s)" in errors_on(cs).name
    end

    test "blank name rejected via validate_required" do
      cs =
        Project.changeset(%Project{}, %{
          "name" => "",
          "is_template" => "false",
          "start_mode" => "immediate",
          "status" => "active"
        })

      refute cs.valid?
      assert "can't be blank" in errors_on(cs).name
    end
  end

  describe "Task.changeset/2 edge cases" do
    test "Unicode + emoji round-trip through title" do
      attrs = %{
        "title" => "デザイン 🚀 Сборка",
        "estimated_duration" => 1,
        "estimated_duration_unit" => "hours"
      }

      assert {:ok, task} = Projects.create_task(attrs)
      assert task.title == "デザイン 🚀 Сборка"

      assert Projects.get_task!(task.uuid).title == "デザイン 🚀 Сборка"
    end

    test "SQL metacharacters in title stored verbatim" do
      attrs = %{
        "title" => "1' OR '1'='1",
        "estimated_duration" => 1,
        "estimated_duration_unit" => "hours"
      }

      assert {:ok, task} = Projects.create_task(attrs)
      assert task.title == "1' OR '1'='1"
    end
  end

  describe "recompute_project_completion/1 transaction wrapper" do
    test "is no-op on a non-existent project (returns :ok inside the tx)" do
      # Wrapped in `repo().transaction(...)` — the read returns nil,
      # the inner block returns :ok, the transaction commits :ok, and
      # the outer pattern unwraps to :ok.
      assert Projects.recompute_project_completion(Ecto.UUID.generate()) == :ok
    end

    test "is no-op on a template project (`is_template: true`)" do
      template = fixture_template()
      assert Projects.recompute_project_completion(template.uuid) == :ok
    end

    test "transitions a project to :completed when all assignments are done" do
      project = fixture_project(%{"start_mode" => "immediate", "status" => "active"})
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "done"
        })

      # Touch the project so it has a started_at (recompute_project_completion
      # only flips for projects that have at least one assignment in done state).
      assert {:completed, updated} = Projects.recompute_project_completion(project.uuid)
      assert updated.completed_at != nil

      # And the broadcast fires — verify the recomputed result, not the
      # broadcast itself (broadcasts_test.exs already covers that path).
      _ = assignment
    end
  end
end
