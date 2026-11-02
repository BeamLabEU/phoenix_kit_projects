defmodule PhoenixKitProjects.Web.Components.AssignmentStatusBadgeTest do
  @moduledoc """
  The one place a task status's choices and colours are decided: the task
  form's status buttons, the project page's Change status popup, the board's
  columns and the Timeline / Calendar bars all ask it.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Schemas.Assignment
  alias PhoenixKitProjects.Web.Components.AssignmentStatusBadge, as: Badge

  @task %Assignment{status: "todo"}
  @sub %Assignment{status: "todo", child_project_uuid: "01900000-0000-7000-8000-000000000000"}

  test "a task: the four, in progress only while that step is on or the row sits there" do
    assert Badge.choices(@task, %{in_progress: true}) == ~w(waiting todo in_progress done)
    assert Badge.choices(@task, %{in_progress: false}) == ~w(waiting todo done)

    assert Badge.choices(%{@task | status: "in_progress"}, %{in_progress: false}) ==
             ~w(waiting todo in_progress done)
  end

  test "a sub-project following its tasks: only release or hold back before it starts" do
    assert Badge.choices(@sub, %{subproject_auto: true, in_progress: true}) == ~w(waiting todo)
    assert Badge.choices(%{@sub | status: "in_progress"}, %{subproject_auto: true}) == []
    # set by hand, it is a task's
    assert Badge.choices(@sub, %{subproject_auto: false, in_progress: false}) ==
             ~w(waiting todo done)
  end

  test "options are the choices with their names" do
    assert Badge.options(@task, %{in_progress: false}) ==
             Enum.map(~w(waiting todo done), &{Badge.label(&1), &1})
  end

  test "every status has a colour in each place, with the waiting fallback" do
    for status <- ~w(waiting todo in_progress done) do
      for fun <- [:color, :badge_class, :outline_class, :column_class, :bar_color],
          do: assert(is_binary(apply(Badge, fun, [status])))
    end

    assert Badge.column_class("bogus") == Badge.column_class("waiting")
  end
end
