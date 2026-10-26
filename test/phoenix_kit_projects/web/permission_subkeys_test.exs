defmodule PhoenixKitProjects.Web.PermissionSubkeysTest do
  @moduledoc """
  The two narrowing sub-keys and the comment moderation scope:

    * `projects.manage_library` — the shared task library's writes (the
      library page, the task form, renaming a library task from inside a
      project, feeding the library from the assignment form). The One-off
      lens lists only one-off tasks of projects the viewer can open.
    * `projects.settings` — the module's settings page and every event on it.
    * Both backfilled once to every role holding `projects`.
    * `moderatable_resources/2` — owners and managers moderate their
      projects' discussions, `admin_all` everything, in a bounded number of
      reads.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, RolePermission, Roles}

  alias PhoenixKitProjects.{
    Authz,
    CommentModeration,
    Grants,
    Members,
    Outline,
    Projects,
    QueryCounter
  }

  alias PhoenixKitProjects.Test.Repo

  defp n, do: System.unique_integer([:positive])

  # Module access only — the shape of a role granted `projects` after the
  # split: no library writes, no settings, no admin_all.
  defp base_scope(opts \\ []), do: fake_scope(Keyword.put(opts, :permissions, ["projects"]))

  # Swap the mounted page's scope — what core's live scope refresh does
  # when a role loses a grant while the page is open.
  defp swap_scope(view, scope) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: Phoenix.Component.assign(socket, :phoenix_kit_current_scope, scope)}
    end)
  end

  describe "the task library page without projects.manage_library" do
    test "is read-only: no create button, no row menu", %{conn: conn} do
      fixture_task(%{"title" => "Shared step #{n()}"})
      {:ok, _view, html} = live(put_test_scope(conn, base_scope()), "/en/admin/projects/tasks")

      refute html =~ ~s(href="/en/admin/projects/tasks/new")
      refute html =~ "task-menu-"
    end

    test "crafted delete, promote and reorder events change nothing", %{conn: conn} do
      lib = fixture_task(%{"title" => "Keep me #{n()}"})
      other = fixture_task(%{"title" => "Other #{n()}"})
      p = fixture_project()
      {:ok, %{task: adhoc}} = Projects.quick_add_assignment(p.uuid, "One-off #{n()}")

      {:ok, view, _html} = live(put_test_scope(conn, base_scope()), "/en/admin/projects/tasks")

      html = render_click(view, "delete", %{"uuid" => lib.uuid})
      assert html =~ "permission to change the task library"
      assert Projects.get_task(lib.uuid)

      render_click(view, "promote_task", %{"uuid" => adhoc.uuid})
      assert Projects.get_task(adhoc.uuid).ad_hoc == true

      before = Enum.map(Projects.list_tasks(), &{&1.uuid, &1.position})
      render_hook(view, "reorder_tasks", %{"ordered_ids" => [other.uuid, lib.uuid]})
      render_click(view, "apply_reorder", %{"strategy" => "reverse"})
      assert Enum.map(Projects.list_tasks(), &{&1.uuid, &1.position}) == before
    end

    test "a holder whose grant is revoked mid-session is refused at the next write",
         %{conn: conn} do
      lib = fixture_task(%{"title" => "Revoked #{n()}"})
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), "/en/admin/projects/tasks")
      swap_scope(view, base_scope())

      render_click(view, "delete", %{"uuid" => lib.uuid})
      assert Projects.get_task(lib.uuid)
    end

    test "the holder deletes", %{conn: conn} do
      lib = fixture_task(%{"title" => "Delete me #{n()}"})
      {:ok, view, html} = live(put_test_scope(conn, fake_scope()), "/en/admin/projects/tasks")

      # The controls the read-only test refutes are there for a holder.
      assert html =~ ~s(href="/en/admin/projects/tasks/new")
      assert html =~ "task-menu-"

      html = render_click(view, "delete", %{"uuid" => lib.uuid})
      assert html =~ "Task deleted."
      refute Projects.get_task(lib.uuid)
    end
  end

  describe "the task form" do
    test "the base key alone is refused at mount, for new and edit", %{conn: conn} do
      lib = fixture_task()
      conn = put_test_scope(conn, base_scope())

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, "/en/admin/projects/tasks/new")

      assert flash["error"] =~ "permission"

      assert {:error, {:live_redirect, _}} =
               live(conn, "/en/admin/projects/tasks/#{lib.uuid}/edit")
    end

    test "save and the dependency events re-check the sub-key", %{conn: conn} do
      lib = fixture_task(%{"title" => "Original #{n()}"})
      dep = fixture_task()

      {:ok, view, _html} =
        live(put_test_scope(conn, fake_scope()), "/en/admin/projects/tasks/#{lib.uuid}/edit")

      swap_scope(view, base_scope())

      html = render_submit(view, "save", %{"task" => %{"title" => "Renamed"}})
      assert html =~ "permission to change the task library"
      assert Projects.get_task(lib.uuid).title == lib.title

      render_click(view, "add_dep", %{"depends_on_task_uuid" => dep.uuid})
      assert Projects.list_task_dependencies(lib.uuid) == []
    end
  end

  describe "renaming a library task from inside a project" do
    test "the typed list renames a one-off, never a library task unless told it may" do
      p = fixture_project()
      lib = fixture_task(%{"title" => "Library title #{n()}"})
      {:ok, a} = Projects.create_assignment(%{"project_uuid" => p.uuid, "task_uuid" => lib.uuid})
      {:ok, %{assignment: one, task: adhoc}} = Projects.quick_add_assignment(p.uuid, "Mine")

      lines = [
        %{"id" => a.uuid, "text" => "Hijacked", "depth" => 0},
        %{"id" => one.uuid, "text" => "Mine, renamed", "depth" => 0}
      ]

      assert {:ok, _} = Outline.sync(p.uuid, lines, [])
      assert Projects.get_task(lib.uuid).title == lib.title
      assert Projects.get_task(adhoc.uuid).title == "Mine, renamed"

      assert {:ok, _} = Outline.sync(p.uuid, lines, [], rename_library: true)
      assert Projects.get_task(lib.uuid).title == "Hijacked"
    end
  end

  describe "the One-off lens" do
    test "lists only one-off tasks of projects the viewer can open", %{conn: conn} do
      user_uuid = embed_user_uuid!()
      mine = fixture_project()
      theirs = fixture_project()
      {:ok, _} = Members.add_member(mine, user_uuid, role: "member")
      {:ok, _} = Projects.quick_add_assignment(mine.uuid, "Visible one-off #{n()}")
      {:ok, %{task: secret}} = Projects.quick_add_assignment(theirs.uuid, "Secret one-off")

      conn = put_test_scope(conn, base_scope(user_uuid: user_uuid))
      {:ok, _view, html} = live(conn, "/en/admin/projects/tasks?lens=one_off")

      assert html =~ "Visible one-off"
      refute html =~ "Secret one-off"
      refute html =~ secret.uuid

      # An administrator of every project sees both.
      {:ok, _view, html} =
        live(put_test_scope(build_conn(), fake_scope()), "/en/admin/projects/tasks?lens=one_off")

      assert html =~ "Secret one-off"
    end

    test "list_tasks/count_tasks honour :project_uuids" do
      p = fixture_project()
      {:ok, %{task: t}} = Projects.quick_add_assignment(p.uuid, "Scoped #{n()}")

      assert t.uuid in Enum.map(
               Projects.list_tasks(ad_hoc: :only, project_uuids: [p.uuid]),
               & &1.uuid
             )

      assert Projects.list_tasks(ad_hoc: :only, project_uuids: []) == []
      assert Projects.count_tasks(ad_hoc: :only, project_uuids: []) == 0
    end
  end

  describe "the settings page" do
    @path "/en/admin/settings/projects"

    test "the base key alone is refused at mount", %{conn: conn} do
      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(put_test_scope(conn, base_scope()), @path)

      assert flash["error"] =~ "permission"
    end

    test "a holder opens it; a revoked one cannot write", %{conn: conn} do
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), @path)
      before = PhoenixKitProjects.Statuses.global_use_status_translations?()

      swap_scope(view, base_scope())
      html = render_click(view, "toggle_status_translations", %{})

      assert html =~ "permission to change the projects settings"
      assert PhoenixKitProjects.Statuses.global_use_status_translations?() == before
    end

    test "the settings tab carries the sub-key" do
      [tab] = PhoenixKitProjects.settings_tabs()
      assert tab.permission == "projects.settings"
    end
  end

  describe "one-off tasks of a project the library manager cannot open" do
    # A library manager who administers no project and is not on this one.
    defp librarian(user_uuid),
      do: fake_scope(user_uuid: user_uuid, permissions: ["projects", "projects.manage_library"])

    test "a crafted delete or promote of one is refused", %{conn: conn} do
      private = fixture_project()
      {:ok, %{task: adhoc}} = Projects.quick_add_assignment(private.uuid, "Private one-off")

      {:ok, view, _html} =
        live(put_test_scope(conn, librarian(embed_user_uuid!())), "/en/admin/projects/tasks")

      render_click(view, "delete", %{"uuid" => adhoc.uuid})
      assert Projects.get_task(adhoc.uuid)

      render_click(view, "promote_task", %{"uuid" => adhoc.uuid})
      assert Projects.get_task(adhoc.uuid).ad_hoc == true
    end

    test "the task form refuses to open or save it, so it cannot be promoted there",
         %{conn: conn} do
      private = fixture_project()
      {:ok, %{task: adhoc}} = Projects.quick_add_assignment(private.uuid, "Private one-off")
      librarian = librarian(embed_user_uuid!())

      assert {:error, {:live_redirect, _}} =
               live(
                 put_test_scope(conn, librarian),
                 "/en/admin/projects/tasks/#{adhoc.uuid}/edit"
               )

      # Opened by someone who may (an administrator), then the scope narrows.
      {:ok, view, _html} =
        live(put_test_scope(conn, fake_scope()), "/en/admin/projects/tasks/#{adhoc.uuid}/edit")

      swap_scope(view, librarian)
      render_submit(view, "save", %{"task" => %{"title" => "Leaked", "ad_hoc" => "false"}})

      task = Projects.get_task(adhoc.uuid)
      assert task.ad_hoc == true
      assert task.title == "Private one-off"
    end

    test "the project's owner who manages the library may", %{conn: conn} do
      user_uuid = embed_user_uuid!()
      mine = fixture_project()
      {:ok, _} = Members.add_member(mine, user_uuid, role: "owner")
      {:ok, %{task: a}} = Projects.quick_add_assignment(mine.uuid, "Mine A")
      {:ok, %{task: b}} = Projects.quick_add_assignment(mine.uuid, "Mine B")

      {:ok, view, _html} =
        live(put_test_scope(conn, librarian(user_uuid)), "/en/admin/projects/tasks")

      render_click(view, "promote_task", %{"uuid" => a.uuid})
      assert Projects.get_task(a.uuid).ad_hoc == false

      render_click(view, "delete", %{"uuid" => b.uuid})
      refute Projects.get_task(b.uuid)
    end

    test "the lens is re-scoped on every load, so a lost membership hides new one-offs",
         %{conn: conn} do
      user_uuid = embed_user_uuid!()
      p = fixture_project()
      {:ok, _} = Members.add_member(p, user_uuid, role: "member")
      {:ok, _} = Projects.quick_add_assignment(p.uuid, "Before #{n()}")

      {:ok, view, html} =
        live(
          put_test_scope(conn, base_scope(user_uuid: user_uuid)),
          "/en/admin/projects/tasks?lens=one_off"
        )

      assert html =~ "Before"

      # Control: a reload while still a member shows a new one-off.
      {:ok, _} = Projects.quick_add_assignment(p.uuid, "While member")
      send(view.pid, {:projects, :task_created, %{}})
      assert render(view) =~ "While member"

      {:ok, _} = Members.remove_member(p, user_uuid)
      {:ok, _} = Projects.quick_add_assignment(p.uuid, "After leaving")
      send(view.pid, {:projects, :task_created, %{}})
      refute render(view) =~ "After leaving"
    end
  end

  describe "renaming a library task on the project page" do
    test "is re-checked against the live scope at the write", %{conn: conn} do
      p = fixture_project()
      lib = fixture_task(%{"title" => "Shared #{n()}"})
      {:ok, a} = Projects.create_assignment(%{"project_uuid" => p.uuid, "task_uuid" => lib.uuid})

      {:ok, view, _} =
        live(
          put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!())),
          "/en/admin/projects/#{p.uuid}"
        )

      # Lost the library right (but still administers the project).
      swap_scope(
        view,
        fake_scope(
          user_uuid: embed_user_uuid!(),
          permissions: ["projects", "projects.admin_all"]
        )
      )

      render_hook(view, "outline_rename", %{"id" => a.uuid, "text" => "Hijacked"})
      assert Projects.get_task(lib.uuid).title == lib.title
    end
  end

  describe "the backfill" do
    # `grant_permission/3` validates keys against the module registry, which
    # this environment does not start — the base row goes in directly and
    # the grant is injected, the seam `backfill_sub_key/3` exposes for this.
    defp role_with_projects! do
      {:ok, role} = Roles.create_role(%{"name" => "Backfill-#{n()}", "description" => "t"})
      Repo.insert!(%RolePermission{role_uuid: role.uuid, module_key: "projects"})
      role
    end

    test "grants the sub-key to every role holding projects, once, then sets the flag" do
      flag = "projects_manage_library_backfilled"
      Settings.update_setting(flag, "false")
      role = role_with_projects!()
      {:ok, outsider} = Roles.create_role(%{"name" => "NoProjects-#{n()}", "description" => "t"})
      test_pid = self()

      grant = fn role_uuid, key, _by ->
        send(test_pid, {:granted, role_uuid, key})
        {:ok, :granted}
      end

      assert :ok =
               PhoenixKitProjects.backfill_sub_keys(flag, ["projects.manage_library"],
                 grant: grant
               )

      role_uuid = role.uuid
      outsider_uuid = outsider.uuid
      assert_received {:granted, ^role_uuid, "projects.manage_library"}
      refute_received {:granted, ^outsider_uuid, _}
      assert Settings.get_setting(flag) == "true"

      # Once: a role granted `projects` afterwards gets the narrow meaning.
      later = role_with_projects!()

      assert :ok =
               PhoenixKitProjects.backfill_sub_keys(flag, ["projects.manage_library"],
                 grant: grant
               )

      later_uuid = later.uuid
      refute_received {:granted, ^later_uuid, _}
    end

    test "a failed grant leaves the flag unset so the next boot retries" do
      flag = "projects_settings_backfilled"
      Settings.update_setting(flag, "false")
      _role = role_with_projects!()

      assert {:error, {:backfill_incomplete, ^flag, [_ | _]}} =
               PhoenixKitProjects.backfill_sub_keys(flag, ["projects.settings"],
                 grant: fn _, _, _ -> {:error, :boom} end
               )

      refute Settings.get_setting(flag) == "true"
    end

    test "a failing lookup answers :lookup_failed and leaves the flag unset" do
      flag = "projects_admin_all_backfilled"
      Settings.update_setting(flag, "false")
      _role = role_with_projects!()

      assert {:error, :lookup_failed} =
               PhoenixKitProjects.backfill_sub_keys(flag, ["projects.admin_all"],
                 holders: fn _ -> raise "db down" end
               )

      refute Settings.get_setting(flag) == "true"
    end

    test "the older backfills (admin_all, own API key rights) set no flag after a failed grant" do
      for {flag, keys} <- [
            {"projects_admin_all_backfilled", ["projects.admin_all"]},
            {"projects_api_keys_permissions_backfilled",
             ~w(projects.api_keys_create projects.api_keys_edit projects.api_keys_rotate projects.api_keys_revoke)}
          ] do
        Settings.update_setting(flag, "false")
        _role = role_with_projects!()

        assert {:error, {:backfill_incomplete, ^flag, failures}} =
                 PhoenixKitProjects.backfill_sub_keys(flag, keys,
                   grant: fn _, _, _ -> {:error, :boom} end
                 )

        assert length(failures) >= length(keys)
        refute Settings.get_setting(flag) == "true"
      end
    end

    test "both sub-keys are declared" do
      keys = Enum.map(PhoenixKitProjects.permission_metadata().sub_permissions, & &1.key)
      assert "manage_library" in keys and "settings" in keys
    end
  end

  describe "moderatable_resources/2" do
    setup do
      owner = embed_user_uuid!()
      manager = embed_user_uuid!()
      member = embed_user_uuid!()
      outsider = embed_user_uuid!()

      p = fixture_project()
      other = fixture_project()
      {:ok, _} = Members.add_member(p, owner, role: "owner")
      {:ok, _} = Members.add_member(p, manager, role: "manager")
      {:ok, _} = Members.add_member(p, member, role: "member")
      {:ok, %{assignment: a}} = Projects.quick_add_assignment(p.uuid, "Discuss #{n()}")
      {:ok, %{assignment: elsewhere}} = Projects.quick_add_assignment(other.uuid, "Elsewhere")

      %{
        p: p,
        other: other,
        a: a,
        elsewhere: elsewhere,
        owner: owner,
        manager: manager,
        member: member,
        outsider: outsider
      }
    end

    test "owners and managers moderate their projects' discussions", ctx do
      for user <- [ctx.owner, ctx.manager] do
        scope = base_scope(user_uuid: user)

        for type <- ~w(project project_notes) do
          assert CommentModeration.moderatable_resources(type, scope) == [ctx.p.uuid]
        end

        for type <- ~w(assignment project_task_notes) do
          assert CommentModeration.moderatable_resources(type, scope) == [ctx.a.uuid]
        end
      end

      # Through the handlers the comments module dispatches to.
      scope = base_scope(user_uuid: ctx.manager)

      assert PhoenixKitProjects.ResourceLinks.moderatable_resources("project", scope) == [
               ctx.p.uuid
             ]

      assert PhoenixKitProjects.CommentNotices.moderatable_resources("assignment", scope) ==
               [ctx.a.uuid]
    end

    test "a member, an outsider and an anonymous scope moderate nothing", ctx do
      for scope <- [base_scope(user_uuid: ctx.member), base_scope(user_uuid: ctx.outsider), nil] do
        for type <- CommentModeration.types() do
          assert CommentModeration.moderatable_resources(type, scope) == []
        end
      end

      assert CommentModeration.moderatable_resources("crm_contact", fake_scope()) == []
    end

    test "a manager through a group grant counts", ctx do
      user = embed_user_uuid!()
      {:ok, role} = Roles.create_role(%{"name" => "Leads-#{n()}", "description" => "t"})
      {:ok, _} = Roles.assign_role(Auth.get_user(user), role.name)
      {:ok, _} = Grants.grant(ctx.other, "role", role.uuid, "manager")

      assert CommentModeration.moderatable_resources("project", base_scope(user_uuid: user)) ==
               [ctx.other.uuid]

      assert CommentModeration.moderatable_resources("assignment", base_scope(user_uuid: user)) ==
               [ctx.elsewhere.uuid]
    end

    test "projects.admin_all moderates everything" do
      for type <- CommentModeration.types() do
        assert CommentModeration.moderatable_resources(type, fake_scope()) == :all
      end
    end

    test "the reads do not grow with the number of projects managed", ctx do
      scope = base_scope(user_uuid: ctx.manager)

      {_, few} =
        QueryCounter.count(fn ->
          CommentModeration.moderatable_resources("assignment", scope)
        end)

      for _ <- 1..6 do
        q = fixture_project()
        {:ok, _} = Members.add_member(q, ctx.manager, role: "manager")
        {:ok, _} = Projects.quick_add_assignment(q.uuid, "More #{n()}")
      end

      {result, many} =
        QueryCounter.count(fn ->
          CommentModeration.moderatable_resources("assignment", scope)
        end)

      assert length(result) == 7
      assert many == few
    end
  end

  describe "Authz's sub-key answers" do
    test "the library right needs the sub-key, its base and the module switched on" do
      lib_only = fake_scope(permissions: ["projects", "projects.manage_library"])

      assert Authz.manage_library?(lib_only)
      refute Authz.manage_library?(base_scope())
      refute Authz.manage_library?(fake_scope(permissions: ["projects.manage_library"]))

      {:ok, _} = PhoenixKitProjects.disable_system()
      refute Authz.manage_library?(lib_only)
      refute Authz.manage_library?(fake_scope(permissions: ["*"]))
    end

    test "a crafted library write is refused while the module is off", %{conn: conn} do
      lib = fixture_task(%{"title" => "Off #{n()}"})
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), "/en/admin/projects/tasks")
      {:ok, _} = PhoenixKitProjects.disable_system()

      render_click(view, "delete", %{"uuid" => lib.uuid})
      assert Projects.get_task(lib.uuid)
    end

    # Only the module's own check: in a host, core's admin mount gate still
    # refuses a disabled module's pages (re-enabling is core's Modules page).
    test "the settings check does not itself depend on the module being on", %{conn: conn} do
      {:ok, _} = PhoenixKitProjects.disable_system()
      assert Authz.settings?(fake_scope())

      assert {:ok, _view, _html} =
               live(put_test_scope(conn, fake_scope()), "/en/admin/settings/projects")
    end
  end
end
