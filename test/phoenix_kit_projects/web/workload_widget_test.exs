defmodule PhoenixKitProjects.Web.WorkloadWidgetTest do
  @moduledoc """
  Pins the Workload widget's tiles-sum-to-total invariant: `:setup`
  (immediate start, not started yet) folds into the "Not started" tile with
  `:scheduled`, so the four detailed tiles always reconcile with the
  headline project count (AI-panel consensus, 2026-07-17).
  """
  use PhoenixKitProjects.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Web.Widgets.WorkloadWidget

  setup do
    PhoenixKit.Settings.update_setting("projects_enabled", "true")
    :ok
  end

  test "detailed tiles fold :setup into Not started and sum to the total" do
    {:ok, _running} =
      Projects.create_project(%{
        "name" => "WL running #{System.unique_integer([:positive])}",
        "start_mode" => "immediate",
        "started_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, _setup} =
      Projects.create_project(%{
        "name" => "WL setup #{System.unique_integer([:positive])}",
        "start_mode" => "immediate"
      })

    {:ok, _scheduled} =
      Projects.create_project(%{
        "name" => "WL scheduled #{System.unique_integer([:positive])}",
        "start_mode" => "scheduled",
        "scheduled_start_date" =>
          DateTime.utc_now() |> DateTime.add(14, :day) |> DateTime.truncate(:second)
      })

    html = render_component(WorkloadWidget, id: "w-workload", view: "detailed")

    assert html =~ "Not started"
    refute html =~ ">Scheduled<"

    # The "Not started" tile counts BOTH the scheduled and the setup project.
    assert [_, "2"] = Regex.run(~r/(\d+)\s*<\/span>\s*<span[^>]*>\s*Not started/s, html)
    # And the headline total reconciles: 1 running + 2 not started.
    assert html =~ "· 3"
  end
end
