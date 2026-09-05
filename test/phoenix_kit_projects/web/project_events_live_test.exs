defmodule PhoenixKitProjects.Web.ProjectEventsLiveTest do
  @moduledoc """
  The Events extension TAB, mounted the way the hub mounts it
  (`live_isolated` + the extension-tab session contract), plus the
  show-page tab-strip integration.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Extensions, ProjectEvents}
  alias PhoenixKitProjects.Web.ProjectEventsLive

  setup %{conn: conn} do
    PhoenixKitProjects.Extensions.Registry.refresh()
    conn = put_test_scope(conn, fake_scope())
    {:ok, conn: conn, project: fixture_project()}
  end

  defp mount_tab(conn, project) do
    live_isolated(conn, ProjectEventsLive,
      session: %{
        "project_uuid" => project.uuid,
        "ext_key" => "events",
        "instance_key" => "default",
        "config" => %{},
        "current_user_uuid" => Ecto.UUID.generate(),
        "can_write" => true,
        "locale" => "en"
      }
    )
  end

  defp mount_tab_readonly(conn, project) do
    live_isolated(conn, ProjectEventsLive,
      session: %{
        "project_uuid" => project.uuid,
        "ext_key" => "events",
        "instance_key" => "default",
        "config" => %{},
        "current_user_uuid" => Ecto.UUID.generate(),
        "can_write" => false,
        "locale" => "en"
      }
    )
  end

  test "the tab appears only when the events extension is enabled",
       %{conn: conn, project: project} do
    path = "/en/admin/projects/#{project.uuid}"

    {:ok, _view, html} = live(conn, path)
    refute html =~ "ext:events:events"

    {:ok, _} = Extensions.enable(project, "events")
    {:ok, _view, html} = live(conn, path)
    assert html =~ "ext:events:events"
  end

  test "renders the calendar, creates an all-day event through the modal",
       %{conn: conn, project: project} do
    {:ok, view, html} = mount_tab(conn, project)

    assert html =~ "Nothing scheduled."

    render_click(view, "open_new_event", %{})

    html =
      render_submit(view, "create_event", %{
        "title" => "Sprint review",
        "date" => "2026-08-20",
        "end_date" => "",
        "all_day" => "true",
        "start_time" => "",
        "end_time" => "",
        "location" => "Room 4",
        "description" => ""
      })

    assert [event] = ProjectEvents.list_for_project(project.uuid)
    assert event.title == "Sprint review"
    assert event.all_day
    assert event.location == "Room 4"
    assert DateTime.to_date(event.starts_at) == ~D[2026-08-20]

    # Upcoming list + the calendar chip both show it; flash confirms.
    assert html =~ "Event added."
    assert html =~ "Sprint review"
  end

  test "a timed event gets its HH:MM prefix on the grid",
       %{conn: conn, project: project} do
    {:ok, view, _} = mount_tab(conn, project)

    html =
      render_submit(view, "create_event", %{
        "title" => "Standup",
        "date" => "2026-08-21",
        "all_day" => "false",
        "start_time" => "09:30",
        "end_time" => "",
        "location" => "",
        "description" => ""
      })

    assert [event] = ProjectEvents.list_for_project(project.uuid)
    refute event.all_day
    assert event.starts_at == elem(DateTime.from_iso8601("2026-08-21T09:30:00Z"), 1)
    assert html =~ "09:30 Standup"
  end

  test "a backwards range is refused with a flash, nothing written",
       %{conn: conn, project: project} do
    {:ok, view, _} = mount_tab(conn, project)

    html =
      render_submit(view, "create_event", %{
        "title" => "Backwards",
        "date" => "2026-08-22",
        "end_date" => "2026-08-21",
        "all_day" => "true",
        "start_time" => "",
        "end_time" => "",
        "location" => "",
        "description" => ""
      })

    assert html =~ "The end must not be before the start."
    assert ProjectEvents.list_for_project(project.uuid) == []
  end

  # Panel round (Grok): three real defects pinned below.

  test "an all-day event TODAY stays in Upcoming all day", %{conn: conn, project: project} do
    {:ok, _} =
      ProjectEvents.create(project, %{
        title: "Company picnic",
        starts_at: DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC"),
        all_day: true
      })

    {:ok, _view, html} = mount_tab(conn, project)

    # It's the only event: if the midnight comparison dropped it, the
    # Upcoming section would fall back to the empty state.
    refute html =~ "Nothing scheduled."
    assert html =~ "Company picnic"
  end

  test "a timed end WITHOUT an end date persists on the start date",
       %{conn: conn, project: project} do
    {:ok, view, _} = mount_tab(conn, project)

    render_submit(view, "create_event", %{
      "title" => "Standup",
      "date" => "2026-08-21",
      "end_date" => "",
      "all_day" => "false",
      "start_time" => "09:00",
      "end_time" => "10:00",
      "location" => "",
      "description" => ""
    })

    assert [event] = ProjectEvents.list_for_project(project.uuid)
    assert event.ends_at == elem(DateTime.from_iso8601("2026-08-21T10:00:00Z"), 1)
  end

  test "a PubSub delete clears a stale open detail panel", %{conn: conn, project: project} do
    {:ok, event} =
      ProjectEvents.create(project, %{
        title: "Doomed",
        starts_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    {:ok, view, _} = mount_tab(conn, project)
    html = render_click(view, "select_event", %{"uuid" => event.uuid})
    assert html =~ "modal-open"

    # Another session deletes it; the broadcast must close the panel.
    :ok = ProjectEvents.delete(event)
    send(view.pid, {:projects, :project_event_deleted, %{uuid: project.uuid}})

    refute render(view) =~ "modal-open"
  end

  test "can_write false hides the buttons and refuses forged writes",
       %{conn: conn, project: project} do
    {:ok, event} =
      ProjectEvents.create(project, %{
        title: "Kept",
        starts_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    {:ok, view, html} = mount_tab_readonly(conn, project)

    refute html =~ "New event"

    html =
      render_submit(view, "create_event", %{
        "title" => "Forged",
        "date" => "2026-08-25",
        "all_day" => "true"
      })

    assert html =~ "permission to change events"

    render_click(view, "delete_event", %{"uuid" => event.uuid})
    assert length(ProjectEvents.list_for_project(project.uuid)) == 1
  end

  test "detail panel opens from the upcoming list and delete removes the event",
       %{conn: conn, project: project} do
    {:ok, event} =
      ProjectEvents.create(project, %{
        title: "Kickoff",
        starts_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        location: "HQ"
      })

    {:ok, view, html} = mount_tab(conn, project)
    assert html =~ "Kickoff"

    html = render_click(view, "select_event", %{"uuid" => event.uuid})
    assert html =~ "HQ"

    html = render_click(view, "delete_event", %{"uuid" => event.uuid})
    assert html =~ "Event removed."
    assert ProjectEvents.list_for_project(project.uuid) == []
  end
end
