defmodule PhoenixKitProjects.Integration.PortalTest do
  @moduledoc """
  The public portal's security model (Phase J): slug lifecycle, the
  uniform-error doorway, the whitelisting DTO, cross-project isolation,
  and the submission guard chain — the hostile-input battery the design
  doc promised.
  """
  use PhoenixKitProjects.DataCase, async: false

  import Ecto.Query
  import PhoenixKitProjects.ActivityLogAssertions

  alias PhoenixKitProjects.Extensions
  alias PhoenixKitProjects.Portal
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Schemas.PortalSubmission

  @good_meta_base %{honeypot: "", peer_ip: {203, 0, 113, 7}}

  defp good_meta(overrides \\ %{}) do
    Map.merge(
      Map.put(@good_meta_base, :mounted_ms, System.monotonic_time(:millisecond) - 10),
      overrides
    )
  end

  defp fresh_ip do
    {203, 0, Enum.random(1..254), Enum.random(1..254)}
  end

  setup do
    PhoenixKitProjects.Extensions.Registry.refresh()
    project = fixture_project()
    {:ok, _} = Extensions.enable(project, "portal")
    portal = Portal.get_portal(project.uuid)
    {:ok, project: project, portal: portal}
  end

  describe "slug lifecycle" do
    test "enable provisions a CSPRNG slug; re-enable keeps it", %{
      project: project,
      portal: portal
    } do
      assert String.length(portal.slug) >= 20
      assert portal.slug =~ ~r/^[A-Za-z0-9_-]+$/

      {:ok, _} = Extensions.disable(project, "portal")
      {:ok, _} = Extensions.enable(project, "portal")
      assert Portal.get_portal(project.uuid).slug == portal.slug
    end

    test "rotation revokes: old slug uniform-errors, broadcast fires", %{
      project: project,
      portal: portal
    } do
      pubsub = PhoenixKitProjects.PubSub
      pubsub.subscribe(pubsub.topic_project(project.uuid))

      {:ok, rotated} = Portal.rotate_slug(project.uuid)

      assert rotated.slug != portal.slug
      assert Portal.resolve(portal.slug) == :error
      assert {:ok, _, _} = Portal.resolve(rotated.slug)

      project_uuid = project.uuid
      assert_receive {:projects, :portal_rotated, %{uuid: ^project_uuid}}, 500
      assert_activity_logged("projects.portal_link_rotated", resource_uuid: project.uuid)
    end
  end

  describe "resolve/1 — the uniform doorway" do
    test "valid slug resolves", %{portal: portal, project: project} do
      assert {:ok, _portal, resolved} = Portal.resolve(portal.slug)
      assert resolved.uuid == project.uuid
    end

    test "EVERY failure mode is the same :error", %{project: project, portal: portal} do
      # Unknown slug, junk shapes, disabled extension — indistinguishable.
      assert Portal.resolve("nope-#{Ecto.UUID.generate()}") == :error
      assert Portal.resolve(nil) == :error
      assert Portal.resolve("short") == :error
      assert Portal.resolve(String.duplicate("x", 200)) == :error
      assert Portal.resolve(%{evil: true}) == :error

      {:ok, _} = Extensions.disable(project, "portal")
      assert Portal.resolve(portal.slug) == :error
    end
  end

  describe "public_view/1 — the whitelist" do
    test "the DTO carries EXACTLY the whitelisted keys", %{portal: portal} do
      assert {:ok, view} = Portal.public_view(portal.slug)

      # Widening this list is a deliberate act, which is the point of
      # asserting it exactly. `access_mode` and the two `may_*` booleans
      # describe the page and the viewer's own permissions — not project
      # data — and the template needs them to avoid offering a control the
      # server would refuse.
      assert Map.keys(view) |> Enum.sort() ==
               [
                 :access_mode,
                 :capabilities,
                 :completed_at,
                 :issue_counts,
                 :issues,
                 :may_comment,
                 :may_submit,
                 :project_name,
                 :project_status,
                 :started_at
               ]
    end

    test "only PUBLIC issues appear, and only from THIS project", %{
      portal: portal,
      project: project
    } do
      other = fixture_project()
      {:ok, _} = Extensions.enable(other, "portal")

      mine_public = issue!(project, "Mine public")
      _mine_private = issue!(project, "Mine private", public: false)
      other_public = issue!(other, "Other public")

      {:ok, _} = Portal.set_public(mine_public, true)
      {:ok, _} = Portal.set_public(other_public, true)

      assert {:ok, view} = Portal.public_view(portal.slug)

      titles = Enum.map(view.issues, & &1.title)
      assert "Mine public" in titles
      refute "Mine private" in titles
      refute "Other public" in titles

      # Issue entries are whitelisted too — no assignee/estimate leakage.
      assert view.issues
             |> Enum.flat_map(&Map.keys/1)
             |> Enum.uniq()
             |> Enum.sort() ==
               [:inserted_at, :status, :status_label, :title, :updated_at]
    end

    test "the list capability off empties issues but keeps the page", %{
      portal: portal,
      project: project
    } do
      {:ok, _} = PhoenixKitProjects.Features.set_flags(project, %{"portal_list" => false})

      issue = issue!(project, "Hidden by flag")
      {:ok, _} = Portal.set_public(issue, true)

      assert {:ok, view} = Portal.public_view(portal.slug)
      assert view.issues == []
      refute view.capabilities.list
    end
  end

  describe "submit/3 — the guard chain" do
    test "happy path: task + assignment created, source portal, NOT public, activity logged",
         %{portal: portal, project: project} do
      assert {:ok, :submitted} =
               Portal.submit(
                 portal.slug,
                 %{"title" => "It breaks", "description" => "Details here"},
                 good_meta()
               )

      assignment =
        PhoenixKit.RepoHelper.repo().one(
          from(a in Assignment,
            where: a.project_uuid == ^project.uuid and a.source == "portal",
            preload: [:task]
          )
        )

      assert assignment
      assert assignment.public == false
      assert assignment.task.title == "It breaks"

      submission =
        PhoenixKit.RepoHelper.repo().get_by(PortalSubmission, assignment_uuid: assignment.uuid)

      assert submission
      assert is_binary(submission.ip_hash)
      # Telemetry-grade: truncated, never the raw address.
      refute submission.ip_hash =~ "203"

      assert_activity_logged("projects.portal_issue_submitted",
        resource_uuid: assignment.uuid,
        metadata_has: %{"source" => "portal"}
      )
    end

    test "honeypot filled → invalid, nothing created", %{portal: portal, project: project} do
      assert {:error, :invalid} =
               Portal.submit(
                 portal.slug,
                 %{"title" => "Spam", "description" => ""},
                 good_meta(%{honeypot: "http://spam"})
               )

      refute portal_assignment_exists?(project)
    end

    test "instant submit (min-fill-time) → invalid", %{portal: portal, project: project} do
      # Raise the window back up for this one test (config is 0 in test env).
      Application.put_env(:phoenix_kit_projects, :portal_min_fill_ms, 3_000)
      on_exit(fn -> Application.put_env(:phoenix_kit_projects, :portal_min_fill_ms, 0) end)

      assert {:error, :invalid} =
               Portal.submit(portal.slug, %{"title" => "Fast", "description" => ""}, good_meta())

      refute portal_assignment_exists?(project)
    end

    test "missing mount timestamp → invalid (replays are not our form)", %{portal: portal} do
      meta = good_meta() |> Map.delete(:mounted_ms)
      assert {:error, :invalid} = Portal.submit(portal.slug, %{"title" => "X"}, meta)
    end

    test "size caps: blank title, >200 title, >5000 description", %{portal: portal} do
      assert {:error, :invalid} =
               Portal.submit(portal.slug, %{"title" => "  ", "description" => ""}, good_meta())

      assert {:error, :invalid} =
               Portal.submit(
                 portal.slug,
                 %{"title" => String.duplicate("a", 201), "description" => ""},
                 good_meta()
               )

      assert {:error, :invalid} =
               Portal.submit(
                 portal.slug,
                 %{"title" => "ok", "description" => String.duplicate("d", 5001)},
                 good_meta()
               )
    end

    test "non-binary params never crash the doorway", %{portal: portal} do
      assert {:error, :invalid} =
               Portal.submit(portal.slug, %{"title" => %{"$gt" => ""}}, good_meta())

      assert {:error, :invalid} =
               Portal.submit(portal.slug, %{"title" => 42, "description" => [1, 2]}, good_meta())
    end

    test "per-IP minute limit: the 6th submit is rate_limited", %{portal: portal} do
      ip = fresh_ip()

      for n <- 1..5 do
        assert {:ok, :submitted} =
                 Portal.submit(
                   portal.slug,
                   %{"title" => "burst #{n}", "description" => ""},
                   good_meta(%{peer_ip: ip})
                 )
      end

      assert {:error, :rate_limited} =
               Portal.submit(
                 portal.slug,
                 %{"title" => "burst 6", "description" => ""},
                 good_meta(%{peer_ip: ip})
               )
    end

    test "submit capability off → uniform error", %{portal: portal, project: project} do
      {:ok, _} = PhoenixKitProjects.Features.set_flags(project, %{"portal_submit" => false})

      assert :error =
               Portal.submit(portal.slug, %{"title" => "Nope", "description" => ""}, good_meta())
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp issue!(project, title, opts \\ []) do
    {:ok, task} = Projects.create_task(%{"title" => title})

    {:ok, assignment} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

    if Keyword.get(opts, :public, false) do
      {:ok, a} = Portal.set_public(assignment, true)
      a
    else
      assignment
    end
  end

  defp portal_assignment_exists?(project) do
    PhoenixKit.RepoHelper.repo().exists?(
      from(a in Assignment, where: a.project_uuid == ^project.uuid and a.source == "portal")
    )
  end
end
