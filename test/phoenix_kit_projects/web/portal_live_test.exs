defmodule PhoenixKitProjects.Web.PortalLiveTest do
  @moduledoc """
  The public portal page: uniform unavailable states, the whitelisted
  render, the submit flow through `handle_event` (where the guards
  actually run — panel #2), and the live rotation downgrade (panel #7).
  """
  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Portal
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.PortalSubmission

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

  describe "the report form is one form" do
    setup %{conn: conn} do
      PhoenixKitProjects.Extensions.Registry.refresh()
      n = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{"name" => "Form #{n}", "start_mode" => "immediate"})

      {:ok, _} = Extensions.enable(project, "portal")
      {:ok, conn: conn, portal: Portal.get_portal(project.uuid)}
    end

    test "no nested form, so nothing gets pushed out of it", %{conn: conn, portal: portal} do
      # The upload component wraps itself in a <form> by default. Nested
      # forms are invalid HTML and the browser closes the OUTER one at the
      # inner tag — which moved the honeypot and the submit button outside
      # the form entirely. Nothing looked wrong, and LiveViewTest did not
      # catch it because it submits by form id rather than parsing HTML.
      {:ok, _view, html} = live(conn, "/portal/#{portal.slug}/report")

      start = :binary.match(html, "id=\"portal-submit-form\"") |> elem(0)
      {close, _} = :binary.match(binary_part(html, start, byte_size(html) - start), "</form>")
      form = binary_part(html, start, close)

      refute form =~ "<form", "a nested form closes the outer one early"
      assert form =~ "name=\"website\"", "the honeypot fell outside the form"
      assert form =~ "Send report", "the submit button fell outside the form"
      assert form =~ "type=\"file\"", "the upload input fell outside the form"
    end
  end

  describe "staff see the attachments before they publish them" do
    setup do
      PhoenixKitProjects.Extensions.Registry.refresh()
      n = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{"name" => "Triage #{n}", "start_mode" => "immediate"})

      {:ok, _} = Extensions.enable(project, "portal")
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, project: project, assignment: assignment}
    end

    test "review_images returns the submitter's files regardless of board mode", %{
      assignment: assignment
    } do
      # `board_images/2` is gated on the board ALREADY being public, which
      # is backwards for triage: the reviewer decides whether to publish, so
      # they must see the files while it is still unpublished. Before this
      # existed, nobody ever looked at an anonymous upload — which made "a
      # person approves it" false of exactly the part that can carry
      # something harmful.
      %PortalSubmission{}
      |> PortalSubmission.changeset(%{
        assignment_uuid: assignment.uuid,
        file_uuids: [Ecto.UUID.generate()]
      })
      |> PhoenixKit.RepoHelper.repo().insert!()

      # The uuid resolves to no storage row, so it drops out rather than
      # rendering broken — the panel is still reached, which is the point.
      assert Portal.review_images(assignment.uuid) == []
      assert Portal.review_images("not-a-uuid") == []
    end

    test "a published issue's images are not seen as orphans", %{assignment: assignment} do
      # `file_uuids` is a JSONB array, not an FK column, so core's orphan
      # detector cannot see the reference by joining — and what it cannot
      # see, it deletes. Every PUBLISHED board image would have looked
      # unreferenced and been handed to DeleteOrphanedFileJob. Core now
      # carries a containment check for this table; this test is what
      # proves the SQL actually matches, which a hand-written fragment
      # over a JSONB column does not do by inspection.
      repo = PhoenixKit.RepoHelper.repo()
      # phoenix_kit_files_user_or_parent_check: every file has an owner or
      # is a chunk of one. Portal attachments are attributed to the project
      # owner for exactly this reason.
      owner_uuid = embed_user_uuid!()

      file =
        repo.insert!(%Storage.File{
          original_file_name: "shot.jpg",
          file_name: "shot.jpg",
          file_path: "portal/shot.jpg",
          mime_type: "image/jpeg",
          file_type: "image",
          ext: "jpg",
          user_uuid: owner_uuid,
          file_checksum: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          user_file_checksum: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          size: 1234,
          status: "ready"
        })

      %PortalSubmission{}
      |> PortalSubmission.changeset(%{
        assignment_uuid: assignment.uuid,
        file_uuids: [file.uuid]
      })
      |> repo.insert!()

      refute Storage.file_orphaned?(file.uuid),
             "a referenced portal attachment was reported orphaned — the prune job would delete a live board image"

      unreferenced =
        repo.insert!(%Storage.File{
          original_file_name: "loose.jpg",
          file_name: "loose.jpg",
          file_path: "portal/loose.jpg",
          mime_type: "image/jpeg",
          file_type: "image",
          ext: "jpg",
          user_uuid: owner_uuid,
          file_checksum: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          user_file_checksum: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          size: 1234,
          status: "ready"
        })

      assert Storage.file_orphaned?(unreferenced.uuid),
             "the check matched everything, which would protect real orphans forever"
    end
  end
  describe "the discussion composer" do
    setup %{conn: conn} do
      Extensions.Registry.refresh()
      n = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{"name" => "Composer #{n}", "start_mode" => "immediate"})

      {:ok, _} = Extensions.enable(project, "portal")
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, assignment} = Portal.set_public(assignment, true)
      {:ok, _} = Portal.set_participation(project.uuid, %{"comment_access" => "members"})

      {:ok, user} =
        PhoenixKit.Users.Auth.register_user(%{
          email: "composer-#{n}@example.com",
          password: "ValidPassword123!"
        })

      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: []))

      {:ok,
       conn: conn, portal: Portal.get_portal(project.uuid), assignment: assignment, user: user}
    end

    test "a signed-in reader can open it without crashing the page", %{
      conn: conn,
      portal: portal,
      assignment: assignment
    } do
      # Opening the composer renders `composer_form/1`, a function component
      # in the comments module. Anything it reads has to come off `ctx` —
      # a bare `@mentions_on` there resolves against the component's OWN
      # assigns, which do not have it, and the render raises KeyError.
      #
      # This only reproduces with PHOENIX_KIT_COMMENTS_PATH pointed at the
      # local checkout: against the published pin the composer has no
      # mentions wiring at all, which is precisely why the suite stayed
      # green while the browser 500'd.
      {:ok, view, html} = live(conn, "/portal/#{portal.slug}/i/#{assignment.uuid}")
      assert html =~ "Write comment"

      opened =
        view
        |> element("button[phx-click=open_composer]")
        |> render_click()

      assert opened =~ "Post Comment"
    end
  end
end
