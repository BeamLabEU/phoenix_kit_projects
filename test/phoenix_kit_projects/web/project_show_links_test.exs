defmodule PhoenixKitProjects.Web.ProjectShowLinksTest do
  @moduledoc """
  A task's card carries what it depends on as small chips; the rest of the
  chain shows on hover and trace (`PkpLinks`,
  `priv/static/assets/phoenix_kit_projects.js`) from the pairs the list
  carries, and only a connected task has a trace button. No rail down the
  side. A task's ID opens its view.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    project = fixture_project(%{"start_mode" => "immediate"})

    task = fn title ->
      t = fixture_task(%{"title" => title})

      {:ok, a} =
        Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => t.uuid})

      a
    end

    consult = task.("Talk to the client")
    measure = task.("Take kitchen measurements")
    loose = task.("Order a coffee machine")
    {:ok, _} = Projects.add_dependency(measure.uuid, consult.uuid)

    {:ok, conn: conn, project: project, consult: consult, measure: measure, loose: loose}
  end

  defp show(ctx), do: live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

  test "the list carries its connections for the hook, and the depends-on chips", ctx do
    {:ok, view, html} = show(ctx)

    assert has_element?(view, ~s([phx-hook="PkpLinks"]))
    assert html =~ ~s([&quot;#{ctx.consult.uuid}&quot;,&quot;#{ctx.measure.uuid}&quot;])
    assert html =~ "depends on:"

    assert has_element?(
             view,
             ~s([phx-click="remove_dependency"][phx-value-assignment="#{ctx.measure.uuid}"])
           )

    # The rail that drew one line through every row is gone.
    refute html =~ "absolute left-5 top-0 bottom-0"
  end

  test "only a connected task gets a trace button", ctx do
    {:ok, view, _html} = show(ctx)

    assert has_element?(view, ~s([data-pkp-trace="#{ctx.consult.uuid}"]))
    assert has_element?(view, ~s([data-pkp-trace="#{ctx.measure.uuid}"]))
    refute has_element?(view, ~s([data-pkp-trace="#{ctx.loose.uuid}"]))
    assert has_element?(view, ~s([data-pkp-card="#{ctx.loose.uuid}"]))
  end

  test "a removed connection leaves the list's data", ctx do
    {:ok, view, _html} = show(ctx)

    html =
      render_click(view, "remove_dependency", %{
        "assignment" => ctx.measure.uuid,
        "depends_on" => ctx.consult.uuid
      })

    refute html =~ ~s([&quot;#{ctx.consult.uuid}&quot;,&quot;#{ctx.measure.uuid}&quot;])
    refute has_element?(view, ~s([data-pkp-trace="#{ctx.measure.uuid}"]))
  end

  test "with dependencies switched off there is no hook and no trace button", ctx do
    {:ok, _} = PhoenixKitProjects.Features.set_flags(ctx.project, %{"dependencies" => false})
    {:ok, view, _html} = show(ctx)

    refute has_element?(view, ~s([phx-hook="PkpLinks"]))
    refute has_element?(view, "[data-pkp-trace]")
  end

  test "a task's ID opens its view, and the open icon is no share arrow", ctx do
    {:ok, view, html} = show(ctx)

    assert has_element?(view, ~s([title="View the task"] [data-ref]))
    assert html =~ "Elixir.PhoenixKitProjects.Web.AssignmentViewLive"
    refute html =~ "hero-arrow-top-right-on-square"
  end
end
