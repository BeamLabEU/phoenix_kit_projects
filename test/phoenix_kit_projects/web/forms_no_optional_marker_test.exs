defmodule PhoenixKitProjects.Web.FormsNoOptionalMarkerTest do
  @moduledoc """
  The forms mark what is required with a star and say nothing about the
  rest (the boss, 2026-10-30: "no need to write (not required), we have
  stars"): no "(optional)" in a label or a placeholder.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Web.{ProjectEventsLive, ProjectHoursLive}

  setup %{conn: conn} do
    me = embed_user_uuid!()
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Fit the doors", "ad_hoc" => true},
        %{}
      )

    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: me)), me: me, project: project, a: a}
  end

  test "the task form, new and edited", %{conn: conn, project: project, a: a} do
    {:ok, _view, html} = live(conn, "/en/admin/projects/#{project.uuid}/assignments/new")
    refute html =~ "(optional)"

    {:ok, _view, html} =
      live(conn, "/en/admin/projects/#{project.uuid}/assignments/#{a.uuid}/edit")

    refute html =~ "(optional)"
  end

  test "the project, task library and template forms", %{conn: conn} do
    for path <-
          ~w(/en/admin/projects/new /en/admin/projects/tasks/new /en/admin/projects/templates/new) do
      {:ok, _view, html} = live(conn, path)
      refute html =~ "(optional)", path
    end
  end

  test "the Hours page's Log time dialog", %{conn: conn, project: project, me: me} do
    {:ok, view, _html} =
      live_isolated(conn, ProjectHoursLive,
        session: %{
          "project_uuid" => project.uuid,
          "ext_key" => "tasks",
          "instance_key" => "default",
          "config" => %{},
          "current_user_uuid" => me,
          "can_write" => true,
          "locale" => "en",
          "wrapper_class" => ""
        }
      )

    html = render_click(view, "open_log", %{})
    assert html =~ "Log time"
    refute html =~ "(optional)"
  end

  test "the Events tab's New event dialog", %{conn: conn, project: project} do
    {:ok, view, _html} =
      live_isolated(conn, ProjectEventsLive,
        session: %{
          "project_uuid" => project.uuid,
          "ext_key" => "events",
          "instance_key" => "default",
          "config" => %{},
          "current_user_uuid" => Ecto.UUID.generate(),
          "can_write" => true,
          "locale" => "en"
        }
      )

    html = render_click(view, "open_new_event", %{})
    assert html =~ "New event"
    refute html =~ "(optional)"
  end

  # Every screen at once, the ones no test above opens included (the
  # portal's issue form, a dialog behind a feature switch): no string the
  # module translates says "(optional)", so no label or placeholder can.
  test "no translated string of any screen says \"(optional)\"" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/gettext\(\s*"[^"]*\((optional|not required)\)/i,
          do: "#{path}:#{n}"

    assert offenders == []
  end
end
