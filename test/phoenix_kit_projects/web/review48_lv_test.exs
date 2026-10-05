defmodule PhoenixKitProjects.Web.Review48LvTest do
  @moduledoc """
  LiveView regressions from the post-merge review of PR #48: the template
  list's delete is for templates, a project form's crafted `settings` post is
  dropped (and the form folds onto the project as it is now), and the
  redirect / adopt events answer to the project's edit floor and take no
  usage from the wire.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.{Ledger, Projects}

  setup %{conn: conn} do
    # a real user: the redirect writes a comment, whose author is a foreign key
    scope = fake_scope(user_uuid: embed_user_uuid!())
    {:ok, conn: put_test_scope(conn, scope)}
  end

  test "the template list deletes templates, not projects", %{conn: conn} do
    project = fixture_project(%{"name" => "Not a template"})
    template = fixture_template(%{"name" => "A template"})

    {:ok, view, _} = live(conn, "/en/admin/projects/templates")

    html = render_click(view, "delete", %{"uuid" => project.uuid})
    assert html =~ "Template not found."
    assert Projects.get_project(project.uuid)

    render_click(view, "delete", %{"uuid" => template.uuid})
    assert Projects.get_project(template.uuid) == nil
  end

  test "a crafted project[settings] post is dropped; the save folds onto the current settings",
       %{conn: conn} do
    project = fixture_project(%{"name" => "Settings"})
    {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}/edit")

    # another page (the Modules panel) changes the project after this form mounted
    {:ok, _} =
      Projects.update_project(project, %{
        "settings" => %{"features" => %{"tasks" => %{"ledger" => true}}}
      })

    render_submit(view, "save", %{
      "project" => %{
        "name" => "Settings",
        "settings" => %{"agents" => %{"delete_tasks" => "any"}, "completion" => "manual"}
      },
      "agents" => %{"delete_tasks" => "own"}
    })

    saved = Projects.get_project(project.uuid)
    refute saved.settings["completion"] == "manual"
    assert get_in(saved.settings, ["agents", "delete_tasks"]) == "own"
    assert get_in(saved.settings, ["features", "tasks", "ledger"]) == true
  end

  # Pins the behaviour (the narrowing to summary/content is hardening; this
  # passes without it), so a later change cannot start taking usage from here.
  test "a redirect takes no usage from the wire", %{conn: conn} do
    {:ok, _} = PhoenixKit.Settings.update_setting("comments_enabled", "true")
    on_exit(fn -> PhoenixKit.Settings.update_setting("comments_enabled", "false") end)

    project = fixture_project(%{"name" => "Redirects"})
    task = fixture_task(%{"title" => "Work"})

    {:ok, a} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}")

    render_submit(view, "save_redirect", %{
      "uuid" => a.uuid,
      "summary" => "Do it the other way",
      "usage" => %{"tokens" => 9_999_999, "minutes" => 600}
    })

    # the note itself was written (comments are on) …
    assert %{redirect: %{metadata: %{"summary" => "Do it the other way"}}} =
             PhoenixKitProjects.TaskNotes.latest(a.uuid)

    # … and the figures posted alongside it reached no ledger row
    assert Ledger.list_entries(project.uuid) == []
  end

  test "the comments drawer opens only on this project or one of its tasks", %{conn: conn} do
    project = fixture_project(%{"name" => "Mine"})
    other = fixture_project(%{"name" => "Theirs"})
    task = fixture_task(%{"title" => "Foreign"})

    {:ok, foreign} =
      Projects.create_assignment(%{
        "project_uuid" => other.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    {:ok, view, _} = live(conn, "/en/admin/projects/#{project.uuid}")

    for type <- ["assignment", "notes"] do
      html = render_hook(view, "open_comments", %{"type" => type, "uuid" => foreign.uuid})
      refute html =~ ~s|aria-label="Comments"|
    end

    html = render_hook(view, "open_comments", %{"type" => "project", "uuid" => other.uuid})
    refute html =~ ~s|aria-label="Comments"|
  end
end
