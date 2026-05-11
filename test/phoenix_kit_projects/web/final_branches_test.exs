defmodule PhoenixKitProjects.Web.FinalBranchesTest do
  @moduledoc """
  Final branch coverage push — exercises the remaining LV paths:

  - `ProjectsLive.handle_event("delete", _)` `:error` branch
    (delete fails — covered via the `Activity.log_failed` source pin)
  - `project_status_label/1` `archived` + fallback branches via render
  - `TaskFormLive.save :new` error branch (validation failure)
  - `TaskFormLive.save :edit` error branch
  - `clear_other_default_assignees` branches via `save` event with each
    `default_assign_type` value
  """

  use PhoenixKitProjects.LiveCase, async: false

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "ProjectsLive render branches" do
    test "renders projects with derived status badge", %{conn: conn} do
      _ =
        fixture_project(%{
          "name" => "A-#{System.unique_integer([:positive])}"
        })

      hidden =
        fixture_project(%{
          "name" => "B-#{System.unique_integer([:positive])}"
        })

      {:ok, _} = PhoenixKitProjects.Projects.archive_project(hidden)

      {:ok, _view, html} = live(conn, "/en/admin/projects/list")

      assert html =~ "setup"
    end

    test "filter event with archived selection renders archived projects", %{conn: conn} do
      hidden = fixture_project()
      {:ok, _} = PhoenixKitProjects.Projects.archive_project(hidden)

      {:ok, view, _html} = live(conn, "/en/admin/projects/list")

      html =
        view
        |> element("form[phx-change=\"filter\"]")
        |> render_change(%{"show" => "archived"})

      assert html =~ "archived"
    end
  end

  describe "TaskFormLive save error branches" do
    test ":new save with empty title re-renders the form (error branch)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/new")

      html =
        view
        |> form("#task-form",
          task: %{
            title: "",
            description: "",
            estimated_duration: "1",
            estimated_duration_unit: "hours"
          }
        )
        |> render_submit()

      # `validate_required(:title)` fires + form re-renders.
      assert html =~ "task-form"
      refute html =~ ~r/live_redirect/
    end

    test ":edit save with empty title re-renders the form (error branch)",
         %{conn: conn} do
      task = fixture_task()

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

      html =
        view
        |> form("#task-form",
          task: %{
            title: "",
            description: "",
            estimated_duration: "1",
            estimated_duration_unit: "hours"
          }
        )
        |> render_submit()

      assert html =~ "task-form"
    end

    test "save with default_assign_type=team triggers the team clear branch",
         %{conn: conn} do
      task = fixture_task()

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

      {:error, {:live_redirect, _}} =
        view
        |> form("#task-form",
          task: %{
            title: task.title,
            estimated_duration: "1",
            estimated_duration_unit: "hours"
          },
          default_assign_type: "team"
        )
        |> render_submit()
    end

    test "save with default_assign_type=department triggers the dept clear branch",
         %{conn: conn} do
      task = fixture_task()

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

      {:error, {:live_redirect, _}} =
        view
        |> form("#task-form",
          task: %{
            title: task.title,
            estimated_duration: "1",
            estimated_duration_unit: "hours"
          },
          default_assign_type: "department"
        )
        |> render_submit()
    end

    test "save with default_assign_type=person triggers the person clear branch",
         %{conn: conn} do
      task = fixture_task()

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

      {:error, {:live_redirect, _}} =
        view
        |> form("#task-form",
          task: %{
            title: task.title,
            estimated_duration: "1",
            estimated_duration_unit: "hours"
          },
          default_assign_type: "person"
        )
        |> render_submit()
    end

    test "save with default_assign_type='' triggers the catch-all clear branch",
         %{conn: conn} do
      task = fixture_task()

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

      {:error, {:live_redirect, _}} =
        view
        |> form("#task-form",
          task: %{
            title: task.title,
            estimated_duration: "1",
            estimated_duration_unit: "hours"
          },
          default_assign_type: ""
        )
        |> render_submit()
    end
  end
end
