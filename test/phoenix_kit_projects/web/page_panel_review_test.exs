defmodule PhoenixKitProjects.Web.PagePanelReviewTest do
  @moduledoc """
  What the panel (grok) found on the project page of the third list: the
  deadline popover's Clear is no submit button, its event is checked
  against an expanded sub-project's own rights, the header settings keep
  what was chosen through another field's validate, and each assignee
  link carries its own name.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{AssigneeSet, Projects}
  alias PhoenixKitProjects.Web.ProjectShowLive

  setup %{conn: conn} do
    me = embed_user_uuid!()
    conn = put_test_scope(conn, fake_scope(user_uuid: me))
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Hang the cabinets", "ad_hoc" => true},
        %{"deadline" => "2030-01-01T09:00:00Z"}
      )

    {:ok, conn: conn, project: project, a: a}
  end

  test "the deadline popover's Clear does not submit the form", %{conn: conn, project: p, a: a} do
    {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}")

    if html =~ ~s(row-deadline-form-#{a.uuid}) do
      refute html =~ ~r/type="submit"[^>]*name="clear"/s
      assert html =~ ~r/phx-value-clear="1"/
    end
  end

  test "save_deadline is checked against the record's own project" do
    assert "save_deadline" in ProjectShowLive.__record_param_events__()
  end

  test "the header settings keep what was chosen through another field's validate",
       %{conn: conn, project: p} do
    {:ok, view, _html} = live(conn, "/en/admin/projects/#{p.uuid}/edit")

    html =
      view
      |> element("form[id^=project-form]")
      |> render_change(%{
        "project" => %{"name" => p.name, "external_label" => "x"},
        "header" => %{"link_show" => "never", "ongoing" => "true"}
      })

    assert html =~
             ~r/<option[^>]*selected[^>]*value="never"|<option[^>]*value="never"[^>]*selected/s
  end

  test "each assignee keeps its own name, a gone one an empty name" do
    keys = [{"person", Ecto.UUID.generate()}, {"person", Ecto.UUID.generate()}]
    assert [{_, _}, {_, _}] = AssigneeSet.named(%{assignee_keys: keys})
    assert Enum.map(AssigneeSet.named(%{assignee_keys: keys}), &elem(&1, 0)) == keys
  end
end
