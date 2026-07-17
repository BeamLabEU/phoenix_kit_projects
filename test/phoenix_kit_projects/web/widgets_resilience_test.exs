defmodule PhoenixKitProjects.Web.WidgetsResilienceTest do
  @moduledoc """
  Pins the AGENTS.md widget invariant: **a widget must never crash the host
  dashboard**. Two real failure shapes are exercised:

  - a read that raises mid-update (a malformed viewer uuid escapes
    `list_assignments_for_user/1`'s own rescue as an `Ecto.Query.CastError`) —
    the widget-level rescue renders the empty state instead of taking down the
    host LiveView;
  - a process with no DB access at all (a `Task` without a sandbox allowance —
    the same shape as a transient connection loss), where every widget must
    still render.
  """
  use PhoenixKitProjects.DataCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitProjects.Web.Widgets.{
    DeadlinesWidget,
    MyTasksWidget,
    OngoingTasksWidget,
    ProjectsBoardWidget,
    ProjectScheduleWidget,
    ProjectStatusWidget,
    WorkloadWidget
  }

  @all_widgets [
    DeadlinesWidget,
    MyTasksWidget,
    OngoingTasksWidget,
    ProjectsBoardWidget,
    ProjectScheduleWidget,
    ProjectStatusWidget,
    WorkloadWidget
  ]

  setup do
    PhoenixKit.Settings.update_setting("projects_enabled", "true")
    :ok
  end

  test "My tasks renders its empty state when the viewer lookup raises" do
    # "not-a-uuid" escapes list_assignments_for_user/1's own rescue list as an
    # Ecto.Query.CastError — exactly the raising-read shape the widget-level
    # rescue exists for.
    html =
      render_component(MyTasksWidget,
        id: "w-my-tasks",
        settings: %{},
        scope: %{user: %{uuid: "not-a-uuid"}}
      )

    assert html =~ "Nothing assigned to you right now."
  end

  test "Deadlines with only_mine renders no rows when the viewer lookup raises" do
    html =
      render_component(DeadlinesWidget,
        id: "w-deadlines",
        settings: %{"only_mine" => true},
        scope: %{user: %{uuid: "not-a-uuid"}}
      )

    # The rescued lookup degrades to the "no resolvable viewer" branch of
    # scope_and_limit/4 — empty, never a leak of all projects.
    assert html =~ "Deadlines"
    refute html =~ "widget-deadline-row"
  end

  # capture_log: core logs the (expected) failed settings read from the
  # no-allowance process — noise, not a failure.
  @tag capture_log: true
  test "every widget renders (not raises) from a process with no DB access" do
    # A process with no sandbox allowance sees DBConnection ownership errors
    # on every query — the same shape as a transient connection loss. Task
    # inherits the allowance via `$callers`, so drop it before rendering.
    # The exact fallback varies (available? fails closed to the disabled
    # state), but the contract under test is: render, don't raise.
    for widget <- @all_widgets do
      html =
        Task.async(fn ->
          Process.delete(:"$callers")
          render_component(widget, id: "w-no-db", settings: %{}, scope: nil)
        end)
        |> Task.await()

      assert html =~ "Projects module is disabled.",
             "#{inspect(widget)} did not degrade to its no-DB fallback"
    end
  end
end
