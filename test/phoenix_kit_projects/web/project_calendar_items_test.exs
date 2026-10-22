defmodule PhoenixKitProjects.Web.ProjectCalendarItemsTest do
  @moduledoc """
  An extension's dated things on the project's Calendar tab (the
  `calendar:` of an extension declaration — the CRM's planned client
  meetings): collected through `Extensions.calendar_items/3`, drawn
  read-only beside the project's own events, read again when the extension
  says they changed, and never able to take the tab down.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Extensions, ProjectEvents}
  alias PhoenixKitProjects.Extensions.Registry
  alias PhoenixKitProjects.Web.ProjectEventsLive

  defmodule Provider do
    @moduledoc false
    def phoenix_kit_project_extensions do
      [
        %{
          key: "meetings",
          name: "Meetings",
          default_enabled: true,
          calendar: {__MODULE__, :items}
        },
        %{key: "broken", name: "Broken", default_enabled: true, calendar: {__MODULE__, :boom}},
        %{key: "odd", name: "Odd", default_enabled: true, calendar: {__MODULE__, :odd}}
      ]
    end

    def items(project_uuid, from, until) do
      send(test_pid(), {:asked, project_uuid, from, until})
      %{items: Agent.get(__MODULE__, & &1), truncated: false}
    end

    def boom(_project_uuid, _from, _until), do: raise("boom")
    # not the shape, and one item without a start
    def odd(_project_uuid, _from, _until), do: %{items: [%{source: "odd", id: "1", title: "x"}]}

    defp test_pid, do: :persistent_term.get({__MODULE__, :pid})
  end

  setup %{conn: conn} do
    :persistent_term.put({Provider, :pid}, self())

    start_supervised!(%{
      id: Provider,
      start: {Agent, :start_link, [fn -> [] end, [name: Provider]]}
    })

    Application.put_env(:phoenix_kit_projects, :extension_providers, [Provider])
    Registry.refresh()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :extension_providers)
      Registry.refresh()
    end)

    conn = put_test_scope(conn, fake_scope())
    {:ok, conn: conn, project: fixture_project()}
  end

  defp item(attrs) do
    Map.merge(
      %{
        source: "crm",
        id: Ecto.UUID.generate(),
        title: "Site visit",
        label: "Meeting",
        starts_at: DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), 3 * 86_400),
        ends_at: nil,
        all_day: false,
        status: "planned",
        location: "ACME showroom",
        url: "/en/admin/crm/companies/x?tab=interactions",
        updated_at: nil
      },
      attrs
    )
  end

  defp put_items(items), do: Agent.update(Provider, fn _ -> items end)

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

  test "calendar_items/3 collects from the enabled extensions, tagged and soonest first; a broken provider contributes nothing",
       %{project: project} do
    later = item(%{title: "Later", starts_at: DateTime.add(DateTime.utc_now(), 9 * 86_400)})
    sooner = item(%{title: "Sooner"})
    put_items([later, sooner])

    now = DateTime.utc_now()
    items = Extensions.calendar_items(project.uuid, now, DateTime.add(now, 30 * 86_400))

    assert Enum.map(items, & &1.title) == ["Sooner", "Later"]
    assert Enum.all?(items, &(&1.ext_key == "meetings"))
    assert_received {:asked, uuid, %DateTime{}, %DateTime{}}
    assert uuid == project.uuid
  end

  test "an item shows on the grid and under Upcoming; it opens read-only", %{
    conn: conn,
    project: project
  } do
    planned = item(%{})
    put_items([planned])
    {:ok, _} = ProjectEvents.create(project, %{title: "Milestone", starts_at: planned.starts_at})

    {:ok, view, html} = mount_tab(conn, project)
    assert html =~ "Site visit"
    assert html =~ "Milestone"
    assert html =~ ~s(phx-click="select_item")

    html = render_click(view, "select_item", %{"id" => "ext:crm:#{planned.id}"})
    assert html =~ "ACME showroom"
    assert html =~ "Meeting"
    # nothing to change it with here: only the way to where it is managed
    assert html =~ planned.url
    refute html =~ ~s(event-item-#{project.uuid}" phx-click="delete_event")
  end

  test "one that happened or was cancelled is on the grid, not in what's next", %{
    conn: conn,
    project: project
  } do
    put_items([
      item(%{title: "Went ahead", status: "happened"}),
      item(%{title: "Called off", status: "cancelled"})
    ])

    {:ok, view, html} = mount_tab(conn, project)
    assert html =~ "Nothing scheduled."
    assert html =~ "Went ahead"
    assert html =~ "✕"

    [_, id] = Regex.run(~r/ext:crm:([0-9a-f-]{36})/, html)
    html = render_click(view, "select_item", %{"id" => "ext:crm:#{id}"})
    assert html =~ "event-item-#{project.uuid}"
  end

  test "the extension says its items changed: the tab reads them again", %{
    conn: conn,
    project: project
  } do
    {:ok, view, html} = mount_tab(conn, project)
    refute html =~ "Site visit"

    put_items([item(%{})])
    Extensions.calendar_changed(project.uuid)
    assert render(view) =~ "Site visit"
  end
end
