defmodule PhoenixKitProjects.PortalAccessTest do
  @moduledoc """
  The portal stops assuming its own secrecy.

  The load-bearing property is that nothing about an existing portal
  changes: `link` is the default, it behaves exactly as before, and no
  amount of flipping the new switches retroactively publishes work that was
  flagged for an audience of one client.
  """
  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKitProjects.{Extensions, Portal, Projects}
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
               [:description, :inserted_at, :status, :status_label, :title, :updated_at, :uuid]
    end
  end
end
