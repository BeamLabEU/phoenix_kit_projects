defmodule PhoenixKitProjects.SubprojectWordingTest do
  @moduledoc """
  A line shared by tasks and sub-projects agrees with the item it names
  (ru "Приостановлена" for a задача, "Приостановлен" for a подпроект): the
  history's ref carries the kind, and the feed, the on-hold badge and the
  next-up question pick the matching form.
  """

  use PhoenixKitProjects.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitProjects.{Activity, History, Projects}
  alias PhoenixKitProjects.Web.Components.{AssignmentStatusBadge, HistoryFeed}

  setup do
    Gettext.put_locale(PhoenixKitProjects.Gettext, "ru")
    on_exit(fn -> Gettext.put_locale(PhoenixKitProjects.Gettext, "en") end)
    :ok
  end

  defp entry(subproject?) do
    %{
      id: "a-#{System.unique_integer([:positive])}",
      at: ~U[2026-07-01 10:00:00Z],
      kind: :activity,
      action: "projects.assignment_on_hold",
      actor: "Marek",
      actor_uuid: nil,
      target: nil,
      target_uuid: nil,
      task: %{uuid: Ecto.UUID.generate(), label: "Walls", subproject: subproject?},
      quote: nil,
      told: [],
      auto: false,
      notice: false,
      meta: %{}
    }
  end

  defp feed(entries, compact) do
    render_component(&HistoryFeed.history_feed/1,
      id: "f",
      entries: entries,
      project: %{key: "K", uuid: Ecto.UUID.generate()},
      compact: compact,
      links: false
    )
  end

  test "the feed's on-hold and auto-reopen lines agree with a sub-project" do
    for compact <- [true, false] do
      assert feed([entry(false)], compact) =~ "Приостановлена, потому что"
      sub = feed([entry(true)], compact)
      assert sub =~ "Приостановлен, потому что"
      refute sub =~ "Приостановлена"

      reopened = %{entry(true) | action: "projects.assignment_reopened", auto: true}
      assert feed([reopened], compact) =~ "Открыт заново"
      refute feed([reopened], compact) =~ "Открыта заново"
    end
  end

  test "the on-hold badge, its tooltip and the next-up question agree with the item" do
    assert AssignmentStatusBadge.on_hold_label(false) == "Приостановлена"
    assert AssignmentStatusBadge.on_hold_label(true) == "Приостановлен"
    assert AssignmentStatusBadge.on_hold_waiting_label("«A»", true) == "Приостановлен — ждёт: «A»"
    assert AssignmentStatusBadge.mark_done_question("X", false) == "Отметить «X» выполненной?"
    assert AssignmentStatusBadge.mark_done_question("X", true) == "Отметить «X» выполненным?"
  end

  test "a history line on a sub-project carries the kind" do
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: sub}} =
      Projects.create_subproject(project.uuid, %{"name" => "Walls"})

    {:ok, _} =
      Activity.log("projects.assignment_on_hold",
        resource_type: "assignment",
        resource_uuid: sub.uuid,
        metadata: %{"project_uuid" => project.uuid},
        tell: false
      )

    %{entries: entries} = History.list(Projects.get_project(project.uuid))
    line = Enum.find(entries, &(&1[:action] == "projects.assignment_on_hold"))
    assert line.task.subproject == true
  end
end
