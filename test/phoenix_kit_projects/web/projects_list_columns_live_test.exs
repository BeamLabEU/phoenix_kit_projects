defmodule PhoenixKitProjects.Web.ProjectsListColumnsLiveTest do
  @moduledoc """
  The projects list's columns, sorts and filters on the page itself: a
  column the viewer adds is drawn from one batched read, a sort over a read
  value orders the rows (and the address carries it), every filter narrows
  and survives a reload, an extension's column behaves like a native one,
  and no filter widens what a non-admin may see.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Extensions, Ledger, Members, Projects}
  alias PhoenixKitProjects.Extensions.Registry

  defmodule Provider do
    @moduledoc false
    def phoenix_kit_project_extensions do
      [
        %{
          key: "clients",
          name: "Clients",
          default_enabled: true,
          project_columns: {__MODULE__, :columns}
        }
      ]
    end

    def columns(uuids) do
      clients = Agent.get(__MODULE__, & &1)

      values =
        for uuid <- uuids, name = Map.get(clients, uuid), into: %{} do
          {uuid, %{text: name, url: "/en/admin/crm/companies/#{uuid}"}}
        end

      [%{key: "client", label: "Client", values: values}]
    end
  end

  @client "ext:clients:client"
  @path "/en/admin/projects"

  setup %{conn: conn} do
    start_supervised!(%{
      id: Provider,
      start: {Agent, :start_link, [fn -> %{} end, [name: Provider]]}
    })

    Application.put_env(:phoenix_kit_projects, :extension_providers, [Provider])
    Registry.refresh()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_projects, :extension_providers)
      Registry.refresh()
    end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp client!(project, name), do: Agent.update(Provider, &Map.put(&1, project.uuid, name))

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "list-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    user
  end

  defp task!(project, attrs \\ %{}) do
    {:ok, a} =
      Projects.create_assignment(
        Map.merge(
          %{
            "project_uuid" => project.uuid,
            "task_uuid" => fixture_task().uuid,
            "status" => "todo"
          },
          attrs
        )
      )

    a
  end

  # The listed names, top to bottom — read off each row's own link, so a
  # name that also appears elsewhere (a parent prefix, a filter option)
  # does not count.
  defp order(html, projects) do
    wanted = MapSet.new(projects, & &1.name)

    ~r/class="link link-hover"[^>]*>\s*([^<]+?)\s*</
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&MapSet.member?(wanted, &1))
  end

  defp three(prefix) do
    for letter <- ~w(A B C), do: fixture_project(%{"name" => "#{prefix}#{letter}"})
  end

  describe "columns" do
    test "a new viewer sees status, the extension's column, progress, tasks, hours, last edited",
         %{conn: conn} do
      project = fixture_project()
      client!(project, "ACME Mööbel OÜ")
      done = task!(project)
      {:ok, _} = Projects.complete_assignment(done, nil)
      task!(project)
      {:ok, _} = Ledger.log_time(project.uuid, 150)

      {:ok, view, html} = live(conn, @path)

      for header <- ["Status", "Client", "Progress", "Tasks", "H. hours", "Last edited"] do
        assert html =~ header
      end

      assert has_element?(
               view,
               ~s|a[href="/en/admin/crm/companies/#{project.uuid}"]|,
               "ACME Mööbel OÜ"
             )

      assert html =~ "1/2"
      assert html =~ "50%"
      assert html =~ "2h 30m"
      # No footer adding the page up: the columns say it (Max, 2026-10-13).
      refute has_element?(view, "#projects-totals")
    end

    test "every column the picker offers renders, and an overdue count is loud", %{conn: conn} do
      project = fixture_project(%{"external_id" => "EXT-77"})
      owner = user!()
      {:ok, _} = Members.add_member(project, owner.uuid, role: "owner")

      task!(project, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), -2 * 86_400, :second) |> DateTime.truncate(:second)
      })

      task!(project, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), 9 * 86_400, :second) |> DateTime.truncate(:second)
      })

      {:ok, _} = Ledger.log_time(project.uuid, 60, billable: true)
      {:ok, _} = Ledger.record_ai(project.uuid, %{tokens: 2500, cost_cents: 12})
      {:ok, _} = Projects.create_subproject(project.uuid, %{"name" => "Inner part"})

      {:ok, view, _html} = live(conn, @path)

      for id <- ~w(open_tasks overdue next_due next_event subprojects members owner assignee
                   started eta completed billable_hours ai_hours total_hours tokens cost last_activity health
                   created created_by external_id) do
        render_hook(view, "add_column", %{"column_id" => id})
      end

      html = render(view)

      for header <- [
            "Open tasks",
            "Overdue tasks",
            "Next due",
            "Sub-projects",
            "Members",
            "Owner",
            "Billable hours",
            "AI tokens",
            "AI cost",
            "Last activity",
            "AI hours",
            "Total hours",
            "Health"
          ] do
        assert html =~ header
      end

      assert has_element?(view, "td.text-error", "1")
      assert html =~ owner.email
      assert html =~ "2.5k tokens"
      assert html =~ "$0.12"
      assert html =~ "EXT-77"
    end
  end

  describe "sorting" do
    test "a header click sorts by a read value, both ways, nothing-last", %{conn: conn} do
      [a, b, c] = projects = three("Sort")
      {:ok, _} = Ledger.log_time(a.uuid, 30)
      {:ok, _} = Ledger.log_time(b.uuid, 300)

      {:ok, view, _} = live(conn, @path)

      html = render_click(view, "toggle_sort", %{"by" => "hours"})
      assert order(html, projects) == [c.name, a.name, b.name]

      html = render_click(view, "toggle_sort", %{"by" => "hours"})
      assert order(html, projects) == [b.name, a.name, c.name]

      assert_push_event(view, "phoenix_kit_url_state", %{query: query})
      assert query =~ "sort=hours"
    end

    test "sorting by a column that is not on screen still reads it", %{conn: conn} do
      [a, b, c] = projects = three("Hidden")

      task!(a, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), -1 * 86_400, :second) |> DateTime.truncate(:second)
      })

      task!(c, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), -1 * 86_400, :second) |> DateTime.truncate(:second)
      })

      task!(c, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), -4 * 86_400, :second) |> DateTime.truncate(:second)
      })

      {:ok, _view, html} = live(conn, @path <> "?sort=overdue&dir=desc")
      assert order(html, projects) == [c.name, a.name, b.name]
    end

    test "the extension's column sorts by its text, from the header and from the URL",
         %{conn: conn} do
      [a, b, c] = projects = three("Cli")
      client!(a, "Zeta")
      client!(b, "alfa")

      {:ok, view, _} = live(conn, @path)
      html = render_click(view, "toggle_sort", %{"by" => @client})
      assert order(html, projects) == [b.name, a.name, c.name]

      {:ok, _view, html} = live(conn, @path <> "?sort=ext&sortx=#{@client}&dir=desc")
      assert order(html, projects) == [a.name, b.name, c.name]
    end

    test "a forged sort keeps the current one", %{conn: conn} do
      three("Forged")
      {:ok, view, _} = live(conn, @path)

      render_click(view, "toggle_sort", %{"by" => "ext:nobody:nothing"})
      render_click(view, "toggle_sort", %{"by" => "drop table"})
      render_change(view, "sort_form", %{"sort_by" => "__struct__"})

      assert :sys.get_state(view.pid).socket.assigns.sort_by == :updated_at
    end

    test "drag-reorder stays off under a computed sort and under a filter", %{conn: conn} do
      three("Drag")

      {:ok, _view, html} = live(conn, @path <> "?sort=position")
      assert html =~ ~s|data-sortable="true"|

      for query <- ~w(?sort=hours ?sort=position&state=setup ?sort=position&subs=true
                      ?sort=position&archived=all ?sort=position&overdue=true) do
        {:ok, _view, html} = live(conn, @path <> query)
        refute html =~ ~s|data-sortable="true"|, "draggable under #{query}"
      end
    end
  end

  describe "past the local-search threshold" do
    test "a computed sort orders the WHOLE set, then pages it", %{conn: conn} do
      bulk = for n <- 1..101, do: fixture_project(%{"name" => "Bulk#{n}"})
      top = fixture_project(%{"name" => "BulkTop"})
      {:ok, _} = Ledger.log_time(top.uuid, 500)
      {:ok, _} = Ledger.log_time(hd(bulk).uuid, 100)

      {:ok, view, html} = live(conn, @path <> "?sort=hours&dir=desc")

      # the two with time lead, whatever page the database would have put them on
      assert Enum.take(order(html, [top | bulk]), 2) == ["BulkTop", "Bulk1"]
      assert length(order(html, [top | bulk])) == 50

      html = render_click(view, "load_more", %{})
      assert length(order(html, [top | bulk])) == 100

      # a filter counts what matches, not what exists
      {:ok, _view, html} = live(conn, @path <> "?who=#{Ecto.UUID.generate()}")
      assert order(html, [top | bulk]) == []
    end
  end

  describe "filters" do
    test "the panel opens from the toolbar and lists the people and the clients", %{conn: conn} do
      project = fixture_project()
      member = user!()
      {:ok, _} = Members.add_member(project, member.uuid, role: "member")
      client!(project, "ACME")

      {:ok, view, html} = live(conn, @path)
      refute html =~ ~s|id="projects-filters"|

      html = view |> element("#projects-filters-toggle") |> render_click()
      assert html =~ ~s|id="projects-filters"|
      assert has_element?(view, ~s|#projects-filters select[name="who"] option|, member.email)

      assert has_element?(
               view,
               ~s|#projects-filters select[name="ext[#{@client}]"] option|,
               "ACME"
             )
    end

    test "state, overdue and the client each narrow, and say how many are set",
         %{conn: conn} do
      [a, b, c] = projects = three("Flt")
      {:ok, _} = Projects.start_project(a)
      {:ok, _} = Projects.update_project(b, %{"settings" => %{"completion" => "manual"}})

      task!(c, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), -1 * 86_400, :second) |> DateTime.truncate(:second)
      })

      client!(a, "ACME")
      client!(c, "Other")

      {:ok, view, _} = live(conn, @path)
      view |> element("#projects-filters-toggle") |> render_click()

      html = render_change(view, "filter", %{"state" => "running"})
      assert order(html, projects) == [a.name]
      assert has_element?(view, "#projects-filters-toggle .badge", "1")

      # Ongoing work is a state, and the only filter for it.
      html = render_change(view, "filter", %{"state" => "ongoing"})
      assert order(html, projects) == [b.name]
      refute has_element?(view, ~s|#projects-filters select[name="mode"]|)

      html = render_change(view, "filter", %{"overdue" => "true"})
      assert order(html, projects) == [c.name]

      html = render_change(view, "filter", %{"ext" => %{@client => "ACME"}})
      assert order(html, projects) == [a.name]

      html = render_change(view, "filter", %{"ext" => %{@client => "ACME"}, "overdue" => "true"})
      assert order(html, projects) == []
      assert html =~ "No projects match."
      assert has_element?(view, "#projects-filters-toggle .badge", "2")

      html = view |> element("#projects-filters-clear") |> render_click()
      assert Enum.sort(order(html, projects)) == Enum.sort(Enum.map(projects, & &1.name))
      refute has_element?(view, "#projects-filters-toggle .badge")
    end

    test "mine and a named person", %{conn: conn} do
      me = user!()
      other = user!()
      [a, b, _c] = projects = three("Who")
      {:ok, _} = Members.add_member(a, me.uuid, role: "owner")
      {:ok, _} = Members.add_member(b, other.uuid, role: "member")

      conn = put_test_scope(conn, fake_scope(user_uuid: me.uuid))

      {:ok, _view, html} = live(conn, @path <> "?who=mine")
      assert order(html, projects) == [a.name]

      {:ok, _view, html} = live(conn, @path <> "?who=#{other.uuid}")
      assert order(html, projects) == [b.name]
    end

    test "every filter survives a reload through the address", %{conn: conn} do
      [a, b, c] = projects = three("Url")
      {:ok, _} = Projects.start_project(a)
      {:ok, _} = Projects.start_project(b)

      task!(a, %{
        "deadline" =>
          DateTime.add(DateTime.utc_now(), -1 * 86_400, :second) |> DateTime.truncate(:second)
      })

      client!(a, "ACME")
      client!(b, "ACME")
      client!(c, "ACME")

      {:ok, view, _} = live(conn, @path)
      view |> element("#projects-filters-toggle") |> render_click()

      render_change(view, "filter", %{
        "state" => "running",
        "overdue" => "true",
        "ext" => %{@client => "ACME"}
      })

      assert_push_event(view, "phoenix_kit_url_state", %{query: query})
      params = URI.decode_query(query)

      assert %{"state" => "running", "overdue" => "true", "xcol" => @client, "xval" => "ACME"} =
               params

      {:ok, _view, html} = live(conn, @path <> "?" <> query)
      assert order(html, projects) == [a.name]
    end

    test "archived and sub-projects change which projects are listed", %{conn: conn} do
      live_one = fixture_project(%{"name" => "ArcLive"})
      gone = fixture_project(%{"name" => "ArcGone"})
      {:ok, _} = Projects.archive_project(gone)

      {:ok, %{child_project: child}} =
        Projects.create_subproject(live_one.uuid, %{"name" => "ArcChild"})

      all = [live_one, gone, child]

      {:ok, _view, html} = live(conn, @path)
      assert order(html, all) == [live_one.name]

      {:ok, _view, html} = live(conn, @path <> "?archived=only")
      assert order(html, all) == [gone.name]

      {:ok, _view, html} = live(conn, @path <> "?archived=all&sort=name&dir=asc")
      assert order(html, all) == [gone.name, live_one.name]

      {:ok, view, html} = live(conn, @path <> "?subs=true&sort=name&dir=asc")
      assert order(html, all) == [child.name, live_one.name]
      # the sub-project says where it lives
      assert has_element?(view, "#projects-list-body span", "ArcLive /")
    end

    test "a member of the sub-project alone does not read its parent's name", %{conn: conn} do
      parent = fixture_project(%{"name" => "HiddenParentName"})

      {:ok, %{child_project: child}} =
        Projects.create_subproject(parent.uuid, %{"name" => "VisibleChild"})

      {:ok, user} =
        Auth.register_user(%{
          "email" => "child-only-#{System.unique_integer([:positive])}@example.com",
          "password" => "ActorPass123!"
        })

      {:ok, _} = Members.add_member(child.uuid, user.uuid, role: "member")
      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, permissions: ["projects"]))

      {:ok, _view, html} = live(conn, @path <> "?subs=true")
      assert html =~ "VisibleChild"
      refute html =~ "HiddenParentName"
    end

    test "a list of only archived projects still shows its toolbar", %{conn: conn} do
      for p <- Projects.list_projects(), do: Projects.archive_project(p)
      gone = fixture_project(%{"name" => "OnlyArchived"})
      {:ok, _} = Projects.archive_project(gone)

      {:ok, view, html} = live(conn, @path)
      refute html =~ "No projects yet."
      assert has_element?(view, "#projects-filters-toggle")
    end

    test "a forged filter value lands on nothing rather than raising", %{conn: conn} do
      three("Forge")

      {:ok, view, html} =
        live(
          conn,
          @path <> "?state=nonsense&mode=x&archived=everything&who=not-a-uuid&xcol=ext:a:b&xval=1"
        )

      # state/mode/archived fall back to their defaults; who and the
      # extension pair are only compared, and match nobody
      assert html =~ "No projects match."
      render_change(view, "filter", %{"ext" => "not a map", "state" => %{"x" => "y"}})
      assert render(view) =~ "ForgeA"
    end
  end

  describe "scoping" do
    test "no sort, filter or listing switch shows a non-admin a foreign project", %{conn: conn} do
      contractor = user!()
      mine = fixture_project(%{"name" => "ScopeMine"})
      foreign = fixture_project(%{"name" => "ScopeForeign"})
      {:ok, _} = Members.add_member(mine, contractor.uuid, role: "member")

      {:ok, %{child_project: _}} =
        Projects.create_subproject(foreign.uuid, %{"name" => "ScopeForeignChild"})

      archived = fixture_project(%{"name" => "ScopeForeignArchived"})
      {:ok, _} = Projects.archive_project(archived)
      client!(foreign, "ACME")
      client!(mine, "ACME")
      {:ok, _} = Ledger.log_time(foreign.uuid, 600)

      conn =
        put_test_scope(conn, fake_scope(user_uuid: contractor.uuid, permissions: ["projects"]))

      for query <- [
            "",
            "?sort=hours&dir=desc",
            "?subs=true",
            "?archived=all",
            "?xcol=#{@client}&xval=ACME",
            "?state=setup&subs=true&archived=all&sort=ext&sortx=#{@client}"
          ] do
        {:ok, view, html} = live(conn, @path <> query)
        assert html =~ "ScopeMine", "missing own project for #{inspect(query)}"
        refute html =~ "ScopeForeign", "foreign project shown for #{inspect(query)}"

        # ... nor in the panel's options
        html = view |> element("#projects-filters-toggle") |> render_click()
        refute html =~ "ScopeForeign"
      end
    end
  end

  describe "extensions" do
    test "an extension the viewer cannot reach contributes no column", %{conn: conn} do
      project = fixture_project()
      client!(project, "Secret client")
      {:ok, _} = Extensions.enable(project, "clients")

      # `module_key` set → the column needs that module's permission
      defmodule Gated do
        @moduledoc false
        def phoenix_kit_project_extensions do
          [
            %{
              key: "gated",
              name: "Gated",
              default_enabled: true,
              permission: "crm",
              project_columns: {__MODULE__, :columns}
            }
          ]
        end

        def columns(uuids),
          do: [
            %{
              key: "c",
              label: "Gated col",
              values: Map.new(uuids, &{&1, %{text: "Secret gated"}})
            }
          ]
      end

      Application.put_env(:phoenix_kit_projects, :extension_providers, [Gated])
      Registry.refresh()

      viewer = user!()
      {:ok, _} = Members.add_member(project, viewer.uuid, role: "member")
      conn = put_test_scope(conn, fake_scope(user_uuid: viewer.uuid, permissions: ["projects"]))

      {:ok, _view, html} = live(conn, @path)
      assert html =~ project.name
      refute html =~ "Gated col"
      refute html =~ "Secret gated"
    end
  end

  describe "reloading" do
    test "the first change reloads at once; a burst after it shares one reload", %{conn: conn} do
      [a | _] = three("Rld")
      {:ok, view, _html} = live(conn, @path)
      reload = fn -> :sys.get_state(view.pid).socket.assigns[:reload] end

      {:ok, _} = Projects.update_project(a, %{"name" => "Renamed once"})
      assert render(view) =~ "Renamed once"

      # Let that reload's pause pass, so the burst below starts from rest
      # (the timings here must not depend on how busy the machine is).
      Process.sleep(600)
      assert reload.() == nil

      {:ok, _} =
        Projects.update_project(Projects.get_project(a.uuid), %{"name" => "Renamed twice"},
          broadcast: false
        )

      # The first message of the burst reloads; the rest only mark the
      # list stale for the one reload that follows the pause.
      for _ <- 1..6, do: send(view.pid, {:projects, :assignment_updated, %{}})
      assert reload.() == :stale
      assert render(view) =~ "Renamed twice"

      Process.sleep(1000)
      assert reload.() == nil
    end
  end
end
