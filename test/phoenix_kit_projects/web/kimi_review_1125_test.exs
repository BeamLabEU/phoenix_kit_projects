defmodule PhoenixKitProjects.Web.KimiReview1125Test do
  @moduledoc """
  Review findings (2026-11-25), the card list's nesting:

    * the ⋮ menu's "Make it a subtask of the task above" moves the row under
      a FOLDED parent and leaves it folded — the row vanishes from the list
      (the drag's `list_drop` unfolds the new parent for exactly this
      reason; the menu path was missed);
    * under a status lens (done rows hidden) the same menu item still nests
      under the row above IN THE PLAN — a row the lens may hide — while the
      drag refuses to nest at all until the whole list is on screen.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Outline, Projects}

  setup %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
    {:ok, conn: conn}
  end

  defp project do
    fixture_project(%{"name" => "Review #{System.unique_integer([:positive])}"})
  end

  defp rows(p), do: Projects.list_assignments(p.uuid)
  defp by_title(p, title), do: Enum.find(rows(p), &(&1.task.title == title))

  test "nest-in under a folded parent leaves the moved row visible (unfolds it)", %{conn: conn} do
    p = project()

    {:ok, _} =
      Outline.sync(
        p.uuid,
        [%{"text" => "Parent"}, %{"text" => "Kid", "depth" => 1}, %{"text" => "Next"}],
        []
      )

    parent = by_title(p, "Parent")
    next = by_title(p, "Next")

    {:ok, view, _html} = live(conn, "/en/admin/projects/#{p.uuid}")

    # Fold the parent: its child disappears from the card list.
    view
    |> element(~s([phx-click="outline_fold"][phx-value-uuid="#{parent.uuid}"]))
    |> render_click()

    refute has_element?(
             view,
             ~s(#project-show-timeline-#{p.uuid} [data-id="#{by_title(p, "Kid").uuid}"])
           )

    # "Make it a subtask of the task above" on Next: it goes under the
    # folded Parent — and the list still shows it (the parent unfolds).
    view
    |> element(~s([phx-click="outline_nest"][phx-value-id="#{next.uuid}"][phx-value-dir="in"]))
    |> render_click()

    assert by_title(p, "Next").parent_uuid == parent.uuid

    assert has_element?(view, ~s(#project-show-timeline-#{p.uuid} [data-id="#{next.uuid}"])),
           "the moved row vanished behind the folded parent"
  end

  test "under a lens the menu does not offer nesting the drag would refuse", %{conn: conn} do
    p = project()

    # Ten tasks so the lens/sort controls render (default threshold), the
    # first one done so the "active" lens hides it.
    lines = for i <- 1..10, do: %{"text" => "Task #{i}"}
    {:ok, _} = Outline.sync(p.uuid, lines, [])
    first = by_title(p, "Task 1")
    second = by_title(p, "Task 2")
    {:ok, _} = Projects.update_assignment_status(first, %{"status" => "done"})

    {:ok, view, _html} = live(conn, "/en/admin/projects/#{p.uuid}")

    # The lens hides the done row; the list on screen starts at Task 2.
    refute has_element?(view, ~s(#project-show-timeline-#{p.uuid} [data-id="#{first.uuid}"]))
    assert has_element?(view, ~s(#project-show-timeline-#{p.uuid} [data-id="#{second.uuid}"]))

    # The drag is off for level changes (data-nest="false"): the row above
    # on screen is not the row above in the plan.
    assert has_element?(view, ~s([data-nest="false"]))

    # So the menu must not offer "Make it a subtask of the task above"
    # either — it would nest under the HIDDEN done row.
    refute has_element?(
             view,
             ~s([phx-click="outline_nest"][phx-value-id="#{second.uuid}"][phx-value-dir="in"])
           ),
           "the menu offers a nest the drag refuses: it targets the hidden done row"
  end
end
