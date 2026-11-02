defmodule PhoenixKitProjects.Web.RepeatControlTest do
  @moduledoc """
  Item 34 in the UI: one row at the end of the task popup's Planning tab
  ("Does not repeat ▾"), saved as the task's rule, and a ↻ before a
  repeating task's title in the list.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Check in", "ad_hoc" => true},
        %{
          "status" => "todo"
        }
      )

    {:ok,
     conn: put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!())), project: project, a: a}
  end

  test "the Planning tab's last row sets the rule; the list shows ↻", ctx do
    path = "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit"
    {:ok, view, html} = live(ctx.conn, path)

    assert has_element?(view, "[id^='assignment-'][id$='-pane-planning'] #assignment-repeat")
    refute has_element?(view, "[id^='assignment-'][id$='-pane-task'] #assignment-repeat")
    assert html =~ "Does not repeat"

    html =
      view
      |> form("#assignment-form")
      |> render_change(%{"assignment" => %{"repeat" => "custom"}})

    assert html =~ ~s(id="assignment-repeat-every")

    view
    |> form("#assignment-form")
    |> render_change(%{
      "assignment" => %{"repeat" => "custom", "repeat_every" => "3", "repeat_unit" => "day"}
    })

    view |> form("#assignment-form") |> render_submit()

    assert Projects.get_assignment(ctx.a.uuid).repeat_rule == %{"every" => 3, "unit" => "day"}

    {:ok, _show, html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")
    assert html =~ "data-repeat"
    assert html =~ "Every 3 days"
  end

  test "the custom unit's word agrees with the number beside it", ctx do
    path = "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit"
    {:ok, view, _html} = live(ctx.conn, path)

    unit = fn every ->
      view
      |> form("#assignment-form")
      |> render_change(%{
        "assignment" => %{"repeat" => "custom", "repeat_every" => every, "repeat_unit" => "week"}
      })

      view |> element("#assignment-repeat-unit option[value=week]") |> render() |> String.trim()
    end

    assert unit.("1") =~ ~r/>\s*week\s*</
    assert unit.("5") =~ ~r/>\s*weeks\s*</
  end
end
