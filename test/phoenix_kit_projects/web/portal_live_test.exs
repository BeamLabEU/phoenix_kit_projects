defmodule PhoenixKitProjects.Web.PortalLiveTest do
  @moduledoc """
  The public portal page: uniform unavailable states, the whitelisted
  render, the submit flow through `handle_event` (where the guards
  actually run — panel #2), and the live rotation downgrade (panel #7).
  """
  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Portal
  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    PhoenixKitProjects.Extensions.Registry.refresh()
    project = fixture_project()
    {:ok, _} = Extensions.enable(project, "portal")
    portal = Portal.get_portal(project.uuid)
    {:ok, conn: conn, project: project, portal: portal}
  end

  test "unknown slug renders the uniform unavailable page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/portal/#{Ecto.UUID.generate()}")
    assert html =~ "This page is unavailable"
  end

  test "a valid slug renders the project name and nothing internal",
       %{conn: conn, project: project, portal: portal} do
    {:ok, task} = Projects.create_task(%{"title" => "Visible issue"})

    {:ok, assignment} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

    {:ok, _} = Portal.set_public(assignment, true)

    {:ok, _view, html} = live(conn, "/portal/#{portal.slug}")

    assert html =~ project.name
    assert html =~ "Visible issue"
    # Belt for the header suspender: robots meta present.
    assert html =~ ~s(name="robots")
    # No internal chrome bleeds through.
    refute html =~ "phx-click=\"switch_tab\""
    refute html =~ "Modules"
  end

  test "anonymous submission through the LV creates the issue",
       %{conn: conn, project: project, portal: portal} do
    {:ok, view, _html} = live(conn, "/portal/#{portal.slug}")

    html =
      view
      |> form("#portal-submit-form", %{
        "title" => "From the page",
        "description" => "Steps to reproduce"
      })
      |> render_submit()

    assert html =~ "Thank you"
    assert PhoenixKit.RepoHelper.repo().exists?(portal_issue_query(project.uuid))
  end

  test "a filled honeypot shows the generic failure, creates nothing",
       %{conn: conn, project: project, portal: portal} do
    {:ok, view, _html} = live(conn, "/portal/#{portal.slug}")

    html =
      view
      |> form("#portal-submit-form", %{"title" => "Spam", "description" => ""})
      |> render_submit(%{"website" => "http://spam.example"})

    assert html =~ "Could not submit"
    refute PhoenixKit.RepoHelper.repo().exists?(portal_issue_query(project.uuid))
  end

  test "rotation downgrades a LIVE session to unavailable",
       %{conn: conn, project: project, portal: portal} do
    {:ok, view, html} = live(conn, "/portal/#{portal.slug}")
    assert html =~ project.name

    {:ok, _} = Portal.rotate_slug(project.uuid)

    assert render(view) =~ "This page is unavailable"
  end

  test "disabling the extension downgrades a LIVE session too",
       %{conn: conn, project: project, portal: portal} do
    {:ok, view, _html} = live(conn, "/portal/#{portal.slug}")

    {:ok, _} = Extensions.disable(project, "portal")

    assert render(view) =~ "This page is unavailable"
  end

  defp portal_issue_query(project_uuid) do
    from(a in PhoenixKitProjects.Schemas.Assignment,
      where: a.project_uuid == ^project_uuid and a.source == "portal"
    )
  end
end
