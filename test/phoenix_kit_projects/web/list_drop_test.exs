defmodule PhoenixKitProjects.Web.ListDropTest do
  @moduledoc """
  Subtasks on the card list (Max and the panel, 2026-11-25): a drag sets a
  row's level (`list_drop`, sent by `PkpListDrag`), the ⋮ menu nests or
  un-nests one level, an empty project has an "Add a task" at the top, and
  the task form's Subtasks box has an Add button.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Outline, Projects}

  setup %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
    {:ok, conn: conn}
  end

  defp project do
    fixture_project(%{"name" => "Drops #{System.unique_integer([:positive])}"})
  end

  defp rows(p), do: Projects.list_assignments(p.uuid)
  defp by_title(p, title), do: Enum.find(rows(p), &(&1.task.title == title))

  defp page(conn, p) do
    {:ok, view, html} = live(conn, "/en/admin/projects/#{p.uuid}")
    {view, html}
  end

  test "a drop under the row above makes it a subtask; out again to the top", %{conn: conn} do
    p = project()
    {:ok, _} = Outline.sync(p.uuid, [%{"text" => "Parent"}, %{"text" => "Child"}], [])
    parent = by_title(p, "Parent")
    child = by_title(p, "Child")
    {view, html} = page(conn, p)
    assert html =~ ~s(phx-hook="PkpListDrag")

    render_hook(view, "list_drop", %{"id" => child.uuid, "parent" => parent.uuid, "after" => nil})
    assert by_title(p, "Child").parent_uuid == parent.uuid

    render_hook(view, "list_drop", %{"id" => child.uuid, "parent" => nil, "after" => parent.uuid})
    assert is_nil(by_title(p, "Child").parent_uuid)
    assert Enum.map(rows(p), & &1.task.title) == ["Parent", "Child"]
  end

  test "a drop into a task's own subtask, or onto another project's row, is refused", %{
    conn: conn
  } do
    p = project()

    {:ok, _} =
      Outline.sync(p.uuid, [%{"text" => "Top"}, %{"text" => "Under", "depth" => 1}], [])

    top = by_title(p, "Top")
    under = by_title(p, "Under")
    other = project()
    {:ok, _} = Outline.sync(other.uuid, [%{"text" => "Foreign"}], [])
    foreign = by_title(other, "Foreign")
    {view, _html} = page(conn, p)

    html = render_hook(view, "list_drop", %{"id" => top.uuid, "parent" => under.uuid})
    assert html =~ "The task cannot go there."
    assert is_nil(by_title(p, "Top").parent_uuid)

    render_hook(view, "list_drop", %{"id" => under.uuid, "parent" => foreign.uuid})
    assert by_title(p, "Under").parent_uuid == top.uuid
  end

  test "the menu offers one-level moves only where they are possible", %{conn: conn} do
    p = project()

    {:ok, _} =
      Outline.sync(
        p.uuid,
        [%{"text" => "First"}, %{"text" => "Second"}, %{"text" => "Deep", "depth" => 1}],
        []
      )

    first = by_title(p, "First")
    second = by_title(p, "Second")
    deep = by_title(p, "Deep")
    {view, _html} = page(conn, p)

    in_item = fn a ->
      has_element?(
        view,
        ~s([phx-click="outline_nest"][phx-value-id="#{a.uuid}"][phx-value-dir="in"])
      )
    end

    out_item = fn a ->
      has_element?(
        view,
        ~s([phx-click="outline_nest"][phx-value-id="#{a.uuid}"][phx-value-dir="out"])
      )
    end

    refute in_item.(first)
    assert in_item.(second)
    refute out_item.(second)
    assert out_item.(deep)

    view
    |> element(~s([phx-click="outline_nest"][phx-value-id="#{second.uuid}"][phx-value-dir="in"]))
    |> render_click()

    assert by_title(p, "Second").parent_uuid == first.uuid
  end

  test "an empty project has Add a task at the top as well as at the foot", %{conn: conn} do
    p = project()
    {view, html} = page(conn, p)

    assert has_element?(view, "#project-quick-top-#{p.uuid}")
    assert html =~ ~s(phx-click="outline_add_first")
    assert html =~ "Add the first task"
  end

  test "the task form's Subtasks box has an Add button", %{conn: conn} do
    p = project()
    {:ok, _} = Outline.sync(p.uuid, [%{"text" => "Holder"}], [])
    holder = by_title(p, "Holder")

    {:ok, view, html} =
      live(conn, "/en/admin/projects/#{p.uuid}/assignments/#{holder.uuid}/edit")

    assert html =~ "Parent task"
    # The button posts the subtask form (its own form, drawn after the task's).
    [_, form_id] =
      Regex.run(
        ~r/<button[^>]*form="(assignment-subtask-form-[^"]+)"[^>]*id="assignment-subtask-add-/s,
        html
      ) ||
        Regex.run(
          ~r/<button[^>]*id="assignment-subtask-add-[^"]*"[^>]*form="(assignment-subtask-form-[^"]+)"/s,
          html
        )

    assert has_element?(view, ~s(form##{form_id}[phx-submit="subtask_add"]))

    view |> element("form##{form_id}") |> render_submit(%{"title" => "Measure"})
    assert render(view) =~ "Measure"
  end

  test "a change of level is refused while subtasks are switched off", %{conn: conn} do
    p = project()
    {:ok, _} = Outline.sync(p.uuid, [%{"text" => "One"}, %{"text" => "Two"}], [])
    {:ok, p} = PhoenixKitProjects.Features.set_flags(p, %{"subtasks" => false})
    one = by_title(p, "One")
    two = by_title(p, "Two")
    {view, _html} = page(conn, p)

    assert render_hook(view, "list_drop", %{"id" => two.uuid, "parent" => one.uuid}) =~
             "The task cannot go there."

    assert is_nil(by_title(p, "Two").parent_uuid)
  end
end
