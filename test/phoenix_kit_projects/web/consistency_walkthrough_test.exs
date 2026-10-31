defmodule PhoenixKitProjects.Web.ConsistencyWalkthroughTest do
  @moduledoc """
  The consistency walk-through of 2026-10-31: the task popup is the
  reference, and the older pages follow it (no empty strips, the same
  header and footer, numbers and calendars in the page's language).
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Web.Components.DescriptionEditor
  alias PhoenixKitProjects.Web.Widgets.Helpers, as: WidgetHelpers

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "walkthrough-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, conn: conn, actor_uuid: user.uuid}
  end

  defp assignment!(project, attrs \\ %{}) do
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

  describe "no empty strip under the add buttons (item 1)" do
    test "a project with nothing done and no schedule row has no lone progress strip",
         %{conn: conn} do
      project = fixture_project()
      assignment!(project)

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert html =~ "Add task"
      refute html =~ ~s(id="project-summary-#{project.uuid}")
    end

    test "the strip comes back once something is done", %{conn: conn} do
      project = fixture_project()
      assignment!(project)
      assignment!(project, %{"status" => "done"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}")

      assert html =~ ~s(id="project-summary-#{project.uuid}")
    end
  end

  describe "task list spacing (item 2)" do
    test "rows keep half a rem between cards, not the old circle's gap", %{conn: conn} do
      project = fixture_project()
      a = assignment!(project)

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")
      row = view |> element("#task-#{a.uuid}") |> render()

      assert row =~ ~r/class="relative flex py-1 /
      refute row =~ ~r/class="relative flex py-3 /
    end
  end

  describe "a board card never cuts off at its right edge (item 3)" do
    test "the deadline chip truncates and the card's foot wraps", %{conn: conn} do
      project = fixture_project(%{"start_mode" => "immediate"})

      a =
        assignment!(project, %{
          "deadline" => DateTime.add(DateTime.utc_now(), 3 * 86_400, :second)
        })

      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/tasks/board")
      card = view |> element("#board-card-#{a.uuid}") |> render()

      [chip] = Regex.run(~r/<span[^>]*data-deadline=[^>]*>/s, card)
      assert chip =~ "max-w-full"
      assert card =~ ~s(<span class="truncate">)

      [foot] = Regex.run(~r/<div[^>]*data-board-card-foot[^>]*>/s, card)
      assert foot =~ "flex-wrap"
      refute card =~ "ml-auto shrink-0"
    end
  end

  describe "calendars speak the page's language (item 4)" do
    test "translations/0 names months, weekdays and the view buttons in the locale" do
      Gettext.put_locale(PhoenixKitProjects.Gettext, "et")
      t = PhoenixKitProjects.CalendarDisplay.translations()
      Gettext.put_locale(PhoenixKitProjects.Gettext, "en")

      # Estonian month names are lower-case (3b4489b).
      assert t.month_names[10] == "oktoober"
      assert t.day_names[2] == "Teisipäev"
      assert t.day_names_short[1] == "E"
      assert t.day_names_narrow[4] == "N"
      assert t.labels.month == "Kuu"
      assert t.labels.more =~ "%{count}"
    end

    test "the project Calendar tab renders Estonian headings and buttons", %{
      conn: conn,
      actor_uuid: actor
    } do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.start_project(project)
      start = Date.utc_today() |> Date.beginning_of_month() |> Date.add(9)

      {:ok, project} =
        Projects.update_project(project, %{started_at: DateTime.new!(start, ~T[08:00:00])})

      task = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})
      assignment!(project, %{"task_uuid" => task.uuid})
      {:ok, _} = PhoenixKitProjects.Members.add_member(project.uuid, actor, role: "member")

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectCalendarLive,
          session: %{"id" => project.uuid, "current_user_uuid" => actor, "locale" => "et"}
        )

      html = render_async(view)

      Gettext.put_locale(PhoenixKitProjects.Gettext, "et")

      month =
        PhoenixKitProjects.CalendarDisplay.translations().month_names[Date.utc_today().month]

      Gettext.put_locale(PhoenixKitProjects.Gettext, "en")

      assert html =~ month
      assert html =~ ">Kuu<" or html =~ "Kuu\n"
      refute html =~ ~r/>\s*Month\s*</
      refute html =~ ~r/>\s*Today\s*</
    end
  end

  describe "Week and Day open on today, at the work day's start (item 5)" do
    alias PhoenixKitProjects.Web.ProjectCalendarLive

    test "snap_to_today/4 takes today when it was on screen, else stays" do
      today = ~D[2026-10-31]

      assert ProjectCalendarLive.snap_to_today(:month, ~D[2026-10-10], today) == today
      assert ProjectCalendarLive.snap_to_today(:month, ~D[2026-12-01], today) == ~D[2026-12-01]
      assert ProjectCalendarLive.snap_to_today(:week, ~D[2026-10-27], today) == today
      assert ProjectCalendarLive.snap_to_today(:day, ~D[2026-10-30], today) == ~D[2026-10-30]
    end

    test "switching the project calendar to Day shows today, with the work-day hook", %{
      conn: conn,
      actor_uuid: actor
    } do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.start_project(project)
      # The schedule starts on the 10th, so the grid's own date is not today.
      start = Date.utc_today() |> Date.beginning_of_month() |> Date.add(9)

      {:ok, project} =
        Projects.update_project(project, %{started_at: DateTime.new!(start, ~T[08:00:00])})

      task = fixture_task(%{"estimated_duration" => 2, "estimated_duration_unit" => "days"})
      assignment!(project, %{"task_uuid" => task.uuid})
      {:ok, _} = PhoenixKitProjects.Members.add_member(project.uuid, actor, role: "member")

      {:ok, view, _html} =
        live_isolated(conn, ProjectCalendarLive,
          session: %{"id" => project.uuid, "current_user_uuid" => actor}
        )

      html = render_async(view)
      assert html =~ ~s(phx-hook="PkpCalendarWorkday")
      assert html =~ ~s(data-start="08:00:00")

      view |> element(~s(button[phx-value-view="day"])) |> render_click()
      html = render(view)

      today = Date.utc_today() |> Date.to_iso8601()

      assert [[^today]] =
               Regex.scan(~r/cal-day-column[^"]*"[^>]*data-date="([^"]+)"/, html,
                 capture: :all_but_first
               )
    end

    test "the hook ships in the module's bundle" do
      js =
        File.read!(
          Application.app_dir(:phoenix_kit_projects, "priv/static/assets/phoenix_kit_projects.js")
        )

      assert js =~ "PkpCalendarWorkday: CalendarWorkday"
    end
  end

  describe "the project popup follows the task popup (item 6)" do
    defp project_popup(conn, project) do
      live_isolated(conn, PhoenixKitProjects.Web.ProjectFormLive,
        session: %{
          "current_user_uuid" => embed_user_uuid!(),
          "mode" => "emit",
          "pubsub_topic" => "walk-#{System.unique_integer([:positive])}",
          "live_action" => "edit",
          "id" => project.uuid,
          "frame_ref" => 1
        }
      )
    end

    test "its footer says Close, not Cancel, and keeps Save", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _view, html} = project_popup(conn, project)

      [_, footer] = String.split(html, ~s(id="project-form-tabs"), parts: 2)
      [footer | _] = String.split(footer, ~s(id="project-modules-card"), parts: 2)
      [_, footer] = String.split(footer, ~s(phx-click="cancel"), parts: 2)
      [footer | _] = String.split(footer, "</form>", parts: 2)

      assert footer =~ ~r/^[^<]*>\s*Close\s*</
      refute footer =~ "Cancel"
      assert footer =~ ~r/>\s*Save\s*</
    end

    test "its header carries the project's key and status, like the task popup's", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.start_project(project)
      project = Projects.get_project!(project.uuid)
      {:ok, _view, html} = project_popup(conn, project)

      [header] = Regex.run(~r{<header id="project-form-header".*?</header>}s, html)
      assert header =~ ~s(data-ref="#{project.key}")
      assert header =~ "badge"
    end

    test "the modules panel inside the form leaves the browser tab's title alone", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
      project = fixture_project()

      {:ok, embedded, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectModulesLive,
          session: %{
            "id" => project.uuid,
            "embedded_in_form" => true,
            "current_user_uuid" => embed_user_uuid!()
          }
        )

      assert lv_page_title(embedded) == nil

      # The same panel as a page of its own still titles the tab.
      {:ok, page, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectModulesLive,
          session: %{"id" => project.uuid, "current_user_uuid" => embed_user_uuid!()}
        )

      assert lv_page_title(page) == "Modules"
    end

    # LiveView sends every LV's `page_title` to the browser, nested ones
    # included — the assign is what reaches the tab.
    defp lv_page_title(view), do: :sys.get_state(view.pid).socket.assigns[:page_title]
  end

  describe "the project link hint (item 7)" do
    test "says a site path opens in a new tab too, as the link does", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
      project = fixture_project()
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")

      assert html =~ "both open in a new tab"
      refute html =~ "opens in the same one"
    end
  end

  describe "an embedded project's header keeps to as few lines as it can (item 8)" do
    test "Archived sits by the name, and ⋮ travels with the status picker", %{
      conn: conn,
      actor_uuid: actor
    } do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, _} = Projects.archive_project(project)
      {:ok, _} = PhoenixKitProjects.Members.add_member(project.uuid, actor, role: "member")

      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectShowLive,
          session: %{"id" => project.uuid, "current_user_uuid" => actor}
        )

      {h1, _} = :binary.match(html, "<h1")
      {archived, _} = :binary.match(html, "data-archived")
      {menu, _} = :binary.match(html, ~s(id="project-header-menu-#{project.uuid}"))
      assert h1 < archived and archived < menu

      [group] = Regex.run(~r/<div[^>]*data-header-end[^>]*>.*?project-header-menu-/s, html)
      assert group =~ "data-header-end"
    end
  end

  describe "decimals in the page's language (item 9)" do
    alias PhoenixKitProjects.Hours.Format
    alias PhoenixKitProjects.L10n

    defp in_locale(locale, fun) do
      Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
      Gettext.put_locale(PhoenixKitProjects.Gettext, locale)
      fun.()
    after
      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")
      Gettext.put_locale(PhoenixKitProjects.Gettext, "en")
    end

    test "format_decimal/2 writes a comma in et/ru/de/es/fr/it/pl and a point in English" do
      for locale <- ~w(et ru de es fr it pl) do
        assert in_locale(locale, fn -> L10n.format_decimal(4.56) end) == "4,6"
      end

      assert in_locale("en", fn -> L10n.format_decimal(4.56) end) == "4.6"
      assert in_locale("et-EE", fn -> L10n.format_decimal(1.1) end) == "1,1"
      assert in_locale("et", fn -> L10n.format_decimal(2.0) end) == "2"

      assert in_locale("et", fn -> L10n.format_decimal(1.5, decimals: 2, trim: false) end) ==
               "1,50"

      assert in_locale("et", fn -> L10n.format_decimal(1.25, decimals: 2) end) == "1,25"
    end

    test "the Hours figures, tokens and costs on a page follow it; the CSV keeps a point" do
      in_locale("ru", fn ->
        assert Format.hours_shown(90) == "1,50"
        assert Format.tokens(3_400) == "3,4k"
        assert Format.cost(1234) == "$12,34"
        assert WidgetHelpers.hours(1.5) == "1,5h"
        assert Format.decimal_hours(90) == "1.50"
      end)
    end
  end

  # Since the boss's second list (item 8) every description takes them.
  describe "a picture pasted into a project's, template's or library task's description" do
    @png <<137, 80, 78, 71, 13, 10, 26, 10>>

    defp paste_kept(view, html, base) do
      [id] =
        Regex.run(~r/data-description-editor="(#{base}--[^"]+)"/, html, capture: :all_but_first)

      # The editor intercepts pastes: the host is asked, nothing goes in as data.
      assert html =~ ~s(data-has-upload="true")

      send(
        view.pid,
        {:leaf_paste_image,
         %{
           editor_id: id,
           data_url: "data:image/png;base64," <> Base.encode64(@png),
           name: "shot.png",
           mime: "image/png"
         }}
      )

      html = render(view)
      refute html =~ "cannot hold images"
      refute html =~ "Upload failed"
      refute html =~ "data:image/png"
    end

    setup %{conn: conn} do
      {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))}
    end

    test "the library task editor keeps it", %{conn: conn} do
      task = fixture_task()
      {:ok, view, html} = live(conn, "/en/admin/projects/tasks/#{task.uuid}/edit")
      paste_kept(view, html, "task-description")
    end

    test "the template editor keeps it", %{conn: conn} do
      template = fixture_project(%{"is_template" => true})
      {:ok, view, html} = live(conn, "/en/admin/projects/templates/#{template.uuid}/edit")
      paste_kept(view, html, "template-description")
    end

    test "the project editor keeps it in the project's folder", %{conn: conn} do
      project = fixture_project()
      {:ok, view, html} = live(conn, "/en/admin/projects/#{project.uuid}/edit")
      paste_kept(view, html, "project-description")
      assert [_ | _] = PhoenixKitProjects.Attachments.list_files(project)
    end
  end

  describe "no English from shared parts on other pages (item 11)" do
    alias PhoenixKitProjects.Web.Components.FormParts

    test "the language tabs carry each language's own name" do
      tabs = [
        %{code: "et", name: "Estonian", flag: nil, is_primary: true, short_code: "ET"},
        %{code: "ru", name: "Russian", flag: nil, is_primary: false, short_code: "RU"},
        %{code: "xx-unknown", name: "Unknown", flag: nil, is_primary: false, short_code: "XX"}
      ]

      assert Enum.map(FormParts.native_tabs(tabs), & &1.name) == ["Eesti", "Русский", "Unknown"]
    end

    test "a region is named only when two variants of the language are on" do
      tab = fn code, name ->
        %{code: code, name: name, flag: nil, is_primary: false, short_code: code}
      end

      lone = FormParts.native_tabs([tab.("et", "Estonian"), tab.("en-US", "English (US)")])
      assert Enum.map(lone, & &1.name) == ["Eesti", "English"]

      both = FormParts.native_tabs([tab.("en-US", "English (US)"), tab.("en-GB", "English (UK)")])
      assert Enum.all?(both, &(&1.name =~ "("))
    end

    test "the description editor hides Leaf's English word / char / read-time counter" do
      html =
        render_component(
          &DescriptionEditor.description_editor/1,
          id: "walk-description--en",
          name: "walk[description]",
          value: "Hello"
        )

      [wrapper] =
        Regex.run(~r/<div[^>]*data-description-editor="walk-description--en"[^>]*>/, html)

      assert wrapper =~ "[&amp;_div:has(&gt;[data-editor-footer])]:hidden" or
               wrapper =~ "[&_div:has(>[data-editor-footer])]:hidden"
    end
  end

  describe "the other popups do the same job the task popup's way (item 12)" do
    setup %{conn: conn} do
      {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))}
    end

    defp popup(conn, lv, extra) do
      live_isolated(conn, lv,
        session:
          Map.merge(
            %{
              "current_user_uuid" => embed_user_uuid!(),
              "mode" => "emit",
              "pubsub_topic" => "walk-#{System.unique_integer([:positive])}",
              "frame_ref" => 1
            },
            extra
          )
      )
    end

    defp header(html, id) do
      [header] = Regex.run(~r{<header id="#{id}".*?</header>}s, html)
      header
    end

    test "the library task popup: Close, and no lone \"← Tasks\" above its title", %{conn: conn} do
      task = fixture_task()

      {:ok, _view, html} =
        popup(conn, PhoenixKitProjects.Web.TaskFormLive, %{
          "live_action" => "edit",
          "id" => task.uuid
        })

      refute header(html, "task-form-header") =~ "Tasks"
      assert html =~ ~r/>\s*Close\s*</
      refute html =~ ~r/>\s*Cancel\s*</
    end

    test "the template popup: Close, and no lone \"← Templates\" above its title", %{conn: conn} do
      template = fixture_project(%{"is_template" => true})

      {:ok, _view, html} =
        popup(conn, PhoenixKitProjects.Web.TemplateFormLive, %{
          "live_action" => "edit",
          "id" => template.uuid
        })

      refute header(html, "template-form-header") =~ "Templates"
      assert html =~ ~r/>\s*Close\s*</
      refute html =~ ~r/>\s*Cancel\s*</
    end

    test "the sub-project popup's footer says Close", %{conn: conn} do
      project = fixture_project()

      {:ok, view, _html} =
        live(conn, "/en/admin/projects/#{project.uuid}/assignments/new?kind=subproject")

      footer = view |> element("#subproject-form button[phx-click=cancel]") |> render()
      assert footer =~ "Close"
    end

    test "popups and the Hours tab leave the browser tab's title to the page", %{conn: conn} do
      project = fixture_project()

      {:ok, _} =
        PhoenixKitProjects.Members.add_member(project.uuid, embed_user_uuid!(), role: "owner")

      for lv <- [
            PhoenixKitProjects.Web.ProjectMembersLive,
            PhoenixKitProjects.Web.ProjectActivityLive,
            PhoenixKitProjects.Web.ProjectApiLive
          ] do
        {:ok, view, _} = popup(conn, lv, %{"id" => project.uuid})
        assert lv_page_title(view) == nil, inspect(lv)
      end

      {:ok, tab, _} =
        live_isolated(conn, PhoenixKitProjects.Web.ProjectHoursLive,
          session: %{
            "project_uuid" => project.uuid,
            "current_user_uuid" => embed_user_uuid!(),
            "locale" => "en",
            "wrapper_class" => ""
          }
        )

      assert lv_page_title(tab) == nil
    end
  end
end
