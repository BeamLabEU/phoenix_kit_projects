defmodule PhoenixKitProjects.DashboardWidgetsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.DashboardWidgets

  test "phoenix_kit_widgets/0 exposes the same catalog" do
    assert PhoenixKitProjects.phoenix_kit_widgets() == DashboardWidgets.all()
  end

  test "every widget definition is well-formed and its component is loadable" do
    widgets = DashboardWidgets.all()
    assert length(widgets) == 10

    keys = Enum.map(widgets, & &1.key)
    assert "projects.board" in keys
    assert "projects.running" in keys
    assert "projects.upcoming" in keys
    assert "projects.calendar" in keys
    assert "projects.status" in keys
    assert "projects.tasks" in keys
    assert "projects.schedule" in keys
    assert "projects.workload" in keys
    assert "projects.my_tasks" in keys
    assert "projects.deadlines" in keys
    # Globally-namespaced + unique.
    assert Enum.all?(keys, &String.starts_with?(&1, "projects."))
    assert length(Enum.uniq(keys)) == length(keys)

    for w <- widgets do
      assert is_binary(w.name)
      assert w.module_key == "projects"
      assert Code.ensure_loaded?(w.component), "#{inspect(w.component)} not loadable"
      assert function_exported?(w.component, :render, 1)
      # Each declares at least two render views + a valid size.
      assert length(w.views) >= 2
      assert %{w: _, h: _} = w.default_size
      assert is_integer(w.refresh_interval) and w.refresh_interval >= 1000

      # Every view carries its own floor (the improved widget API), the widget
      # min is never above any view's min, and the default fits the largest.
      assert Enum.all?(w.views, &match?(%{min_size: %{w: _, h: _}}, &1))

      for %{min_size: m} <- w.views do
        assert w.min_size.w <= m.w and w.min_size.h <= m.h
        assert w.default_size.w >= m.w or w.default_size.h >= m.h
      end
    end
  end

  test "deadlines supports the employee filter (only_mine) and the pure filter works" do
    widget = Enum.find(DashboardWidgets.all(), &(&1.key == "projects.deadlines"))
    assert Enum.any?(widget.settings_schema, &(&1.key == "only_mine" and &1.type == :boolean))

    rows = [
      %{project: %{uuid: "a"}, planned_end: nil},
      %{project: %{uuid: "b"}, planned_end: nil}
    ]

    alias PhoenixKitProjects.Web.Widgets.DeadlinesWidget
    assert [%{project: %{uuid: "a"}}] = DeadlinesWidget.filter_mine(rows, MapSet.new(["a"]))
    assert [] = DeadlinesWidget.filter_mine(rows, MapSet.new([]))
  end

  test "deadlines only_mine narrows BEFORE the row cap (the viewer's later deadlines survive)" do
    alias PhoenixKitProjects.Web.Widgets.DeadlinesWidget

    # Sorted by nearest deadline: a, b are other people's; c, d are the viewer's.
    rows = for u <- ~w(a b c d), do: %{project: %{uuid: u}, planned_end: nil}
    mine = MapSet.new(["c", "d"])

    # Cap of 2, but the two nearest (a, b) aren't the viewer's — must still surface
    # c, d rather than capping to a, b first and then filtering them all away.
    assert [%{project: %{uuid: "c"}}, %{project: %{uuid: "d"}}] =
             DeadlinesWidget.scope_and_limit(rows, true, mine, 2)

    # only_mine with no resolvable viewer => empty (never leak all).
    assert [] = DeadlinesWidget.scope_and_limit(rows, true, nil, 2)

    # not only_mine => a plain cap, order preserved.
    assert [%{project: %{uuid: "a"}}, %{project: %{uuid: "b"}}] =
             DeadlinesWidget.scope_and_limit(rows, false, nil, 2)
  end

  test "single-project widgets pick their project from a SELECT of {name, uuid}" do
    for key <- ~w(projects.status projects.tasks projects.schedule) do
      widget = Enum.find(DashboardWidgets.all(), &(&1.key == key))
      field = Enum.find(widget.settings_schema, &(&1.key == "project"))
      assert field.type == :select
      # Blank prompt first = "first running project".
      assert [{_prompt, ""} | _] = field.options
    end
  end

  test "single-project widgets accept a project setting" do
    for key <- ~w(projects.status projects.tasks projects.schedule) do
      widget = Enum.find(DashboardWidgets.all(), &(&1.key == key))
      assert Enum.any?(widget.settings_schema, &(&1.key == "project"))
    end
  end
end
