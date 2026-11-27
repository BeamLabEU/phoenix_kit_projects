defmodule PhoenixKitProjects.HistoryMoveWordingTest do
  @moduledoc """
  The sweep of 2026-11-27 (codex): a reorder under the same parent read
  "moved under another task", and the task drawer called a move back to
  Waiting "reopened" while the project's History said "set back to
  waiting".
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitProjects.Web.Components.HistoryFeed

  defp entry(action, meta) do
    %{
      id: "a-#{System.unique_integer([:positive])}",
      at: ~U[2026-07-01 10:00:00Z],
      kind: :activity,
      action: action,
      actor: "Marek",
      actor_uuid: nil,
      target: nil,
      target_uuid: nil,
      task: %{uuid: Ecto.UUID.generate(), label: "Walls", subproject: false},
      quote: nil,
      told: [],
      auto: false,
      notice: false,
      meta: meta
    }
  end

  defp feed(e, compact) do
    render_component(&HistoryFeed.history_feed/1,
      id: "f",
      entries: [e],
      project: %{key: "K", uuid: Ecto.UUID.generate()},
      compact: compact,
      links: false
    )
  end

  test "a reorder is a move; a new parent is a move under another task" do
    p = Ecto.UUID.generate()
    moved = "projects.assignment_moved"

    reorder = feed(entry(moved, %{"parent" => p, "from_parent" => p}), false)
    assert reorder =~ "moved:"
    refute reorder =~ "under another task"

    assert feed(entry(moved, %{"parent" => p, "from_parent" => nil}), false) =~
             "moved under another task:"

    assert feed(entry(moved, %{"parent" => nil, "from_parent" => p}), false) =~
             "moved to the top level:"

    # An entry from before `from_parent` says only that it moved.
    refute feed(entry(moved, %{"parent" => p}), false) =~ "under another task"
    assert feed(entry(moved, %{"parent" => p, "from_parent" => p}), true) =~ "moved it"
  end

  test "the drawer and the project agree on a move back to Waiting" do
    e = entry("projects.assignment_reopened", %{"from" => "in_progress", "to" => "waiting"})
    assert feed(e, true) =~ "set it back to waiting"
    refute feed(e, true) =~ "reopened"
    assert feed(entry("projects.assignment_made_idle", %{}), true) =~ "set it back to waiting"
  end
end
