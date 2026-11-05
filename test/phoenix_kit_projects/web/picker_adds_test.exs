defmodule PhoenixKitProjects.Web.PickerAddsTest do
  @moduledoc """
  The assignee picker adds, never replaces (the boss, 2026-11-03: "it
  shouldn't be switching out the currently assigned one. It should be
  adding"), in the project popup and the library task form as in the task
  popup; ✕ removes. The whole list is saved with Save (V30).
  """

  use PhoenixKitProjects.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{AssigneeSet, Projects}
  alias PhoenixKitProjects.Test.Repo
  alias PhoenixKitStaff.Schemas.Person

  defp person!(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{String.downcase(name)}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    Repo.insert!(%Person{user_uuid: user.uuid, status: "active", name: name})
  end

  setup %{conn: conn} do
    conn = put_test_scope(conn, fake_scope(user_uuid: embed_user_uuid!()))
    {:ok, conn: conn, ann: person!("Ann"), bob: person!("Bob")}
  end

  test "the project popup adds a second assignee and saves both", ctx do
    project = fixture_project(%{"start_mode" => "immediate"})
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{project.uuid}/edit")

    render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => ctx.ann.uuid})
    html = render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => ctx.bob.uuid})

    assert html =~ ~s(value="person:#{ctx.ann.uuid}")
    assert html =~ ~s(value="person:#{ctx.bob.uuid}")

    view
    |> element("form[id^=project-form]")
    |> render_submit(%{"project" => %{"name" => project.name}})

    assert AssigneeSet.keys(Projects.get_project(project.uuid)) == [
             {"person", ctx.ann.uuid},
             {"person", ctx.bob.uuid}
           ]
  end

  test "✕ removes one and leaves the other", ctx do
    {:ok, project} =
      Projects.create_project(%{
        "name" => "Hall #{System.unique_integer([:positive])}",
        "start_mode" => "immediate",
        "assignees" => [{"person", ctx.ann.uuid}, {"person", ctx.bob.uuid}]
      })

    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{project.uuid}/edit")
    html = render_click(view, "assignee_remove", %{"kind" => "person", "uuid" => ctx.ann.uuid})

    refute html =~ ~s(value="person:#{ctx.ann.uuid}")
    assert html =~ ~s(value="person:#{ctx.bob.uuid}")
  end

  test "the library task form adds defaults too", ctx do
    task = fixture_task()
    {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

    render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => ctx.ann.uuid})
    html = render_click(view, "assignee_toggle", %{"kind" => "person", "uuid" => ctx.bob.uuid})

    assert html =~ ~s(value="person:#{ctx.ann.uuid}")
    assert html =~ ~s(value="person:#{ctx.bob.uuid}")
  end

  describe "a posted set is checked at save" do
    # A crafted `kind:uuid` (a row that does not exist, a trashed person) or
    # a person hard-deleted since the pick failed on a foreign key inside
    # the save and crashed the form.
    defp forged(ctx) do
      trashed = person!("Trashed")
      Repo.update_all(from(p in Person, where: p.uuid == ^trashed.uuid), set: [status: "trashed"])
      ["person:#{ctx.ann.uuid}", "person:#{Ecto.UUID.generate()}", "person:#{trashed.uuid}"]
    end

    test "the project form saves only the people that exist", ctx do
      project = fixture_project(%{"start_mode" => "immediate"})
      {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{project.uuid}/edit")

      view
      |> element("form[id^=project-form]")
      |> render_submit(%{"project" => %{"name" => project.name, "assignees" => forged(ctx)}})

      assert AssigneeSet.keys(Projects.get_project(project.uuid)) == [{"person", ctx.ann.uuid}]
    end

    test "the project form keeps a person trashed since they were assigned", ctx do
      {:ok, project} =
        Projects.create_project(%{
          "name" => "Hall #{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "assignees" => [{"person", ctx.bob.uuid}]
        })

      Repo.update_all(from(p in Person, where: p.uuid == ^ctx.bob.uuid), set: [status: "trashed"])
      {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{project.uuid}/edit")

      view
      |> element("form[id^=project-form]")
      |> render_submit(%{
        "project" => %{
          "name" => project.name,
          "assignees" => ["person:#{ctx.bob.uuid}", "person:#{ctx.ann.uuid}"]
        }
      })

      assert AssigneeSet.keys(Projects.get_project(project.uuid)) ==
               [{"person", ctx.bob.uuid}, {"person", ctx.ann.uuid}]
    end

    test "the library task form saves only the people that exist", ctx do
      task = fixture_task()
      {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/tasks/#{task.uuid}/edit")

      view
      |> element("form[id^=task-form]")
      |> render_submit(%{"task" => %{"title" => task.title, "assignees" => forged(ctx)}})

      assert AssigneeSet.keys(Projects.get_task(task.uuid)) == [{"person", ctx.ann.uuid}]
    end
  end

  describe "typing in the form" do
    # A record with none or several assignees has an empty mirror, so each
    # `phx-change` used to read its rows again.
    defp assignee_reads(fun) do
      event = Repo.config()[:telemetry_prefix] ++ [:query]
      handler = "reads-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        event,
        fn _e, _m, %{query: q}, _ ->
          if q =~ ~r/FROM "phoenix_kit_project_assignees"/, do: send(parent, :read)
        end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

      drain(0)
    end

    defp drain(n) do
      receive do
        :read -> drain(n + 1)
      after
        0 -> n
      end
    end

    test "the project form reads the assignee rows at mount, not on every change", ctx do
      {:ok, project} =
        Projects.create_project(%{
          "name" => "Hall #{System.unique_integer([:positive])}",
          "start_mode" => "immediate",
          "assignees" => [{"person", ctx.ann.uuid}, {"person", ctx.bob.uuid}]
        })

      {:ok, view, _html} = live(ctx.conn, "/en/admin/projects/#{project.uuid}/edit")

      reads =
        assignee_reads(fn ->
          for name <- ["A", "AB", "ABC"] do
            view
            |> element("form[id^=project-form]")
            |> render_change(%{"project" => %{"name" => name}})
          end
        end)

      assert reads == 0
    end
  end
end
