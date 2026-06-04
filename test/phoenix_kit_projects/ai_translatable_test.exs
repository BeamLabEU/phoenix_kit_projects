defmodule PhoenixKitProjects.AITranslatableTest do
  @moduledoc """
  Unit coverage for the projects `Translatable` adapter — the storage half of
  the AI-translation pipeline. No live `PhoenixKitAI` needed; fetch /
  source-field extraction / persist are tested directly against the DB.
  """

  use PhoenixKitProjects.DataCase, async: true

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitProjects.AITranslatable
  alias PhoenixKitProjects.Projects

  defp primary, do: Multilang.primary_language()

  describe "fetch/2 with is_template validation" do
    test "project type loads a real project, rejects a template" do
      project = fixture_project()
      template = fixture_template()

      assert {:ok, p} = AITranslatable.fetch("project", project.uuid)
      assert p.uuid == project.uuid
      assert {:error, :resource_type_mismatch} = AITranslatable.fetch("project", template.uuid)
    end

    test "template type loads a template, rejects a real project" do
      project = fixture_project()
      template = fixture_template()

      assert {:ok, t} = AITranslatable.fetch("template", template.uuid)
      assert t.uuid == template.uuid
      assert {:error, :resource_type_mismatch} = AITranslatable.fetch("template", project.uuid)
    end

    test "task type loads a task" do
      task = fixture_task()
      assert {:ok, t} = AITranslatable.fetch("task", task.uuid)
      assert t.uuid == task.uuid
    end

    test "missing row → :resource_not_found; unknown type → :unknown_resource_type" do
      assert {:error, :resource_not_found} =
               AITranslatable.fetch("project", "00000000-0000-0000-0000-000000000000")

      assert {:error, {:unknown_resource_type, "bogus"}} = AITranslatable.fetch("bogus", "x")
    end
  end

  describe "source_fields/2" do
    test "project reads name/description from columns when no override exists" do
      project = fixture_project(%{"name" => "Launch", "description" => "Q3 launch"})
      fields = AITranslatable.source_fields(project, primary())
      assert fields["name"] == "Launch"
      assert fields["description"] == "Q3 launch"
    end

    test "task reads its title field" do
      task = fixture_task(%{"title" => "Audit"})
      assert AITranslatable.source_fields(task, primary())["title"] == "Audit"
    end

    test "a secondary-language override is preferred over the column" do
      project =
        fixture_project(%{
          "name" => "Launch",
          "translations" => %{"es" => %{"name" => "Lanzamiento"}}
        })

      assert AITranslatable.source_fields(project, "es")["name"] == "Lanzamiento"
    end

    test "a blank/whitespace override falls back to the primary column" do
      project =
        fixture_project(%{"name" => "Launch", "translations" => %{"es" => %{"name" => "   "}}})

      assert AITranslatable.source_fields(project, "es")["name"] == "Launch"
    end

    test "blank source fields are skipped entirely" do
      project = fixture_project(%{"name" => "Launch", "description" => "   "})
      fields = AITranslatable.source_fields(project, primary())
      assert fields["name"] == "Launch"
      refute Map.has_key?(fields, "description")
    end
  end

  describe "put_translation/4" do
    test "merges into translations[lang] under plain field keys" do
      project = fixture_project()

      assert {:ok, _} =
               AITranslatable.put_translation(project, "es", %{"name" => "Lanzamiento"}, [])

      assert Projects.get_project(project.uuid).translations["es"]["name"] == "Lanzamiento"
    end

    test "a second write keeps sibling fields in the same lang" do
      project = fixture_project()
      {:ok, _} = AITranslatable.put_translation(project, "es", %{"name" => "Lanzamiento"}, [])
      fresh = Projects.get_project(project.uuid)
      {:ok, _} = AITranslatable.put_translation(fresh, "es", %{"description" => "Una cosa"}, [])

      reloaded = Projects.get_project(project.uuid)
      assert reloaded.translations["es"]["name"] == "Lanzamiento"
      assert reloaded.translations["es"]["description"] == "Una cosa"
    end

    test "force-stores a value identical to the source" do
      project = fixture_project(%{"name" => "ABC-1"})
      {:ok, _} = AITranslatable.put_translation(project, "es", %{"name" => "ABC-1"}, [])
      assert Projects.get_project(project.uuid).translations["es"]["name"] == "ABC-1"
    end

    test "persists a task translation under plain field keys" do
      task = fixture_task(%{"title" => "Audit"})
      assert {:ok, _} = AITranslatable.put_translation(task, "es", %{"title" => "Auditoría"}, [])
      assert Projects.get_task(task.uuid).translations["es"]["title"] == "Auditoría"
    end

    test "a row deleted mid-flight rolls back with :resource_not_found" do
      project = fixture_project()
      {:ok, _} = Projects.delete_project(project)

      assert {:error, :resource_not_found} =
               AITranslatable.put_translation(project, "es", %{"name" => "Lanzamiento"}, [])
    end
  end
end
