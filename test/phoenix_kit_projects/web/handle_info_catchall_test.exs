defmodule PhoenixKitProjects.Web.HandleInfoCatchallTest do
  @moduledoc """
  Pinning tests for the canonical post-Apr `handle_info` catch-all on
  every LiveView that subscribes to PubSub.

  The original sweep predates the Logger.debug requirement. A silent
  catch-all (`do: {:noreply, socket}`) drops unexpected messages
  without leaving any breadcrumb — when a future PubSub broadcast
  shape lands and the receiving LV stays stale, debugging it requires
  a Logger entry. Runtime path: `send/2` a non-recognized message to
  `view.pid` and assert the debug log fires.

  The test config sets `level: :warning` (per
  `config/test.exs`), which filters debug *before* `capture_log`
  sees it. Each test must `Logger.configure(level: :debug)` for its
  duration with `on_exit` reset (per workspace memory
  `feedback_logger_level_in_tests.md`).
  """

  use PhoenixKitProjects.LiveCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Users.Auth

  setup %{conn: conn} do
    # A REAL user row: the gated LVs are mounted off-router here, so the
    # session names this viewer and a membership row is written for them —
    # both need a user that actually exists (fake_scope's uuid does not).
    {:ok, user} =
      Auth.register_user(%{
        "email" => "catchall-#{System.unique_integer([:positive])}@example.com",
        "password" => "CatchallPass123!"
      })

    scope = fake_scope(user_uuid: user.uuid)
    conn = put_test_scope(conn, scope)

    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "OverviewLive" do
    test "logs unexpected handle_info at debug", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/overview")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :unexpected_message_for_test)
          # Force a render so the LiveView processes the message.
          _ = render(view)
        end)

      assert log =~ "[OverviewLive] unexpected handle_info"
    end
  end

  describe "ProjectsLive" do
    test "logs unexpected handle_info at debug", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :unexpected_message_for_test)
          _ = render(view)
        end)

      assert log =~ "[ProjectsLive] unexpected handle_info"
    end
  end

  describe "TasksLive" do
    test "logs unexpected handle_info at debug", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :unexpected_message_for_test)
          _ = render(view)
        end)

      assert log =~ "[TasksLive] unexpected handle_info"
    end
  end

  describe "TemplatesLive" do
    test "logs unexpected handle_info at debug", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :unexpected_message_for_test)
          _ = render(view)
        end)

      assert log =~ "[TemplatesLive] unexpected handle_info"
    end
  end

  describe "ProjectShowLive" do
    test "logs unexpected handle_info at debug", %{conn: conn, actor_uuid: actor_uuid} do
      project = fixture_project()
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")
      {:ok, view, _html} = live(conn, "/en/admin/projects/list/#{project.uuid}")

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :unexpected_message_for_test)
          _ = render(view)
        end)

      assert log =~ "[ProjectShowLive] unexpected handle_info"
    end
  end

  # Not router-mounted — both are reached only via `live_render` (PopupHost is
  # mounted by the host; the gantt is nested inside ProjectShowLive). Drive them
  # with `live_isolated/3`.
  describe "PopupHostLive" do
    test "logs unexpected handle_info at debug", %{conn: conn, actor_uuid: actor_uuid} do
      topic = "catchall:popup:#{System.unique_integer([:positive])}"

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{"pubsub_topic" => topic}
        )

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :unexpected_message_for_test)
          _ = render(view)
        end)

      assert log =~ "[PopupHostLive] unexpected handle_info"
    end
  end

  describe "ProjectGanttLive" do
    test "logs unexpected handle_info at debug", %{conn: conn, actor_uuid: actor_uuid} do
      project = fixture_project()
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectGanttLive,
          session: %{"id" => project.uuid, "current_user_uuid" => actor_uuid}
        )

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :unexpected_message_for_test)
          _ = render(view)
        end)

      assert log =~ "[ProjectGanttLive] unexpected handle_info"
    end
  end

  describe "ProjectCalendarLive" do
    test "logs unexpected handle_info at debug", %{conn: conn, actor_uuid: actor_uuid} do
      project = fixture_project()
      {:ok, _} = PhoenixKitProjects.Members.add_member(project, actor_uuid, role: "member")

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectCalendarLive,
          session: %{"id" => project.uuid, "current_user_uuid" => actor_uuid}
        )

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, :unexpected_message_for_test)
          _ = render(view)
        end)

      assert log =~ "[ProjectCalendarLive] unexpected handle_info"
    end
  end
end
