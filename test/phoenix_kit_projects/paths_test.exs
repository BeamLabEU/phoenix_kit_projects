defmodule PhoenixKitProjects.PathsTest do
  @moduledoc """
  Direct unit tests for the URL builder helpers.

  All paths route through `PhoenixKit.Utils.Routes.path/1`, with
  `url_prefix` pinned to `/` (see `test_helper.exs`). These database-free
  tests use core's boot/mix-task context, where URLs keep their locale
  prefix. Runtime LiveView tests configure their multilingual host in
  `LiveCase`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Paths

  # phoenix_kit core PR #552 made the primary-locale strip on
  # `Routes.admin_path/2` conditional on the site-wide
  # `default_language_no_prefix` setting (default `false`). With the
  # setting OFF, primary-locale admin URLs now include the `/en/`
  # segment again — restoring the pre-#551 shape. Hosts that want the
  # prefixless shape flip the toggle on `/admin/settings/languages`.
  # ...and core 2.62 drops the segment on a single-language site, which is
  # what a test site is: the expected root is asked of core, so the test
  # holds on either side of that release.
  defp prefix, do: PhoenixKitProjects.DataCase.admin_projects()

  setup do
    # These database-free tests exercise the boot/mix-task URL shape. Runtime
    # LiveView tests configure the multilingual host in LiveCase instead.
    Process.put(:phoenix_kit_config_status, :configured)
    :ok
  end

  test "index/0 returns the base admin URL" do
    assert Paths.index() == prefix()
  end

  describe "Tasks paths" do
    test "tasks/0" do
      assert Paths.tasks() == "#{prefix()}/tasks"
    end

    test "new_task/0" do
      assert Paths.new_task() == "#{prefix()}/tasks/new"
    end

    test "edit_task/1 interpolates the id" do
      assert Paths.edit_task("abc-123") == "#{prefix()}/tasks/abc-123/edit"
    end
  end

  describe "Templates paths" do
    test "templates/0" do
      assert Paths.templates() == "#{prefix()}/templates"
    end

    test "new_template/0" do
      assert Paths.new_template() == "#{prefix()}/templates/new"
    end

    test "template/1 interpolates the id" do
      assert Paths.template("uuid-x") == "#{prefix()}/templates/uuid-x"
    end

    test "edit_template/1 interpolates the id" do
      assert Paths.edit_template("uuid-x") == "#{prefix()}/templates/uuid-x/edit"
    end
  end

  describe "Projects paths" do
    test "projects/0" do
      assert Paths.projects() == prefix()
    end

    test "new_project/0" do
      assert Paths.new_project() == "#{prefix()}/new"
    end

    test "project/1 interpolates the id" do
      assert Paths.project("p-1") == "#{prefix()}/p-1"
    end

    test "edit_project/1 interpolates the id" do
      assert Paths.edit_project("p-1") == "#{prefix()}/p-1/edit"
    end

    test "the task views live under the Tasks tab; extensions by their key" do
      assert Paths.project_tasks("p-1") == "#{prefix()}/p-1/tasks"
      assert Paths.project_board("p-1") == "#{prefix()}/p-1/tasks/board"
      assert Paths.project_gantt("p-1") == "#{prefix()}/p-1/tasks/timeline"
      assert Paths.project_calendar("p-1") == "#{prefix()}/p-1/tasks/calendar"
      assert Paths.project_comments("p-1") == "#{prefix()}/p-1/comments"
      assert Paths.project_ext_tab("p-1", "whiteboards") == "#{prefix()}/p-1/whiteboards"
    end
  end

  describe "Assignment paths" do
    test "new_assignment/1 interpolates the project id" do
      assert Paths.new_assignment("p-1") == "#{prefix()}/p-1/assignments/new"
    end

    test "edit_assignment/2 interpolates project + assignment ids" do
      assert Paths.edit_assignment("p-1", "a-9") ==
               "#{prefix()}/p-1/assignments/a-9/edit"
    end
  end
end
