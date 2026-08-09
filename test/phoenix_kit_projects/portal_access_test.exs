defmodule PhoenixKitProjects.PortalAccessTest do
  @moduledoc """
  The portal stops assuming its own secrecy.

  The load-bearing property is that nothing about an existing portal
  changes: `link` is the default, it behaves exactly as before, and no
  amount of flipping the new switches retroactively publishes work that was
  flagged for an audience of one client.
  """
  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Extensions, Members, Portal, Projects}
  alias PhoenixKitProjects.Schemas.Portal, as: PortalRow

  defp uniq, do: System.unique_integer([:positive])

  setup do
    PhoenixKitProjects.Extensions.Registry.refresh()

    {:ok, project} =
      Projects.create_project(%{"name" => "Board #{uniq()}", "start_mode" => "immediate"})

    {:ok, _} = Extensions.enable(project, "portal")

    {:ok, project: project, portal: Portal.get_portal(project.uuid)}
  end

  defp signed_in, do: %{user: %{uuid: Ecto.UUID.generate()}}

  describe "defaults preserve today's portal" do
    test "a fresh portal is a secret link that nobody may comment on", %{portal: portal} do
      assert portal.access_mode == "link"
      assert portal.submit_access == "anyone"
      assert portal.comment_access == "nobody"
      assert String.length(portal.slug) == 22
    end

    test "link mode admits anyone holding the slug", %{portal: portal} do
      assert {:ok, _, _} = Portal.resolve(portal.slug, nil)
    end
  end

  describe "members mode" do
    setup %{project: project} do
      {:ok, portal} = Portal.set_access_mode(project.uuid, "members")
      {:ok, portal: portal}
    end

    test "refuses an anonymous visitor", %{portal: portal} do
      assert Portal.resolve(portal.slug, nil) == :error
    end

    test "admits any signed-in user", %{portal: portal} do
      assert {:ok, _, _} = Portal.resolve(portal.slug, signed_in())
    end

    test "keeps an unguessable slug — there is nothing to gain by dropping it", %{portal: portal} do
      assert String.length(portal.slug) == 22
    end
  end

  describe "public mode" do
    test "takes a human slug and admits anyone", %{project: project} do
      {:ok, portal} = Portal.set_access_mode(project.uuid, "public", slug: "acme-board-#{uniq()}")

      assert portal.access_mode == "public"
      assert {:ok, _, _} = Portal.resolve(portal.slug, nil)
    end

    test "refuses a reserved slug", %{project: project} do
      assert {:error, _} = Portal.set_access_mode(project.uuid, "public", slug: "admin")
    end

    test "refuses a slug that isn't a slug", %{project: project} do
      assert {:error, _} = Portal.set_access_mode(project.uuid, "public", slug: "Not A Slug")
    end

    test "a rename is validated, not waved through", %{project: project} do
      {:ok, _} = Portal.set_access_mode(project.uuid, "public", slug: "good-name-#{uniq()}")

      # Same mode, new slug: an early "nothing changed" return here is how
      # an invalid slug would sail past validation.
      assert {:error, _} = Portal.set_access_mode(project.uuid, "public", slug: "admin")
    end

    test "a rename actually renames", %{project: project} do
      {:ok, _} = Portal.set_access_mode(project.uuid, "public", slug: "first-name-#{uniq()}")
      wanted = "second-name-#{uniq()}"

      assert {:ok, portal} = Portal.set_access_mode(project.uuid, "public", slug: wanted)
      assert portal.slug == wanted
    end
  end

  describe "changing mode mints a new slug" do
    test "leaving link, so the old secret stops working", %{project: project, portal: portal} do
      {:ok, updated} = Portal.set_access_mode(project.uuid, "members")

      refute updated.slug == portal.slug
      assert Portal.resolve(portal.slug, signed_in()) == :error
    end

    test "leaving public, so an indexed name never becomes a secret", %{project: project} do
      {:ok, public} = Portal.set_access_mode(project.uuid, "public", slug: "indexed-#{uniq()}")
      {:ok, back} = Portal.set_access_mode(project.uuid, "link")

      refute back.slug == public.slug
      assert String.length(back.slug) == 22
      assert Portal.resolve(public.slug, nil) == :error
    end
  end

  describe "the blast radius of going public" do
    setup %{project: project} do
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      # Flagged public under link-mode semantics: "whoever holds the link".
      {:ok, assignment} = Portal.set_public(assignment, true)
      {:ok, assignment: assignment}
    end

    test "the count is available before the switch", %{project: project} do
      assert Portal.board_exposure_count(project.uuid) == 1
    end

    test "going public publishes NOTHING by default", %{project: project, portal: portal} do
      # The whole guard: a task flagged for link-holders is not a task
      # flagged for the open web, and the switch must not decide otherwise.
      assert {:ok, _, _} = Portal.resolve(portal.slug, nil)
      assert %{issues: [_]} = elem(Portal.public_view(portal.slug, nil), 1)

      {:ok, public} = Portal.set_access_mode(project.uuid, "public", slug: "empty-#{uniq()}")
      {:ok, view} = Portal.public_view(public.slug, nil)

      assert view.issues == [], "switching to public retroactively published existing work"
    end

    test "...unless the admin explicitly asks", %{project: project} do
      {:ok, public} =
        Portal.set_access_mode(project.uuid, "public",
          slug: "filled-#{uniq()}",
          publish_existing: true
        )

      {:ok, view} = Portal.public_view(public.slug, nil)
      assert length(view.issues) == 1
    end

    test "leaving public resets the board, so coming back is a fresh decision", %{
      project: project,
      assignment: assignment
    } do
      {:ok, _} =
        Portal.set_access_mode(project.uuid, "public",
          slug: "first-run-#{uniq()}",
          publish_existing: true
        )

      # Going private is usually a reaction to a problem. Coming back must
      # not silently restore what was on the board before.
      {:ok, _} = Portal.set_access_mode(project.uuid, "link")
      {:ok, again} = Portal.set_access_mode(project.uuid, "public", slug: "second-run-#{uniq()}")

      {:ok, view} = Portal.public_view(again.slug, nil)
      assert view.issues == []

      assert Projects.get_assignment(assignment.uuid).board_published_at == nil
    end

    test "a task can be put on the board and taken off again", %{
      project: project,
      assignment: assignment
    } do
      {:ok, public} = Portal.set_access_mode(project.uuid, "public", slug: "toggle-#{uniq()}")

      {:ok, 1} = Portal.set_board_published(assignment.uuid, true)
      assert %{issues: [_]} = elem(Portal.public_view(public.slug, nil), 1)

      {:ok, 1} = Portal.set_board_published(assignment.uuid, false)
      assert %{issues: []} = elem(Portal.public_view(public.slug, nil), 1)
    end

    test "taking it off the board leaves the link-holder view alone", %{
      project: project,
      assignment: assignment
    } do
      {:ok, 1} = Portal.set_board_published(assignment.uuid, false)
      {:ok, link} = Portal.set_access_mode(project.uuid, "link")

      assert %{issues: [_]} = elem(Portal.public_view(link.slug, nil), 1)
    end
  end

  describe "participation" do
    test "commenting is off until someone turns it on", %{project: project, portal: portal} do
      refute Portal.may_comment?(portal, project, signed_in())
    end

    test "members-only commenting admits signed-in and refuses anonymous", %{
      project: project
    } do
      {:ok, portal} = Portal.set_participation(project.uuid, %{"comment_access" => "members"})

      assert Portal.may_comment?(portal, project, signed_in())
      refute Portal.may_comment?(portal, project, nil)
    end

    test "\"anyone\" does not yet mean anonymous, and says so", %{project: project} do
      # Storing the intent is fine; honouring it without a guest identity
      # model would make "Alice from Acme" a text field anyone can type.
      {:ok, portal} = Portal.set_participation(project.uuid, %{"comment_access" => "anyone"})

      assert portal.comment_access == "anyone"
      refute Portal.may_comment?(portal, project, nil)
      assert Portal.may_comment?(portal, project, signed_in())
      assert Portal.comment_access_note() =~ "guest identity"
    end

    test "submission policy can require a signed-in user", %{project: project} do
      {:ok, portal} = Portal.set_participation(project.uuid, %{"submit_access" => "members"})

      assert Portal.may_submit?(portal, project, signed_in())
      refute Portal.may_submit?(portal, project, nil)
    end

    test "a bad policy value is refused, not coerced", %{project: project} do
      assert {:error, _} = Portal.set_participation(project.uuid, %{"comment_access" => "sure"})
    end
  end

  describe "the DTO does not widen for a public board" do
    test "the same fields ship in every mode", %{project: project, portal: portal} do
      {:ok, link_view} = Portal.public_view(portal.slug, nil)
      {:ok, public} = Portal.set_access_mode(project.uuid, "public", slug: "same-#{uniq()}")
      {:ok, public_view} = Portal.public_view(public.slug, nil)

      # If a field is too hot to show a link-holder it is far hotter shown
      # to a crawler; per-mode field lists are how that discipline rots.
      assert Map.keys(link_view) == Map.keys(public_view)
    end
  end

  describe "one issue and its discussion" do
    setup %{project: project} do
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, assignment} = Portal.set_public(assignment, true)
      {:ok, assignment: assignment}
    end

    test "a published issue is fetchable by uuid", %{portal: portal, assignment: assignment} do
      assert {:ok, issue} = Portal.public_issue(portal.slug, assignment.uuid, nil)
      assert issue.uuid == assignment.uuid
      assert is_binary(issue.title)
    end

    test "an issue that isn't public is indistinguishable from one that doesn't exist", %{
      portal: portal,
      assignment: assignment
    } do
      {:ok, _} = Portal.set_public(assignment, false)

      assert Portal.public_issue(portal.slug, assignment.uuid, nil) == :error
      assert Portal.public_issue(portal.slug, Ecto.UUID.generate(), nil) == :error
    end

    test "on a public board it must be published to the BOARD, not merely public", %{
      project: project,
      assignment: assignment
    } do
      {:ok, public} = Portal.set_access_mode(project.uuid, "public", slug: "issues-#{uniq()}")

      # Same guard as the list: `public` was a promise to link-holders.
      assert Portal.public_issue(public.slug, assignment.uuid, nil) == :error

      {:ok, 1} = Portal.set_board_published(assignment.uuid, true)
      assert {:ok, _} = Portal.public_issue(public.slug, assignment.uuid, nil)
    end

    test "a members board refuses an anonymous reader the issue too", %{
      project: project,
      assignment: assignment
    } do
      {:ok, members} = Portal.set_access_mode(project.uuid, "members")

      assert Portal.public_issue(members.slug, assignment.uuid, nil) == :error
      assert {:ok, _} = Portal.public_issue(members.slug, assignment.uuid, signed_in())
    end

    test "the issue DTO carries exactly what the page needs", %{
      portal: portal,
      assignment: assignment
    } do
      {:ok, issue} = Portal.public_issue(portal.slug, assignment.uuid, nil)

      assert Map.keys(issue) |> Enum.sort() ==
               [
                 :description,
                 :images,
                 :inserted_at,
                 :status,
                 :status_label,
                 :title,
                 :updated_at,
                 :uuid
               ]
    end
  end

  describe "findings from the review panel" do
    setup %{project: project} do
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo",
          "description" => "Internal note nobody outside should read"
        })

      {:ok, assignment} = Portal.set_public(assignment, true)
      {:ok, assignment: assignment}
    end

    test "the submit policy is enforced in the WRITE path, not just the UI", %{
      project: project,
      portal: portal
    } do
      {:ok, _} = Portal.set_participation(project.uuid, %{"submit_access" => "members"})

      meta = %{peer_ip: {127, 0, 0, 1}, honeypot: nil, mounted_ms: -60_000, viewer: nil}
      attrs = %{"title" => "Forged", "description" => "via a hidden form"}

      # A hidden form is a courtesy; this is the control.
      assert Portal.submit(portal.slug, attrs, meta) == :error
    end

    test "a task description is NOT exposed on a link portal", %{
      portal: portal,
      assignment: assignment
    } do
      # The portal has never shown descriptions in any mode. Adding them to
      # every existing link portal on deploy would be retroactive exposure
      # arriving through a side door.
      {:ok, issue} = Portal.public_issue(portal.slug, assignment.uuid, nil)

      refute issue.description
    end

    test "...but a task published to a PUBLIC board shows its text", %{
      project: project,
      assignment: assignment
    } do
      {:ok, public} = Portal.set_access_mode(project.uuid, "public", slug: "desc-#{uniq()}")
      {:ok, 1} = Portal.set_board_published(assignment.uuid, true)

      {:ok, issue} = Portal.public_issue(public.slug, assignment.uuid, nil)
      assert issue.description =~ "Internal note"
    end

    test "a disabled portal stops answering what its mode was", %{
      project: project,
      portal: portal
    } do
      # Otherwise a members board's "Sign in to view" page confirms the slug
      # exists, which is exactly the oracle the uniform failure prevents.
      {:ok, _} = Portal.set_access_mode(project.uuid, "members")
      {:ok, _} = Extensions.disable(project, "portal")

      assert Portal.access_mode_of(portal.slug) == "link"
    end

    test "a capability slug cannot be hand-set through the API", %{project: project} do
      # 16 CSPRNG bytes is the mandate; "aaaaaaaaaaaaaaaa" satisfies a
      # length check and nothing else.
      assert {:error, _} =
               Portal.set_access_mode(project.uuid, "link", slug: "aaaaaaaaaaaaaaaa")
    end

    test "going public without a chosen slug still produces a valid one", %{project: project} do
      # The fallback used to generate url-base64, which the public-slug
      # validator rejects — so the documented path failed every time.
      assert {:ok, portal} = Portal.set_access_mode(project.uuid, "public")
      assert portal.access_mode == "public"
      assert portal.slug =~ ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    end

    test "publishing to the board implies public", %{assignment: assignment} do
      {:ok, _} = Portal.set_public(assignment, false)
      {:ok, 1} = Portal.set_board_published(assignment.uuid, true)

      reloaded = Projects.get_assignment(assignment.uuid)
      assert reloaded.public
      assert reloaded.board_published_at
    end

    test "the portal's discussion namespace is not the admin's" do
      # Staff notes live on resource_type "assignment" (the hub's comments
      # drawer); the public board uses its own. If these ever converge,
      # every internal note ever written lands on a public page.
      assert Portal.discussion_resource_type() != "assignment"
      assert Portal.discussion_resource_type() != "project"
    end
  end

  describe "the anonymous failure page tells you nothing" do
    test "a real members board looks exactly like an unknown slug", %{project: project} do
      # Otherwise any candidate URL becomes an existence probe: unknown
      # said \"unavailable\", real said \"sign in\".
      {:ok, members} = Portal.set_access_mode(project.uuid, "members")

      assert Portal.resolve(members.slug, nil) == :error
      assert Portal.resolve("no-such-slug-at-all", nil) == :error
    end

    test "and a disabled portal does too", %{project: project, portal: portal} do
      {:ok, _} = Portal.set_access_mode(project.uuid, "members")
      {:ok, _} = Extensions.disable(project, "portal")

      assert Portal.access_mode_of(portal.slug) == "link"
    end
  end

  describe "screenshots on a report" do
    @describetag :tmp_dir

    setup %{project: project} do
      # An uploaded file needs an owner — core's invariant — and the
      # project's owner is who it belongs to. A project created through
      # the UI always has one; this fixture creates projects without an
      # actor, so it has to say so explicitly.
      {:ok, user} =
        Auth.register_user(%{
          "email" => "owner-#{uniq()}@example.com",
          "password" => "ValidPassword123!"
        })

      {:ok, _} = Members.add_member(project, user.uuid, role: "owner")
      :ok
    end

    defp make_png(dir, name) do
      path = Path.join(dir, name)
      {_, 0} = System.cmd("convert", ["-size", "40x40", "xc:red", path], stderr_to_stdout: true)
      path
    end

    defp imagemagick? do
      match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))
    rescue
      _ -> false
    end

    test "a valid image is stored, re-encoded", %{tmp_dir: dir, project: project} do
      if imagemagick?() do
        path = make_png(dir, "shot.png")

        assert {:ok, [uuid]} =
                 Portal.store_attachments([%{path: path, name: "shot.png"}], project.uuid)

        assert is_binary(uuid)
      end
    end

    test "an appended payload does not survive into storage", %{tmp_dir: dir, project: project} do
      if imagemagick?() do
        path = make_png(dir, "poly.png")
        File.write!(path, "\n<script>alert(1)</script>NEEDLE", [:append])

        assert {:ok, [uuid]} =
                 Portal.store_attachments([%{path: path, name: "poly.png"}], project.uuid)

        stored = Storage.get_file(uuid)
        assert stored, "the file should have been stored"
        # Whatever went in, what came out is our encoder's output.
        # Whatever went in, what came out is our encoder's output — note the
        # upload claimed .png and the stored file is a jpeg.
        assert stored.mime_type == "image/jpeg"
      end
    end

    test "something that isn't an image is refused whatever it's named", %{
      tmp_dir: dir,
      project: project
    } do
      path = Path.join(dir, "screenshot.png")
      File.write!(path, "#!/bin/sh\nrm -rf /\n")

      assert Portal.store_attachments([%{path: path, name: "screenshot.png"}], project.uuid) ==
               {:error, :invalid}
    end

    test "too many files is refused before anything is stored", %{tmp_dir: dir, project: project} do
      if imagemagick?() do
        files =
          for i <- 1..(Portal.attachment_limits().count + 1) do
            %{path: make_png(dir, "s#{i}.png"), name: "s#{i}.png"}
          end

        assert Portal.store_attachments(files, project.uuid) == {:error, :invalid}
      end
    end

    test "one bad file refuses the whole report", %{tmp_dir: dir, project: project} do
      if imagemagick?() do
        good = %{path: make_png(dir, "good.png"), name: "good.png"}
        bad_path = Path.join(dir, "bad.png")
        File.write!(bad_path, "nope")

        # A report that silently loses the screenshot it refers to is worse
        # than one that says so.
        assert Portal.store_attachments([good, %{path: bad_path, name: "bad.png"}], project.uuid) ==
                 {:error, :invalid}
      end
    end

    test "no files is not an error" do
      assert Portal.store_attachments([], nil) == {:ok, []}
    end

    test "images reach the issue page only on a public board", %{project: project, portal: portal} do
      task = fixture_task()

      {:ok, assignment} =
        Projects.create_assignment(%{
          "project_uuid" => project.uuid,
          "task_uuid" => task.uuid,
          "status" => "todo"
        })

      {:ok, assignment} = Portal.set_public(assignment, true)

      # Link board: the description is withheld and so are the images.
      {:ok, issue} = Portal.public_issue(portal.slug, assignment.uuid, nil)
      assert issue.images == []

      {:ok, public} = Portal.set_access_mode(project.uuid, "public", slug: "shots-#{uniq()}")
      {:ok, 1} = Portal.set_board_published(assignment.uuid, true)

      {:ok, issue} = Portal.public_issue(public.slug, assignment.uuid, nil)
      assert is_list(issue.images)
    end
  end
end
