defmodule PhoenixKitProjects.Web.MultilangFormsTest do
  @moduledoc """
  What is typed on a language tab survives the save and reaches the read
  pages, on a host whose Languages module registers dialect codes (`es-ES`).

  Every form folds its tabs through `Web.Helpers.merge_translations_attrs/3`
  from the in-flight changeset, so the words typed on one tab live only there
  until the save, and the tab that saves may post none of them.
  """
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  setup %{conn: conn} do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("es-ES")

    %{conn: put_test_scope(conn, fake_scope()), primary: Multilang.primary_language()}
  end

  # Applies a tab the way the debounced `switch_language` does, without the wait.
  defp open_tab(view, lang) do
    send(view.pid, {:__multilang_apply_lang__, lang})
    render(view)
  end

  defp edit_project(conn, project) do
    {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")
    view
  end

  defp project_fields(project) do
    %{name: project.name, start_mode: project.start_mode, counts_weekends: "false"}
  end

  defp type_project_name(view, text) do
    view
    |> form("#project-form", project: %{translations: %{"es-ES" => %{name: text}}})
    |> render_change()
  end

  describe "the project form" do
    test "a translation reaches a viewer on that dialect", %{conn: conn} do
      project = fixture_project(%{"name" => "KitchenPRIMARY"})
      view = edit_project(conn, project)

      open_tab(view, "es-ES")

      view
      |> form("#project-form", project: %{translations: %{"es-ES" => %{name: "CocinaES"}}})
      |> render_submit()

      {:ok, _view, html} = conn |> with_request_locale("es-ES") |> live("/en/admin/projects")

      assert html =~ "CocinaES"
      refute html =~ "KitchenPRIMARY"
    end

    test "a translation survives a save from the primary tab", ctx do
      project = fixture_project(%{"name" => "Kitchen"})
      view = edit_project(ctx.conn, project)

      open_tab(view, "es-ES")
      type_project_name(view, "CocinaES")
      open_tab(view, ctx.primary)

      view |> form("#project-form", project: project_fields(project)) |> render_submit()

      assert Projects.get_project(project.uuid).translations["es-ES"]["name"] == "CocinaES"
    end

    test "a translation survives a primary-tab validate before the save", ctx do
      project = fixture_project(%{"name" => "Kitchen"})
      view = edit_project(ctx.conn, project)

      open_tab(view, "es-ES")
      type_project_name(view, "CocinaES")
      open_tab(view, ctx.primary)

      view
      |> form("#project-form", project: %{project_fields(project) | name: "Kitchen 2"})
      |> render_change()

      view
      |> form("#project-form", project: %{project_fields(project) | name: "Kitchen 2"})
      |> render_submit()

      reloaded = Projects.get_project(project.uuid)
      assert reloaded.name == "Kitchen 2"
      assert reloaded.translations["es-ES"]["name"] == "CocinaES"
    end

    test "a blanked translation is removed", %{conn: conn} do
      project =
        fixture_project(%{
          "name" => "Kitchen",
          "translations" => %{"es-ES" => %{"name" => "Cocina", "description" => "Palabras"}}
        })

      view = edit_project(conn, project)
      open_tab(view, "es-ES")

      view
      |> form("#project-form", project: %{translations: %{"es-ES" => %{name: ""}}})
      |> render_submit()

      assert Projects.get_project(project.uuid).translations == %{
               "es-ES" => %{"description" => "Palabras"}
             }
    end

    test "the last blanked translation stays gone through a save from the primary tab", ctx do
      project =
        fixture_project(%{
          "name" => "Kitchen",
          "translations" => %{"es-ES" => %{"name" => "Cocina"}}
        })

      view = edit_project(ctx.conn, project)

      open_tab(view, "es-ES")
      type_project_name(view, "")
      open_tab(view, ctx.primary)

      view |> form("#project-form", project: project_fields(project)) |> render_submit()

      assert Projects.get_project(project.uuid).translations == %{}
    end

    test "a primary field cleared on its tab stays cleared through a language tab's save", ctx do
      project = fixture_project(%{"name" => "Kitchen", "description" => "Stored words"})
      view = edit_project(ctx.conn, project)

      view
      |> form("#project-form", project: project_fields(project))
      |> render_change(%{"project" => %{"description" => ""}})

      open_tab(view, "es-ES")

      view
      |> form("#project-form", project: %{translations: %{"es-ES" => %{name: "Cocina"}}})
      |> render_submit()

      reloaded = Projects.get_project(project.uuid)
      assert reloaded.description in [nil, ""]
      assert reloaded.translations["es-ES"]["name"] == "Cocina"
    end

    test "a primary-tab save that changed no translation leaves a newer one alone", ctx do
      project =
        fixture_project(%{
          "name" => "Kitchen",
          "translations" => %{"es-ES" => %{"name" => "Cocina"}}
        })

      view = edit_project(ctx.conn, project)
      open_tab(view, ctx.primary)

      # Another writer, the AI worker or the API, while the form is open.
      {:ok, _} =
        Projects.update_project(project, %{
          "translations" => %{"es-ES" => %{"name" => "Cocina"}, "et" => %{"name" => "Kook"}}
        })

      view |> form("#project-form", project: project_fields(project)) |> render_submit()

      assert Projects.get_project(project.uuid).translations["et"]["name"] == "Kook"
    end
  end

  describe "the task form" do
    defp edit_task(conn, task) do
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")
      view
    end

    test "a translation reaches a viewer on that dialect", %{conn: conn} do
      task = fixture_task(%{"title" => "MeasurePRIMARY"})
      view = edit_task(conn, task)

      open_tab(view, "es-ES")

      view
      |> form("#task-form", task: %{translations: %{"es-ES" => %{title: "MedirES"}}})
      |> render_submit()

      {:ok, _view, html} =
        conn |> with_request_locale("es-ES") |> live("/en/admin/projects/tasks")

      assert html =~ "MedirES"
      refute html =~ "MeasurePRIMARY"
    end

    test "a translation survives a save from the primary tab", ctx do
      task = fixture_task(%{"title" => "Measure"})
      view = edit_task(ctx.conn, task)

      open_tab(view, "es-ES")

      view
      |> form("#task-form", task: %{translations: %{"es-ES" => %{title: "Medir"}}})
      |> render_change()

      open_tab(view, ctx.primary)

      view |> form("#task-form", task: %{title: "Measure"}) |> render_submit()

      assert Projects.get_task(task.uuid).translations["es-ES"]["title"] == "Medir"
    end

    test "a blanked translation is removed", %{conn: conn} do
      task =
        fixture_task(%{
          "title" => "Measure",
          "translations" => %{"es-ES" => %{"title" => "Medir"}}
        })

      view = edit_task(conn, task)
      open_tab(view, "es-ES")

      view
      |> form("#task-form", task: %{translations: %{"es-ES" => %{title: ""}}})
      |> render_submit()

      assert Projects.get_task(task.uuid).translations == %{}
    end
  end

  describe "the template form" do
    test "a translation survives a save from the primary tab", ctx do
      template = fixture_template(%{"name" => "Kitchen template"})

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/projects/templates/#{template.uuid}/edit")

      open_tab(view, "es-ES")

      view
      |> form("#template-form", project: %{translations: %{"es-ES" => %{name: "Plantilla"}}})
      |> render_change()

      open_tab(view, ctx.primary)

      {:error, {:live_redirect, _}} =
        view |> form("#template-form", project: %{name: template.name}) |> render_submit()

      assert Projects.get_project(template.uuid).translations["es-ES"]["name"] == "Plantilla"
    end
  end

  describe "the assignment form" do
    defp edit_assignment(conn, project, assignment) do
      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{assignment.uuid}/edit")

      view
    end

    defp type_description(view, text) do
      view
      |> form("#assignment-form")
      |> render_change(%{
        "assignment" => %{"translations" => %{"es-ES" => %{"description" => text}}}
      })
    end

    test "its own translated description survives a save from the primary tab", ctx do
      project = fixture_project()
      task = fixture_task(%{"title" => "Measure"})

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "description" => "Own words"
        })

      view = edit_assignment(ctx.conn, project, assignment)

      open_tab(view, "es-ES")
      type_description(view, "Palabras")
      open_tab(view, ctx.primary)

      view |> form("#assignment-form") |> render_submit()

      assert Projects.get_assignment(assignment.uuid).translations["es-ES"]["description"] ==
               "Palabras"
    end

    test "a one-off task's blanked description translation leaves the task", ctx do
      project = fixture_project(%{"start_mode" => "immediate"})

      {:ok, %{assignment: assignment}} =
        Projects.create_task_with_assignment(
          project.uuid,
          %{
            "title" => "Measure",
            "ad_hoc" => true,
            "description" => "Task words",
            "translations" => %{
              "es-ES" => %{"title" => "Medir", "description" => "Palabras"}
            }
          },
          %{}
        )

      view = edit_assignment(ctx.conn, project, assignment)

      open_tab(view, "es-ES")
      type_description(view, "")

      view |> form("#assignment-form") |> render_submit()

      assert Projects.get_task(assignment.task_uuid).translations == %{
               "es-ES" => %{"title" => "Medir"}
             }
    end

    test "a one-off task's translated description reaches the task from the primary tab", ctx do
      project = fixture_project(%{"start_mode" => "immediate"})

      {:ok, %{assignment: assignment}} =
        Projects.create_task_with_assignment(
          project.uuid,
          %{"title" => "Measure", "ad_hoc" => true, "description" => "Task words"},
          %{}
        )

      view = edit_assignment(ctx.conn, project, assignment)

      open_tab(view, "es-ES")
      type_description(view, "Palabras")
      open_tab(view, ctx.primary)

      view |> form("#assignment-form") |> render_submit()

      assert Projects.get_task(assignment.task_uuid).translations["es-ES"]["description"] ==
               "Palabras"
    end

    test "a new task keeps the title typed on another tab through a primary-tab save", ctx do
      project = fixture_project()
      title = "Inline-#{System.unique_integer([:positive])}"

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      view
      |> form("#assignment-form",
        assignment: %{status: "todo"},
        task_mode: "new",
        task: %{title: title}
      )
      |> render_change()

      open_tab(view, "es-ES")

      view
      |> form("#assignment-form", task: %{translations: %{"es-ES" => %{title: "MedirES"}}})
      |> render_change()

      open_tab(view, ctx.primary)

      {:error, {:live_redirect, _}} =
        view
        |> form("#assignment-form", assignment: %{status: "todo"}, task: %{title: title})
        |> render_submit()

      [task] = Enum.filter(Projects.list_tasks(ad_hoc: :all), &(&1.title == title))
      assert task.translations["es-ES"]["title"] == "MedirES"
    end
  end

  describe "a viewer on the primary language" do
    test "reads the primary column, not another dialect's override", %{primary: primary} do
      project =
        fixture_project(%{
          "name" => "Color",
          "translations" => %{"en-GB" => %{"name" => "Colour"}}
        })

      assert primary == "en-US"
      assert Project.localized_name(project, primary) == "Color"
      assert Project.localized_name(project, "en-AU") == "Colour"
    end
  end

  describe "the sub-project form" do
    test "a translation survives a save from the primary tab", ctx do
      project = fixture_project(%{"start_mode" => "immediate"})
      name = "Island-#{System.unique_integer([:positive])}"

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/projects/#{project.uuid}/assignments/new?kind=subproject")

      view |> form("#subproject-form", %{"subproject" => %{"name" => name}}) |> render_change()

      open_tab(view, "es-ES")

      view
      |> form("#subproject-form", %{
        "subproject" => %{"translations" => %{"es-ES" => %{"name" => "IslaES"}}}
      })
      |> render_change()

      open_tab(view, ctx.primary)

      view |> form("#subproject-form") |> render_submit()

      link = project.uuid |> Projects.list_assignments() |> Enum.find(&Assignment.subproject?/1)

      assert Projects.get_project(link.child_project_uuid).translations["es-ES"]["name"] ==
               "IslaES"
    end
  end
end
