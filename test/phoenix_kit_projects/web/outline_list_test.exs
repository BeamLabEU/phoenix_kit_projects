defmodule PhoenixKitProjects.Web.OutlineListTest do
  @moduledoc """
  The project page's task list as an outline (`Web.OutlineList`): the text
  face for a plain to-do list (the `PkpOutline` hook and its server side),
  the cards with typed titles and nesting, the settings that choose
  between them, and the task form's "Sits under" and Subtasks box.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Features, Outline, Projects}
  alias PhoenixKitProjects.Web.OutlineList

  setup %{conn: conn} do
    # A real user: ticking stamps who did it, and that is a foreign key.
    conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
    {:ok, conn: conn}
  end

  defp project(name \\ "List") do
    fixture_project(%{"name" => "#{name} #{System.unique_integer([:positive])}"})
  end

  defp simple(name \\ "Simple") do
    {:ok, p} = Features.apply_preset(project(name), "simple")
    p
  end

  defp fixture_user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "outline-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp fixture_person do
    {:ok, person} =
      PhoenixKitStaff.Staff.create_person(%{
        "user_uuid" => fixture_user().uuid,
        "name" => "Someone Else",
        "employment_type" => "full_time"
      })

    person
  end

  defp titles(p), do: p.uuid |> Projects.list_assignments() |> Enum.map(& &1.task.title)

  describe "the text face" do
    test "a plain to-do list is one text field, with its tasks as lines", %{conn: conn} do
      p = simple()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "Milk"}, %{"text" => "Oat", "depth" => 1}], [])

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}")

      assert html =~ ~s(phx-hook="PkpOutline")
      assert html =~ ~s(data-can-edit="1")
      [json] = Regex.run(~r/data-lines="([^"]*)"/, html, capture: :all_but_first)
      lines = json |> String.replace("&quot;", "\"") |> Jason.decode!()
      assert Enum.map(lines, &{&1["text"], &1["depth"]}) == [{"Milk", 0}, {"Oat", 1}]
      # The filter and sort strip has nothing to act on.
      refute html =~ ~s(phx-change="list_sort")
    end

    test "the hook's lines are saved through the page, with a reply for the new ones",
         %{conn: conn} do
      p = simple()
      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_sync", %{
        "lines" => [
          %{"id" => nil, "tmp" => "a", "text" => "Call the bank", "depth" => 0},
          %{"id" => nil, "tmp" => "b", "text" => "Ask about fees", "depth" => 1}
        ],
        "known" => []
      })

      assert_reply(view, %{created: %{"a" => %{uuid: _, ref: ref}, "b" => _}})
      assert ref =~ "-"
      assert titles(p) == ["Call the bank", "Ask about fees"]
      assert_push_event(view, "pkp_outline:lines", %{lines: [_, %{depth: 1}]})
    end

    test "ticking a line is the Done button, and asks first for other people's subtasks",
         %{conn: conn} do
      p = simple()

      {:ok, _} =
        Outline.sync(p.uuid, [%{"text" => "Parent"}, %{"text" => "Theirs", "depth" => 1}], [])

      [parent, child] = Projects.list_assignments(p.uuid)
      person = fixture_person()
      {:ok, _} = Projects.update_assignment_form(child, %{"assigned_person_uuid" => person.uuid})

      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_tick", %{"id" => parent.uuid, "done" => true})
      assert_reply(view, %{asked: true})
      assert Projects.get_assignment(parent.uuid).status == "waiting"

      render_hook(view, "outline_tick", %{"id" => parent.uuid, "done" => true, "force" => true})
      assert_reply(view, %{asked: false})
      assert Projects.get_assignment(child.uuid).status == "done"
    end

    test "a removed line that carries work is held below the list, and comes back",
         %{conn: conn} do
      p = simple()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "Keep"}, %{"text" => "Worked on"}], [])
      [keep, worked] = Projects.list_assignments(p.uuid)
      {:ok, _} = Projects.update_assignment_form(worked, %{"description" => "notes"})

      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_sync", %{
        "lines" => [%{"id" => keep.uuid, "text" => "Keep", "depth" => 0}],
        "known" => [keep.uuid, worked.uuid]
      })

      assert_reply(view, %{note: note})
      assert note =~ "kept below"
      assert render(view) =~ "Removed from the list, still kept"

      view |> element("button[phx-click='outline_restore']") |> render_click()
      assert titles(p) == ["Keep", "Worked on"]
    end

    test "lines that are not objects do not take the page down, and the edit is on record",
         %{conn: conn} do
      p = simple()
      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_sync", %{"lines" => ["foo", 42], "known" => []})
      assert_reply(view, %{created: created})
      assert created == %{}
      assert render(view) =~ "PkpOutline"

      render_hook(view, "outline_sync", %{"lines" => [%{"text" => "Logged"}], "known" => []})
      assert_reply(view, %{created: _})

      assert_activity_logged("projects.task_list_edited",
        resource_uuid: p.uuid,
        metadata_has: %{"created" => 1}
      )
    end

    test "a list nobody may edit refuses the lines it is sent" do
      p = simple()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, project: p, outline_can: %{edit: false, delete: false}}
      }

      assert {:reply, %{error: _}, _} =
               OutlineList.handle_event(
                 "outline_sync",
                 %{"lines" => [%{"text" => "Sneaky"}], "known" => []},
                 socket,
                 & &1
               )

      assert titles(p) == []
    end
  end

  describe "the cards" do
    test "a richer project keeps cards, nested, with titles typed in place", %{conn: conn} do
      p = project()

      {:ok, _} =
        Outline.sync(p.uuid, [%{"text" => "Parent"}, %{"text" => "Child", "depth" => 1}], [])

      [parent, child] = Projects.list_assignments(p.uuid)

      {:ok, view, html} = live(conn, "/en/admin/projects/#{p.uuid}")
      refute html =~ ~s(phx-hook="PkpOutline")
      assert html =~ ~s(id="task-title-#{child.uuid}")
      # The parent says how far its subtasks are, and folds them away.
      assert html =~ "0/1"

      view
      |> element("button[phx-click='outline_fold'][phx-value-uuid='#{parent.uuid}']")
      |> render_click()

      refute render(view) =~ ~s(id="task-title-#{child.uuid}")
    end

    test "Enter adds the next task, Tab nests it, and a typed title is saved", %{conn: conn} do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "First"}], [])
      [first] = Projects.list_assignments(p.uuid)
      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_add", %{"after" => first.uuid, "text" => "Second"})
      [_, second] = Projects.list_assignments(p.uuid)
      assert second.task.title == "Second"

      render_hook(view, "outline_nest", %{"id" => second.uuid, "dir" => "in"})
      assert Projects.get_assignment(second.uuid).parent_uuid == first.uuid

      render_hook(view, "outline_rename", %{"id" => first.uuid, "text" => "First, renamed"})
      assert titles(p) == ["First, renamed", "Second"]

      render_hook(view, "outline_paste", %{
        "after" => first.uuid,
        "lines" => [
          %{"text" => "Pasted one", "depth" => 0},
          %{"text" => "Pasted two", "depth" => 1}
        ]
      })

      assert titles(p) == ["First, renamed", "Second", "Pasted one", "Pasted two"]
    end

    test "the board shows top-level tasks with their subtask counts", %{conn: conn} do
      p = project()

      {:ok, _} =
        Outline.sync(p.uuid, [%{"text" => "Card"}, %{"text" => "Inside", "depth" => 1}], [])

      {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}")

      [board] =
        Regex.run(~r/id="board-column-waiting-[^"]*".*?id="board-column-todo-[^"]*"/s, html)

      assert board =~ "Card"
      refute board =~ "Inside"
    end
  end

  # The page's socket, as the handlers left it.
  defp page_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "the draft row (Enter on a card)" do
    test "Enter opens a draft that writes nothing until a title is typed", %{conn: conn} do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "First"}, %{"text" => "Last"}], [])
      [first, _last] = Projects.list_assignments(p.uuid)
      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_add", %{"after" => first.uuid, "text" => ""})
      assert titles(p) == ["First", "Last"]
      draft = page_assigns(view).outline_draft
      assert %{slot: slot, depth: 0, key: key} = draft
      assert slot == first.uuid

      # Enter with a title: written right below its row, and the next draft opens.
      render_hook(view, "outline_draft_save", %{"key" => key, "text" => "Second", "next" => true})
      assert titles(p) == ["First", "Second", "Last"]
      next = page_assigns(view).outline_draft
      assert next.key != key

      # The same event again (a blur as the row went) writes nothing more.
      render_hook(view, "outline_draft_save", %{"key" => key, "text" => "Second", "next" => true})
      assert titles(p) == ["First", "Second", "Last"]

      # The last Enter of a run, on the empty draft: nothing is left behind.
      render_hook(view, "outline_draft_save", %{"key" => next.key, "text" => "  ", "next" => true})

      assert titles(p) == ["First", "Second", "Last"]
      assert page_assigns(view).outline_draft == nil
    end

    test "Esc or clicking away drops the draft; text after the cursor is a task at once",
         %{conn: conn} do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "Only"}], [])
      [only] = Projects.list_assignments(p.uuid)
      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_add", %{"after" => only.uuid, "text" => ""})
      key = page_assigns(view).outline_draft.key
      render_hook(view, "outline_draft_cancel", %{"key" => key, "refocus" => true})
      assert page_assigns(view).outline_draft == nil
      assert page_assigns(view).outline_focus == only.uuid
      assert titles(p) == ["Only"]

      # Splitting a title: what was after the cursor is typed already.
      render_hook(view, "outline_add", %{"after" => only.uuid, "text" => "Tail"})
      assert titles(p) == ["Only", "Tail"]
      assert page_assigns(view).outline_draft == nil
    end

    test "Tab nests the draft under the row above, and it is written there", %{conn: conn} do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "Parent"}], [])
      [parent] = Projects.list_assignments(p.uuid)
      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_add", %{"after" => parent.uuid, "text" => ""})
      key = page_assigns(view).outline_draft.key
      render_hook(view, "outline_draft_nest", %{"key" => key, "dir" => "in", "text" => "Chi"})
      draft = page_assigns(view).outline_draft
      assert %{parent: parent_uuid, depth: 1, text: "Chi"} = draft
      assert parent_uuid == parent.uuid

      render_hook(view, "outline_draft_save", %{"key" => draft.key, "text" => "Child"})
      [_, child] = Projects.list_assignments(p.uuid)
      assert child.task.title == "Child"
      assert child.parent_uuid == parent.uuid

      # Out again, before anything is typed.
      render_hook(view, "outline_add", %{"after" => child.uuid, "text" => ""})
      draft = page_assigns(view).outline_draft
      assert draft.depth == 1
      render_hook(view, "outline_draft_nest", %{"key" => draft.key, "dir" => "out", "text" => ""})
      assert %{parent: nil, depth: 0} = page_assigns(view).outline_draft
    end

    test "Add a task opens a draft at the foot, and a pasted list lands there",
         %{conn: conn} do
      p = project()

      {:ok, _} =
        Outline.sync(p.uuid, [%{"text" => "One"}, %{"text" => "Under", "depth" => 1}], [])

      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_add_first", %{})
      assert %{slot: :end, key: key} = page_assigns(view).outline_draft
      assert titles(p) == ["One", "Under"]

      render_hook(view, "outline_draft_paste", %{
        "key" => key,
        "text" => "Two",
        "lines" => [%{"text" => "Three", "depth" => 0}, %{"text" => "Four", "depth" => 1}]
      })

      assert titles(p) == ["One", "Under", "Two", "Three", "Four"]
      assert page_assigns(view).outline_draft == nil
      [_, _, two, three, four] = Projects.list_assignments(p.uuid)
      assert two.parent_uuid == nil
      assert four.parent_uuid == three.uuid
    end

    test "a task this list made and left empty is removed; any other is not", %{conn: conn} do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "Old"}], [])
      [old] = Projects.list_assignments(p.uuid)
      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

      render_hook(view, "outline_add", %{"after" => old.uuid, "text" => ""})
      key = page_assigns(view).outline_draft.key
      render_hook(view, "outline_draft_save", %{"key" => key, "text" => "Made here"})
      [_, made] = Projects.list_assignments(p.uuid)

      render_hook(view, "outline_drop", %{"id" => old.uuid})
      render_hook(view, "outline_drop", %{"id" => made.uuid})
      assert titles(p) == ["Old"]
    end

    # The drop is the client's word: a row this list made that was filled
    # in since (its popup, another tab, the API) is kept.
    for {what, fill} <- [
          description: :description,
          subtask: :subtask,
          time: :time,
          file: :file
        ] do
      test "a task this list made but given a #{what} since is not removed", %{conn: conn} do
        p = project()
        {:ok, _} = Outline.sync(p.uuid, [%{"text" => "Old"}], [])
        [old] = Projects.list_assignments(p.uuid)
        {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")

        render_hook(view, "outline_add", %{"after" => old.uuid, "text" => ""})
        key = page_assigns(view).outline_draft.key
        render_hook(view, "outline_draft_save", %{"key" => key, "text" => "Made here"})
        [_, made] = Projects.list_assignments(p.uuid)

        case unquote(fill) do
          :description ->
            {:ok, _} = Projects.update_assignment_form(made, %{"description" => "Notes"})

          :subtask ->
            {:ok, %{assignment: sub}} =
              Projects.create_task_with_assignment(
                p.uuid,
                %{"title" => "Sub", "ad_hoc" => true},
                %{}
              )

            {:ok, _} = Outline.move(Projects.get_assignment(sub.uuid), made.uuid, :last)

          :time ->
            {:ok, _} =
              PhoenixKitProjects.Ledger.log_time(p.uuid, 30,
                assignment_uuid: made.uuid,
                actor_uuid: embed_user_uuid!()
              )

          :file ->
            path = Path.join(System.tmp_dir!(), "pkp-drop-#{System.unique_integer([:positive])}")
            File.write!(path, "notes #{System.unique_integer()}")

            {:ok, _} =
              PhoenixKitProjects.Attachments.store_task_file(
                made,
                path,
                [filename: "n.txt", content_type: "text/plain", size_bytes: 5],
                embed_user_uuid!()
              )

            File.rm(path)
        end

        render_hook(view, "outline_drop", %{"id" => made.uuid})
        assert made.uuid in Enum.map(Projects.list_assignments(p.uuid), & &1.uuid)
      end
    end

    test "a suggestion's hint is the description's words, not its markdown", %{conn: conn} do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "First"}], [])
      [first] = Projects.list_assignments(p.uuid)
      tag = "Vh#{System.unique_integer([:positive])}"

      fixture_task(%{
        "title" => "#{tag} hang the doors",
        "description" =>
          "**Check** the [hinges](https://example.com/h) with @[user:01a1|Ann]\n" <>
            "![photo](https://example.com/p.png)\n- then `level` them"
      })

      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")
      render_hook(view, "outline_add", %{"after" => first.uuid, "text" => ""})
      key = page_assigns(view).outline_draft.key
      # No dashed number circle in front of the draft any more.
      refute render(view) =~ "rounded-full border-2 border-dashed"

      {:reply, %{items: [%{hint: hint}]}, _} =
        OutlineList.handle_event(
          "outline_draft_suggest",
          %{"key" => key, "q" => tag},
          :sys.get_state(view.pid).socket,
          & &1
        )

      assert hint == "Check the hinges with @Ann then level them"
    end

    test "the library's tasks are offered as a title is typed, and one is taken",
         %{conn: conn} do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "First"}, %{"text" => "Last"}], [])
      [first, _] = Projects.list_assignments(p.uuid)
      tag = "Vq#{System.unique_integer([:positive])}"

      library =
        fixture_task(%{
          "title" => "#{tag} fit the worktop",
          "description" => "Bring the clamps",
          "estimated_duration" => 3,
          "estimated_duration_unit" => "hours"
        })

      # Someone else's one-off of the same words is never offered.
      fixture_task(%{"title" => "#{tag} elsewhere", "ad_hoc" => true})

      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}")
      render_hook(view, "outline_add", %{"after" => first.uuid, "text" => ""})
      key = page_assigns(view).outline_draft.key

      reply =
        view
        |> render_hook("outline_draft_suggest", %{"key" => key, "q" => tag})

      assert is_binary(reply)

      # The reply carries the items (read straight from the handler).
      socket = :sys.get_state(view.pid).socket

      {:reply, %{items: items}, _} =
        OutlineList.handle_event(
          "outline_draft_suggest",
          %{"key" => key, "q" => tag},
          socket,
          & &1
        )

      assert [%{uuid: uuid, title: title, hint: "Bring the clamps"}] = items
      assert uuid == library.uuid
      assert title =~ "fit the worktop"

      render_hook(view, "outline_draft_pick", %{
        "key" => key,
        "task" => library.uuid,
        "next" => true
      })

      [_, picked, _] = Projects.list_assignments(p.uuid)
      assert picked.task_uuid == library.uuid
      assert picked.description == "Bring the clamps"
      assert picked.estimated_duration == 3
      # The next draft waits below it.
      assert page_assigns(view).outline_draft.slot == picked.uuid

      # A one-off or a stranger's uuid is not taken.
      key = page_assigns(view).outline_draft.key
      render_hook(view, "outline_draft_pick", %{"key" => key, "task" => "not-a-uuid"})
      assert length(Projects.list_assignments(p.uuid)) == 3
    end

    test "the draft row is drawn only at its own place" do
      draft = %{key: "d1", slot: "row-a", depth: 1, text: "Typed"}

      html =
        render_component(&OutlineList.draft_row/1, draft: draft, slot: "row-a", indent: true)

      assert html =~ ~s(phx-hook="PkpDraft")
      assert html =~ ~s(data-key="d1")
      assert html =~ ~s(value="Typed")
      assert html =~ "margin-left: 2rem"

      assert render_component(&OutlineList.draft_row/1, draft: draft, slot: "row-b") =~
               ~r/^\s*$/

      assert render_component(&OutlineList.draft_row/1, draft: nil, slot: :end) =~ ~r/^\s*$/
    end
  end

  describe "the settings" do
    test "a project picks its list style, and keeps a feature off its cards", %{conn: conn} do
      p = project()
      assert OutlineList.style(p, Features.gates(p), []) == :cards

      {:ok, view, _} = live(conn, "/en/admin/projects/#{p.uuid}/edit")

      view
      |> form("#project-form")
      |> render_submit(%{
        "outline" => %{
          "style" => "text",
          "complete_parent" => "false",
          "row" => %{"assignees" => "false", "priorities" => "true"}
        }
      })

      p = Projects.get_project(p.uuid)
      assert OutlineList.stored_style(p) == "text"
      refute Outline.parent_auto?(p)
      refute OutlineList.on_row?(p, "assignees")
      assert OutlineList.on_row?(p, "priorities")
      assert OutlineList.style(p, Features.gates(p), []) == :text
    end
  end

  describe "the task form" do
    test "it shows the subtasks, adds one by typing, and moves the task", %{conn: conn} do
      p = project()

      {:ok, _} =
        Outline.sync(
          p.uuid,
          [%{"text" => "Holder"}, %{"text" => "Sub", "depth" => 1}, %{"text" => "Other"}],
          []
        )

      [holder, sub, other] = Projects.list_assignments(p.uuid)

      {:ok, view, html} =
        live(conn, "/en/admin/projects/#{p.uuid}/assignments/#{holder.uuid}/edit")

      assert html =~ ~s(id="assignment-subtasks")
      assert html =~ "Sub"
      refute html =~ ~s(name="checklist_text")

      render_submit(element(view, "[id^='assignment-subtask-form-']"), %{"title" => "Typed here"})
      assert "Typed here" in titles(p)

      view
      |> element("input[phx-click='subtask_toggle'][phx-value-uuid='#{sub.uuid}']")
      |> render_click()

      assert Projects.get_assignment(sub.uuid).status == "done"

      view |> form("#assignment-form") |> render_change(%{"parent_task" => other.uuid})
      assert Projects.get_assignment(holder.uuid).parent_uuid == other.uuid
    end
  end

  describe "a plain to-do, as Max tried it" do
    test "its task form is a title, a status and a description — and has Delete", %{conn: conn} do
      p = simple()

      {:ok, _} =
        Outline.sync(p.uuid, [%{"text" => "Hello"}, %{"text" => "Under", "depth" => 1}], [])

      [hello, _under] = Projects.list_assignments(p.uuid)

      {:ok, view, html} =
        live(conn, "/en/admin/projects/#{p.uuid}/assignments/#{hello.uuid}/edit")

      refute html =~ ~s(name="assignment[waiting_on]")
      refute html =~ ~s(name="assignment[origin]")
      refute html =~ ~s(name="assignment[start_date]")
      assert html =~ ~s(name="assignment[description]")
      assert html =~ "Delete this task and its subtask?"

      # Delete asks first (the page's own dialog); the confirmation deletes.
      view |> element("#assignment-delete") |> render_click()
      assert titles(p) != []
      render_click(view, "confirm_action_ok", %{})
      assert titles(p) == []
    end

    test "a richer project's form keeps them", %{conn: conn} do
      p = project()
      {:ok, _} = Outline.sync(p.uuid, [%{"text" => "Full"}], [])
      [a] = Projects.list_assignments(p.uuid)
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}/assignments/#{a.uuid}/edit")
      # "Waiting on" left the form (the boss, 2026-10-29); the dates stay.
      refute html =~ ~s(name="assignment[waiting_on]")
      assert html =~ ~s(name="assignment[start_date]")
    end

    test "the text list's × is on and its drag handles off, unless the project says otherwise",
         %{conn: conn} do
      p = simple()
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}")
      assert html =~ ~s(data-delete="1")
      assert html =~ ~s(data-handles="0")

      settings =
        Map.put(p.settings || %{}, "outline", %{
          "lines" => %{"delete" => false, "handles" => true}
        })

      {:ok, _} = Projects.update_project(p, %{"settings" => settings})
      {:ok, _view, html} = live(conn, "/en/admin/projects/#{p.uuid}")
      assert html =~ ~s(data-delete="0")
      assert html =~ ~s(data-handles="1")
    end
  end
end
