defmodule PhoenixKitProjects.KimiReviewRrQ2RestoreSideEffectsTest do
  @moduledoc """
  Re-review probe (night 2026-11-26, Q2): `Outline.restore/1` now rewrites
  the WHOLE project's order depth first (`restore_order/1`). Does that move
  rows that were NOT restored — the restored row's siblings, OTHER held
  rows, a sub-project row — in what the accepted-only lists show?
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Outline, Projects}
  alias PhoenixKitProjects.Schemas.Assignment

  import Ecto.Query

  defp all_rows(project_uuid) do
    PhoenixKit.RepoHelper.repo().all(
      from(a in Assignment,
        where: a.project_uuid == ^project_uuid,
        order_by: [asc: a.position, asc: a.inserted_at],
        select: {a.uuid, a.parent_uuid, a.review_status, a.child_project_uuid}
      )
    )
  end

  # What a position-ordered, accepted-only reader shows (shape/1's rule).
  defp accepted_view(project_uuid) do
    rows =
      PhoenixKit.RepoHelper.repo().all(
        from(a in Assignment,
          where: a.project_uuid == ^project_uuid and a.review_status == "accepted",
          order_by: [asc: a.position, asc: a.inserted_at],
          select: %{uuid: a.uuid, parent_uuid: a.parent_uuid}
        )
      )

    rows |> Outline.walk() |> Enum.map(fn {row, _depth} -> row.uuid end)
  end

  defp create_task(project, title, description \\ nil) do
    attrs =
      if description,
        do: %{"description" => description},
        else: %{}

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        attrs
      )

    {:ok, a}
  end

  test "restoring one held row leaves other held rows held and uninvolved accepted rows in order" do
    project = fixture_project()
    {:ok, a} = create_task(project, "A")
    {:ok, b} = create_task(project, "B")

    # C under A and D under B, both carrying words so a drop HOLDS them.
    {:ok, c} = create_task(project, "C", "carries words")
    {:ok, d} = create_task(project, "D", "carries words")
    {:ok, c} = Outline.move(c, a.uuid, :last)
    {:ok, d} = Outline.move(d, b.uuid, :last)

    # A sub-project row at the top level.
    {:ok, %{child_project: _child}} = Projects.create_subproject(project.uuid, %{"name" => "Sub"})
    [s_row] = Enum.filter(all_rows(project.uuid), fn {_u, _p, _r, child} -> child end)
    s_uuid = elem(s_row, 0)

    # Depth-first sanity: A, C, B, D, S.
    assert all_rows(project.uuid) |> Enum.map(&elem(&1, 0)) == [
             a.uuid,
             c.uuid,
             b.uuid,
             d.uuid,
             s_uuid
           ]

    # Hold C and D (the typed list drops them; the browser knew them).
    lines = [
      %{"id" => a.uuid, "text" => "A", "depth" => 0},
      %{"id" => b.uuid, "text" => "B", "depth" => 0},
      %{"id" => s_uuid, "text" => "Sub", "depth" => 0}
    ]

    known = [a.uuid, b.uuid, c.uuid, d.uuid, s_uuid]
    {:ok, summary} = Outline.sync(project.uuid, lines, known, actor_uuid: nil)
    assert Enum.sort(summary.held) == Enum.sort([c.uuid, d.uuid])

    # Held rows sit at the tail afterwards (write_order/2's rest).
    assert all_rows(project.uuid) |> Enum.map(&elem(&1, 0)) |> Enum.take(-2) |> Enum.sort() ==
             Enum.sort([c.uuid, d.uuid])

    before_view = accepted_view(project.uuid)
    assert before_view == [a.uuid, b.uuid, s_uuid]

    # Restore C only.
    {:ok, restored} = Outline.restore(Projects.get_assignment(c.uuid))
    assert restored.review_status == "accepted"

    # The accepted view: C at the end of A's branch; B, S unmoved relative
    # to each other and to A.
    assert accepted_view(project.uuid) == [a.uuid, c.uuid, b.uuid, s_uuid]

    # D is still held, still under B.
    d_row = Enum.find(all_rows(project.uuid), &(elem(&1, 0) == d.uuid))
    assert elem(d_row, 2) == "removed"
    assert elem(d_row, 1) == b.uuid

    # The sub-project row kept its parent (top level) and its place after B.
    s_after = Enum.find(all_rows(project.uuid), &(elem(&1, 0) == s_uuid))
    assert elem(s_after, 1) == nil

    # And the stored order over ALL rows is depth first again.
    all = all_rows(project.uuid)
    assert Enum.map(all, &elem(&1, 0)) |> Enum.take(3) == [a.uuid, c.uuid, b.uuid]
  end

  test "restoring a held child while its parent stays held keeps it under the held parent" do
    project = fixture_project()
    {:ok, p} = create_task(project, "P")
    {:ok, h} = create_task(project, "H", "parent words")
    {:ok, c} = create_task(project, "C", "child words")
    {:ok, h} = Outline.move(h, p.uuid, :last)
    {:ok, c} = Outline.move(c, h.uuid, :last)

    # Hold H and C together (the typed list drops both; both carry words).
    lines = [%{"id" => p.uuid, "text" => "P", "depth" => 0}]
    known = [p.uuid, h.uuid, c.uuid]
    {:ok, summary} = Outline.sync(project.uuid, lines, known, actor_uuid: nil)
    assert Enum.sort(summary.held) == Enum.sort([h.uuid, c.uuid])

    # Restore the child alone: it is accepted again, still under held H.
    {:ok, restored} = Outline.restore(Projects.get_assignment(c.uuid))
    assert restored.review_status == "accepted"
    assert restored.parent_uuid == h.uuid

    h_row = Projects.get_assignment(h.uuid)
    assert h_row.review_status == "removed"

    # restore_order did not re-parent anything and left the order depth
    # first over all rows: P, H, C.
    assert all_rows(project.uuid) |> Enum.map(&elem(&1, 0)) == [p.uuid, h.uuid, c.uuid]

    # Restoring H afterwards puts the family back under P.
    {:ok, _} = Outline.restore(Projects.get_assignment(h.uuid))
    assert accepted_view(project.uuid) == [p.uuid, h.uuid, c.uuid]
  end
end
