defmodule PhoenixKitProjects.Web.BossList1118Test do
  @moduledoc """
  The boss's fourth list (tim-dev, 2026-11-18), the project page's part:

    * 1 — the × on a "depends on" chip asks first, and says what it means;
    * 3 — a created task's title opens the task; only the row being typed
      is a text box;
    * 4/5 — the task popup is centred, and a task's comments and notes open
      in it on their own tab;
    * 7 — the quick-add line at the top adds at the end and answers what it
      added;
    * 9 — the side panel beside the list is each viewer's own, kept on their
      account;
    * 12 — the step into "can be started" is named like the status;
    * 16 — a card's small menus are native popovers (the top layer).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Web.AssignmentViewLive

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "boss-1118-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))

    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    measure = assignment!(project, "Measure the walls")
    doors = assignment!(project, "Fit the doors")
    {:ok, _} = Projects.add_dependency(doors.uuid, measure.uuid)

    {:ok, conn: conn, project: project, measure: measure, doors: doors, user: user}
  end

  defp assignment!(project, title) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{}
      )

    a
  end

  defp show(ctx), do: live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

  describe "1 — removing a dependency asks first" do
    test "the × opens a question naming both tasks; confirming removes it", ctx do
      {:ok, view, html} = show(ctx)

      # No one-click removal any more: the × asks through the confirm modal.
      refute html =~ ~s(phx-click="remove_dependency")
      assert html =~ ~s(phx-value-event="remove_dependency")

      html =
        render_click(view, "request_confirm", %{
          "event" => "remove_dependency",
          "assignment" => ctx.doors.uuid,
          "depends_on" => ctx.measure.uuid,
          "title" => "Remove the dependency?",
          "message" => "x",
          "confirm" => "Remove dependency"
        })

      assert html =~ "Remove the dependency?"
      assert Projects.list_dependencies(ctx.doors.uuid) != []

      html = render_click(view, "confirm_action_ok", %{})
      assert html =~ "Dependency removed."
      assert Projects.list_dependencies(ctx.doors.uuid) == []
    end
  end

  describe "3 — the title opens the task" do
    test "a created task's title is a link to it, not a text box", ctx do
      {:ok, view, _html} = show(ctx)

      refute has_element?(view, "#task-title-#{ctx.measure.uuid}")

      assert has_element?(
               view,
               "#task-#{ctx.measure.uuid} [phx-click='open_embed']",
               "Measure the walls"
             )
    end

    test "the row being typed is a text box until it loses the cursor", ctx do
      {:ok, view, _html} = show(ctx)

      # Enter in the middle of a title splits it: the new row takes the cursor.
      render_hook(view, "outline_add", %{"after" => ctx.measure.uuid, "text" => "Order the tiles"})

      [new] =
        Projects.list_assignments(ctx.project.uuid)
        |> Enum.filter(&(&1.task.title == "Order the tiles"))

      assert has_element?(view, "#task-title-#{new.uuid}")

      render_hook(view, "outline_blur", %{"id" => new.uuid})
      refute has_element?(view, "#task-title-#{new.uuid}")
    end
  end

  describe "4/5 — one centred popup per task" do
    test "the comments button opens the task's popup on its Comments tab", ctx do
      # The comments module known to core's registry and switched on (the
      # project's Discussions extension is on by default).
      registry_key = {PhoenixKit, :registered_modules}
      before = :persistent_term.get(registry_key, [])
      :persistent_term.put(registry_key, Enum.uniq(before ++ [PhoenixKitComments]))
      PhoenixKitComments.enable_system()

      on_exit(fn ->
        PhoenixKitComments.disable_system()
        :persistent_term.put(registry_key, before)
      end)

      {:ok, _view, html} = show(ctx)

      # The session the button hands the popup carries the tab.
      assert html =~ "&quot;tab&quot;:&quot;comments&quot;"
      refute html =~ ~s(phx-value-type="assignment")
    end

    test "the popup opens on the tab it was asked for", ctx do
      {:ok, view, _html} =
        live_isolated(ctx.conn, AssignmentViewLive,
          session: %{
            "project_id" => ctx.project.uuid,
            "id" => ctx.measure.uuid,
            "current_user_uuid" => ctx.user.uuid,
            "tab" => "history"
          }
        )

      assert :sys.get_state(view.pid).socket.assigns.activity_tab == "history"
      assert :sys.get_state(view.pid).socket.assigns.focus_activity? == true
    end

    test "the pencil renames a one-off task from its popup", ctx do
      {:ok, view, _html} =
        live_isolated(ctx.conn, AssignmentViewLive,
          session: %{
            "project_id" => ctx.project.uuid,
            "id" => ctx.measure.uuid,
            "current_user_uuid" => ctx.user.uuid
          }
        )

      render_click(view, "rename_start", %{})
      assert has_element?(view, "#task-view-rename-#{ctx.measure.uuid}")

      view
      |> form("#task-view-rename-#{ctx.measure.uuid}", %{"title" => "Measure every wall"})
      |> render_submit()

      assert Projects.get_assignment(ctx.measure.uuid).task.title == "Measure every wall"
      refute has_element?(view, "#task-view-rename-#{ctx.measure.uuid}")
    end
  end

  describe "7 — quick add at the top" do
    test "each title becomes a task at the end; the reply counts them", ctx do
      {:ok, view, html} = show(ctx)
      assert html =~ ~s(phx-hook="PkpQuickTop")

      render_hook(view, "outline_quick_add", %{"text" => "  Paint   the hall "})
      render_hook(view, "outline_quick_add", %{"lines" => ["Buy brushes", "", "Clean up"]})

      titles =
        Projects.list_assignments(ctx.project.uuid)
        |> Enum.sort_by(& &1.position)
        |> Enum.map(& &1.task.title)

      assert Enum.take(titles, -3) == ["Paint the hall", "Buy brushes", "Clean up"]
    end
  end

  describe "9 — the side panel" do
    test "is the viewer's own choice, kept on their account", ctx do
      {:ok, view, html} = show(ctx)
      refute html =~ "project-side-panel-"

      html = render_click(view, "side_panel_toggle", %{})
      assert html =~ "project-side-panel-#{ctx.project.uuid}"

      render_click(view, "side_panel_view", %{"view" => "activity"})
      user = Auth.get_user!(ctx.user.uuid)
      assert user.custom_fields["projects_side_panel"] == %{"open" => true, "view" => "activity"}

      # A crafted view name is ignored.
      render_click(view, "side_panel_view", %{"view" => "bogus"})

      assert Auth.get_user!(ctx.user.uuid).custom_fields["projects_side_panel"]["view"] ==
               "activity"
    end
  end

  describe "16 — card menus in the top layer" do
    test "the status chip's menu is a native popover with its placing hook", ctx do
      {:ok, _view, html} = show(ctx)

      assert html =~ ~s(id="row-status-pop-#{ctx.measure.uuid}")
      assert html =~ ~s(popover="auto")
      assert html =~ ~s(phx-hook="PkpPop")
      refute html =~ ~s(<details class="dropdown shrink-0" id="row-status-pop-)
    end
  end
end
