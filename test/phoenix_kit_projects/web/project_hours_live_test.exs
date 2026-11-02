defmodule PhoenixKitProjects.Web.ProjectHoursLiveTest do
  @moduledoc """
  The Hours page: a project's tab (mounted the way the hub mounts a
  contributed tab) and the site-wide page — the filters, the sort, logging,
  amending and removing time, who may do which, and the report.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Extensions, Features, Ledger, Members, Projects}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.ProjectHoursLive

  defp uniq, do: System.unique_integer([:positive])

  defp user(first, last) do
    {:ok, user} =
      Auth.register_user(%{
        email: "hours-lv-#{uniq()}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = Auth.update_user_profile(user, %{first_name: first, last_name: last})
    user
  end

  defp task(project, title) do
    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => title, "ad_hoc" => true},
        %{}
      )

    a
  end

  defp log(project, minutes, opts) do
    {:ok, entry} = Ledger.log_time(project.uuid, minutes, opts)
    entry
  end

  # The hub's extension-tab session; identity is rebuilt from the uuid.
  defp mount_tab(conn, project, user_uuid) do
    live_isolated(conn, ProjectHoursLive,
      session: %{
        "project_uuid" => project.uuid,
        "ext_key" => "tasks",
        "instance_key" => "default",
        "config" => %{},
        "current_user_uuid" => user_uuid,
        "can_write" => true,
        "locale" => "en",
        "wrapper_class" => ""
      }
    )
  end

  defp tighten(project, floors) do
    {:ok, project} =
      Projects.update_project(project, %{
        "settings" => Map.put(project.settings || %{}, "authz", floors)
      })

    project
  end

  # The project's `billable` Tasks flag (off by default).
  defp billable!(project) do
    {:ok, project} =
      Projects.update_project(project, %{
        "settings" => Map.put(project.settings || %{}, "features", %{"billable" => true})
      })

    project
  end

  setup %{conn: conn} do
    Extensions.Registry.refresh()
    admin = embed_user_uuid!()
    project = fixture_project(%{"name" => "Kitchen #{uniq()}"})
    {:ok, conn: put_test_scope(conn, fake_scope()), admin: admin, project: project}
  end

  describe "the project's tab" do
    test "sits in the hub's tab strip while the work ledger is on", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      assert html =~ "ext:tasks:hours"

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/hours")
      assert html =~ "hours-#{project.uuid}"

      {:ok, _} = Features.set_flags(project, %{"ledger" => false})
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")
      refute html =~ "ext:tasks:hours"
    end

    test "shows the totals, the people, the tasks, the chart and the entries",
         %{conn: conn, project: project, admin: admin} do
      ann = user("Ann", "Able")
      bob = user("Bob", "Baker")
      cut = task(project, "Cut the panels")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      log(project, 90,
        actor_uuid: ann.uuid,
        assignment_uuid: cut.uuid,
        ended_at: now,
        billable: true
      )

      log(project, 30, actor_uuid: bob.uuid, ended_at: now, note: "Site visit")

      {:ok, view, html} = mount_tab(conn, project, admin)

      assert html =~ "2h"
      assert html =~ "1h 30m billable"
      assert html =~ "Ann Able" and html =~ "Bob Baker"
      assert html =~ "Cut the panels"
      assert html =~ "Site visit"
      assert html =~ "Hours per day"
      assert html =~ "Timesheet"
      assert has_element?(view, "#hours-#{project.uuid}-entries")
      # a tab does not own the address bar
      refute has_element?(view, "[phx-hook=PhoenixKitUrlState]")
    end

    test "filters by person, by billable and by period; clearing brings everything back",
         %{conn: conn, project: project, admin: admin} do
      ann = user("Ann", "Able")
      bob = user("Bob", "Baker")
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      log(project, 60, actor_uuid: ann.uuid, ended_at: now, billable: true, note: "ann-now")
      log(project, 30, actor_uuid: bob.uuid, ended_at: now, note: "bob-now")

      log(project, 15,
        actor_uuid: bob.uuid,
        ended_at: ~U[2020-01-10 10:00:00Z],
        note: "bob-long-ago"
      )

      {:ok, view, html} = mount_tab(conn, project, admin)
      assert html =~ "ann-now" and html =~ "bob-now"
      refute html =~ "bob-long-ago"

      html =
        render_change(view, "filter", %{"worker" => "user:#{bob.uuid}", "subprojects" => "true"})

      assert html =~ "bob-now"
      refute html =~ "ann-now"

      html =
        render_change(view, "filter", %{
          "worker" => "",
          "billable" => "yes",
          "subprojects" => "true"
        })

      assert html =~ "ann-now"
      refute html =~ "bob-now"

      html =
        render_change(view, "filter", %{
          "billable" => "all",
          "period" => "all",
          "subprojects" => "true"
        })

      assert html =~ "bob-long-ago"

      # typing a day makes the period a custom one
      html =
        render_change(view, "filter", %{
          "_target" => ["to"],
          "period" => "all",
          "from" => "2020-01-01",
          "to" => "2020-01-31",
          "subprojects" => "true"
        })

      assert html =~ "bob-long-ago"
      refute html =~ "ann-now"
      assert html =~ "Jan 1, 2020"

      html = render_click(view, "clear_filters", %{})
      assert html =~ "ann-now" and html =~ "bob-now"
      refute html =~ "bob-long-ago"
    end

    test "sorts by a header click and groups the entries", %{
      conn: conn,
      project: project,
      admin: admin
    } do
      ann = user("Ann", "Able")
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      log(project, 10, actor_uuid: ann.uuid, ended_at: now, note: "small")
      log(project, 200, actor_uuid: ann.uuid, ended_at: DateTime.add(now, -60), note: "large")

      {:ok, view, html} = mount_tab(conn, project, admin)
      assert before?(html, "small", "large")

      html = render_click(view, "toggle_sort", %{"by" => "amount"})
      assert before?(html, "small", "large")
      html = render_click(view, "toggle_sort", %{"by" => "amount"})
      assert before?(html, "large", "small")
      # a forged field changes nothing
      assert render_click(view, "toggle_sort", %{"by" => "password"}) =~ "large"

      html = render_change(view, "filter", %{"group" => "person", "subprojects" => "true"})
      assert html =~ ~r/font-semibold">Ann Able</
      assert html =~ "3h 30m"
    end

    test "includes a sub-project's time until the switch is off", %{
      conn: conn,
      project: project,
      admin: admin
    } do
      {:ok, %{child_project: child}} =
        Projects.create_subproject(project.uuid, %{"name" => "Child #{uniq()}"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      log(project, 60, ended_at: now, note: "on-parent")
      log(child, 45, ended_at: now, note: "on-child")

      {:ok, view, html} = mount_tab(conn, project, admin)
      assert html =~ "on-parent" and html =~ "on-child"
      assert html =~ "By project"

      html = render_change(view, "filter", %{"subprojects" => "false"})
      assert html =~ "on-parent"
      refute html =~ "on-child"
    end

    test "logs time: for me, on a task, with a typed duration", %{
      conn: conn,
      project: project,
      admin: admin
    } do
      project = billable!(project)
      cut = task(project, "Cut the panels")
      {:ok, view, _html} = mount_tab(conn, project, admin)

      assert render_click(view, "open_log", %{}) =~ "How long"

      html =
        render_submit(view, "save_log", %{
          "project" => project.uuid,
          "date" => Date.to_iso8601(Date.utc_today()),
          "time" => "09:00",
          "duration" => %{"amount" => "1.5", "unit" => "hours"},
          "person" => "me",
          "task" => cut.uuid,
          "note" => "Morning shift",
          "billable" => "true"
        })

      assert html =~ "Time logged."
      assert html =~ "Morning shift"

      [entry] = Ledger.list_entries(project.uuid)
      assert Decimal.to_integer(entry.amount) == 90
      assert entry.actor_kind == "user" and entry.actor_uuid == admin
      assert entry.assignment_uuid == cut.uuid
      assert entry.billable
      assert DateTime.diff(entry.ended_at, entry.started_at) == 90 * 60
    end

    test "refuses a duration it cannot read, a task of another project and a far-off day",
         %{conn: conn, project: project, admin: admin} do
      other = fixture_project()
      foreign = task(other, "Elsewhere")
      own = task(project, "Here")
      {:ok, view, _html} = mount_tab(conn, project, admin)
      render_click(view, "open_log", %{})

      base = %{
        "project" => project.uuid,
        "date" => Date.to_iso8601(Date.utc_today()),
        "duration" => %{"amount" => "45", "unit" => "minutes"},
        "person" => "me",
        "task" => own.uuid
      }

      assert render_submit(view, "save_log", %{
               base
               | "duration" => %{"amount" => "soon", "unit" => "hours"}
             }) =~
               "Enter a positive amount of time"

      assert render_submit(view, "save_log", %{base | "task" => foreign.uuid}) =~
               "Pick a task of this project"

      assert render_submit(view, "save_log", %{base | "date" => "2999-01-01"}) =~
               "cannot be in the future"

      assert render_submit(view, "save_log", %{base | "project" => other.uuid}) =~
               "permission to log time here"

      assert render_submit(
               view,
               "save_log",
               Map.put(base, "person", "user:#{Ecto.UUID.generate()}")
             ) =~
               "Pick a person from the list"

      assert Ledger.list_entries(project.uuid) == []
    end

    test "logs for a member when the viewer runs the plan", %{
      conn: conn,
      project: project,
      admin: admin
    } do
      ann = user("Ann", "Able")
      {:ok, _} = Members.add_member(project, ann.uuid, role: "member")
      fit = task(project, "Fit")
      {:ok, view, _html} = mount_tab(conn, project, admin)
      render_click(view, "open_log", %{})
      dom = "hours-#{project.uuid}"

      # Whose time is searched like every other person pick, by name.
      render_hook(view, "pick_search", %{"q" => "ann", "id" => "#{dom}-pick-logperson"})
      assert_push_event(view, "picker_results", %{results: [%{label: "Ann Able", uuid: key}]})

      render_click(view, "pick_pick", %{"uuid" => key, "id" => "#{dom}-pick-logperson"})
      assert has_element?(view, "input[name=person][value='user:#{ann.uuid}']")

      render_submit(view, "save_log", %{
        "project" => project.uuid,
        "date" => Date.to_iso8601(Date.utc_today()),
        "duration" => %{"amount" => "2", "unit" => "hours"},
        "person" => key,
        "task" => fit.uuid
      })

      assert [%{actor_uuid: uuid, started_at: nil}] = Ledger.list_entries(project.uuid)
      assert uuid == ann.uuid
    end

    test "without the project's billable flag there is no Billable box and nothing is billable",
         %{conn: conn, project: project, admin: admin} do
      fit = task(project, "Fit")
      {:ok, view, _html} = mount_tab(conn, project, admin)
      refute render_click(view, "open_log", %{}) =~ "-log-billable"

      render_submit(view, "save_log", %{
        "project" => project.uuid,
        "date" => Date.to_iso8601(Date.utc_today()),
        "duration" => %{"amount" => "1", "unit" => "hours"},
        "person" => "me",
        "task" => fit.uuid,
        "billable" => "true"
      })

      assert [%{billable: false}] = Ledger.list_entries(project.uuid)
    end

    # The `project_time` flag (time on the project as a whole) is the
    # project page's Log time rule; the Hours page logs with no task the
    # same way, so it answers to it too. Off by default × on.
    for {flag, outcome} <- [{nil, :refused}, {false, :refused}, {true, :logged}] do
      test "time on the project itself with project_time #{inspect(flag)}: #{outcome}",
           %{conn: conn, project: project, admin: admin} do
        project =
          case unquote(flag) do
            nil ->
              project

            value ->
              {:ok, project} =
                Projects.update_project(project, %{
                  "settings" =>
                    Map.put(project.settings || %{}, "features", %{"project_time" => value})
                })

              project
          end

        {:ok, view, _html} = mount_tab(conn, project, admin)
        opened = render_click(view, "open_log", %{})

        # The task picker offers "the project itself" only where it may be
        assert opened =~ ~s(placeholder="The project itself — or search a task") ==
                 (unquote(outcome) == :logged)

        assert opened =~ ~s(placeholder="Search a task") == (unquote(outcome) == :refused)

        html =
          render_submit(view, "save_log", %{
            "project" => project.uuid,
            "date" => Date.to_iso8601(Date.utc_today()),
            "duration" => %{"amount" => "1", "unit" => "hours"},
            "person" => "me",
            "task" => ""
          })

        case unquote(outcome) do
          :refused ->
            assert html =~ "keeps time on its tasks only"
            assert Ledger.list_entries(project.uuid) == []

          :logged ->
            assert [%{assignment_uuid: nil}] = Ledger.list_entries(project.uuid)
        end
      end
    end

    test "editing an entry where billable time is off keeps its billable mark",
         %{conn: conn, project: project, admin: admin} do
      entry =
        log(project, 30,
          actor_uuid: admin,
          billable: true,
          ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      {:ok, view, _html} = mount_tab(conn, project, admin)
      render_click(view, "edit_entry", %{"uuid" => entry.uuid})

      assert render_submit(view, "save_edit", %{
               "duration" => %{"amount" => "45", "unit" => "minutes"}
             }) =~ "Entry updated."

      amended = Ledger.get_entry(entry.uuid)
      assert Decimal.to_integer(amended.amount) == 45
      assert amended.billable
    end

    test "an account with no name of its own shows by its staff person's name, never its email",
         %{conn: conn, project: project, admin: admin} do
      {:ok, nameless} =
        Auth.register_user(%{
          email: "nameless-#{uniq()}@example.com",
          password: "ValidPassword123!"
        })

      Repo.insert!(%PhoenixKitStaff.Schemas.Person{
        user_uuid: nameless.uuid,
        status: "active",
        name: "Mati Mets"
      })

      log(project, 45, actor_uuid: nameless.uuid, ended_at: DateTime.utc_now(), note: "fitting")
      {:ok, _view, html} = mount_tab(conn, project, admin)

      assert html =~ "Mati Mets"
      refute html =~ nameless.email
    end

    test "amends and removes an entry, leaving a trace", %{
      conn: conn,
      project: project,
      admin: admin
    } do
      project = billable!(project)

      entry =
        log(project, 30,
          actor_uuid: admin,
          ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      {:ok, view, _html} = mount_tab(conn, project, admin)

      assert render_click(view, "edit_entry", %{"uuid" => entry.uuid}) =~ "Edit entry"

      assert render_submit(view, "save_edit", %{
               "duration" => %{"amount" => "x", "unit" => "hours"}
             }) =~
               "Enter a positive amount of time"

      html =
        render_submit(view, "save_edit", %{
          "duration" => %{"amount" => "45", "unit" => "minutes"},
          "billable" => "true"
        })

      assert html =~ "Entry updated."

      amended = Ledger.get_entry(entry.uuid)
      assert Decimal.to_integer(amended.amount) == 45 and amended.billable

      render_click(view, "request_confirm", %{
        "event" => "delete_entry",
        "uuid" => entry.uuid,
        "title" => "t"
      })

      html = render_click(view, "confirm_action_ok", %{})
      assert html =~ "Entry removed."
      assert Ledger.get_entry(entry.uuid) == nil
      assert_activity_logged("projects.work_removed", resource_uuid: project.uuid)
    end

    test "an entry of another project is never amended from here", %{
      conn: conn,
      project: project,
      admin: admin
    } do
      other = fixture_project()
      foreign = log(other, 30, actor_uuid: admin)
      {:ok, view, _html} = mount_tab(conn, project, admin)

      assert render_click(view, "edit_entry", %{"uuid" => foreign.uuid}) =~ "Entry not found."
      assert render_click(view, "delete_entry", %{"uuid" => foreign.uuid}) =~ "Entry not found."
      assert render_click(view, "edit_entry", %{"uuid" => "nonsense"}) =~ "Entry not found."
      assert Ledger.get_entry(foreign.uuid)
    end

    test "an invoiced entry is shown as such and left alone", %{
      conn: conn,
      project: project,
      admin: admin
    } do
      entry =
        log(project, 30,
          actor_uuid: admin,
          billable: true,
          ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      Repo.query!(
        "INSERT INTO phoenix_kit_project_invoiced_entries (entry_uuid, project_uuid, invoice_uuid) VALUES ($1, $2, $3)",
        Enum.map([entry.uuid, project.uuid, Ecto.UUID.generate()], &Ecto.UUID.dump!/1)
      )

      {:ok, view, html} = mount_tab(conn, project, admin)
      assert html =~ "invoiced"
      refute has_element?(view, "#hours-#{project.uuid}-entry-menu-#{entry.uuid}")
      assert render_click(view, "delete_entry", %{"uuid" => entry.uuid}) =~ "on an invoice"
      assert Ledger.get_entry(entry.uuid)
    end

    test "a viewer the project does not let log time reads, and cannot write",
         %{conn: conn, project: project} do
      project = tighten(project, %{"log_time" => "managers", "edit_tasks" => "managers"})
      viewer = user("Vera", "Viewer")
      {:ok, _} = Members.add_member(project, viewer.uuid, role: "viewer")

      theirs =
        log(project, 30,
          actor_uuid: viewer.uuid,
          ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      {:ok, view, html} = mount_tab(conn, project, viewer.uuid)

      assert html =~ "Vera Viewer"
      refute has_element?(view, "#hours-#{project.uuid}-log")
      refute has_element?(view, "#hours-#{project.uuid}-entry-menu-#{theirs.uuid}")

      assert render_click(view, "open_log", %{}) =~ "permission to log time here"

      assert render_submit(view, "save_log", %{
               "project" => project.uuid,
               "date" => Date.to_iso8601(Date.utc_today()),
               "duration" => %{"amount" => "1", "unit" => "hours"}
             }) =~ "Vera Viewer"

      assert render_click(view, "edit_entry", %{"uuid" => theirs.uuid}) =~
               "permission to change this entry"

      assert render_click(view, "delete_entry", %{"uuid" => theirs.uuid}) =~
               "permission to change this entry"

      assert [_only] = Ledger.list_entries(project.uuid)
    end

    test "a member changes their own entry and nobody else's", %{conn: conn, project: project} do
      project = tighten(project, %{"edit_tasks" => "managers"})
      me = user("Mia", "Member")
      ann = user("Ann", "Able")
      {:ok, _} = Members.add_member(project, me.uuid, role: "member")
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      mine = log(project, 30, actor_uuid: me.uuid, ended_at: now)
      hers = log(project, 30, actor_uuid: ann.uuid, ended_at: now)

      {:ok, view, _html} = mount_tab(conn, project, me.uuid)

      assert has_element?(view, "#hours-#{project.uuid}-entry-menu-#{mine.uuid}")
      refute has_element?(view, "#hours-#{project.uuid}-entry-menu-#{hers.uuid}")

      assert render_click(view, "delete_entry", %{"uuid" => hers.uuid}) =~
               "permission to change this entry"

      assert render_click(view, "delete_entry", %{"uuid" => mine.uuid}) =~ "Entry removed."
      # only "Me" is offered to someone who does not run the plan
      render_click(view, "open_log", %{})
      assert has_element?(view, "#hours-#{project.uuid}-log-form")
      refute has_element?(view, "#hours-#{project.uuid}-log-person")
    end

    test "someone who cannot see the project gets nothing", %{conn: conn, project: project} do
      stranger = user("Sam", "Stranger")
      log(project, 30, note: "private-note")
      {:ok, _view, html} = mount_tab(conn, project, stranger.uuid)
      assert html =~ "Project not found."
      refute html =~ "private-note"
    end

    test "a project with the ledger off says so", %{conn: conn, project: project, admin: admin} do
      {:ok, _} = Features.set_flags(project, %{"ledger" => false})
      {:ok, view, html} = mount_tab(conn, project, admin)
      assert html =~ "Hours are turned off"
      assert render_click(view, "open_log", %{}) =~ "Hours are turned off"
    end

    test "re-reads when time is logged elsewhere", %{conn: conn, project: project, admin: admin} do
      {:ok, view, html} = mount_tab(conn, project, admin)
      refute html =~ "from-elsewhere"

      log(project, 20,
        ended_at: DateTime.utc_now() |> DateTime.truncate(:second),
        note: "from-elsewhere"
      )

      assert render(view) =~ "from-elsewhere"
    end

    test "the timesheet pages by week", %{conn: conn, project: project, admin: admin} do
      ann = user("Ann", "Able")
      last_week = DateTime.utc_now() |> DateTime.add(-7 * 86_400) |> DateTime.truncate(:second)
      log(project, 60, actor_uuid: ann.uuid, ended_at: last_week)

      {:ok, view, _html} = mount_tab(conn, project, admin)
      render_change(view, "filter", %{"period" => "all", "subprojects" => "true"})
      # Core's date_nav names the day to show; the sheet shows its week.
      today = Date.utc_today()
      render_click(view, "sheet_week", %{"date" => Date.to_iso8601(today)})

      assert view |> element("#hours-#{project.uuid}-sheet") |> render() =~ "Nothing logged for"

      sheet = render_click(view, "sheet_week", %{"date" => Date.to_iso8601(Date.add(today, -7))})
      assert sheet =~ "Ann Able"
    end
  end

  describe "the report" do
    test "replaces the page with a sheet, its text and an on-demand CSV",
         %{conn: conn, project: project, admin: admin} do
      ann = user("Ann", "Able")
      cut = task(project, "Cut the panels")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      log(project, 90,
        actor_uuid: ann.uuid,
        assignment_uuid: cut.uuid,
        ended_at: now,
        note: "=SUM(A1)"
      )

      {:ok, view, _html} = mount_tab(conn, project, admin)
      html = render_click(view, "open_report", %{})

      assert html =~ "Hours — #{project.name}"
      assert html =~ "Print or save as PDF"
      assert html =~ "By person"
      assert html =~ "# Hours — #{project.name}"
      refute has_element?(view, "#hours-#{project.uuid}-report-csv")

      render_click(view, "prepare_csv", %{})
      href = view |> element("#hours-#{project.uuid}-report-csv") |> render()
      [_, encoded] = Regex.run(~r/href="data:text\/csv;charset=utf-8;base64,([^"]+)"/, href)
      csv = Base.decode64!(encoded)
      assert csv =~ "Ann Able"
      assert csv =~ "Cut the panels"
      assert csv =~ "1.50"
      # a formula in a note is written as text
      assert csv =~ "'=SUM(A1)"

      html = render_click(view, "close_report", %{})
      assert html =~ "Timesheet"
    end
  end

  describe "the site-wide page" do
    test "an admin sees every project, filters to one and keeps it in the URL",
         %{conn: conn, project: project} do
      other = fixture_project(%{"name" => "Bathroom #{uniq()}"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      log(project, 60, ended_at: now, note: "kitchen-note")
      log(other, 30, ended_at: now, note: "bathroom-note")

      {:ok, view, html} = live(conn, "/en/admin/projects/hours")
      assert html =~ "kitchen-note" and html =~ "bathroom-note"
      assert html =~ "By project"
      assert has_element?(view, "[phx-hook=PhoenixKitUrlState]")

      html = render_change(view, "filter", %{"project" => other.uuid, "subprojects" => "true"})
      assert html =~ "bathroom-note"
      refute html =~ "kitchen-note"

      {:ok, _view, html} = live(conn, "/en/admin/projects/hours?project=#{other.uuid}&period=all")
      assert html =~ "bathroom-note"
      refute html =~ "kitchen-note"
    end

    test "a member sees only the projects they are on, whatever the URL names",
         %{conn: conn, project: project} do
      mine = fixture_project(%{"name" => "Mine #{uniq()}"})
      member = user("Mia", "Member")
      {:ok, _} = Members.add_member(mine, member.uuid, role: "member")
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      log(mine, 60, ended_at: now, note: "mine-note")
      log(project, 30, ended_at: now, note: "not-mine-note")

      conn = put_test_scope(conn, fake_scope(user_uuid: member.uuid, permissions: ["projects"]))

      {:ok, _view, html} = live(conn, "/en/admin/projects/hours")
      assert html =~ "mine-note"
      refute html =~ "not-mine-note"
      refute html =~ project.name

      {:ok, view, html} = live(conn, "/en/admin/projects/hours?project=#{project.uuid}")
      refute html =~ "not-mine-note"

      foreign = Ledger.list_entries(project.uuid) |> hd()
      assert render_click(view, "delete_entry", %{"uuid" => foreign.uuid}) =~ "Entry not found."
    end

    test "the log form reads tasks only of a project the viewer may log on",
         %{conn: conn, project: project} do
      task(project, "Foreign secret task")
      mine = fixture_project(%{"name" => "Mine #{uniq()}"})
      task(mine, "My own task")
      off = fixture_project(%{"name" => "Ledger off #{uniq()}"})
      task(off, "Task behind a switched-off ledger")
      {:ok, _} = PhoenixKitProjects.Features.set_flags(off, %{"ledger" => false})
      member = user("Lena", "Logger")
      {:ok, _} = Members.add_member(mine, member.uuid, role: "member")
      {:ok, _} = Members.add_member(off, member.uuid, role: "member")

      conn = put_test_scope(conn, fake_scope(user_uuid: member.uuid, permissions: ["projects"]))
      {:ok, view, _html} = live(conn, "/en/admin/projects/hours")
      render_click(view, "open_log", %{})

      # Tasks are searched, not listed (core's search_picker).
      render_change(view, "log_change", %{"project" => mine.uuid})
      assert "My own task" in task_search(view)
      # a project they cannot see, named by a forged param
      render_change(view, "log_change", %{"project" => project.uuid})
      refute "Foreign secret task" in task_search(view)

      # theirs, but its work ledger is off: no tasks offered, no entry taken
      render_change(view, "log_change", %{"project" => off.uuid})
      refute "Task behind a switched-off ledger" in task_search(view)

      render_submit(view, "save_log", %{
        "project" => off.uuid,
        "date" => Date.to_iso8601(Date.utc_today()),
        "duration" => %{"amount" => "20", "unit" => "minutes"}
      })

      assert Ledger.list_entries(off.uuid) == []
    end

    test "logging from here picks the project and reads its tasks", %{
      conn: conn,
      project: project
    } do
      cut = task(project, "Cut the panels")
      scope = fake_scope(user_uuid: embed_user_uuid!())
      conn = put_test_scope(conn, scope)
      {:ok, view, _html} = live(conn, "/en/admin/projects/hours")

      render_click(view, "open_log", %{})

      render_change(view, "log_change", %{
        "project" => project.uuid,
        "duration" => %{"amount" => "20", "unit" => "minutes"}
      })

      assert "Cut the panels" in task_search(view)

      render_submit(view, "save_log", %{
        "project" => project.uuid,
        "date" => Date.to_iso8601(Date.utc_today()),
        "duration" => %{"amount" => "20", "unit" => "minutes"},
        "task" => cut.uuid
      })

      assert [%{assignment_uuid: uuid}] = Ledger.list_entries(project.uuid)
      assert uuid == cut.uuid
    end
  end

  # What the log form's task picker answers for an empty search.
  defp task_search(view) do
    render_hook(view, "pick_search", %{"q" => "", "id" => "log-pick-logtask"})
    assert_push_event(view, "picker_results", %{id: "log-pick-logtask", results: rows})
    Enum.map(rows, & &1.label)
  end

  defp before?(html, a, b) do
    {ia, _} = :binary.match(html, a)
    {ib, _} = :binary.match(html, b)
    ia < ib
  end
end
