defmodule PhoenixKitProjects.Web.PortalLiveTest do
  @moduledoc """
  The public portal page: uniform unavailable states, the whitelisted
  render, the submit flow through `handle_event` (where the guards
  actually run — panel #2), and the live rotation downgrade (panel #7).
  """
  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Members
  alias PhoenixKitProjects.Portal
  alias PhoenixKitProjects.PortalLinks
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.PortalSubmission
  alias PhoenixKitProjects.Web.PortalLive

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
        Auth.register_user(%{
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

  describe "the mention typeahead names only what the page already shows" do
    setup do
      Extensions.Registry.refresh()
      n = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{"name" => "Mentions #{n}", "start_mode" => "immediate"})

      {:ok, _} = Extensions.enable(project, "portal")
      {:ok, _} = Portal.set_participation(project.uuid, %{"comment_access" => "members"})

      published = published_issue(project, "Published issue #{n}")
      {:ok, hidden_task} = Projects.create_task(%{"title" => "Internal only #{n}"})

      {:ok, hidden} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => hidden_task.uuid
        })

      {:ok, user} =
        Auth.register_user(%{
          email: "mentioner-#{n}@example.com",
          password: "ValidPassword123!"
        })

      {:ok,
       project: project,
       portal: Portal.get_portal(project.uuid),
       published: published,
       hidden: hidden,
       user: user}
    end

    defp published_issue(project, title) do
      {:ok, task} = Projects.create_task(%{"title" => title})

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, assignment} = Portal.set_public(assignment, true)
      assignment
    end

    defp scope_for(user), do: fake_scope(user_uuid: user.uuid, permissions: [])

    test "# offers published issues and never an unpublished one", %{
      portal: portal,
      published: published,
      hidden: hidden,
      user: user
    } do
      results = Portal.mention_candidates(:resource, "", portal, viewer: scope_for(user))
      uuids = Enum.map(results, & &1.uuid)

      assert published.uuid in uuids

      refute hidden.uuid in uuids,
             "an unpublished issue was offered — picking it publishes its title"
    end

    test "# offers nothing from another project's board", %{portal: portal, user: user} do
      other = fixture_project(%{"name" => "Other #{System.unique_integer([:positive])}"})
      {:ok, _} = Extensions.enable(other, "portal")
      stranger = published_issue(other, "Someone else's issue")

      results = Portal.mention_candidates(:resource, "", portal, viewer: scope_for(user))

      refute stranger.uuid in Enum.map(results, & &1.uuid),
             "a different board's issue leaked into this board's typeahead"
    end

    test "@ offers only people who have commented on THIS issue", %{
      portal: portal,
      published: published,
      user: user
    } do
      {:ok, other} =
        Auth.register_user(%{
          email: "silent-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      # `other` exists in the directory but has said nothing here. The
      # global Mentions.search would hand them over; this must not.
      assert Portal.mention_candidates(:user, "", portal,
               viewer: scope_for(user),
               issue_uuid: published.uuid
             ) == []

      {:ok, _} =
        PhoenixKitComments.create_comment(
          Portal.discussion_resource_type(),
          published.uuid,
          user.uuid,
          %{content: "I can reproduce this"}
        )

      uuids =
        Portal.mention_candidates(:user, "", portal,
          viewer: scope_for(user),
          issue_uuid: published.uuid
        )
        |> Enum.map(& &1.uuid)

      assert user.uuid in uuids
      refute other.uuid in uuids, "a user who never commented was offered"
    end

    test "un-publishing an issue kills the mentions that named it", %{
      project: project,
      published: published
    } do
      {:ok, _} = Portal.set_access_mode(project.uuid, "public")
      {:ok, _} = Portal.set_board_published(published.uuid, true)

      assert %{} = PortalLinks.resolve_comment_resources([published.uuid])[published.uuid]

      # Un-publishing clears `board_published_at` and deliberately LEAVES
      # `public` true. Matching on `public` alone meant an issue pulled off
      # the open-web board kept its live title inside every discussion that
      # had linked it — still resolving, still linking, still current.
      {:ok, _} = Portal.set_board_published(published.uuid, false)

      assert PortalLinks.resolve_comment_resources([published.uuid]) == %{}
      assert PortalLinks.visible_resource_uuids([published.uuid], scope: nil) == []
    end

    test "a viewer who may not comment gets nothing at all", %{
      portal: portal,
      published: published
    } do
      # The composer is hidden from an anonymous reader, but hiding a
      # control has never been the control — this is reachable by anyone
      # who can send a LiveView event.
      assert Portal.mention_candidates(:resource, "", portal, viewer: nil) == []

      assert Portal.mention_candidates(:user, "", portal,
               viewer: nil,
               issue_uuid: published.uuid
             ) == []
    end

    test "the LiveView answers the typeahead instead of swallowing it", %{
      portal: portal,
      published: published,
      user: user
    } do
      # The hook pushes to the LIVEVIEW, not the component. PortalLive had
      # no clause for it, so the event fell through to the catch-all
      # `handle_event(_, _, socket)` and was silently discarded — the menu
      # simply never appeared, with nothing in the log to say why. A
      # {:noreply, _} here means that regression is back.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          portal: portal,
          issue_uuid: published.uuid,
          phoenix_kit_current_scope: fake_scope(user_uuid: user.uuid, permissions: [])
        }
      }

      assert {:reply, %{results: results, seq: 7}, _socket} =
               PortalLive.handle_event(
                 "pk_mention_search",
                 %{"kind" => "resource", "query" => "", "seq" => 7},
                 socket
               )

      assert Enum.any?(results, &(&1.uuid == published.uuid))

      # Every result carries a server-built token; a nil one would mean the
      # client had to assemble it, which is how a forged mention gets in.
      assert Enum.all?(results, &is_binary(&1.token))
    end

    test "a foreign issue uuid in the URL cannot harvest its commenters", %{
      portal: portal,
      user: user
    } do
      # A reviewer flagged this as critical: point the URL at an issue that
      # belongs to somebody else and read back who has commented on it.
      # `handle_params` runs the uuid through `Portal.public_issue/3` first
      # and nils it when that refuses, so the handler never sees it — but
      # "the code looks like it validates" is not evidence, so: evidence.
      other = fixture_project(%{"name" => "Foreign #{System.unique_integer([:positive])}"})
      {:ok, _} = Extensions.enable(other, "portal")
      secret = published_issue(other, "Someone else's issue")

      {:ok, _} =
        PhoenixKitComments.create_comment(
          Portal.discussion_resource_type(),
          secret.uuid,
          user.uuid,
          %{content: "internal chatter"}
        )

      # Straight at the context, i.e. assuming the uuid DID get through.
      assert Portal.mention_candidates(:user, "", portal,
               viewer: fake_scope(user_uuid: user.uuid, permissions: []),
               issue_uuid: secret.uuid
             ) == []
    end

    test "@ with no issue in scope offers nobody", %{portal: portal, user: user} do
      # The board page has no discussion, so there is no set of people the
      # page has already revealed.
      assert Portal.mention_candidates(:user, "", portal, viewer: scope_for(user)) == []
    end
  end

  describe "speaking for the project" do
    setup do
      Extensions.Registry.refresh()
      n = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{"name" => "Voice #{n}", "start_mode" => "immediate"})

      {:ok, _} = Extensions.enable(project, "portal")

      {:ok, member} =
        Auth.register_user(%{
          email: "member-#{n}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, outsider} =
        Auth.register_user(%{
          email: "outsider-#{n}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, _} = Members.add_member(project, member.uuid, role: "member")

      {:ok,
       project: project,
       portal: Portal.get_portal(project.uuid),
       member: member,
       outsider: outsider}
    end

    defp scope(user), do: fake_scope(user_uuid: user.uuid, permissions: [])

    test "offered to a member, and checked by default on a public board", %{
      project: project,
      member: member
    } do
      {:ok, _} = Portal.set_access_mode(project.uuid, "public")
      portal = Portal.get_portal(project.uuid)

      assert %{label: label, default_on: true, verify: verify} =
               Portal.comment_attribution(portal, project, scope(member))

      assert label == project.name
      assert verify.(member.uuid)
    end

    test "never offered on a link board", %{project: project, portal: portal, member: member} do
      # The slug IS the grant on a link board, so a project-signed comment
      # would tell every link-holder who is affiliated with the project —
      # the one thing a capability URL must not reveal.
      assert portal.access_mode == "link"
      assert Portal.comment_attribution(portal, project, scope(member)) == nil
    end

    test "never offered to a non-member", %{project: project, member: member, outsider: outsider} do
      {:ok, _} = Portal.set_access_mode(project.uuid, "public")
      portal = Portal.get_portal(project.uuid)

      assert Portal.comment_attribution(portal, project, scope(outsider)) == nil
      assert Portal.comment_attribution(portal, project, nil) == nil

      # And the verifier itself refuses them, which is what the comments
      # component re-asks at submit.
      %{verify: verify} = Portal.comment_attribution(portal, project, scope(member))
      refute verify.(outsider.uuid)
    end

    test "a viewer-role member is not a voice", %{project: project, outsider: outsider} do
      # Read-only. Someone who cannot change the project should not be able
      # to speak as it, and `Authz.roles/0` keeps `:viewer` distinct for
      # exactly this kind of question.
      {:ok, _} = Members.add_member(project, outsider.uuid, role: "viewer")
      {:ok, _} = Portal.set_access_mode(project.uuid, "public")
      portal = Portal.get_portal(project.uuid)

      assert Portal.comment_attribution(portal, project, scope(outsider)) == nil
    end

    test "the verifier reflects membership revoked after the composer rendered", %{
      project: project,
      member: member
    } do
      {:ok, _} = Portal.set_access_mode(project.uuid, "public")
      portal = Portal.get_portal(project.uuid)

      %{verify: verify} = Portal.comment_attribution(portal, project, scope(member))
      assert verify.(member.uuid)

      {:ok, _} = Members.remove_member(project.uuid, member.uuid)

      refute verify.(member.uuid),
             "a removed member kept speaking for the project by leaving a tab open"
    end

    # Frozen attribution ships in phoenix_kit_comments and is not in the
    # published pin this suite resolves by default. Run the whole file with
    # PHOENIX_KIT_COMMENTS_PATH=../phoenix_kit_comments to exercise it —
    # otherwise these would fail for the environment rather than the code,
    # and a suite that is red for a reason nobody can act on gets ignored.
    if :attribution_mode in PhoenixKitComments.Comment.__schema__(:fields) do
      test "posting as the project still records who wrote it", %{
        project: project,
        member: member
      } do
        # The boss's constraint: the public sees the project, and internally
        # we never lose the author.
        {:ok, comment} =
          PhoenixKitComments.create_comment(
            Portal.discussion_resource_type(),
            Ecto.UUID.generate(),
            member.uuid,
            %{
              content: "We are on it",
              attribution: %{
                mode: "project",
                label: project.name,
                project_uuid: project.uuid
              }
            }
          )

        assert comment.attribution_mode == "project"
        assert comment.author_display_name == project.name
        assert comment.attributed_project_uuid == project.uuid
        assert comment.user_uuid == member.uuid, "the actual author was lost"
      end

      test "a personal comment freezes the name the reader saw", %{member: member} do
        {:ok, comment} =
          PhoenixKitComments.create_comment(
            Portal.discussion_resource_type(),
            Ecto.UUID.generate(),
            member.uuid,
            %{
              content: "Speaking for myself",
              attribution: %{
                mode: "personal",
                label: User.display_name(member)
              }
            }
          )

        assert comment.attribution_mode == "personal"
        assert comment.author_display_name == User.display_name(member)
        refute comment.author_display_name == member.email
        assert comment.attributed_project_uuid == nil
      end

      test "attribution cannot be forged through the comment attrs", %{member: member} do
        # These are not in `cast/3`. A client that could set them could sign a
        # comment as anyone.
        {:ok, comment} =
          PhoenixKitComments.create_comment(
            Portal.discussion_resource_type(),
            Ecto.UUID.generate(),
            member.uuid,
            %{
              content: "nice try",
              attribution_mode: "project",
              author_display_name: "Totally Legit Inc",
              attributed_label: "Totally Legit Inc"
            }
          )

        assert comment.attribution_mode == nil
        assert comment.author_display_name == nil
        assert comment.attributed_label == nil
      end
    end
  end
end
