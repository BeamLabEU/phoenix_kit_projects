defmodule PhoenixKitProjects.Web.OngoingChoiceTest do
  @moduledoc """
  Ongoing made obvious (item 33, the panel of 2026-10-31): "Has an end |
  Ongoing" right under the project's name, at creation and on an existing
  project; an "∞ Ongoing" badge beside the name on the project page (it
  opens the popup on that control) and in the projects list; ongoing work
  never late or ahead/behind, and counted by its open tasks, not a share.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Project

  @ongoing %{"completion" => "manual"}

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp open_task!(project) do
    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => fixture_task().uuid,
        "status" => "todo"
      })

    a
  end

  describe "the choice under the name" do
    test "a new project made ongoing from the creation form", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/projects/new")
      assert html =~ ~s(id="project-completion")
      assert html =~ "Has an end"

      name = "Upkeep #{System.unique_integer([:positive])}"

      view
      |> form("#project-form", project: %{name: name, start_mode: "immediate"})
      |> render_submit(%{"completion" => "manual"})

      [project] = Projects.list_projects() |> Enum.filter(&(&1.name == name))
      assert Project.ongoing?(project)
    end

    test "an existing project's choice, kept across a change and saved", %{conn: conn} do
      project = fixture_project()
      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")
      assert html =~ ~s(id="project-completion-auto")
      refute html =~ "End this project"

      html = view |> form("#project-form") |> render_change(%{"completion" => "manual"})
      assert html =~ "it ends only when someone ends it"

      view |> form("#project-form") |> render_submit(%{"completion" => "manual"})
      assert Project.ongoing?(Projects.get_project!(project.uuid))
    end
  end

  describe "the badge and what ongoing work shows" do
    test "beside the name on its page, opening the popup; no plan badges", %{conn: conn} do
      # Shown when switched on (the third list, item 3: off by default).
      project =
        fixture_project(%{
          "settings" => Map.put(@ongoing, "header", %{"ongoing" => true, "open_tasks" => true}),
          "start_mode" => "immediate"
        })

      project = Projects.get_project!(project.uuid)
      open_task!(project)
      open_task!(project)

      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert html =~ "∞"
      assert html =~ "2 open tasks"
      refute html =~ ~r/(overdue|ahead|behind)<\/span>/

      assert has_element?(view, ~s([data-id="project-ongoing-#{project.uuid}"]))
    end

    test "a project with an end has no badge", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.start_project(project)
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      refute html =~ ~s(data-id="project-ongoing-)
    end

    test "in the projects list", %{conn: conn} do
      project = fixture_project(%{"settings" => @ongoing})
      {:ok, _view, html} = live(conn, "/en/admin/projects")
      assert html =~ project.name
      assert html =~ "∞"
    end

    test "is never late to start" do
      past = DateTime.add(DateTime.utc_now(), -86_400, :second) |> DateTime.truncate(:second)

      p = %Project{
        start_mode: "scheduled",
        scheduled_start_date: past,
        settings: @ongoing,
        is_template: false
      }

      assert Project.derived_status(p) == :scheduled
      assert Project.derived_status(%{p | settings: %{}}) == :overdue
    end
  end
end
