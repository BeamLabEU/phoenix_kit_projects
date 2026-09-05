defmodule PhoenixKitProjects.Web.AssignmentFormDefaultsTest do
  @moduledoc """
  The add-task form's defaults (Max, 2026-09-05): Create new is the first
  and default tab, "Add to the task library" is off, the library tab only
  exists once the library has an entry, the new task's title is
  translatable like the description, and no user-facing copy calls a
  task a "template".
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Web.AssignmentFormLive

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, project: fixture_project()}
  end

  defp new_form_html(conn, project) do
    # No layout: the sidebar's "Templates" subtab must not pollute the
    # wording assertion below.
    {:ok, view, html} =
      live_isolated(conn, AssignmentFormLive,
        session: %{
          "project_id" => project.uuid,
          "live_action" => "new",
          "current_user_uuid" => embed_user_uuid!()
        }
      )

    {view, html}
  end

  test "with an empty library there is no tab strip — just the Create-new form",
       %{conn: conn, project: p} do
    {_view, html} = new_form_html(conn, p)

    refute html =~ ~s(phx-value-tab="existing")
    assert html =~ ~s(name="task_mode" value="new")
    assert html =~ ~s(name="task[title]")
    refute html =~ ~s(name="assignment[task_uuid]")
  end

  test "once the library has an entry, Create new is first and default; From library second",
       %{conn: conn, project: p} do
    _ = fixture_task()
    {view, html} = new_form_html(conn, p)

    {new_at, _} = :binary.match(html, "Create new")
    {lib_at, _} = :binary.match(html, "From library")
    assert new_at < lib_at
    assert html =~ ~s(name="task_mode" value="new")
    assert html =~ ~s(name="task[title]")

    html = view |> element("button[phx-value-tab='existing']") |> render_click()
    assert html =~ ~s(name="assignment[task_uuid]")
    refute html =~ ~s(name="task[title]")
  end

  test "no user-facing copy calls a task a template", %{conn: conn, project: p} do
    _ = fixture_task()
    {view, html} = new_form_html(conn, p)

    refute html =~ ~r/template/i
    assert html =~ "Add to the task library"

    html = view |> element("button[phx-value-tab='existing']") |> render_click()
    refute html =~ ~r/template/i
    assert html =~ ">Task"
  end

  test "the new task's title is translatable; its translations merge with the description's",
       %{conn: conn, project: p} do
    {view, _} = new_form_html(conn, p)
    title = "Titled-#{System.unique_integer([:positive])}"

    # Raw params — the secondary-language inputs only render with the
    # workspace's multilang on, but the save path is the same.
    render_submit(view, "save", %{
      "assignment" => %{
        "status" => "todo",
        "description" => "Primary text",
        "translations" => %{"et" => %{"description" => "Eesti kirjeldus"}}
      },
      "task_mode" => "new",
      "task" => %{
        "title" => title,
        "translations" => %{"et" => %{"title" => "Eesti pealkiri"}, "fr" => %{"title" => ""}}
      }
    })

    [task] = Enum.filter(Projects.list_tasks(ad_hoc: :all), &(&1.title == title))

    assert task.translations["et"] == %{
             "title" => "Eesti pealkiri",
             "description" => "Eesti kirjeldus"
           }

    refute Map.has_key?(task.translations, "fr")
    # Off by default: a one-off, out of the library.
    assert task.ad_hoc
  end
end
