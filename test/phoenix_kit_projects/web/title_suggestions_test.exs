defmodule PhoenixKitProjects.Web.TitleSuggestionsTest do
  @moduledoc """
  Library suggestions under the add-task popup's Title (the boss: "suggest
  tasks when typing the name, auto-complete style"): library tasks only;
  a pick adds that task as the library tab would — its description,
  estimate and default assignee; ignored, the typed task is made as before.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    me = embed_user_uuid!()
    project = fixture_project(%{"start_mode" => "immediate"})
    tag = System.unique_integer([:positive])

    {:ok, lib} =
      Projects.create_task(%{
        "title" => "Install sink #{tag}",
        "description" => "Silicone round the edge",
        "estimated_duration" => 2,
        "estimated_duration_unit" => "hours"
      })

    {:ok, _one_off} =
      Projects.create_task(%{"title" => "Install sink #{tag} once", "ad_hoc" => true})

    {:ok,
     conn: put_test_scope(conn, fake_scope(user_uuid: me)), project: project, lib: lib, tag: tag}
  end

  defp new(ctx), do: live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/new")

  test "typing a title offers library tasks only, and a pick adds it from the library", ctx do
    {:ok, view, _} = new(ctx)

    view
    |> form("#assignment-form", task: %{title: "Install sink #{ctx.tag}"})
    |> render_change()

    assert has_element?(view, "#assignment-title-suggestions", "Install sink #{ctx.tag}")
    refute has_element?(view, "#assignment-title-suggestions", "once")

    view
    |> element("#assignment-title-suggestions button[phx-value-uuid='#{ctx.lib.uuid}']")
    |> render_click()

    view |> form("#assignment-form") |> render_submit()

    [a] = Projects.list_assignments(ctx.project.uuid)
    assert a.task_uuid == ctx.lib.uuid
    assert a.estimated_duration == 2
  end

  test "ignoring the suggestions creates a new task as typed", ctx do
    {:ok, view, _} = new(ctx)

    view
    |> form("#assignment-form", task: %{title: "Install sink #{ctx.tag} tomorrow"})
    |> render_submit()

    [a] = Projects.list_assignments(ctx.project.uuid)
    refute a.task_uuid == ctx.lib.uuid
  end

  test "a forged pick of a task never offered does nothing", ctx do
    {:ok, view, _} = new(ctx)
    render_click(view, "pick_title_suggestion", %{"uuid" => ctx.lib.uuid})
    refute has_element?(view, "select[name='assignment[task_uuid]']")
  end
end
