defmodule PhoenixKitProjects.Web.FormsNight1125Test do
  @moduledoc """
  Max's hand review of 2026-11-25, the forms and the popup's chrome:

    * the new-project page drops the title beside its back arrow (the
      breadcrumb names the page);
    * the Schedule tab's section is open, its start date shows once
      "Scheduled date" is the choice (by the server too, not only a CSS
      rule), "No template" is said only where a template can be picked, and
      the weekends box reads "Count weekends";
    * times are the viewer's own zone: a browser zone (`PkpZone`) is taken
      when the profile names none, and the forms say which zone;
    * a popup host hands its open frames back after a dropped connection
      (`pkp_restore_stack`), each checked like any opening;
    * the ✕ and the offline notice are part of every frame.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitProjects.L10n

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope)}
  end

  describe "the new-project page" do
    test "no title beside the back arrow; the breadcrumb names the page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/new")
      assert html =~ ~r/<h2[^>]*id="project-form-header-title"[^>]*class="[^"]*sr-only/
    end

    test "the schedule section is open and the start date follows the choice", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/projects/new")
      assert html =~ ~r/<details[^>]*id="create-start"[^>]*open/

      html =
        view
        |> form("#project-form", project: %{name: "Kitchen", start_mode: "immediate"})
        |> render_change()

      assert html =~ ~s(class="hidden group-has-[option[value=scheduled]:checked]/start:block")

      html =
        view
        |> form("#project-form", project: %{name: "Kitchen", start_mode: "scheduled"})
        |> render_change()

      assert html =~ ~s(class="group-has-[option[value=scheduled]:checked]/start:block")
      assert html =~ "project-scheduled-start"
    end

    test "the weekends box reads 'Count weekends'; no 'No template' with nothing to pick",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/new")
      assert html =~ "Count weekends"
      refute html =~ "Count weekends in schedule"
      refute html =~ "No template"
    end
  end

  describe "the viewer's own time zone" do
    test "a browser zone is taken only without a profile zone, and only a real zone" do
      assert L10n.use_browser_zone(%{user_timezone: nil}, "Asia/Tokyo")
      assert L10n.viewer_zone() == "Asia/Tokyo"
      refute L10n.use_browser_zone(%{user_timezone: nil}, "Asia/Tokyo")
      refute L10n.use_browser_zone(%{user_timezone: "Europe/Tallinn"}, "America/Lima")
      refute L10n.use_browser_zone(%{user_timezone: nil}, "Not/AZone")
      assert L10n.viewer_zone() == "Asia/Tokyo"
    after
      L10n.reset_viewer_zone()
    end

    test "the task form takes the browser's zone, names it, and 'In 1 hour' is that clock",
         %{conn: conn} do
      project = fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")

      html = render_hook(view, "pkp_zone", %{"zone" => "Asia/Tokyo"})
      assert html =~ TimeZone.label("Asia/Tokyo")
      assert html =~ ~s(phx-hook="PkpZone")

      html = render_click(view, "deadline_preset", %{"preset" => "hour"})

      # Added before the shift: this test database knows UTC only.
      minutes =
        for m <- [0, 1] do
          DateTime.utc_now()
          |> DateTime.add(3600 + m * 60)
          |> TimeZone.shift("Asia/Tokyo")
          |> Calendar.strftime("%H:%M")
        end

      assert Enum.any?(minutes, &(html =~ &1)), "deadline not on Tokyo's clock"
    end

    test "the project form names the zone beside the scheduled start", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/new")
      html = render_hook(view, "pkp_zone", %{"zone" => "America/Lima"})
      assert html =~ TimeZone.label("America/Lima")
    end
  end

  describe "the popup host after a dropped connection" do
    # A real viewer: the host stamps it into each frame, and a form with no
    # viewer refuses and closes its own frame.
    defp host(conn) do
      topic = "forms-night-#{System.unique_integer([:positive])}"

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitProjects.Web.PopupHostLive,
          session: %{
            "pubsub_topic" => topic,
            "placement" => "center",
            "current_user_uuid" => embed_user_uuid!()
          }
        )

      view
    end

    defp stack(view), do: :sys.get_state(view.pid).socket.assigns.modal_stack

    test "hands the open frames back; refuses what an opening would refuse", %{conn: conn} do
      project = fixture_project()
      view = host(conn)

      render_hook(view, "pkp_restore_stack", %{
        "frames" => [
          %{"lv" => "Elixir.Kernel", "session" => %{}},
          %{
            "lv" => "Elixir.PhoenixKitProjects.Web.AssignmentFormLive",
            "session" => %{
              "live_action" => "new",
              "project_id" => project.uuid,
              "current_user_uuid" => Ecto.UUID.generate(),
              "pubsub_topic" => "elsewhere"
            }
          }
        ]
      })

      assert [frame] = stack(view)
      assert frame.lv == PhoenixKitProjects.Web.AssignmentFormLive
      # The host's own keys are the host's, never the browser's.
      refute frame.session["pubsub_topic"] == "elsewhere"
      refute Map.has_key?(frame.origin, "current_user_uuid")

      # The list the browser keeps carries what opened it.
      html = render(view)
      assert html =~ ~s(phx-hook="PkpKeepStack")
      assert html =~ "AssignmentFormLive"

      # Something is open: nothing more is handed back.
      render_hook(view, "pkp_restore_stack", %{
        "frames" => [
          %{
            "lv" => "Elixir.PhoenixKitProjects.Web.AssignmentFormLive",
            "session" => %{"live_action" => "new", "project_id" => project.uuid}
          }
        ]
      })

      assert [_only_one] = stack(view)
    end

    test "every frame has its pinned ✕ and the offline notice", %{conn: conn} do
      project = fixture_project()
      view = host(conn)

      html =
        render_hook(view, "pkp_restore_stack", %{
          "frames" => [
            %{
              "lv" => "Elixir.PhoenixKitProjects.Web.AssignmentFormLive",
              "session" => %{"live_action" => "new", "project_id" => project.uuid}
            }
          ]
        })

      assert html =~ "pkp-frame-close"
      assert html =~ "pkp-offline"
    end
  end
end
