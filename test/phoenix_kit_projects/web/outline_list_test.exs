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

      [board] = Regex.run(~r/id="board-column-waiting".*?id="board-column-todo"/s, html)
      assert board =~ "Card"
      refute board =~ "Inside"
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

      render_submit(element(view, "#assignment-subtask-form"), %{"title" => "Typed here"})
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

      view |> element("#assignment-delete") |> render_click()
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
