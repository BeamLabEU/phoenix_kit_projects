defmodule PhoenixKitProjects.Web.LibraryPickerTest do
  @moduledoc """
  Item 27 (the panel's proposal, Max 2026-10-31: "Go for it"): the add-task
  form's "From library" picker opens on a focused search box
  (diacritic-insensitive, title then description), then Recent (this
  viewer's adds), Often used (the site's) and the whole library A–Z under
  letter headings; ticked tasks are added in the order ticked by one
  "Add N tasks".
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{LibrarySearch, Projects}
  alias PhoenixKitProjects.Web.AssignmentFormLive

  describe "LibrarySearch (no page)" do
    test "fold/1 drops accents and case" do
      assert LibrarySearch.fold("  Mõõtmine  ÄÖÜ ") == "mootmine aou"
    end

    test "filter/3: diacritic-insensitive, title before description" do
      measure = %PhoenixKitProjects.Schemas.Task{uuid: "1", title: "Mõõtmine", description: nil}

      other = %PhoenixKitProjects.Schemas.Task{
        uuid: "2",
        title: "Paigaldus",
        description: "pärast mõõtmist"
      }

      third = %PhoenixKitProjects.Schemas.Task{uuid: "3", title: "Tellimine", description: nil}

      assert [%{uuid: "1"}, %{uuid: "2"}] =
               LibrarySearch.filter([third, other, measure], "mootmi", nil)

      assert LibrarySearch.filter([third], "  ", nil) == []
    end

    test "alphabetical/2: letter headings; Estonian Õ Ä Ö Ü after W" do
      tasks =
        for {u, t} <- [
              {"1", "Ülevaatus"},
              {"2", "Arve"},
              {"3", "Õlitamine"},
              {"4", "Värvimine"},
              {"5", "Äär"}
            ],
            do: %PhoenixKitProjects.Schemas.Task{uuid: u, title: t}

      assert LibrarySearch.alphabetical(tasks, "et") |> Enum.map(&elem(&1, 0)) ==
               ["A", "V", "Õ", "Ä", "Ü"]

      # Elsewhere an accented letter sits with its base letter.
      assert LibrarySearch.alphabetical(tasks, "en") |> Enum.map(&elem(&1, 0)) ==
               ["A", "O", "U", "V"]
    end
  end

  describe "the picker in the add-task form" do
    setup %{conn: conn} do
      {:ok, user} =
        Auth.register_user(%{
          "email" => "lib-picker-#{System.unique_integer([:positive])}@example.com",
          "password" => "PickerPass123!"
        })

      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
      project = fixture_project()

      measure = fixture_task(%{"title" => "Mõõtmine", "description" => "Kitchen measured"})
      design = fixture_task(%{"title" => "Disain"})
      fit = fixture_task(%{"title" => "Paigaldus", "description" => "after the mõõtmine"})

      {:ok, conn: conn, user: user, project: project, measure: measure, design: design, fit: fit}
    end

    defp open(ctx) do
      {:ok, view, _html} =
        live_isolated(ctx.conn, AssignmentFormLive,
          session: %{
            "project_id" => ctx.project.uuid,
            "live_action" => "new",
            "current_user_uuid" => ctx.user.uuid
          }
        )

      render_click(view, "set_task_mode", %{"tab" => "existing"})
      view
    end

    defp search(view, q),
      do:
        view
        |> element("form[id^='assignment-library-form-']")
        |> render_change(%{"library_q" => q})

    test "opens on the search box, then the library A–Z with letter headings", ctx do
      view = open(ctx)
      assert has_element?(view, "input[type=search][name=library_q][phx-mounted]")
      assert has_element?(view, "[id^='library-letter-'] h4", "D")
      assert has_element?(view, "[id^='library-letter-'] h4", "M")
      assert has_element?(view, "[id^='library-letter-'] h4", "P")
      refute has_element?(view, "[id^='library-recent-']")
    end

    test "typing replaces the blocks with one list: title matches first, then description",
         ctx do
      view = open(ctx)
      html = search(view, "mootmine")

      assert has_element?(
               view,
               "[id^='library-matches-'] [data-library-task='#{ctx.measure.uuid}']"
             )

      assert has_element?(view, "[id^='library-matches-'] [data-library-task='#{ctx.fit.uuid}']")

      refute has_element?(
               view,
               "[id^='library-matches-'] [data-library-task='#{ctx.design.uuid}']"
             )

      refute has_element?(view, "[id^='library-letter-']")

      {m, _} = :binary.match(html, ctx.measure.uuid)
      {f, _} = :binary.match(html, ctx.fit.uuid)
      assert m < f

      search(view, "zzz-nothing")
      assert render(view) =~ "No library task matches"
    end

    test "two ticked tasks are added in the order ticked, and remembered as Recent", ctx do
      view = open(ctx)

      render_click(view, "library_toggle", %{"uuid" => ctx.fit.uuid})
      html = render_click(view, "library_toggle", %{"uuid" => ctx.design.uuid})
      assert html =~ "Add 2 tasks"

      # The server draws every tick, on each row of a task listed twice too.
      assert has_element?(view, "[data-library-task='#{ctx.fit.uuid}'][aria-checked='true']")
      refute has_element?(view, "[data-library-task='#{ctx.fit.uuid}'][aria-checked='false']")
      refute has_element?(view, "[data-library-task='#{ctx.measure.uuid}'][aria-checked='true']")

      render_submit(view, "save", %{
        "assignment" => %{"status" => "waiting"},
        "task_mode" => "existing"
      })

      rows = Projects.list_assignments(ctx.project.uuid)
      assert Enum.map(rows, & &1.task_uuid) == [ctx.fit.uuid, ctx.design.uuid]
      assert LibrarySearch.recent(ctx.user.uuid) == [ctx.design.uuid, ctx.fit.uuid]

      # The next picker shows them under Recent.
      view = open(ctx)

      assert has_element?(
               view,
               "[id^='library-recent-'] [data-library-task='#{ctx.design.uuid}']"
             )
    end

    test "one ticked task is the form's own pick, with its library details", ctx do
      view = open(ctx)
      html = render_click(view, "library_toggle", %{"uuid" => ctx.measure.uuid})
      assert html =~ "Add 1 task"
      assert html =~ ~s(name="assignment[task_uuid]" value="#{ctx.measure.uuid}")

      render_submit(view, "save", %{
        "assignment" => %{"status" => "waiting", "task_uuid" => ctx.measure.uuid},
        "task_mode" => "existing"
      })

      assert [%{task_uuid: uuid}] = Projects.list_assignments(ctx.project.uuid)
      assert uuid == ctx.measure.uuid
      assert LibrarySearch.recent(ctx.user.uuid) == [ctx.measure.uuid]
    end

    test "Often used lists what projects add most", ctx do
      for _ <- 1..2 do
        p = fixture_project()

        {:ok, _} =
          Projects.create_assignment(%{"project_uuid" => p.uuid, "task_uuid" => ctx.design.uuid})
      end

      view = open(ctx)
      assert has_element?(view, "[id^='library-often-'] [data-library-task='#{ctx.design.uuid}']")
      refute has_element?(view, "[id^='library-often-'] [data-library-task='#{ctx.fit.uuid}']")
    end

    test "a forged tick of something not in the library is ignored", ctx do
      view = open(ctx)
      html = render_click(view, "library_toggle", %{"uuid" => Ecto.UUID.generate()})
      refute html =~ "Add 1 task"
    end
  end
end
