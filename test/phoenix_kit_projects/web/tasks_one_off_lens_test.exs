defmodule PhoenixKitProjects.Web.TasksOneOffLensTest do
  @moduledoc """
  The task library's Library | One-off lens (V15): one-off tasks minted by
  a project's quick-add stay out of the default list and the pickers, can
  be found under the lens, and can be promoted back into the library.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), actor_uuid: scope.user.uuid}
  end

  test "no lens strip while there are no one-off tasks", %{conn: conn} do
    fixture_task(%{"title" => "Plain library task"})
    {:ok, _view, html} = live(conn, "/en/admin/projects/tasks")
    refute html =~ "Task library lens"
  end

  test "one-off tasks are hidden by default, listed under the lens, and promotable",
       %{conn: conn, actor_uuid: actor_uuid} do
    lib = fixture_task(%{"title" => "Reusable step"})
    p = fixture_project(%{"name" => "Lens-#{System.unique_integer([:positive])}"})
    {:ok, %{task: adhoc}} = Projects.quick_add_assignment(p.uuid, "Ring the supplier")

    {:ok, view, html} = live(conn, "/en/admin/projects/tasks")
    assert html =~ "Reusable step"
    refute html =~ "Ring the supplier"
    assert html =~ "Task library lens"

    html = view |> element("[role=tab][phx-value-tab=one_off]") |> render_click()
    assert html =~ "Ring the supplier"
    refute html =~ "Reusable step"
    assert html =~ "one-off"

    html =
      view
      |> element("button[phx-click=promote_task][phx-value-uuid='#{adhoc.uuid}']")
      |> render_click()

    assert html =~ "Task added to the library."
    assert Projects.get_task(adhoc.uuid).ad_hoc == false

    assert_activity_logged("projects.task_promoted",
      actor_uuid: actor_uuid,
      resource_uuid: adhoc.uuid
    )

    # That was the last one-off: the page falls back to the library lens,
    # where both are ordinary rows, and the strip is gone.
    html = render(view)
    assert html =~ "Ring the supplier" and html =~ "Reusable step"
    refute html =~ "Task library lens"
    assert lib.uuid in Enum.map(Projects.list_tasks(), & &1.uuid)
  end

  test "the assignment form's library picker never offers one-off tasks", %{conn: conn} do
    p = fixture_project(%{"name" => "Picker-#{System.unique_integer([:positive])}"})
    fixture_task(%{"title" => "Offered"})
    {:ok, _} = Projects.quick_add_assignment(p.uuid, "Not offered")

    {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{p.uuid}/assignments/new")
    [select] = Regex.run(~r/<select[^>]*name="assignment\[task_uuid\]"[^>]*>.*?<\/select>/s, html)
    assert select =~ "Offered"
    refute select =~ "Not offered"
  end

  test "the edit form can promote a one-off task with its checkbox", %{conn: conn} do
    p = fixture_project(%{"name" => "Edit-#{System.unique_integer([:positive])}"})
    {:ok, %{task: adhoc}} = Projects.quick_add_assignment(p.uuid, "Promote via form")

    {:ok, view, html} = live(conn, "/en/admin/projects/tasks/#{adhoc.uuid}/edit")
    assert html =~ "One-off task"

    view
    |> form("#task-form", %{"task" => %{"title" => "Promote via form", "ad_hoc" => "false"}})
    |> render_submit()

    assert Projects.get_task(adhoc.uuid).ad_hoc == false
  end
end
