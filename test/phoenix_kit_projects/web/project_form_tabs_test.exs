defmodule PhoenixKitProjects.Web.ProjectFormTabsTest do
  @moduledoc """
  The project popup in the task popup's shape (the boss, 2026-10-30): the
  header follows the typed name, tabs Project · Schedule · Settings, and the
  shared assignee picker instead of a kind select and a second select.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.Person

  setup %{conn: conn} do
    me = embed_user_uuid!()
    project = fixture_project(%{"name" => "Kitchen Tamm", "start_mode" => "immediate"})
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: me)), project: project}
  end

  test "editing: header, tabs, and the panes switch without losing the form", ctx do
    {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/edit")

    assert view |> element("#project-form-header-title") |> render() =~ "Kitchen Tamm"

    for pane <- ~w(project schedule settings),
        do: assert(has_element?(view, "#project-tab-#{pane}"))

    refute html =~ ~s(name="assign_type" id=)

    view |> form("#project-form", project: %{name: "Kitchen Saar"}) |> render_change()
    assert view |> element("#project-form-header-title") |> render() =~ "Kitchen Saar"

    render_click(view, "set_form_pane", %{"pane" => "settings"})
    assert has_element?(view, "#project-pane-project.hidden")
    refute has_element?(view, "#project-pane-settings.hidden")

    view |> form("#project-form") |> render_submit()
    assert Projects.get_project(ctx.project.uuid).name == "Kitchen Saar"
  end

  test "the assignee is picked with the shared picker", ctx do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "gert-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    gert = Repo.insert!(%Person{user_uuid: user.uuid, status: "active", name: "Gert"})
    {:ok, view, _} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/edit")

    render_click(view, "assignee_pick", %{"kind" => "person", "uuid" => gert.uuid})
    assert has_element?(view, "#project-assignee-chips", "Gert")
    view |> form("#project-form") |> render_submit()

    assert Projects.get_project(ctx.project.uuid).assigned_person_uuid == gert.uuid
  end

  test "in the popup no lone Projects line sits above the title", ctx do
    {:ok, _view, html} =
      live_isolated(ctx.conn, PhoenixKitProjects.Web.ProjectFormLive,
        session: %{
          "current_user_uuid" => embed_user_uuid!(),
          "mode" => "emit",
          "pubsub_topic" => "pfl-#{System.unique_integer([:positive])}",
          "live_action" => "edit",
          "id" => ctx.project.uuid,
          "frame_ref" => 1
        }
      )

    [header] = Regex.run(~r{<header id="project-form-header".*?</header>}s, html)
    assert header =~ "Kitchen Tamm"
    refute header =~ "Projects"
  end

  test "a new project has the same tabs", ctx do
    {:ok, view, html} = live(ctx.conn, "/en/admin/projects/new")
    assert html =~ "New project"
    assert has_element?(view, "#project-tab-schedule")
    assert has_element?(view, "#project-pane-settings #create-features")
  end
end
