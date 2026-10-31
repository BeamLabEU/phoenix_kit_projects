defmodule PhoenixKitProjects.Web.TabsNeverJumpTest do
  @moduledoc """
  Tabs never jump (item 29, the panel of 2026-10-31): under every tab strip
  ONE scroll area holding only the open tab, the strip outside it, and the
  `PkpTabScroll` hook to take the area to its top when the tab changes.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Web.Components.{FormParts, PopupHost}

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "a form's strip carries the hook and the open pane" do
    html =
      rendered_to_string(
        FormParts.form_tabs(%{
          id: "t",
          prefix: "x",
          panes: [{"a", "A"}, {"b", "B"}],
          active: "b",
          errors: MapSet.new(),
          event: "set_form_pane"
        })
      )

    assert html =~ ~s(phx-hook="PkpTabScroll")
    assert html =~ "data-pkp-tabs"
    assert html =~ ~s(data-active="b")
    assert html =~ ~s(aria-controls="x-pane-b")
  end

  test "a drawer frame is the column; a centred one is a fixed-height column" do
    frame = [%{frame_ref: "f1", lv: nil, session: %{}, id: "f1"}]

    drawer =
      rendered_to_string(
        PopupHost.popup_host(%{
          modal_stack: frame,
          placement: :end,
          max_width: "2xl",
          on_close: "close_top_modal",
          class: nil,
          modal_box_class: "w-11/12",
          inner_block: [%{inner_block: fn _, _ -> "root" end}],
          frame: [%{inner_block: fn _, _ -> "frame" end}]
        })
      )

    assert drawer =~ "pkp-frame"
    refute drawer =~ "relative pkp-frame pkp-center"
    assert drawer =~ ~s|.pkp-frame *:has(> [data-pkp-tabs]) > [role="tabpanel"]:not(.hidden)|

    centred =
      rendered_to_string(
        PopupHost.popup_host(%{
          modal_stack: frame,
          placement: :center,
          max_width: "6xl",
          on_close: "close_top_modal",
          class: nil,
          modal_box_class: "w-11/12",
          inner_block: [%{inner_block: fn _, _ -> "root" end}],
          frame: [%{inner_block: fn _, _ -> "frame" end}]
        })
      )

    # A centred popup with tabs keeps one height whatever the open tab
    # holds (the boss, 2026-10-31: the tabs jumped).
    assert centred =~ "relative pkp-frame pkp-center"
    assert centred =~ ".pkp-frame.pkp-center:has([data-pkp-tabs])"
  end

  test "the project page's views are one scroll area that follows the view", %{conn: conn} do
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, view, _html} = live(conn, "/en/admin/projects/#{project.uuid}")

    area = "#project-views-#{project.uuid}"

    assert has_element?(
             view,
             ~s(#{area}[phx-hook="PkpTabScroll"][data-pkp-fill][data-active="list"])
           )

    assert has_element?(view, "#{area} #project-list-tab-#{project.uuid}")
    # The strip is outside what scrolls.
    refute has_element?(view, "#{area} #project-task-views-#{project.uuid}")

    render_click(view, "switch_tab", %{"tab" => "board"})
    assert has_element?(view, ~s(#{area}[data-active="board"]))
  end
end
