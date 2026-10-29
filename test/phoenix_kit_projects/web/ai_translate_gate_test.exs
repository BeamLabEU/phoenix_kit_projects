defmodule PhoenixKitProjects.Web.AITranslateGateTest do
  @moduledoc """
  `PhoenixKitAI.Components.AITranslate.Embed` handles the AI-translate
  modal's events (`ai_translate_lang` enqueues translation jobs) with no
  permission check. Every form using it attaches `Web.AITranslateGate`
  first, which asks the form's `ai_translate_allowed?/1` — the right its
  save needs — against the scope the socket holds when the event arrives.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Test.Repo

  # A role that kept the module but lost everything the forms need: no
  # library writes, no admin override, no membership in any project.
  defp revoked, do: fake_scope(roles: [], permissions: ["projects"])

  # Nothing left at all — templates ride the module key itself.
  defp nothing, do: fake_scope(roles: [], permissions: [])

  # What core's live scope refresh does when a role loses a grant while the
  # page is open.
  defp swap_scope(view, scope) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: Phoenix.Component.assign(socket, :phoenix_kit_current_scope, scope)}
    end)

    view
  end

  defp jobs, do: Repo.aggregate(Oban.Job, :count)

  # Opens `path` as the site admin, swaps `scope` in, then sends a crafted
  # ai_translate_lang. True when it was refused and nothing was enqueued.
  defp refused_after_revoke?(conn, path, scope) do
    {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), path)
    before = jobs()

    html = view |> swap_scope(scope) |> render_click("ai_translate_lang", %{"lang" => "*"})
    html =~ "permission" and jobs() == before
  end

  test "the task form refuses it once manage_library is gone", %{conn: conn} do
    task = fixture_task(%{"title" => "Shared step"})
    assert refused_after_revoke?(conn, "/en/admin/projects/tasks/#{task.uuid}/edit", revoked())
  end

  test "the project form refuses it once the project's edit right is gone", %{conn: conn} do
    project = fixture_project()
    assert refused_after_revoke?(conn, "/en/admin/projects/#{project.uuid}/edit", revoked())
  end

  test "the assignment form refuses it once the project's edit right is gone", %{conn: conn} do
    project = fixture_project()
    task = fixture_task(%{"title" => "Step"})

    {:ok, a} =
      Projects.create_assignment(%{"project_uuid" => project.uuid, "task_uuid" => task.uuid})

    assert refused_after_revoke?(
             conn,
             "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit",
             revoked()
           )
  end

  test "the template form refuses it once the module key is gone", %{conn: conn} do
    template = fixture_template()

    assert refused_after_revoke?(
             conn,
             "/en/admin/projects/templates/#{template.uuid}/edit",
             nothing()
           )
  end

  test "a holder's event still reaches the modal", %{conn: conn} do
    task = fixture_task(%{"title" => "Shared step"})

    {:ok, view, _html} =
      live(put_test_scope(conn, fake_scope()), "/en/admin/projects/tasks/#{task.uuid}/edit")

    refute render_click(view, "ai_toggle_modal", %{}) =~ "permission to do that here"
  end
end
