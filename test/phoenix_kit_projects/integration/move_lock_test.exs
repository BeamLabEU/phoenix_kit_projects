defmodule PhoenixKitProjects.Integration.MoveLockTest do
  @moduledoc """
  The host's move lock (`config :phoenix_kit_projects, move_lock: {Mod, :fun}`):
  the hook contract, `ProjectMove.run/4`, the Move… dialog, the menu entries
  and the «Project to nest» picker.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{MoveLock, ProjectMove, Projects}

  defmodule Hook do
    @moduledoc false
    # Locks whatever uuids the test put in app env; reports each call to the
    # test process, so batching is observable across LiveView processes.
    def reasons(projects) do
      if pid = Application.get_env(:phoenix_kit_projects, :test_lock_pid),
        do: send(pid, {:hook_called, Enum.map(projects, & &1.uuid)})

      case Application.get_env(:phoenix_kit_projects, :test_lock_mode, :normal) do
        :raise ->
          raise "host hook exploded"

        :garbage ->
          :nope

        :normal ->
          locked = Application.get_env(:phoenix_kit_projects, :test_locked, %{})

          for p <- projects, Map.has_key?(locked, p.uuid), into: %{} do
            {p.uuid, Map.fetch!(locked, p.uuid)}
          end
      end
    end
  end

  setup %{conn: conn} do
    Application.put_env(:phoenix_kit_projects, :move_lock, {Hook, :reasons})
    Application.put_env(:phoenix_kit_projects, :test_lock_pid, self())

    on_exit(fn ->
      for k <- [:move_lock, :test_lock_pid, :test_locked, :test_lock_mode],
          do: Application.delete_env(:phoenix_kit_projects, k)
    end)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "lock-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    admin = fake_scope(user_uuid: user.uuid)
    {:ok, conn: put_test_scope(conn, admin), scope: admin}
  end

  defp lock!(map), do: Application.put_env(:phoenix_kit_projects, :test_locked, map)

  defp project!(name),
    do: fixture_project(%{"name" => "#{name} #{System.unique_integer([:positive])}"})

  defp child!(parent, name) do
    {:ok, %{child_project: child}} = Projects.create_subproject(parent.uuid, %{"name" => name})
    child
  end

  defp drain do
    receive do
      {:hook_called, _} -> drain()
    after
      0 -> :ok
    end
  end

  describe "MoveLock.reasons/1" do
    test "no hook configured: nothing is locked and nothing is called" do
      Application.delete_env(:phoenix_kit_projects, :move_lock)
      p = project!("Free")

      assert MoveLock.reasons([p]) == %{}
      refute_received {:hook_called, _}
    end

    test "the hook gets the whole list in one call; only reasons for those projects come back" do
      a = project!("A")
      b = project!("B")
      lock!(%{a.uuid => "Order project", Ecto.UUID.generate() => "stranger"})

      assert MoveLock.reasons([a, b]) == %{a.uuid => "Order project"}
      assert_received {:hook_called, uuids}
      assert uuids == [a.uuid, b.uuid]
      refute_received {:hook_called, _}
    end

    test "an empty list does not call the hook" do
      assert MoveLock.reasons([]) == %{}
      refute_received {:hook_called, _}
    end

    test "a raising hook fails open and warns" do
      Application.put_env(:phoenix_kit_projects, :test_lock_mode, :raise)
      p = project!("Boom")

      log = capture_log(fn -> assert MoveLock.reasons([p]) == %{} end)
      assert log =~ "move_lock"
      assert log =~ "host hook exploded"
    end

    test "a hook that returns something else is unlocked, with a warning" do
      Application.put_env(:phoenix_kit_projects, :test_lock_mode, :garbage)
      p = project!("Garbage")

      log = capture_log(fn -> assert MoveLock.reasons([p]) == %{} end)
      assert log =~ "move_lock"
    end

    test "reason/1 is the single-project form" do
      p = project!("One")
      lock!(%{p.uuid => "Why"})
      assert MoveLock.reason(p) == "Why"
      assert MoveLock.reason(project!("Other")) == nil
    end
  end

  describe "ProjectMove.run/4" do
    test "refuses a locked project and moves nothing", ctx do
      parent = project!("Parent")
      child = child!(parent, "Locked kid")
      lock!(%{child.uuid => "An order's project cannot be moved"})

      assert {:error, {:locked, "An order's project cannot be moved"}} =
               ProjectMove.run(child, :top, ctx.scope)

      assert Projects.subproject_link(child.uuid)
    end

    test "an unlocked project moves as before", ctx do
      parent = project!("Parent")
      child = child!(parent, "Free kid")
      lock!(%{Ecto.UUID.generate() => "someone else"})

      assert {:ok, %{to: nil}} = ProjectMove.run(child, :top, ctx.scope)
      assert Projects.subproject_link(child.uuid) == nil
    end

    test "a raising hook does not block the move", ctx do
      parent = project!("Parent")
      child = child!(parent, "Kid")
      Application.put_env(:phoenix_kit_projects, :test_lock_mode, :raise)

      capture_log(fn -> assert {:ok, _} = ProjectMove.run(child, :top, ctx.scope) end)
    end

    test "the context functions stay policy-free" do
      parent = project!("Parent")
      child = child!(parent, "Kid")
      lock!(%{child.uuid => "locked"})

      assert {:ok, _} = Projects.move_project(child.uuid, :top)
    end
  end

  describe "the projects list" do
    test "a locked project's Move… is a disabled item with the reason; others stay live", ctx do
      locked = project!("Locked Alpha")
      free = project!("Free Beta")
      lock!(%{locked.uuid => "An order's project cannot be moved"})

      {:ok, view, html} = live(ctx.conn, "/en/admin/projects")

      assert html =~ locked.name
      assert html =~ ~s(aria-disabled="true")

      assert html =~ "An order&#39;s project cannot be moved" or
               html =~ "An order's project cannot be moved"

      assert html =~ "cursor-not-allowed"

      assert has_element?(
               view,
               ~s(button[phx-click="move_project_open"][phx-value-uuid="#{free.uuid}"])
             )

      refute has_element?(
               view,
               ~s(button[phx-click="move_project_open"][phx-value-uuid="#{locked.uuid}"])
             )
    end

    test "the hook is asked for the listed projects together, not once per row", ctx do
      for n <- 1..3, do: project!("Batch #{n}")
      drain()

      {:ok, _view, _html} = live(ctx.conn, "/en/admin/projects")

      calls = collect_calls()
      assert calls != []
      assert Enum.all?(calls, &(length(&1) >= 3))
    end

    test "a crafted open on a locked project opens no dialog", ctx do
      locked = project!("Locked Crafted")
      lock!(%{locked.uuid => "No moving"})

      {:ok, view, _html} = live(ctx.conn, "/en/admin/projects")
      html = render_click(view, "move_project_open", %{"uuid" => locked.uuid})

      refute html =~ "Put it under another project"
      refute has_element?(view, "#move-project-form-#{locked.uuid}")
    end

    test "a submit after the project got locked moves nothing", ctx do
      a = project!("Alpha")
      b = project!("Beta")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/projects")
      render_click(view, "move_project_open", %{"uuid" => a.uuid})
      assert has_element?(view, "#move-project-form-#{a.uuid}")

      view |> form("#move-project-form-#{a.uuid}", %{"place" => "under"}) |> render_change()
      lock!(%{a.uuid => "Now locked"})

      view
      |> form("#move-project-form-#{a.uuid}", %{"place" => "under", "parent" => b.uuid})
      |> render_submit()

      assert Projects.parent_chain(a.uuid) == []
    end

    test "unlocked everything: no disabled items", ctx do
      project!("Plain")
      {:ok, _view, html} = live(ctx.conn, "/en/admin/projects")
      refute html =~ "aria-disabled"
    end
  end

  describe "the project page" do
    test "the header Move… of a locked project is disabled", ctx do
      p = project!("Page Locked")
      lock!(%{p.uuid => "Page reason"})

      {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{p.uuid}")

      assert html =~ "Page reason"
      assert html =~ ~s(aria-disabled="true")
      refute has_element?(view, ~s(button[phx-click="move_project_open"]))
    end

    test "a locked sub-project's Move out… is disabled, an unlocked one's is live", ctx do
      parent = project!("Parent")
      locked = child!(parent, "Locked Child")
      free = child!(parent, "Free Child")
      lock!(%{locked.uuid => "Child reason"})

      {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{parent.uuid}")

      assert html =~ "Child reason"

      refute has_element?(
               view,
               ~s(button[phx-click="move_project_open"][phx-value-uuid="#{locked.uuid}"])
             )

      assert has_element?(
               view,
               ~s(button[phx-click="move_project_open"][phx-value-uuid="#{free.uuid}"])
             )
    end

    test "unlocked: Move… is the plain button", ctx do
      p = project!("Plain page")
      {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{p.uuid}")
      refute html =~ "aria-disabled"

      assert has_element?(
               view,
               ~s(button[phx-click="move_project_open"][phx-value-uuid="#{p.uuid}"])
             )
    end
  end

  describe "the «Project to nest» picker" do
    test "leaves locked projects out, and a crafted save does not nest one", ctx do
      parent = project!("Nest Parent")
      locked = project!("Nest Locked")
      free = project!("Nest Free")
      lock!(%{locked.uuid => "No nesting"})

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/projects/#{parent.uuid}/assignments/new?kind=subproject")

      html = render_click(view, "set_sp_mode", %{"tab" => "existing"})
      refute html =~ locked.name
      assert html =~ free.name

      render_submit(view, "save_subproject", %{"link_child_uuid" => locked.uuid})

      refute Enum.any?(
               Projects.list_assignments(parent.uuid),
               &(&1.child_project_uuid == locked.uuid)
             )
    end

    test "without a lock the project is offered", ctx do
      parent = project!("Nest Parent")
      other = project!("Nest Other")

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/projects/#{parent.uuid}/assignments/new?kind=subproject")

      assert render_click(view, "set_sp_mode", %{"tab" => "existing"}) =~ other.name
    end
  end

  describe "hook contract details" do
    test "a malformed config value locks nothing and warns once" do
      :persistent_term.erase({MoveLock, :malformed})
      Application.put_env(:phoenix_kit_projects, :move_lock, SomeBareModule)
      p = project!("Typo")

      log =
        capture_log(fn ->
          assert MoveLock.reasons([p]) == %{}
          assert MoveLock.reasons([p]) == %{}
        end)

      assert length(String.split(log, "ignoring move_lock config")) == 2
    end

    test "an empty reason does not lock" do
      p = project!("Empty")
      lock!(%{p.uuid => ""})
      assert MoveLock.reasons([p]) == %{}
    end

    test "an unauthorised caller gets :forbidden, not the reason" do
      parent = project!("Parent")
      child = child!(parent, "Kid")
      lock!(%{child.uuid => "secret reason"})
      nobody = fake_scope(user_uuid: Ecto.UUID.generate(), permissions: ["projects"])

      assert {:error, :forbidden} = ProjectMove.run(child, :top, nobody)
    end
  end

  describe "detach_subproject" do
    test "a crafted event on a locked sub-project detaches nothing", ctx do
      parent = project!("Parent")
      locked = child!(parent, "Locked kid")
      free = child!(parent, "Free kid")
      lock!(%{locked.uuid => "Kept here"})

      {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{parent.uuid}")

      link = Projects.subproject_link(locked.uuid)
      html = render_click(view, "detach_subproject", %{"uuid" => link.uuid})
      assert html =~ "Kept here"
      assert Projects.subproject_link(locked.uuid)

      free_link = Projects.subproject_link(free.uuid)
      render_click(view, "detach_subproject", %{"uuid" => free_link.uuid})
      assert Projects.subproject_link(free.uuid) == nil
    end
  end

  defp collect_calls(acc \\ []) do
    receive do
      {:hook_called, uuids} -> collect_calls([uuids | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
