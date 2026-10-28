defmodule PhoenixKitProjects.Web.ProjectShowLinksTest do
  @moduledoc """
  The task list never writes a task's connections on its card: no
  "depends on" chips and no rail down the side. The browser draws them on
  hover and trace (`PkpLinks`, `priv/static/assets/phoenix_kit_projects.js`)
  from the pairs the list carries; only a connected task has a trace button.
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

  test "the list carries its connections for the hook, and no connection text", ctx do
    {:ok, view, html} = show(ctx)

    assert has_element?(view, ~s([phx-hook="PkpLinks"]))
    assert html =~ ~s([&quot;#{ctx.consult.uuid}&quot;,&quot;#{ctx.measure.uuid}&quot;])
    refute html =~ "depends on:"
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
end
