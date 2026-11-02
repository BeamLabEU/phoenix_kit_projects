defmodule PhoenixKitProjects.Changes do
  @moduledoc """
  What one save changed, for the history (the boss, 2026-10-31: "All he saw
  was that the boss changed the task … It needs to show what was changed,
  from what to what").

  `assignment/3` and `project/3` compare the record before and after a save
  and give the fields that differ as a list stored in the activity row's
  `metadata["changes"]`:

      [%{"field" => "deadline", "from" => "2026-11-03T09:00:00Z", "to" => "2026-11-05T09:00:00Z"}]

  Values are stored raw — ISO dates and instants, status and priority
  slugs, minutes — and put into words when the history is read, in the
  viewer's language and time zone (`PhoenixKitProjects.Web.Components.HistoryFeed`).
  A text (a description) is kept as a short excerpt of each side, never
  whole. Status, assignee and waiting-on changes have rows of their own and
  are left out here.
  """

  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  @excerpt 160

  @assignment_fields ~w(deadline start_date end_date start_time end_time estimate
                        priority progress_pct repeat_rule counts_weekends)a

  @project_fields ~w(name description start_mode scheduled_start_date counts_weekends
                     external_url external_label completion)a

  @doc """
  The fields of a task that one save changed. `opts`: `:title` — `{was, now}`
  of the task's name (kept on the library task, not the row), `:description`
  — `{was, now}` when the words were saved apart from the row.
  """
  @spec assignment(Assignment.t(), Assignment.t(), keyword()) :: [map()]
  def assignment(%Assignment{} = was, %Assignment{} = now, opts \\ []) do
    title = Keyword.get(opts, :title)

    description =
      Keyword.get(opts, :description) || {was.description, now.description}

    [text_change("title", title, :whole), text_change("description", description, :excerpt)]
    |> Kernel.++(Enum.map(@assignment_fields, &field_change(&1, was, now)))
    |> Enum.reject(&is_nil/1)
  end

  @doc "The fields of a project (or a sub-project's own project) that one save changed."
  @spec project(Project.t(), Project.t(), keyword()) :: [map()]
  def project(%Project{} = was, %Project{} = now, _opts \\ []) do
    @project_fields
    |> Enum.map(&project_change(&1, was, now))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Several saves of one visit as one list (oldest first): each field from
  where it started to where it ended; a field that came back to where it
  started is left out.
  """
  @spec merge([[map()]]) :: [map()]
  def merge(lists) do
    lists
    |> List.flatten()
    |> Enum.reduce({[], %{}}, fn %{"field" => f} = c, {order, acc} ->
      case acc do
        %{^f => first} -> {order, Map.put(acc, f, %{first | "to" => c["to"]})}
        _ -> {order ++ [f], Map.put(acc, f, c)}
      end
    end)
    |> then(fn {order, acc} -> Enum.map(order, &acc[&1]) end)
    |> Enum.reject(&(&1["from"] == &1["to"]))
  end

  # ── Fields ──────────────────────────────────────────────────────────

  defp field_change(:estimate, was, now) do
    from = estimate(was)
    to = estimate(now)
    if from != to, do: %{"field" => "estimate", "from" => from, "to" => to}
  end

  defp field_change(:repeat_rule, was, now) do
    if blank_map(was.repeat_rule) != blank_map(now.repeat_rule),
      do: %{
        "field" => "repeat_rule",
        "from" => blank_map(was.repeat_rule),
        "to" => blank_map(now.repeat_rule)
      }
  end

  defp field_change(field, was, now) do
    from = raw(Map.get(was, field))
    to = raw(Map.get(now, field))
    if from != to, do: %{"field" => to_string(field), "from" => from, "to" => to}
  end

  defp project_change(:completion, was, now) do
    from = Project.completion(was)
    to = Project.completion(now)
    if from != to, do: %{"field" => "completion", "from" => from, "to" => to}
  end

  defp project_change(:description, was, now),
    do: text_change("description", {was.description, now.description}, :excerpt)

  defp project_change(:name, was, now), do: text_change("name", {was.name, now.name}, :whole)

  defp project_change(field, was, now) do
    from = raw(Map.get(was, field))
    to = raw(Map.get(now, field))
    if from != to, do: %{"field" => to_string(field), "from" => from, "to" => to}
  end

  defp text_change(_field, nil, _how), do: nil

  defp text_change(field, {was, now}, how) do
    from = trimmed(was)
    to = trimmed(now)

    cond do
      from == to -> nil
      how == :excerpt -> %{"field" => field, "from" => excerpt(from), "to" => excerpt(to)}
      true -> %{"field" => field, "from" => from, "to" => to}
    end
  end

  defp estimate(%{estimated_duration: n, estimated_duration_unit: unit}) when is_integer(n),
    do: "#{n} #{unit || "hours"}"

  defp estimate(_), do: nil

  defp raw(nil), do: nil
  defp raw(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp raw(%NaiveDateTime{} = v), do: NaiveDateTime.to_iso8601(v)
  defp raw(%Date{} = v), do: Date.to_iso8601(v)
  defp raw(%Time{} = v), do: v |> Time.truncate(:second) |> Time.to_iso8601()
  defp raw(v) when is_binary(v), do: trimmed(v)
  defp raw(v) when is_boolean(v) or is_number(v), do: v
  defp raw(v) when is_atom(v), do: to_string(v)
  defp raw(_), do: nil

  defp blank_map(m) when is_map(m) and map_size(m) > 0, do: m
  defp blank_map(_), do: nil

  defp trimmed(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp trimmed(_), do: nil

  defp excerpt(nil), do: nil

  defp excerpt(text) do
    plain =
      text
      |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/u, "🖼")
      |> String.replace(~r/<img[^>]*>/u, "🖼")
      |> String.replace(~r/[*_`#>]+/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if String.length(plain) > @excerpt,
      do: String.slice(plain, 0, @excerpt) <> "…",
      else: plain
  end
end
