defmodule PhoenixKitProjects.Web.ProjectHubPagesTest do
  @moduledoc """
  P2b surfaces: the Files page (built-in `files` extension + Attachments),
  the Activity page (core feed via resource_uuid), and project health (the
  manual Needle) on the show page.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Attachments, Extensions, Health, Projects}

  setup %{conn: conn} do
    PhoenixKitProjects.Extensions.Registry.refresh()
    conn = put_test_scope(conn, fake_scope())
    {:ok, conn: conn, project: fixture_project()}
  end

  describe "Files page" do
    test "renders empty state; folder resolves lazily (none until needed)",
         %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/files")

      assert html =~ "No files yet."
      assert Attachments.folder_uuid(project.uuid) == nil
    end

    test "open_picker ensures the folder; media_selected attaches + logs",
         %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, "/en/admin/projects/list/#{project.uuid}/files")

      render_click(view, "open_picker", %{})
      assert folder_uuid = Attachments.folder_uuid(project.uuid)

      # Simulate the modal's plain-LV notify with a real stored file (the
      # files table requires an owning user or parent).
      {:ok, uploader} =
        Auth.register_user(%{
          email: "uploader-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, file} =
        %Storage.File{}
        |> Ecto.Changeset.change(%{
          user_uuid: uploader.uuid,
          original_file_name: "spec.pdf",
          file_name: "spec.pdf",
          file_path: "/tmp/spec.pdf",
          ext: "pdf",
          file_type: "document",
          mime_type: "application/pdf",
          file_checksum: "test-checksum-#{System.unique_integer([:positive])}",
          user_file_checksum: "user-checksum-#{System.unique_integer([:positive])}",
          size: 123,
          status: "active"
        })
        |> PhoenixKit.RepoHelper.repo().insert()

      send(view.pid, {:media_selected, [file.uuid]})
      html = render(view)

      assert html =~ "spec.pdf"
      assert [listed] = Attachments.list_files(project.uuid)
      assert listed.uuid == file.uuid
      assert listed_folder(listed, folder_uuid)
    end

    test "the files extension off bounces the page", %{conn: conn, project: project} do
      {:ok, _} = Extensions.disable(project, "files")

      {:error, {:live_redirect, %{to: to}}} =
        live(conn, "/en/admin/projects/list/#{project.uuid}/files")

      assert to =~ "/admin/projects"
    end
  end

  describe "Activity page" do
    test "shows this project's rows only, newest first", %{conn: conn, project: project} do
      other = fixture_project(%{"name" => "Other #{System.unique_integer([:positive])}"})

      PhoenixKit.Activity.log(%{
        action: "projects.project_updated",
        module: "projects",
        resource_type: "project",
        resource_uuid: project.uuid,
        metadata: %{"marker" => "mine"}
      })

      PhoenixKit.Activity.log(%{
        action: "projects.project_updated",
        module: "projects",
        resource_type: "project",
        resource_uuid: other.uuid,
        metadata: %{"marker" => "not-mine"}
      })

      {:ok, _view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}/activity")

      assert html =~ "mine"
      refute html =~ "not-mine"
    end
  end

  describe "project health (the Needle)" do
    test "context: set/get round-trip, invalid status refused", %{project: project} do
      assert Health.get(project) == nil
      assert {:error, :invalid_status} = Health.set(project, "amazing")

      {:ok, project} = Health.set(project, "some_risk", "Supplier slipping")
      health = Health.get(project)
      assert health["status"] == "some_risk"
      assert health["note"] == "Supplier slipping"

      # Note trims to absent; previous status recorded in the activity row.
      {:ok, project} = Health.set(project, "on_track", "   ")
      refute Health.get(project)["note"]
    end

    test "show page renders the strip and saves through the modal",
         %{conn: conn, project: project} do
      {:ok, project} = Health.set(project, "concerned", "Two blockers")

      {:ok, view, html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      assert html =~ "Concerned"
      assert html =~ "Two blockers"

      render_click(view, "open_health_modal", %{})
      html = render_submit(view, "save_health", %{"status" => "on_track", "note" => ""})

      assert html =~ "On track"
      assert Health.get(Projects.get_project(project.uuid))["status"] == "on_track"
    end

    test "a scope without permission cannot save health", %{project: project} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_test_scope(fake_scope(permissions: []))

      # Without the projects permission the page itself is gated upstream;
      # exercise the resolver directly for the event-level check.
      refute PhoenixKitProjects.Authz.can?(
               fake_scope(permissions: []),
               project,
               :set_health
             )

      # And the admin-scoped path allows it.
      assert PhoenixKitProjects.Authz.can?(
               fake_scope(permissions: ["projects"]),
               project,
               :set_health
             )

      # conn unused beyond construction — silences the warning.
      _ = conn
    end
  end

  defp listed_folder(file, folder_uuid) do
    file_uuid = file.uuid

    file.folder_uuid == folder_uuid or
      PhoenixKit.RepoHelper.repo().exists?(
        from(fl in Storage.FolderLink,
          where: fl.file_uuid == ^file_uuid and fl.folder_uuid == ^folder_uuid
        )
      )
  end
end
