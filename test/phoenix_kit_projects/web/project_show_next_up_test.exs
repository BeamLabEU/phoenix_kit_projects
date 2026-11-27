defmodule PhoenixKitProjects.Web.ProjectShowNextUpTest do
  @moduledoc """
  A new task is `waiting` (idle, nobody asked yet) until it is released —
  `todo`, shown as "can be started", which tells its people. Completing a
  task that others wait on asks first ("next up"): each task nothing would
  hold up is released on confirm unless it is kept idle, and a comment can
  be left for whoever does it. Nothing is written before the confirm.
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{People, Projects}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitProjects.Web.ProjectShowLive
  alias PhoenixKitStaff.Schemas.{Department, Person}

  setup %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "next-up-#{System.unique_integer([:positive])}@example.com",
        "password" => "ActorPass123!"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))

    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, _} = Projects.start_project(project)
    project = Projects.get_project!(project.uuid)

    consult = assignment!(project, "Consultation")
    measure = assignment!(project, "Measurement")
    render = assignment!(project, "3D render")
    {:ok, _} = Projects.add_dependency(measure.uuid, consult.uuid)
    {:ok, _} = Projects.add_dependency(render.uuid, consult.uuid)

    {:ok,
     conn: conn,
     project: project,
     consult: consult,
     measure: measure,
     render: render,
     actor_uuid: user.uuid}
  end

  # No status given: a new task's default.
  defp assignment!(project, title) do
    task = fixture_task(%{"title" => title})

    {:ok, a} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

    a
  end

  defp status(a), do: Projects.get_assignment(a.uuid).status
  defp next_up(project), do: "#project-next-up-#{project.uuid}"
  defp show(ctx), do: live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}")

  # The words a person reads: the text between tags (ids and attribute
  # values like `board-column-todo` are code, not copy).
  defp visible(html), do: Regex.replace(~r/<[^>]*>/, html, " ")

  test "a new task waits, and no screen says to do", ctx do
    assert status(ctx.consult) == "waiting"

    {:ok, view, html} = show(ctx)
    assert html =~ "waiting"
    refute visible(html) =~ ~r/to.?do/i

    board = render_click(view, "switch_tab", %{"tab" => "board"})
    assert board =~ "Waiting"
    assert board =~ "Can be started"
    refute visible(board) =~ ~r/to.?do/i
  end

  test "Can be started releases a waiting task; idle puts it back", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "make_ready", %{"uuid" => ctx.consult.uuid})
    assert status(ctx.consult) == "todo"
    assert_activity_logged("projects.assignment_made_ready", resource_uuid: ctx.consult.uuid)

    render_click(view, "make_idle", %{"uuid" => ctx.consult.uuid})
    assert status(ctx.consult) == "waiting"
  end

  test "completing a task that hands work on asks first and writes nothing", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})

    assert has_element?(view, next_up(ctx.project), "Measurement")
    assert has_element?(view, next_up(ctx.project), "3D render")
    assert has_element?(view, next_up(ctx.project), "Keep idle")
    assert status(ctx.consult) == "waiting"

    render_click(view, "next_up_close", %{})
    refute has_element?(view, next_up(ctx.project))
    assert status(ctx.consult) == "waiting"
    assert status(ctx.measure) == "waiting"
  end

  test "confirm completes the task and releases what it held up", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    refute has_element?(view, next_up(ctx.project))
    assert status(ctx.consult) == "done"
    assert status(ctx.measure) == "todo"
    assert status(ctx.render) == "todo"

    assert_activity_logged("projects.assignment_completed",
      actor_uuid: ctx.actor_uuid,
      resource_uuid: ctx.consult.uuid
    )
  end

  test "Keep idle leaves a task waiting; pressed again it is released", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.render.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.measure.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.measure.uuid})

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    assert status(ctx.consult) == "done"
    assert status(ctx.measure) == "todo"
    assert status(ctx.render) == "waiting"
  end

  test "a released task kept idle goes back to waiting", ctx do
    {:ok, _} = Projects.update_assignment_status(ctx.render, %{status: "todo"})
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.render.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    assert status(ctx.render) == "waiting"
  end

  test "a task started after the dialog opened is not put back by the confirm", ctx do
    {:ok, _} = Projects.update_assignment_status(ctx.render, %{status: "todo"})
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.render.uuid})

    # Meanwhile, behind the page's back (no broadcast reaches it): one
    # offered task is started, the one to keep idle too.
    {2, _} =
      Repo.update_all(
        from(a in PhoenixKitProjects.Schemas.Assignment,
          where: a.uuid in ^[ctx.measure.uuid, ctx.render.uuid]
        ),
        set: [status: "in_progress"]
      )

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    assert status(ctx.measure) == "in_progress"
    assert status(ctx.render) == "in_progress"
  end

  # The database refuses to mark `a` done, as a check constraint would: the
  # write comes back as a changeset error (the trigger and its function go
  # with the test's sandbox transaction).
  defp refuse_done!(a) do
    Repo.query!("""
    CREATE FUNCTION pkp_test_refuse_done() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'refused by the test' USING ERRCODE = 'check_violation',
        CONSTRAINT = 'phoenix_kit_project_assignments_dates_check';
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER pkp_test_refuse_done BEFORE UPDATE ON phoenix_kit_project_assignments
    FOR EACH ROW WHEN (NEW.status = 'done' AND NEW.uuid = '#{a.uuid}'::uuid)
    EXECUTE FUNCTION pkp_test_refuse_done()
    """)
  end

  test "a completion that fails puts nothing back: the kept-idle task stays released", ctx do
    {:ok, _} = Projects.update_assignment_status(ctx.render, %{status: "todo"})
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.render.uuid})
    refuse_done!(ctx.consult)

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})

    assert status(ctx.consult) == "waiting"
    # Without one transaction around the confirm it was already back to
    # waiting when the completion failed.
    assert status(ctx.render) == "todo"
    assert status(ctx.measure) == "waiting"
    refute_activity_logged("projects.assignment_made_idle", resource_uuid: ctx.render.uuid)
  end

  # Done always asks (the boss, 2026-11-18): a comment and who to tell,
  # even when nothing waits on the task.
  test "a completion that holds nothing up still asks, then completes", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.render.uuid})

    assert has_element?(view, next_up(ctx.project), "done?")
    assert has_element?(view, "#{next_up(ctx.project)} [data-next-up-tell]")
    assert status(ctx.render) == "waiting"

    render_submit(view, "next_up_confirm", %{"uuid" => ctx.render.uuid})
    refute has_element?(view, next_up(ctx.project))
    assert status(ctx.render) == "done"
  end

  test "only the offered tasks can be toggled, and only the asked task confirmed", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.render.uuid})

    assert status(ctx.render) == "waiting"
    assert status(ctx.consult) == "waiting"
  end

  test "a waiting task offers only Ready to start; a released one Start", ctx do
    {:ok, view, _html} = show(ctx)
    button = &"button[phx-click='#{&1}'][phx-value-uuid='#{ctx.consult.uuid}']"

    assert has_element?(view, button.("ask_ready"))
    refute has_element?(view, button.("complete"))
    refute has_element?(view, button.("start_task"))

    render_click(view, "make_ready", %{"uuid" => ctx.consult.uuid})

    refute has_element?(view, button.("ask_ready"))
    assert has_element?(view, button.("start_task"))
  end

  test "Ready to start opens the dialog for that task; nothing is written until confirm", ctx do
    {:ok, view, _html} = show(ctx)

    render_click(view, "ask_ready", %{"uuid" => ctx.consult.uuid})
    assert has_element?(view, next_up(ctx.project), "as can be started?")
    refute has_element?(view, next_up(ctx.project), "Keep idle")
    assert status(ctx.consult) == "waiting"

    render_click(view, "next_up_close", %{})
    assert status(ctx.consult) == "waiting"

    render_click(view, "ask_ready", %{"uuid" => ctx.consult.uuid})
    render_submit(view, "next_up_confirm", %{"uuid" => ctx.consult.uuid})
    assert status(ctx.consult) == "todo"
    assert_activity_logged("projects.assignment_made_ready", resource_uuid: ctx.consult.uuid)
  end

  describe "who is told" do
    setup ctx do
      dept = Repo.insert!(%Department{name: "Measurers #{System.unique_integer([:positive])}"})
      alice = person!(ctx.project, "Alice", dept)
      bob = person!(ctx.project, "Bob", dept)

      {:ok, measure} =
        Projects.update_assignment_form(ctx.measure, %{"assigned_department_uuid" => dept.uuid})

      %{alice: alice, bob: bob, dept: dept, measure: measure}
    end

    defp person!(project, name, dept) do
      {:ok, user} =
        Auth.register_user(%{
          "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!",
          "first_name" => name
        })

      Repo.insert!(%Person{
        user_uuid: user.uuid,
        status: "active",
        name: name,
        primary_department_uuid: dept.uuid
      })

      {:ok, _} = PhoenixKitProjects.Members.add_member(project, user.uuid, role: "member")
      user.uuid
    end

    defp notices(action, user_uuid) do
      Repo.all(
        from(e in PhoenixKit.Activity.Entry,
          where: e.action == ^action and e.target_uuid == ^user_uuid
        )
      )
    end

    defp person_key(user_uuid),
      do: {"person", People.get_person_by_user_uuid(user_uuid).uuid}

    defp row_picker(a), do: ProjectShowLive.row_picker_id(a.uuid)

    test "the dialog lists everyone the notice would reach, tagged with why", ctx do
      {:ok, view, _html} = show(ctx)

      html = render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      assert html =~ "Send a notification to"
      assert has_element?(view, next_up(ctx.project), "Alice")
      assert has_element?(view, next_up(ctx.project), "Bob")
      # who is who, and why (item 22): through the department, and a member
      assert html =~ "Assigned through #{ctx.dept.name}"
      assert html =~ "Member"
    end

    # Max, 2026-11-27: someone tagged in the comment belongs on the list;
    # "Added by you" read as "you added them to the project".
    test "a person tagged in the comment joins the list, and leaves with the tag", ctx do
      {:ok, view, _html} = show(ctx)
      render_click(view, "ask_ready", %{"uuid" => ctx.render.uuid})
      editor = "pkp-dialog-next-#{ctx.render.uuid}"
      mention = "please @[user:#{ctx.alice}|Alice] look"

      send(view.pid, {:leaf_changed, %{editor_id: editor, markdown: mention, html: ""}})
      html = render(view)
      assert has_element?(view, next_up(ctx.project), "Alice")
      assert html =~ "Mentioned in the comment"
      refute html =~ "Added by you"

      send(view.pid, {:leaf_changed, %{editor_id: editor, markdown: "please look", html: ""}})
      render(view)
      render(view)
      refute has_element?(view, next_up(ctx.project), "Alice")
    end

    test "back-to-back edits use the latest recipient list", ctx do
      {:ok, view, _html} = show(ctx)
      render_click(view, "ask_ready", %{"uuid" => ctx.render.uuid})
      editor = "pkp-dialog-next-#{ctx.render.uuid}"

      for text <- ["@[user:#{ctx.alice}|Alice]", ""] do
        send(view.pid, {:leaf_changed, %{editor_id: editor, markdown: text, html: ""}})
      end

      render_submit(view, "next_up_confirm", %{"uuid" => ctx.render.uuid})
      assert notices("projects.assignment_ready", ctx.alice) == []

      refute person_key(ctx.alice) in PhoenixKitProjects.AssigneeSet.keys(
               Projects.get_assignment(ctx.render.uuid)
             )
    end

    # The whole way (kimi's question, 2026-11-27): tagged in the comment,
    # confirmed — assigned, and told it is their turn once.
    test "a person tagged in the comment is assigned and told once", ctx do
      {:ok, view, _html} = show(ctx)
      render_click(view, "ask_ready", %{"uuid" => ctx.render.uuid})
      note = "please @[user:#{ctx.alice}|Alice] look"

      send(
        view.pid,
        {:leaf_changed,
         %{editor_id: "pkp-dialog-next-#{ctx.render.uuid}", markdown: note, html: ""}}
      )

      render(view)
      render(view)

      render_submit(view, "next_up_confirm", %{
        "uuid" => ctx.render.uuid,
        "notes" => %{ctx.render.uuid => note}
      })

      assert person_key(ctx.alice) in PhoenixKitProjects.AssigneeSet.keys(
               Projects.get_assignment(ctx.render.uuid)
             )

      assert [_] = notices("projects.assignment_ready", ctx.alice)

      all =
        Repo.all(
          from(e in PhoenixKit.Activity.Entry,
            where: e.target_uuid == ^ctx.alice,
            select: e.action
          )
        )

      # One "your turn", and no second ping from the comment's own mention.
      assert Enum.count(all, &(&1 == "projects.assignment_ready")) == 1
      refute Enum.any?(all, &String.contains?(&1, "mention"))
    end

    # vibe, 2026-11-27: untagging someone who was on the list anyway took
    # them off it (and they were not told).
    test "a person on the list anyway stays when their tag is removed", ctx do
      {:ok, view, _html} = show(ctx)
      render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})
      editor = "pkp-dialog-next-#{ctx.measure.uuid}"
      assert has_element?(view, next_up(ctx.project), "Alice")

      for md <- ["hi @[user:#{ctx.alice}|Alice]", "hi"] do
        send(view.pid, {:leaf_changed, %{editor_id: editor, markdown: md, html: ""}})
        render(view)
        render(view)
      end

      assert has_element?(view, next_up(ctx.project), "Alice")
    end

    # codex, 2026-11-27: a sub-project's list takes no additions (its picker
    # is read-only), and a tag added to it anyway.
    test "a tag adds nobody to a sub-project's list", ctx do
      {:ok, %{assignment: link}} =
        Projects.create_subproject(ctx.project.uuid, %{"name" => "Sub"})

      {:ok, link} = Projects.update_assignment_status(link, %{"status" => "waiting"})

      {:ok, view, _html} = show(ctx)
      render_click(view, "ask_ready", %{"uuid" => link.uuid})
      md = "please @[user:#{ctx.alice}|Alice] look"

      send(
        view.pid,
        {:leaf_changed, %{editor_id: "pkp-dialog-next-#{link.uuid}", markdown: md, html: ""}}
      )

      render(view)
      render(view)
      refute has_element?(view, next_up(ctx.project), "Alice")
    end

    test "a tag written with an escaped bracket (an older Leaf) still adds", ctx do
      {:ok, view, _html} = show(ctx)
      render_click(view, "ask_ready", %{"uuid" => ctx.render.uuid})
      md = "please @\\[user:#{ctx.alice}|Alice] look"

      send(
        view.pid,
        {:leaf_changed,
         %{editor_id: "pkp-dialog-next-#{ctx.render.uuid}", markdown: md, html: ""}}
      )

      render(view)
      render(view)
      assert has_element?(view, next_up(ctx.project), "Alice")
    end

    test "someone added by hand is tagged Added here", ctx do
      {:ok, view, _html} = show(ctx)
      render_click(view, "ask_ready", %{"uuid" => ctx.render.uuid})

      send(
        view.pid,
        {PhoenixKitWeb.Components.PeoplePicker, row_picker(ctx.render),
         {:changed, [person_key(ctx.bob)]}}
      )

      html = render(view)
      assert html =~ "Added here"
      refute html =~ "Added by you"
    end

    test "a person taken off the list is not told; the comment rides as the quote", ctx do
      {:ok, view, _html} = show(ctx)

      render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      send(
        view.pid,
        {PhoenixKitWeb.Components.PeoplePicker, row_picker(ctx.measure),
         {:changed, [person_key(ctx.alice)]}}
      )

      _ = render(view)

      render_submit(view, "next_up_confirm", %{
        "uuid" => ctx.measure.uuid,
        "notes" => %{ctx.measure.uuid => "Client is home after 17:00."}
      })

      assert status(ctx.measure) == "todo"
      assert [notice] = notices("projects.assignment_ready", ctx.alice)

      assert notice.metadata["quote"]["text"] == "Client is home after 17:00." or
               notice.metadata["notification_text"] =~ "Client is home after 17:00."

      assert notices("projects.assignment_ready", ctx.bob) == []
    end

    test "a person added is assigned to the task, made a member, and told", ctx do
      # Carol works elsewhere (not in the task's department) and is not on
      # the project (person!/3 made her a member — undo it).
      elsewhere =
        Repo.insert!(%Department{name: "Elsewhere #{System.unique_integer([:positive])}"})

      outsider = person!(ctx.project, "Carol", elsewhere)
      {:ok, _} = PhoenixKitProjects.Members.remove_member(ctx.project, outsider)

      {:ok, view, _html} = show(ctx)
      render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      keys = [person_key(ctx.alice), person_key(ctx.bob), person_key(outsider)]

      send(
        view.pid,
        {PhoenixKitWeb.Components.PeoplePicker, row_picker(ctx.measure), {:changed, keys}}
      )

      html = render(view)
      assert html =~ "Added here"

      render_submit(view, "next_up_confirm", %{"uuid" => ctx.measure.uuid})

      assert person_key(outsider) in PhoenixKitProjects.AssigneeSet.keys(
               Projects.get_assignment(ctx.measure.uuid)
             )

      assert PhoenixKitProjects.Members.get_member(ctx.project.uuid, outsider)
      assert [_] = notices("projects.assignment_ready", outsider)
    end

    test "without the right to assign, an added person is refused", ctx do
      elsewhere =
        Repo.insert!(%Department{name: "Elsewhere #{System.unique_integer([:positive])}"})

      outsider = person!(ctx.project, "Dan", elsewhere)
      scope = fake_scope(user_uuid: ctx.actor_uuid, permissions: ["projects"])

      {:ok, _} =
        PhoenixKitProjects.Members.add_member(ctx.project, ctx.actor_uuid, role: "member")

      {:ok, _} =
        PhoenixKitProjects.Authz.set_overrides(ctx.project, %{"assign_tasks" => "managers"})

      {:ok, view, _html} =
        live(put_test_scope(ctx.conn, scope), "/en/admin/projects/#{ctx.project.uuid}")

      render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      keys = [person_key(ctx.alice), person_key(ctx.bob), person_key(outsider)]

      send(
        view.pid,
        {PhoenixKitWeb.Components.PeoplePicker, row_picker(ctx.measure), {:changed, keys}}
      )

      assert render(view) =~ "You may not assign people here."

      render_submit(view, "next_up_confirm", %{"uuid" => ctx.measure.uuid})

      refute person_key(outsider) in PhoenixKitProjects.AssigneeSet.keys(
               Projects.get_assignment(ctx.measure.uuid)
             )
    end

    test "without the right to assign, someone can still be taken off the list", ctx do
      scope = fake_scope(user_uuid: ctx.actor_uuid, permissions: ["projects"])

      {:ok, _} =
        PhoenixKitProjects.Members.add_member(ctx.project, ctx.actor_uuid, role: "member")

      {:ok, _} =
        PhoenixKitProjects.Authz.set_overrides(ctx.project, %{"assign_tasks" => "managers"})

      {:ok, view, _html} =
        live(put_test_scope(ctx.conn, scope), "/en/admin/projects/#{ctx.project.uuid}")

      html = render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      # The chips keep their × (core's `can_remove`) though nobody can be added.
      {"person", bob_uuid} = person_key(ctx.bob)
      assert html =~ ~s(id="#{row_picker(ctx.measure)}-remove-person-#{bob_uuid}")

      send(
        view.pid,
        {PhoenixKitWeb.Components.PeoplePicker, row_picker(ctx.measure),
         {:changed, [person_key(ctx.alice)]}}
      )

      refute render(view) =~ "You may not assign people here."

      render_submit(view, "next_up_confirm", %{"uuid" => ctx.measure.uuid})

      assert status(ctx.measure) == "todo"
      assert [_] = notices("projects.assignment_ready", ctx.alice)
      assert notices("projects.assignment_ready", ctx.bob) == []
    end

    test "with comments on, the comment is kept on the task without a second notice", ctx do
      :ok = PhoenixKitProjects.DataCase.with_comments_module()
      {:ok, view, _html} = show(ctx)

      render_click(view, "ask_ready", %{"uuid" => ctx.measure.uuid})

      render_submit(view, "next_up_confirm", %{
        "uuid" => ctx.measure.uuid,
        "notes" => %{ctx.measure.uuid => "Bring the long tape."}
      })

      assert [comment] = PhoenixKitComments.list_comments("assignment", ctx.measure.uuid)
      assert comment.content == "Bring the long tape."
      assert [_] = notices("projects.assignment_ready", ctx.alice)
      assert notices("projects.comment_added", ctx.alice) == []
    end
  end

  describe "with comments" do
    setup do
      :ok = PhoenixKitProjects.DataCase.with_comments_module()
    end

    test "comments are posted to each task's thread on confirm, not before", ctx do
      {:ok, view, _html} = show(ctx)

      render_click(view, "complete", %{"uuid" => ctx.consult.uuid})
      render_click(view, "next_up_toggle_idle", %{"uuid" => ctx.render.uuid})

      render_submit(view, "next_up_confirm", %{
        "uuid" => ctx.consult.uuid,
        "notes" => %{
          ctx.measure.uuid => "  Client is home after 17:00.  ",
          ctx.render.uuid => "Wait for the measurements first.",
          ctx.consult.uuid => "not offered"
        }
      })

      assert [comment] = PhoenixKitComments.list_comments("assignment", ctx.measure.uuid)
      assert comment.content == "Client is home after 17:00."
      assert comment.user_uuid == ctx.actor_uuid
      assert [_] = PhoenixKitComments.list_comments("assignment", ctx.render.uuid)
      assert PhoenixKitComments.list_comments("assignment", ctx.consult.uuid) == []
    end
  end
end
