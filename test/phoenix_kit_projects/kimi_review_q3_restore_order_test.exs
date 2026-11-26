defmodule PhoenixKitProjects.KimiReviewQ3RestoreOrderTest do
  @moduledoc """
  Review probe (night 2026-11-25, Q3): `Outline.restore/1` revives a held
  task without putting its `position` back. The sync that held it had
  already moved the row to the tail of the project (`write_order/2` places
  every unlisted row after the named ones), so after a restore the stored
  position order no longer has the parent followed by its branch — the
  module's one load-bearing order invariant ("a parent is followed by
  everything under it", AGENTS.md → Tasks under tasks).
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Outline, Projects}
  alias PhoenixKitProjects.Schemas.Assignment

  import Ecto.Query

  defp positions(project_uuid) do
    PhoenixKit.RepoHelper.repo().all(
      from(a in Assignment,
        where: a.project_uuid == ^project_uuid and a.review_status == "accepted",
        order_by: [asc: a.position],
        select: {a.uuid, a.parent_uuid, a.position}
      )
    )
  end

  test "a restored subtask is not left at the tail, away from its parent" do
    project = fixture_project()
    {:ok, a} = create_task(project, "A")
    {:ok, b} = create_task(project, "B")

    # C carries a description, so taking it out of the list HOLDS it
    # (`Outline.protected?/2`), never deletes it.
    {:ok, %{assignment: c}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "C", "ad_hoc" => true},
        %{"description" => "carries words"}
      )

    {:ok, c} = Outline.move(c, a.uuid, :last)

    # Sanity: depth-first order A, C, B.
    assert positions(project.uuid) |> Enum.map(&elem(&1, 0)) == [a.uuid, c.uuid, b.uuid]

    # The typed list drops C (the browser knew it) — C carries a
    # description, so it is HELD, not deleted.
    lines = [
      %{"id" => a.uuid, "text" => "A", "depth" => 0},
      %{"id" => b.uuid, "text" => "B", "depth" => 0}
    ]

    known = [a.uuid, b.uuid, c.uuid]

    {:ok, summary} =
      Outline.sync(project.uuid, lines, known, actor_uuid: nil)

    assert summary.held == [c.uuid]
    assert Projects.get_assignment(c.uuid).review_status == "removed"

    # Restore it (the held section's Restore button).
    {:ok, restored} = Outline.restore(Projects.get_assignment(c.uuid))
    assert restored.review_status == "accepted"

    # The invariant: in position order, a parent is followed by its branch.
    # Expected: A, C, B. Actual (bug): A, B, C — C is back at the tail.
    ordered_uuids = positions(project.uuid) |> Enum.map(&elem(&1, 0))

    assert ordered_uuids == [a.uuid, c.uuid, b.uuid],
           "restored subtask was left at the tail: #{inspect(ordered_uuids)}"
  end

  defp create_task(project, title) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{}
      )

    {:ok, a}
  end
end
