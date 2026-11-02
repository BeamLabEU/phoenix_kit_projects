defmodule PhoenixKitProjects.LibrarySearch do
  @moduledoc """
  The task library searched as a title is typed — the suggestions under a
  new task's title (the card list's draft row; the add-task popup can ask
  the same) — and browsed in the add-task form's "From library" picker
  (item 27, the panel's proposal Max approved on 2026-10-31): `filter/3`
  (diacritic-insensitive, title first, then description), the viewer's
  `recent/1` adds, the site's `often_used/2`, and the whole library
  `alphabetical/2` under letter headings.

  Only the reusable library: a project's one-off tasks (`ad_hoc`) belong to
  that project, and another project's titles must not surface here (Max,
  2026-10-31: "we shouldn't do cross-project stuff. The library being a
  source is good enough").
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitProjects.Schemas.{Assignment, Task}

  require Logger

  @default_limit 6
  @min_length 2

  @doc """
  Library tasks whose title (in any language) contains `query`, the ones
  that start with it first, then the shorter titles. Fewer than two
  characters ask for nothing (`[]`).

  Options: `:limit` (default #{@default_limit}), `:exclude` — task uuids to
  leave out.
  """
  @spec suggest(String.t() | nil, keyword()) :: [Task.t()]
  def suggest(query, opts \\ [])

  def suggest(query, opts) when is_binary(query) do
    q = query |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(q) < @min_length do
      []
    else
      run(q, Keyword.get(opts, :limit, @default_limit), List.wrap(Keyword.get(opts, :exclude)))
    end
  end

  def suggest(_query, _opts), do: []

  defp run(q, limit, exclude) do
    escaped = escape_like(q)
    contains = "%" <> escaped <> "%"
    prefix = escaped <> "%"

    from(t in Task,
      where: t.ad_hoc == false,
      where:
        ilike(t.title, ^contains) or
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_each(?) AS tr WHERE tr.value->>'title' ILIKE ?)",
            t.translations,
            ^contains
          ),
      order_by: [
        asc: fragment("CASE WHEN ? ILIKE ? THEN 0 ELSE 1 END", t.title, ^prefix),
        asc: fragment("length(?)", t.title),
        asc: t.title
      ],
      limit: ^limit
    )
    |> exclude_uuids(exclude)
    |> RepoHelper.repo().all()
  rescue
    e ->
      # Suggestions are a help, never a reason for the title box to fail.
      Logger.warning("[Projects.LibrarySearch] suggest failed: #{Exception.message(e)}")
      []
  end

  defp exclude_uuids(query, []), do: query
  defp exclude_uuids(query, uuids), do: where(query, [t], t.uuid not in ^uuids)

  defp escape_like(q) do
    q
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ── The "From library" picker ───────────────────────────────────────

  @doc """
  `text` for comparing: lower-cased, accents and other combining marks
  dropped, runs of space as one — "Mõõtmine" and "mootmine" fold alike.
  """
  @spec fold(String.t() | nil) :: String.t()
  def fold(text) when is_binary(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def fold(_), do: ""

  @doc """
  The library `tasks` matching `query`, diacritic-insensitive: titles (in
  `lang`, or any language) that start with it, then titles that contain
  it, then the tasks whose description contains it. A blank query is `[]`.
  """
  @spec filter([Task.t()], String.t() | nil, String.t() | nil) :: [Task.t()]
  def filter(tasks, query, lang) do
    case fold(query) do
      "" ->
        []

      q ->
        tasks
        |> Enum.map(&{rank(&1, q, lang), &1})
        |> Enum.reject(fn {r, _} -> is_nil(r) end)
        |> Enum.sort_by(fn {r, t} -> {r, sort_key(Task.localized_title(t, lang), lang)} end)
        |> Enum.map(&elem(&1, 1))
    end
  end

  defp rank(task, q, lang) do
    titles = Enum.map(titles(task, lang), &fold/1)

    cond do
      Enum.any?(titles, &String.starts_with?(&1, q)) -> 0
      Enum.any?(titles, &String.contains?(&1, q)) -> 1
      Enum.any?(descriptions(task, lang), &String.contains?(fold(&1), q)) -> 2
      true -> nil
    end
  end

  defp titles(%Task{} = task, lang),
    do: Enum.uniq([Task.localized_title(task, lang), task.title | translated(task, "title")])

  defp descriptions(%Task{} = task, lang),
    do:
      [Task.localized_description(task, lang), task.description | translated(task, "description")]
      |> Enum.filter(&is_binary/1)

  defp translated(%Task{translations: tr}, field) when is_map(tr),
    do: for({_lang, %{} = fields} <- tr, is_binary(fields[field]), do: fields[field])

  @doc """
  The library under letter headings, A–Z by the title in `lang`:
  `[{"A", [task]}, …]`. In Estonian Õ Ä Ö Ü come after W, as in its
  alphabet; elsewhere a letter with an accent sits with its base letter.
  Titles starting with no letter come first, under "#".
  """
  @spec alphabetical([Task.t()], String.t() | nil) :: [{String.t(), [Task.t()]}]
  def alphabetical(tasks, lang) do
    tasks
    |> Enum.sort_by(&sort_key(Task.localized_title(&1, lang), lang))
    |> Enum.chunk_by(&heading(Task.localized_title(&1, lang), lang))
    |> Enum.map(fn [first | _] = group ->
      {heading(Task.localized_title(first, lang), lang), group}
    end)
  end

  @estonian_after_w %{"õ" => 1, "ä" => 2, "ö" => 3, "ü" => 4}

  defp heading(title, lang) do
    first = title |> to_string() |> String.trim() |> String.first() |> to_string()
    lower = String.downcase(first)

    cond do
      estonian?(lang) and Map.has_key?(@estonian_after_w, lower) -> String.upcase(first)
      fold(first) =~ ~r/^\p{L}$/u -> String.upcase(fold(first))
      true -> "#"
    end
  end

  # A list of integers per character: the letter's place, with Estonian's
  # four after "w"; the folded title breaks ties.
  defp sort_key(title, lang) do
    text = title |> to_string() |> String.trim() |> String.downcase()
    est? = estonian?(lang)

    weights =
      text
      |> String.graphemes()
      |> Enum.map(fn g ->
        case est? && Map.get(@estonian_after_w, g) do
          n when is_integer(n) -> ?w * 10 + n
          _ -> char_weight(fold(g))
        end
      end)

    first_is_letter? = heading(title, lang) != "#"
    {if(first_is_letter?, do: 1, else: 0), weights, fold(text)}
  end

  defp char_weight(<<c::utf8, _::binary>>), do: c * 10
  defp char_weight(_), do: 0

  defp estonian?(lang) when is_binary(lang), do: String.starts_with?(lang, "et")
  defp estonian?(_), do: false

  @doc """
  The library tasks added to projects most often across the site — counted
  from the projects' rows that name them (template rows included) — most
  first, at most `limit`: `[task_uuid]`.
  """
  @spec often_used([String.t()], pos_integer()) :: [String.t()]
  def often_used(task_uuids, limit \\ 8)

  def often_used([], _limit), do: []

  def often_used(task_uuids, limit) do
    from(a in Assignment,
      where: a.task_uuid in ^task_uuids,
      group_by: a.task_uuid,
      having: count(a.uuid) > 1,
      order_by: [desc: count(a.uuid), asc: a.task_uuid],
      limit: ^limit,
      select: a.task_uuid
    )
    |> RepoHelper.repo().all()
  rescue
    e ->
      Logger.warning("[Projects.LibrarySearch] often_used failed: #{Exception.message(e)}")
      []
  end

  @recent_key "projects_recent_library_tasks"
  @recent_cap 8

  @doc "The `custom_fields` key the viewer's recently added library tasks live under."
  @spec recent_key() :: String.t()
  def recent_key, do: @recent_key

  @doc "The library tasks `user` added lately, newest first: `[task_uuid]`."
  @spec recent(User.t() | String.t() | nil) :: [String.t()]
  def recent(%User{custom_fields: %{@recent_key => uuids}}) when is_list(uuids),
    do: Enum.filter(uuids, &is_binary/1)

  def recent(%User{}), do: []

  def recent(user_uuid) when is_binary(user_uuid) do
    case Auth.get_user(user_uuid) do
      %User{} = user -> recent(user)
      _ -> []
    end
  rescue
    _ -> []
  end

  def recent(_), do: []

  @doc """
  Remembers that `user_uuid` added the library tasks `task_uuids` (in that
  order): they go first in their list, once each, at most #{@recent_cap}
  kept. Written with `Auth.merge_user_custom_fields/3` (this one key, every
  other left as it is). Never raises.
  """
  @spec remember(String.t() | nil, [String.t()]) :: :ok
  def remember(user_uuid, task_uuids) when is_binary(user_uuid) and is_list(task_uuids) do
    with [_ | _] <- task_uuids,
         %User{} = user <- Auth.get_user(user_uuid) do
      newest = task_uuids |> Enum.reverse() |> Enum.uniq()
      list = Enum.take(newest ++ (recent(user) -- newest), @recent_cap)

      _ =
        Auth.merge_user_custom_fields(user, %{@recent_key => list},
          ensure_definitions: false,
          broadcast: false
        )
    end

    :ok
  rescue
    e ->
      Logger.warning("[Projects.LibrarySearch] remembering adds failed: #{Exception.message(e)}")
      :ok
  end

  def remember(_user_uuid, _task_uuids), do: :ok
end
