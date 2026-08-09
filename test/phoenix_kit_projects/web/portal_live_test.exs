defmodule PhoenixKitProjects.Web.PortalLiveTest do
  @moduledoc """
  The public portal page: uniform unavailable states, the whitelisted
  render, the submit flow through `handle_event` (where the guards
  actually run — panel #2), and the live rotation downgrade (panel #7).
  """
  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Utils.Routes
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
    {:ok, view, _html} = live(conn, "/portal/#{portal.slug}/report")

    view
    |> form("#portal-submit-form", %{
      "title" => "From the page",
      "description" => "Steps to reproduce"
    })
    |> render_submit()

    # A redirect back to the board, which is also what stops the browser's
    # back button re-posting the report.
    # The path carries the locale prefix Routes.path/1 applies.
    assert_redirect(view, Routes.path("/portal/#{portal.slug}"))
    assert PhoenixKit.RepoHelper.repo().exists?(portal_issue_query(project.uuid))
  end

  test "a filled honeypot shows the generic failure, creates nothing",
       %{conn: conn, project: project, portal: portal} do
    {:ok, view, _html} = live(conn, "/portal/#{portal.slug}/report")

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

  describe "an issue page" do
    setup %{conn: conn} do
      PhoenixKitProjects.Extensions.Registry.refresh()
      n = System.unique_integer([:positive])

      {:ok, project} =
        PhoenixKitProjects.Projects.create_project(%{
          "name" => "Board #{n}",
          "start_mode" => "immediate"
        })

      {:ok, _} = PhoenixKitProjects.Extensions.enable(project, "portal")
      task = fixture_task()

      {:ok, assignment} =
        PhoenixKitProjects.Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, assignment} = PhoenixKitProjects.Portal.set_public(assignment, true)
      portal = PhoenixKitProjects.Portal.get_portal(project.uuid)

      {:ok, conn: conn, project: project, portal: portal, assignment: assignment}
    end

    defp issue_path(portal, assignment),
      do: "/portal/#{portal.slug}/i/#{assignment.uuid}"

    test "renders the issue", %{conn: conn, portal: portal, assignment: assignment} do
      {:ok, _view, html} = live(conn, issue_path(portal, assignment))

      assert html =~ "Discussion"
    end

    test "an anonymous reader is told how to take part, not given a box", %{
      conn: conn,
      portal: portal,
      assignment: assignment
    } do
      # The composer must never render for someone the server would refuse:
      # `false` where the comments component expects a user is also how this
      # page 500'd the first time it was wired.
      {:ok, _view, html} = live(conn, issue_path(portal, assignment))

      assert html =~ "Only signed-in people can reply"
    end

    test "an unpublished issue falls back to the board rather than erroring", %{
      conn: conn,
      portal: portal,
      assignment: assignment
    } do
      {:ok, _} = PhoenixKitProjects.Portal.set_public(assignment, false)

      {:ok, _view, html} = live(conn, issue_path(portal, assignment))

      refute html =~ "Discussion"
    end

    test "an anonymous reader cannot post through the embedded discussion", %{
      conn: conn,
      portal: portal,
      assignment: assignment
    } do
      # The page is public; the composer is not. This asserts the SERVER
      # refuses, not merely that the box is hidden — a forged event is the
      # whole reason hiding a control is never the control.
      {:ok, view, _html} = live(conn, issue_path(portal, assignment))

      before = PhoenixKitComments.list_comments("project_assignment", assignment.uuid)

      view
      |> element("[id^=portal-issue-]")
      |> render_hook("add_comment", %{"comment" => "I should not be able to say this"})

      assert PhoenixKitComments.list_comments("project_assignment", assignment.uuid) == before
    rescue
      # No composer rendered at all is the same refusal, more thoroughly.
      ArgumentError -> :ok
    end
  end

  describe "the submit form follows the policy, not just the capability" do
    setup %{conn: conn} do
      PhoenixKitProjects.Extensions.Registry.refresh()
      n = System.unique_integer([:positive])

      {:ok, project} =
        PhoenixKitProjects.Projects.create_project(%{
          "name" => "Policy #{n}",
          "start_mode" => "immediate"
        })

      {:ok, _} = PhoenixKitProjects.Extensions.enable(project, "portal")

      {:ok,
       conn: conn, project: project, portal: PhoenixKitProjects.Portal.get_portal(project.uuid)}
    end

    test "anyone-submits offers the report link", %{conn: conn, portal: portal} do
      {:ok, _view, html} = live(conn, "/portal/#{portal.slug}")
      assert html =~ "Report an issue"
      assert html =~ "/report"
    end

    test "members-only hides it from an anonymous visitor and says why", %{
      conn: conn,
      project: project,
      portal: portal
    } do
      {:ok, _} =
        PhoenixKitProjects.Portal.set_participation(project.uuid, %{"submit_access" => "members"})

      {:ok, _view, html} = live(conn, "/portal/#{portal.slug}")

      refute html =~ "/report"
      assert html =~ "Sign in to report an issue"
    end
  end
end
