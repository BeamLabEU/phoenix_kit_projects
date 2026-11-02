defmodule PhoenixKitProjects.Web.PopupsPanelReviewTest do
  @moduledoc """
  The seven defects the panel (codex) found in the third list's popups:
  Delete asking first, each stacked project popup saving its own form, a
  dirty Close asking, a mistyped time kept and refused, the picker's list
  loading its next page, a queued picture removal asked again, and the
  one-pick picker's ticks following the choice.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.Components.TimeInput
  alias PhoenixKitStaff.Schemas.Person

  setup %{conn: conn} do
    me = embed_user_uuid!()
    conn = put_test_scope(conn, fake_scope(user_uuid: me))
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Hang the cabinets", "ad_hoc" => true},
        %{}
      )

    {:ok, conn: conn, me: me, project: project, a: a}
  end

  defp edit(ctx),
    do: live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

  defp person!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!",
        "first_name" => name
      })

    Repo.insert!(%Person{user_uuid: user.uuid, status: "active", name: name})
  end

  test "1: Delete asks first; only the confirmation deletes", ctx do
    {:ok, view, _} = edit(ctx)

    button = view |> element("#assignment-delete") |> render()
    refute button =~ ~s(phx-click="delete_task")

    view |> element("#assignment-delete") |> render_click()
    assert Projects.get_assignment(ctx.a.uuid)

    render_click(view, "confirm_action_ok", %{})
    refute Projects.get_assignment(ctx.a.uuid)
  end

  test "2: a project popup's form and its outside Save carry the popup's own id", ctx do
    {:ok, _view, html} =
      live_isolated(ctx.conn, PhoenixKitProjects.Web.ProjectFormLive,
        session: %{
          "current_user_uuid" => ctx.me,
          "mode" => "emit",
          "pubsub_topic" => "pr-#{System.unique_integer([:positive])}",
          "live_action" => "edit",
          "id" => ctx.project.uuid,
          "frame_ref" => 7
        }
      )

    assert html =~ ~s(id="project-form-f7")
    assert html =~ ~s(form="project-form-f7")
    refute html =~ ~s(form="project-form")
  end

  test "3: Close with unsaved changes asks in the page's dialog", ctx do
    {:ok, view, _} = edit(ctx)

    view
    |> form("#assignment-form", %{"assignment" => %{"priority" => "high"}})
    |> render_change()

    html = view |> element("#assignment-close-edit") |> render_click()
    assert html =~ "Discard your changes?"
  end

  describe "4: a time that does not read" do
    test "is passed on as typed, never cleared or made midnight" do
      assert TimeInput.fold(%{"date" => "2026-11-03", "time" => "soon"}) == "2026-11-03Tsoon"
      assert TimeInput.fold(%{"time" => "25:00"}) == "25:00"
      assert TimeInput.fold(%{"time" => ""}) == ""
      assert TimeInput.fold(%{"date" => "2026-11-03", "time" => "17:30"}) == "2026-11-03T17:30"
    end

    test "is kept in the box" do
      assert TimeInput.parts("2026-11-03Tsoon")[:typed] == "soon"
      assert TimeInput.parts("25:00")[:typed] == "25:00"
    end

    test "is refused at Save with the deadline left as it was", ctx do
      {:ok, view, _} = edit(ctx)

      view
      |> form("#assignment-form", %{
        "assignment" => %{"deadline" => %{"date" => "2026-11-03", "time" => "soon"}}
      })
      |> render_submit()

      assert Projects.get_assignment(ctx.a.uuid).deadline == nil
    end
  end

  test "5: the empty line sits outside the list the next page is loaded from", ctx do
    {:ok, view, _} = edit(ctx)

    render_change(view, "assignee_query", %{
      "assignee_q" => "zzz-nobody-#{System.unique_integer()}"
    })

    assert has_element?(view, "#assignment-assignee-options-empty")
    refute has_element?(view, "#assignment-assignee-options #assignment-assignee-options-empty")
  end

  test "7: a one-pick picker's list row follows the choice", ctx do
    cleo = person!("Cleopatra#{System.unique_integer([:positive])}")
    {:ok, view, _} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/edit")

    render_change(view, "assignee_query", %{"assignee_q" => cleo.name})
    sel = "#project-assignee-options [data-assignee='person:#{cleo.uuid}']"
    assert has_element?(view, sel <> "[aria-selected='false']")

    view |> element(sel) |> render_click()
    assert has_element?(view, sel <> "[aria-selected='true']")
  end
end
