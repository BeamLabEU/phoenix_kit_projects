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
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/files")

      assert html =~ "No files yet."
      assert Attachments.folder_uuid(project.uuid) == nil
    end

    test "open_picker ensures the folder; media_selected attaches + logs",
         %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}/files")

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
        live(conn, "/en/admin/projects/#{project.uuid}/files")

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

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/activity")

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

      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

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

      # Nor does merely reaching the module — that is the permission split.
      refute PhoenixKitProjects.Authz.can?(
               fake_scope(permissions: ["projects"]),
               project,
               :set_health
             )

      # A site admin (module + admin_all) does.
      assert PhoenixKitProjects.Authz.can?(
               fake_scope(permissions: ["projects", "projects.admin_all"]),
               project,
               :set_health
             )

      # conn unused beyond construction — silences the warning.
      _ = conn
    end
  end

  describe "the discussions bridge (comments as a per-project toggle)" do
    setup do
      # The Comments tab needs the comments MODULE known to core's registry
      # AND switched on (a system setting), as well as the project's
      # Discussions extension (on by default). The test env starts no
      # registry process, so seed its persistent_term directly.
      registry_key = {PhoenixKit, :registered_modules}
      before = :persistent_term.get(registry_key, [])
      :persistent_term.put(registry_key, Enum.uniq(before ++ [PhoenixKitComments]))
      PhoenixKitComments.enable_system()

      on_exit(fn ->
        PhoenixKitComments.disable_system()
        :persistent_term.put(registry_key, before)
      end)

      :ok
    end

    test "the Comments tab shows the project thread inline; Discussions off removes it",
         %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      # The tab is in the top strip; the header no longer carries the trigger.
      assert html =~ ~s(phx-value-tab="comments")
      refute html =~ ~s(open_comments" phx-value-type="project")

      html = render_click(view, "switch_tab", %{"tab" => "comments"})
      assert html =~ ~s(id="pk-comments-body-comments-tab-project-#{project.uuid}")
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/comments")

      {:ok, _} = Extensions.disable(project, "discussions")
      {:ok, view, html_off} = live(conn, "/en/admin/projects/#{project.uuid}")
      refute html_off =~ ~s(phx-value-tab="comments")
      refute html_off =~ ~s(open_comments" phx-value-type="project")

      # A forged switch onto the missing tab lands on the list.
      html = render_click(view, "switch_tab", %{"tab" => "comments"})
      refute html =~ ~s(id="pk-comments-body-comments-tab-project-#{project.uuid}")
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/tasks")
    end

    test "/comments deep-links onto the tab; with Discussions off it lands on the list",
         %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/comments")
      assert html =~ ~s(id="pk-comments-body-comments-tab-project-#{project.uuid}")

      {:ok, _} = Extensions.disable(project, "discussions")
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/comments")
      refute html =~ ~s(id="pk-comments-body-comments-tab-project-#{project.uuid}")
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/tasks")
    end

    test "a template never gets a Comments tab, even with Discussions on", %{conn: conn} do
      template = fixture_template()
      {:ok, view, html} = live(conn, "/en/admin/projects/templates/#{template.uuid}")
      refute html =~ ~s(phx-value-tab="comments")
      refute html =~ "pk-comments-body-comments-tab-project-"

      html = render_click(view, "switch_tab", %{"tab" => "comments"})
      refute html =~ "pk-comments-body-comments-tab-project-"
    end

    test "a project that is ONLY a discussion lands on Comments with no strip",
         %{conn: conn, project: project} do
      {:ok, _} = Extensions.disable(project, "tasks")
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert html =~ ~s(id="pk-comments-body-comments-tab-project-#{project.uuid}")
      # One tab → no strip; the address still names the tab.
      refute html =~ ~s(phx-value-tab="comments")
      refute html =~ "Add task"
    end
  end

  defmodule FakeTabLive do
    use Phoenix.LiveView

    @impl true
    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         project_uuid: session["project_uuid"],
         greeting: get_in(session, ["config", "greeting"]) || "none"
       )}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div id="fake-ext-tab">ext-tab-content greeting={@greeting} project={@project_uuid}</div>
      """
    end
  end

  defmodule TabProvider do
    def phoenix_kit_project_extensions do
      [
        %{
          key: "tab_ext",
          name: "Tab Ext",
          default_enabled: false,
          tabs: [
            %{
              key: "main",
              label: "Tab Ext",
              lv: PhoenixKitProjects.Web.ProjectHubPagesTest.FakeTabLive
            }
          ],
          config_schema: [%{key: "greeting", type: :string, label: "Greeting"}]
        }
      ]
    end
  end

  describe "contributed extension tabs on the show page" do
    setup %{project: project} do
      Application.put_env(:phoenix_kit_projects, :extension_providers, [TabProvider])
      PhoenixKitProjects.Extensions.Registry.refresh()

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_projects, :extension_providers)
        PhoenixKitProjects.Extensions.Registry.refresh()
      end)

      {:ok, _} =
        Extensions.enable(project, "tab_ext", config: %{"greeting" => "howdy"})

      :ok
    end

    test "the tab appears in the strip and mounts its LV with the config",
         %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert html =~ "Tab Ext"

      html = render_click(view, "switch_tab", %{"tab" => "ext:tab_ext:main"})
      assert html =~ "ext-tab-content"
      assert html =~ "greeting=howdy"
      assert html =~ "project=#{project.uuid}"
    end

    test "a forged ext tab id falls back to list", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}")

      html = render_click(view, "switch_tab", %{"tab" => "ext:evil:main"})
      refute html =~ "ext-tab-content"
    end

    test "tasks OFF lands directly on the extension tab, not the empty state",
         %{conn: conn, project: project} do
      {:ok, _} = Extensions.disable(project, "tasks")

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert html =~ "ext-tab-content"
      refute html =~ "Nothing is turned on for this project yet."
      # No Tasks tab at all — none of the task chrome renders.
      refute html =~ ~s(phx-value-tab="tasks")
      refute html =~ "Add task"
    end

    test "tasks OFF: a forged 'tasks' / unknown / bad-extension switch stays on a real tab",
         %{conn: conn, project: project} do
      {:ok, _} = Extensions.disable(project, "tasks")
      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert html =~ "ext-tab-content"

      # codex (2026-09-05): these used to resolve to :list, whose pane a
      # tasks-off project does not render — a blank page.
      for forged <- ["tasks", "board", "nonsense", "ext:evil:main"] do
        html = render_click(view, "switch_tab", %{"tab" => forged})
        assert html =~ "ext-tab-content", "#{forged} blanked the page"
        assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/main")
      end
    end

    test "turning tasks off while on the list moves the page to the extension tab",
         %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/tasks")

      {:ok, _} = Extensions.disable(project, "tasks")
      send(view.pid, {:projects, :project_modules_changed, %{}})

      html = render(view)
      assert html =~ "ext-tab-content"
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/main")
      refute html =~ ~s(phx-value-tab="tasks")
    end

    test "the extension tab sits in the top strip beside Tasks and deep-links by its key",
         %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert html =~ ~s(phx-value-tab="tasks")
      assert html =~ ~s(phx-value-tab="ext:tab_ext:main")

      html = render_click(view, "switch_tab", %{"tab" => "ext:tab_ext:main"})
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/main")

      # `/projects/:id/<tab key>` opens the tab directly.
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/main")
      assert html =~ "ext-tab-content"
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/main")

      # An unknown segment lands on the first tab, like the bare page.
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/no-such-tab")
      refute html =~ "ext-tab-content"
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/tasks")
    end

    test "switching to Tasks reopens the task view you left", %{conn: conn, project: project} do
      {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}/tasks/board")

      html = render_click(view, "switch_tab", %{"tab" => "ext:tab_ext:main"})
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/main")

      html = render_click(view, "switch_tab", %{"tab" => "tasks"})
      assert html =~ ~s(data-url="/en/admin/projects/#{project.uuid}/tasks/board")
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
