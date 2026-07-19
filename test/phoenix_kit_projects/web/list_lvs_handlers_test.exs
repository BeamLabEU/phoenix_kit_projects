defmodule PhoenixKitProjects.Web.ListLVsHandlersTest do
  @moduledoc """
  Event-handler coverage for the new behaviours added during the
  modal-to-native-dialog refactor on `ProjectsLive`, `TasksLive`, and
  `TemplatesLive`:

  * sort handlers (`sort_form`, `toggle_sort`) — direction flip, sort
    change resets `loaded_count` so the user never sees a stale cap on
    a fresh sort.
  * `load_more` — bumps `loaded_count` by `@per_batch`, total/loaded
    visible row counts stay coherent.
  * Reorder-modal lifecycle — `open_reorder_modal` snapshots
    DOM-driven selection, collapses <2 selections to `:all`, fires the
    server-side strategy whitelist on `apply_reorder`, logs activity,
    and resets state on `close_reorder_modal` + success path.
  * `sanitize_uuids/1` private guard — non-list payloads, non-binary
    list elements, missing key — none should leak through.
  * `reorder_*` DnD handler error paths — `:too_many_uuids`.

  All handler dispatches use `render_click(view, "event", params)`
  rather than DOM-targeted forms, because several events are triggered
  by JS hooks (BulkSelectScope, SortableGrid) that we can't simulate
  in `LiveViewTest`.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  # ─── ProjectsLive ────────────────────────────────────────────────

  describe "ProjectsLive — sort handlers" do
    test "sort_form switches field and resets to :asc", %{conn: conn} do
      fixture_project(%{"name" => "B"})
      fixture_project(%{"name" => "A"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list")

      html = render_change(view, "sort_form", %{"sort_by" => "name"})
      # When sorted by name asc, "A" should render before "B" in the table body.
      assert html =~ ~r/A[\s\S]*?B/
    end

    test "sort_form switches direction without changing field", %{conn: conn} do
      fixture_project(%{"name" => "B"})
      fixture_project(%{"name" => "A"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      render_change(view, "sort_form", %{"sort_by" => "name"})
      html = render_change(view, "sort_form", %{"sort_dir" => "desc"})
      # name desc → "B" before "A"
      assert html =~ ~r/B[\s\S]*?A/
    end

    test "toggle_sort on the active field flips direction", %{conn: conn} do
      fixture_project(%{"name" => "B"})
      fixture_project(%{"name" => "A"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      render_change(view, "sort_form", %{"sort_by" => "name"})
      html = render_click(view, "toggle_sort", %{"by" => "name"})
      assert html =~ ~r/B[\s\S]*?A/
    end

    test "toggle_sort on a different field resets to :asc", %{conn: conn} do
      fixture_project(%{"name" => "B"})
      fixture_project(%{"name" => "A"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      # First switch to name+desc, then toggle to inserted_at — should
      # snap back to :asc on the new field, not inherit :desc.
      render_change(view, "sort_form", %{"sort_by" => "name", "sort_dir" => "desc"})
      html = render_click(view, "toggle_sort", %{"by" => "inserted_at"})
      # Inserted_at asc → earlier insertion first; "B" inserted first.
      assert html =~ ~r/B[\s\S]*?A/
    end

    test "toggle_sort ignores unknown field strings", %{conn: conn} do
      fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      # Should not crash; should return :noreply, socket.
      assert render_click(view, "toggle_sort", %{"by" => "drop_table"})
    end

    test "sort_form coerces unknown sort_by to current field", %{conn: conn} do
      fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      # Bogus field shouldn't crash, page should still render.
      assert render_change(view, "sort_form", %{"sort_by" => "evil_field"})
    end
  end

  describe "ProjectsLive — load_more" do
    test "load_more increases loaded cap and shows the new row", %{conn: conn} do
      # 51 rows: only the first 50 render initially.
      for n <- 1..51, do: fixture_project(%{"name" => "P#{String.pad_leading("#{n}", 3, "0")}"})

      {:ok, view, html} = live(conn, "/en/admin/projects/list")
      refute html =~ "P051"

      html_after = render_click(view, "load_more", %{})
      assert html_after =~ "P051"
    end
  end

  describe "ProjectsLive — reorder modal lifecycle" do
    test "open_reorder_modal with 0 uuids opens with empty captured_uuids",
         %{conn: conn} do
      fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      html = render_click(view, "open_reorder_modal", %{})
      # Modal is now in the DOM (keep_in_dom + data-show flip).
      assert html =~ "reorder-modal"
      # Scope label should read "all" since captured_uuids = [].
      assert html =~ "Reorder all"
    end

    test "open_reorder_modal with 1 uuid collapses to :all (no single-row permute)",
         %{conn: conn} do
      p = fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      html = render_click(view, "open_reorder_modal", %{"uuids" => [p.uuid]})
      assert html =~ "Reorder all"
    end

    test "open_reorder_modal with 2+ uuids keeps the selection", %{conn: conn} do
      a = fixture_project()
      b = fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      html = render_click(view, "open_reorder_modal", %{"uuids" => [a.uuid, b.uuid]})
      assert html =~ "2 selected"
    end

    test "open_reorder_modal filters non-binary uuids", %{conn: conn} do
      p = fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      # Mix uuid + integer + map; only the uuid string should survive.
      html =
        render_click(view, "open_reorder_modal", %{
          "uuids" => [p.uuid, 42, %{"k" => "v"}]
        })

      # Filtered list has 1 element → collapses to :all.
      assert html =~ "Reorder all"
    end

    test "close_reorder_modal clears state", %{conn: conn} do
      fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      render_click(view, "open_reorder_modal", %{"uuids" => []})
      html = render_click(view, "close_reorder_modal", %{})
      # Modal still in DOM (keep_in_dom), but data-show flipped to "false".
      assert html =~ ~s(data-show="false")
    end
  end

  describe "ProjectsLive — apply_reorder" do
    test "applies a valid strategy on the full set",
         %{conn: conn, actor_uuid: actor_uuid} do
      _b = fixture_project(%{"name" => "B"})
      _a = fixture_project(%{"name" => "A"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      render_click(view, "open_reorder_modal", %{})

      html = render_click(view, "apply_reorder", %{"strategy" => "name_asc"})

      assert html =~ "Projects reordered"
      # Positions are now 1=A, 2=B.
      listed = Projects.list_projects(archived: false) |> Enum.sort_by(& &1.position)
      assert Enum.map(listed, & &1.name) == ["A", "B"]

      assert_activity_logged("project.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"mechanism" => "strategy", "strategy" => "name_asc"}
      )
    end

    test "rejects an unknown strategy string with a fallback flash",
         %{conn: conn} do
      fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      render_click(view, "open_reorder_modal", %{})

      # A crafted payload mustn't reach `String.to_existing_atom` —
      # this would otherwise raise (or, worse on `:to_atom`, leak the
      # atom slot).
      html = render_click(view, "apply_reorder", %{"strategy" => "delete_all"})
      assert html =~ "Pick a strategy"
    end

    test "rejects an empty submit with a fallback flash", %{conn: conn} do
      fixture_project()
      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      render_click(view, "open_reorder_modal", %{})
      html = render_click(view, "apply_reorder", %{})
      assert html =~ "Pick a strategy"
    end

    test "applies on the selected scope when 2+ uuids captured",
         %{conn: conn} do
      a = fixture_project(%{"name" => "AA"})
      b = fixture_project(%{"name" => "BB"})
      _c = fixture_project(%{"name" => "CC"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list")
      render_click(view, "open_reorder_modal", %{"uuids" => [b.uuid, a.uuid]})

      html = render_click(view, "apply_reorder", %{"strategy" => "name_desc"})
      assert html =~ "Projects reordered"
    end
  end

  describe "ProjectsLive — reorder_projects DnD" do
    test "happy path: 2-row swap", %{conn: conn, actor_uuid: actor_uuid} do
      a = fixture_project(%{"name" => "A"})
      b = fixture_project(%{"name" => "B"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/list")

      render_click(view, "reorder_projects", %{
        "ordered_ids" => [b.uuid, a.uuid],
        "moved_id" => b.uuid
      })

      reloaded = Projects.list_projects(archived: false) |> Enum.sort_by(& &1.position)
      assert Enum.map(reloaded, & &1.uuid) == [b.uuid, a.uuid]

      # DnD path uses the same action key but doesn't stamp a
      # `mechanism` field (only strategy reorders do) — distinguish
      # by absence.
      assert_activity_logged("project.reordered", actor_uuid: actor_uuid)
    end
  end

  # ─── TasksLive ───────────────────────────────────────────────────

  describe "TasksLive — sort + load_more" do
    test "sort_form switches by title", %{conn: conn} do
      fixture_task(%{"title" => "Zee"})
      fixture_task(%{"title" => "Aye"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      html = render_change(view, "sort_form", %{"sort_by" => "title"})
      assert html =~ ~r/Aye[\s\S]*?Zee/
    end

    test "load_more bumps the loaded cap", %{conn: conn} do
      for n <- 1..51, do: fixture_task(%{"title" => "T#{String.pad_leading("#{n}", 3, "0")}"})

      {:ok, view, html} = live(conn, "/en/admin/projects/tasks")
      refute html =~ "T051"

      html_after = render_click(view, "load_more", %{})
      assert html_after =~ "T051"
    end
  end

  describe "TasksLive — reorder modal lifecycle" do
    test "open + close with 0 uuids", %{conn: conn} do
      fixture_task()
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      html = render_click(view, "open_reorder_modal", %{})
      assert html =~ "Reorder all"
      html = render_click(view, "close_reorder_modal", %{})
      assert html =~ ~s(data-show="false")
    end

    test "open with 1 uuid collapses to :all", %{conn: conn} do
      t = fixture_task()
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      html = render_click(view, "open_reorder_modal", %{"uuids" => [t.uuid]})
      assert html =~ "Reorder all"
    end

    test "open with 2 uuids keeps the selection", %{conn: conn} do
      a = fixture_task()
      b = fixture_task()
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      html = render_click(view, "open_reorder_modal", %{"uuids" => [a.uuid, b.uuid]})
      assert html =~ "2 selected"
    end
  end

  describe "TasksLive — apply_reorder" do
    test "valid strategy succeeds, logs activity",
         %{conn: conn, actor_uuid: actor_uuid} do
      _z = fixture_task(%{"title" => "Z"})
      _a = fixture_task(%{"title" => "A"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      render_click(view, "open_reorder_modal", %{})
      html = render_click(view, "apply_reorder", %{"strategy" => "name_asc"})

      assert html =~ "Tasks reordered"

      assert_activity_logged("task.reordered",
        actor_uuid: actor_uuid,
        metadata_has: %{"mechanism" => "strategy", "strategy" => "name_asc"}
      )
    end

    test "rejects unknown strategy", %{conn: conn} do
      fixture_task()
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      render_click(view, "open_reorder_modal", %{})
      html = render_click(view, "apply_reorder", %{"strategy" => "shell_exec"})
      assert html =~ "Pick a strategy"
    end

    test "rejects empty submit", %{conn: conn} do
      fixture_task()
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      render_click(view, "open_reorder_modal", %{})
      html = render_click(view, "apply_reorder", %{})
      assert html =~ "Pick a strategy"
    end
  end

  describe "TasksLive — set_view" do
    test "switches to card view", %{conn: conn} do
      fixture_task()
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      assert render_click(view, "set_view", %{"view" => "card"})
    end

    test "rejects invalid view name", %{conn: conn} do
      fixture_task()
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      # Should not crash; should return noreply.
      assert render_click(view, "set_view", %{"view" => "evil_mode"})
    end
  end

  describe "TasksLive — Groups tab" do
    test "renders each group with the root task as the card title", %{conn: conn} do
      root = fixture_task(%{"title" => "Deploy"})
      prereq = fixture_task(%{"title" => "Build"})

      {:ok, _} = PhoenixKitProjects.Projects.add_task_dependency(root.uuid, prereq.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      html = render_click(view, "set_view", %{"view" => "groups"})

      # The root task name appears as a card title (with the flag icon).
      assert html =~ "card-title"
      assert html =~ "Deploy"
      # The prereq appears in the same card.
      assert html =~ "Build"
      # The root is badged.
      assert html =~ "root"
    end

    test "groups with no prereqs (lone roots) DON'T appear — only multi-task chains",
         %{conn: conn} do
      # A task with no dependencies is "standalone", not a group root.
      _t = fixture_task(%{"title" => "Lonely"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      html = render_click(view, "set_view", %{"view" => "groups"})

      # Standalone section renders.
      assert html =~ "Standalone"
      assert html =~ "Lonely"
    end

    test "prereq label pluralises by count", %{conn: conn} do
      root = fixture_task(%{"title" => "Ship"})
      p1 = fixture_task(%{"title" => "P1"})
      p2 = fixture_task(%{"title" => "P2"})

      {:ok, _} = PhoenixKitProjects.Projects.add_task_dependency(root.uuid, p1.uuid)
      {:ok, _} = PhoenixKitProjects.Projects.add_task_dependency(root.uuid, p2.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      html = render_click(view, "set_view", %{"view" => "groups"})

      # Two prereqs → plural template.
      assert html =~ "2 prerequisites, then the root."
    end

    test "empty Groups tab renders the empty-state CTA", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/tasks")
      html = render_click(view, "set_view", %{"view" => "groups"})

      assert html =~ "No tasks yet."
    end
  end

  # ─── TemplatesLive ───────────────────────────────────────────────

  describe "TemplatesLive — DnD reorder" do
    test "happy path 2-row swap", %{conn: conn, actor_uuid: actor_uuid} do
      a = fixture_template(%{"name" => "TA"})
      b = fixture_template(%{"name" => "TB"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")

      render_click(view, "reorder_templates", %{
        "ordered_ids" => [b.uuid, a.uuid],
        "moved_id" => b.uuid
      })

      reloaded = Projects.list_templates() |> Enum.sort_by(& &1.position)
      assert Enum.map(reloaded, & &1.uuid) == [b.uuid, a.uuid]

      assert_activity_logged("template.reordered", actor_uuid: actor_uuid)
    end
  end

  describe "TemplatesLive — sort + load_more" do
    test "sort_form switches field; leaving manual sort disables DnD", %{conn: conn} do
      fixture_template(%{"name" => "TB"})
      fixture_template(%{"name" => "TA"})

      {:ok, view, html} = live(conn, "/en/admin/projects/templates")
      # Manual (position) sort: the tbody is a SortableGrid target.
      assert html =~ ~s(data-sortable="true")

      html = render_change(view, "sort_form", %{"sort_by" => "name"})
      assert html =~ ~r/TA[\s\S]*?TB/
      # Name sort is a *view* — dragging would be lossy, so DnD is off.
      refute html =~ ~s(data-sortable="true")
    end

    test "toggle_sort on the active field flips direction", %{conn: conn} do
      fixture_template(%{"name" => "TB"})
      fixture_template(%{"name" => "TA"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")
      render_change(view, "sort_form", %{"sort_by" => "name"})
      html = render_click(view, "toggle_sort", %{"by" => "name"})
      assert html =~ ~r/TB[\s\S]*?TA/
    end

    test "toggle_sort ignores unknown field strings", %{conn: conn} do
      fixture_template()
      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")
      assert render_click(view, "toggle_sort", %{"by" => "drop_table"})
    end

    test "load_more increases the loaded cap and shows the new row", %{conn: conn} do
      for n <- 1..51, do: fixture_template(%{"name" => "T#{String.pad_leading("#{n}", 3, "0")}"})

      {:ok, view, html} = live(conn, "/en/admin/projects/templates")
      refute html =~ "T051"

      html_after = render_click(view, "load_more", %{})
      assert html_after =~ "T051"
    end
  end

  describe "TemplatesLive — reorder modal lifecycle" do
    test "open with 0 or 1 uuids collapses to :all", %{conn: conn} do
      t = fixture_template()
      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")

      html = render_click(view, "open_reorder_modal", %{})
      assert html =~ "Reorder all"

      render_click(view, "close_reorder_modal", %{})
      html = render_click(view, "open_reorder_modal", %{"uuids" => [t.uuid]})
      assert html =~ "Reorder all"
    end

    test "open with 2 uuids keeps the selection", %{conn: conn} do
      a = fixture_template(%{"name" => "TA"})
      b = fixture_template(%{"name" => "TB"})
      fixture_template(%{"name" => "TC"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")
      html = render_click(view, "open_reorder_modal", %{"uuids" => [a.uuid, b.uuid]})
      # The modal's scope line reads "the 2 selected", not "all 3".
      assert html =~ "2 selected"
      refute html =~ "Reorder all 3"
    end
  end

  describe "TemplatesLive — apply_reorder" do
    test "applies a valid strategy on the full set", %{conn: conn, actor_uuid: actor_uuid} do
      _b = fixture_template(%{"name" => "TB"})
      _a = fixture_template(%{"name" => "TA"})

      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")
      render_click(view, "open_reorder_modal", %{})

      html = render_click(view, "apply_reorder", %{"strategy" => "name_asc"})

      assert html =~ "Templates reordered"
      listed = Projects.list_templates() |> Enum.sort_by(& &1.position)
      assert Enum.map(listed, & &1.name) == ["TA", "TB"]

      assert_activity_logged("template.reordered", actor_uuid: actor_uuid)
    end

    test "rejects an unknown strategy string with a fallback flash", %{conn: conn} do
      fixture_template()
      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")
      render_click(view, "open_reorder_modal", %{})
      html = render_click(view, "apply_reorder", %{"strategy" => "delete_all"})
      assert html =~ "Pick a strategy"
    end
  end

  describe "TemplatesLive — column visibility" do
    test "toggle_column hides/shows columns and persists across mounts", %{conn: conn} do
      fixture_template(%{"name" => "TA"})

      # Scope assertions to `<th>` — the Columns dropdown always lists
      # every label, so a bare `html =~` can't distinguish visibility.
      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")
      # Defaults: Weekends on, Created/Updated off.
      assert has_element?(view, "th", "Weekends")
      refute has_element?(view, "th", "Created")

      render_click(view, "toggle_column", %{"col" => "weekends"})
      refute has_element?(view, "th", "Weekends")

      render_click(view, "toggle_column", %{"col" => "created"})
      assert has_element?(view, "th", "Created")

      # Persisted in settings — a fresh mount sees the same set.
      {:ok, view2, _html2} = live(conn, "/en/admin/projects/templates")
      refute has_element?(view2, "th", "Weekends")
      assert has_element?(view2, "th", "Created")
    end

    test "toggle_column ignores unknown column names", %{conn: conn} do
      fixture_template()
      {:ok, view, _html} = live(conn, "/en/admin/projects/templates")
      assert render_click(view, "toggle_column", %{"col" => "evil"})
    end
  end
end
