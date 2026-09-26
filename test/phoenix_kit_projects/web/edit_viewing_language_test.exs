defmodule PhoenixKitProjects.Web.EditViewingLanguageTest do
  @moduledoc """
  The project, template, task and assignment forms open an EDIT on the
  language tab of the language the admin is viewing the page in; a new
  record starts on the main language, which holds its required fields.
  """
  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("fr-FR")

    project = fixture_project(%{"name" => "Kitchen"})
    task = fixture_task(%{"title" => "Measure"})
    template = fixture_template(%{"name" => "Kitchen template"})

    {:ok, assignment} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

    conn =
      conn
      |> put_test_scope(fake_scope())
      |> with_request_locale("fr-FR")

    %{conn: conn, project: project, task: task, template: template, assignment: assignment}
  end

  defp open_lang(view), do: :sys.get_state(view.pid).socket.assigns.current_lang

  test "viewed in French, the edit forms open on the French tab", ctx do
    for path <- [
          "/en/admin/projects/#{ctx.project.uuid}/edit",
          "/en/admin/projects/templates/#{ctx.template.uuid}/edit",
          "/en/admin/projects/tasks/#{ctx.task.uuid}/edit",
          "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.assignment.uuid}/edit"
        ] do
      {:ok, view, _html} = live(ctx.conn, path)
      assert open_lang(view) == "fr-FR", path
    end
  end

  test "viewed in French, a new record starts on the main tab", ctx do
    for path <- [
          "/en/admin/projects/new",
          "/en/admin/projects/templates/new",
          "/en/admin/projects/tasks/new",
          "/en/admin/projects/#{ctx.project.uuid}/assignments/new"
        ] do
      {:ok, view, _html} = live(ctx.conn, path)
      assert open_lang(view) == "en-US", path
    end
  end
end
