defmodule PhoenixKitProjects.Outline.Api do
  @moduledoc """
  What the HTTP API needs from a project's outline (`PhoenixKitProjects.Outline`):

    * `info/1` — one read of a project's shape, with what a task's JSON says
      about its place in it (its parent's ref, its depth, "3 of 7" for what
      is under it, the refs directly under it);
    * `batch_create/4` — many one-off tasks from lines of text in one
      transaction, nested by depth, placed under a task or at the top level.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitProjects.Outline
  alias PhoenixKitProjects.PubSub, as: ProjectsPubSub
  alias PhoenixKitProjects.Refs
  alias PhoenixKitProjects.Schemas.{Assignment, Project, Task}

  @max_lines 500
  @title_max 500

  @type info :: %{
          key: String.t() | nil,
          rows: [map()],
          by_uuid: %{binary() => map()},
          depths: %{binary() => non_neg_integer()},
          counts: %{binary() => %{done: non_neg_integer(), total: non_neg_integer()}},
          children: %{binary() => [map()]}
        }

  defp repo, do: RepoHelper.repo()

  @doc "The most lines one batch may carry."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc """
  A project's accepted rows in outline order, read once, with the lookups a
  list of task JSON needs. Pass it to `Json.task/5` for every row of a list;
  a single task builds its own.
  """
  @spec info(binary()) :: info()
  def info(project_uuid) when is_binary(project_uuid) do
    rows =
      from(a in Assignment,
        where: a.project_uuid == ^project_uuid and a.review_status == "accepted",
        order_by: [asc: a.position, asc: a.inserted_at],
        select: %{
          uuid: a.uuid,
          parent_uuid: a.parent_uuid,
          status: a.status,
          number: a.number,
          position: a.position,
          child_project_uuid: a.child_project_uuid
        }
      )
      |> repo().all()

    present = MapSet.new(rows, & &1.uuid)

    %{
      key: repo().one(from(p in Project, where: p.uuid == ^project_uuid, select: p.key)),
      rows: rows,
      by_uuid: Map.new(rows, &{&1.uuid, &1}),
      depths: Outline.depths(rows),
      counts: Outline.counts(rows),
      children:
        rows
        |> Enum.filter(&(&1.parent_uuid && MapSet.member?(present, &1.parent_uuid)))
        |> Enum.group_by(& &1.parent_uuid)
    }
  end

  @doc "What a task's JSON says about its place: `parent_task`, `depth`, `subtasks`."
  @spec place(info(), Assignment.t()) :: map()
  def place(info, %Assignment{uuid: uuid, parent_uuid: parent_uuid}) do
    %{
      parent_task: ref_of(info, parent_uuid),
      depth: Map.get(info.depths, uuid, 0),
      subtasks: Map.get(info.counts, uuid, %{done: 0, total: 0})
    }
  end

  @doc "The refs of the tasks directly under `uuid`, in order."
  @spec subtask_refs(info(), binary()) :: [String.t()]
  def subtask_refs(info, uuid) do
    info.children
    |> Map.get(uuid, [])
    |> Enum.map(&ref_of(info, &1.uuid))
    |> Enum.reject(&is_nil/1)
  end

  defp ref_of(_info, nil), do: nil

  defp ref_of(info, uuid) do
    case Map.get(info.by_uuid, uuid) do
      %{number: number} -> Refs.task_ref(info.key, number)
      nil -> nil
    end
  end

  @doc """
  The status of every accepted row, by uuid — taken before and after a
  transition to say how many OTHER rows it moved (`changed_besides/3`).
  """
  @spec statuses(binary()) :: %{binary() => String.t()}
  def statuses(project_uuid) do
    from(a in Assignment,
      where: a.project_uuid == ^project_uuid and a.review_status == "accepted",
      select: {a.uuid, a.status}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc "How many rows other than `uuid` have a different status in `after_` than in `before`."
  @spec changed_besides(map(), map(), binary()) :: non_neg_integer()
  def changed_besides(before, after_, uuid) do
    Enum.count(after_, fn {id, status} -> id != uuid and Map.get(before, id, status) != status end)
  end

  @doc """
  Reads the `lines` of a batch: each a string or `%{"text", "depth", "done"}`.
  Blank lines are dropped. `{:ok, [%{text, depth, done}]}`, or `{:error,
  reason}` — `:not_a_list`, `:empty`, `:too_many`, `{:bad_line, index}`.
  """
  @spec read_lines(term()) :: {:ok, [map()]} | {:error, term()}
  def read_lines(lines) when is_list(lines) and length(lines) > @max_lines,
    do: {:error, :too_many}

  def read_lines(lines) when is_list(lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {line, index}, acc ->
      case read_line(line) do
        {:ok, nil} -> {:cont, acc}
        {:ok, entry} -> {:cont, [entry | acc]}
        :error -> {:halt, {:error, {:bad_line, index}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      [] -> {:error, :empty}
      entries -> {:ok, Enum.reverse(entries)}
    end
  end

  def read_lines(_), do: {:error, :not_a_list}

  defp read_line(text) when is_binary(text), do: read_line(%{"text" => text})

  defp read_line(%{"text" => text} = line) when is_binary(text) do
    depth = Map.get(line, "depth", 0)
    done = Map.get(line, "done", false)
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    cond do
      not (is_integer(depth) and depth >= 0 and depth <= 100) -> :error
      done not in [true, false] -> :error
      String.length(text) > @title_max -> :error
      text == "" -> {:ok, nil}
      true -> {:ok, %{text: text, depth: depth, done: done}}
    end
  end

  defp read_line(_), do: :error

  @doc """
  Creates one one-off task per line, in one transaction under the project
  lock: nested by `depth` (0 sits under `parent_uuid`, or at the top level
  when that is nil; a depth more than one below the line above is pulled up
  to it), placed after everything already under that parent — or at the end
  of the project. One `:assignment_reordered` broadcast after commit.

  Options: `:actor_uuid`, `:key_uuid` (stamped as creator and as whose words
  the titles are). Returns `{:ok, [uuid]}` in line order, `{:error,
  :not_found}` (no project, or the parent is not an accepted task of it),
  or `{:error, {:line, index, changeset}}`.
  """
  @spec batch_create(binary(), [map()], binary() | nil, keyword()) ::
          {:ok, [binary()]} | {:error, term()}
  def batch_create(project_uuid, lines, parent_uuid, opts \\ []) when is_list(lines) do
    result =
      Outline.with_project_lock(project_uuid, fn _project ->
        rows = Outline.shape(project_uuid)

        if parent_uuid && not Enum.any?(rows, &(&1.uuid == parent_uuid)),
          do: repo().rollback(:not_found)

        created = insert_lines(project_uuid, lines, opts)
        block = nest(created, parent_uuid)

        # After the last row under the parent; with no parent, at the end.
        anchor =
          case parent_uuid && rows |> Outline.descendants(parent_uuid) |> List.last() do
            nil -> parent_uuid
            last -> last.uuid
          end

        existing =
          rows |> Outline.walk() |> Enum.map(fn {row, _depth} -> {row.uuid, row.parent_uuid} end)

        Outline.write_order(project_uuid, place_after(existing, anchor, block))

        # An open task now sits under a done one: that one reopens.
        reopen_parent(block, created, parent_uuid)

        Enum.map(created, & &1.uuid)
      end)

    with {:ok, uuids} <- result do
      ProjectsPubSub.broadcast_assignment(:assignment_reordered, %{project_uuid: project_uuid})
      {:ok, uuids}
    end
  end

  defp created_open?(created, uuid),
    do: Enum.any?(created, &(&1.uuid == uuid and not &1.done))

  defp insert_lines(project_uuid, lines, opts) do
    actor_uuid = Keyword.get(opts, :actor_uuid)
    key_uuid = Keyword.get(opts, :key_uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      task = insert!(index, Task.changeset(%Task{}, %{"title" => line.text, "ad_hoc" => true}))

      assignment =
        insert!(
          index,
          Assignment.status_changeset(%Assignment{}, %{
            "project_uuid" => project_uuid,
            "task_uuid" => task.uuid,
            "status" => if(line.done, do: "done", else: "waiting"),
            "progress_pct" => if(line.done, do: 100, else: 0),
            "completed_at" => if(line.done, do: now),
            "completed_by_uuid" => if(line.done, do: actor_uuid),
            "created_by_uuid" => actor_uuid,
            "created_by_key_uuid" => key_uuid,
            "words_by_key_uuid" => key_uuid
          })
        )

      %{uuid: assignment.uuid, depth: line.depth, done: line.done}
    end)
  end

  defp insert!(index, changeset) do
    case repo().insert(changeset) do
      {:ok, record} -> record
      {:error, cs} -> repo().rollback({:line, index, cs})
    end
  end

  # Lines → `[{uuid, parent_uuid}]`: a line sits under the nearest line
  # above it that is one level shallower; depth 0 sits under `base`.
  defp nest(created, base) do
    {order, _stack} =
      Enum.map_reduce(created, [], fn line, stack ->
        stack = Enum.take(stack, min(line.depth, length(stack)))
        parent = List.last(stack) || base
        {{line.uuid, parent}, stack ++ [line.uuid]}
      end)

    order
  end

  defp reopen_parent(_block, _created, nil), do: :ok

  defp reopen_parent(block, created, parent_uuid) do
    open =
      Enum.find(block, fn {uuid, parent} ->
        parent == parent_uuid and created_open?(created, uuid)
      end)

    with {uuid, _} <- open,
         %Assignment{} = a <- repo().get(Assignment, uuid),
         do: Outline.settle_placed(a)

    :ok
  end

  # The new block right after `anchor` (at the end with no anchor).
  defp place_after(existing, nil, block), do: existing ++ block

  defp place_after(existing, anchor, block) do
    Enum.flat_map(existing, fn {uuid, _} = item ->
      if uuid == anchor, do: [item | block], else: [item]
    end)
  end
end
