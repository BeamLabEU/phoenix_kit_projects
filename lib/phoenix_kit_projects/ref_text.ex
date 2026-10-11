defmodule PhoenixKitProjects.RefText do
  @moduledoc """
  Short refs in the text people write: `#ANDI-42` instead of the stored
  `#[project_task:018e…|label]`.

  The stored form does not change. A link in text is core's mention token
  (`PhoenixKit.Mentions.Token`) and points at the uuid, which is why a link
  survives a project being renamed or moved. What changes is what a person
  types and reads in an edit box:

    * `expand/1`, on the way IN (every write of a description, see
      `expand_on_write/2`): a `#KEY` or `#KEY-number` that names a real
      project or task becomes its token. Anything else stays the prose it was — a
      `#hashtag`, a ref to nothing, a ref inside `code`.
    * `collapse/1`, on the way OUT to an edit box: the tokens of projects
      and tasks become their short refs again; every other token (a person,
      a client interaction) is left as it is.

  ## Neither direction asks who is looking

  The token `expand/1` writes carries the ref as its label and nothing
  else, so the author's text holds no more than they typed; the title is
  resolved per reader at render, where `ResourceLinks` decides who may see
  it. `collapse/1` shows a ref the text already pointed at. All either
  tells anybody is that such a ref exists, and the numbers are consecutive.

  ## What counts as a ref

  A `#` that starts a word, then a key (2–10 of `A–Z0-9`) and, for a task,
  `-` and its number, then the end of the word. A task ref is read in any
  case (`#andi-42`); a bare project key only as typed in capitals, because
  `#todo` is far more often a tag than a project called TODO. A retired key
  resolves like the current one and the token is labelled with the current
  ref.
  """

  alias PhoenixKit.Mentions.Token
  alias PhoenixKitProjects.{Projects, Refs}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  @types ~w(project project_task)

  # The `#` must start a word: not after a letter or digit, not inside a
  # URL (`/`, `&`, `:`, `.`, `-`), not after another `#` (a Markdown
  # heading), a backslash (escaped), or a Markdown link's text `[#…` or
  # target `](#…`. A ref in plain brackets, `(#ANDI-42)`, is a ref.
  @ref ~r/(?<![\p{L}\p{N}_\/\\#&:.\-\[])(?<!\]\()#([A-Za-z0-9]{2,10})(?:-([0-9]{1,9}))?(?![\p{L}\p{N}_\-])/u

  # Left exactly as written: fenced and inline code.
  @code ~r/```.*?```|`[^`\n]*`/s

  @doc """
  `text` with every short ref that names a real project or task turned
  into its mention token. Text without a `#` (and anything not a binary)
  comes back untouched, with no query made.
  """
  @spec expand(term()) :: term()
  def expand(text) when is_binary(text) do
    if String.contains?(text, "#"), do: outside_tokens(text, &expand_plain/1), else: text
  end

  def expand(other), do: other

  # Splits on the existing tokens (escaped ones included: the pattern takes
  # the backslash with it) and on code, and maps only what lies between.
  defp outside_tokens(text, fun) do
    Token.pattern()
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn piece ->
      if Regex.match?(Token.pattern(), piece), do: piece, else: outside_code(piece, fun)
    end)
  end

  defp outside_code(text, fun) do
    @code
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn piece ->
      if Regex.match?(@code, piece), do: piece, else: fun.(piece)
    end)
  end

  defp expand_plain(text) do
    Regex.replace(@ref, text, fn whole, key, number -> token_for(key, number) || whole end)
  end

  defp token_for(key, "") do
    # A bare key only in capitals (see the moduledoc).
    with true <- key == String.upcase(key),
         {:project, _} <- Refs.parse(key),
         %Project{key: current} = project when is_binary(current) <- Projects.get_project(key),
         {:ok, token} <- Token.to_string(:resource, "project", project.uuid, current) do
      token
    else
      _ -> nil
    end
  end

  defp token_for(key, number) do
    with {:task, _, _} <- Refs.parse("#{key}-#{number}"),
         %Assignment{} = a <- Projects.get_assignment("#{key}-#{number}"),
         ref when is_binary(ref) <- Assignment.row_ref(a),
         {:ok, token} <- Token.to_string(:resource, "project_task", a.uuid, ref) do
      token
    else
      _ -> nil
    end
  end

  @doc """
  `text` with the tokens of projects and tasks shown as their short refs,
  for an edit box. A token whose record is gone, or has no ref, stays a
  token; so does every token when a ref would not read back as the same
  link (it stands against a letter, say) — an edit box must never lose a
  link by being opened and saved.
  """
  @spec collapse(term()) :: term()
  def collapse(text) when is_binary(text) do
    if String.contains?(text, "#[") do
      short = Regex.replace(Token.pattern(), text, &collapse_token/6)
      if targets(expand(short)) == targets(text), do: short, else: text
    else
      text
    end
  end

  def collapse(other), do: other

  # The pattern's groups in order: esc, trigger, type, uuid, label.
  defp collapse_token(whole, "", "#", type, uuid, _label) when type in @types do
    case ref_of(type, uuid) do
      nil -> whole
      ref -> "#" <> ref
    end
  end

  defp collapse_token(whole, _esc, _trigger, _type, _uuid, _label), do: whole

  defp ref_of("project", uuid) do
    case Projects.get_project(uuid) do
      %Project{key: key} when is_binary(key) -> key
      _ -> nil
    end
  end

  defp ref_of("project_task", uuid) do
    case Projects.get_assignment(uuid) do
      %Assignment{} = a -> Assignment.row_ref(a)
      _ -> nil
    end
  end

  defp targets(text), do: text |> Token.parse() |> Enum.map(&{&1.kind, &1.type, &1.uuid})

  @doc """
  Has the refs in a changeset's changed text expanded when it is WRITTEN:
  each of `fields`, and the same fields inside a changed `translations`
  map (`%{lang => %{"description" => …}}`).

  In the changeset because that is the one place every writer of these
  columns passes — a form, the API, an import — and as `prepare_changes`
  because a changeset is also what a form validates with on every
  keystroke: the text in the box must stay what was typed until it is
  saved. A lookup that fails leaves the text as typed; it never fails the
  save.
  """
  @spec expand_on_write(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def expand_on_write(%Ecto.Changeset{} = changeset, fields) when is_list(fields) do
    Ecto.Changeset.prepare_changes(changeset, &expand_changes(&1, fields))
  end

  @doc false
  @spec expand_changes(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def expand_changes(%Ecto.Changeset{} = changeset, fields) when is_list(fields) do
    changeset = Enum.reduce(fields, changeset, &expand_change(&2, &1))

    case Ecto.Changeset.fetch_change(changeset, :translations) do
      {:ok, %{} = translations} ->
        names = Enum.map(fields, &Atom.to_string/1)

        Ecto.Changeset.put_change(
          changeset,
          :translations,
          map_translations(translations, names, &expand/1)
        )

      _ ->
        changeset
    end
  rescue
    _ -> changeset
  end

  defp expand_change(changeset, field) do
    case Ecto.Changeset.fetch_change(changeset, field) do
      {:ok, text} when is_binary(text) ->
        Ecto.Changeset.put_change(changeset, field, expand(text))

      _ ->
        changeset
    end
  end

  @doc """
  A record as an edit form should hold it: `fields`, and the same fields
  in its `translations`, with short refs (`collapse/1`). The form's
  changesets then compare what was typed with what was shown, so an
  untouched description is no change at all.
  """
  @spec collapse_fields(struct(), [atom()]) :: struct()
  def collapse_fields(%{} = record, fields) when is_list(fields) do
    record =
      Enum.reduce(fields, record, fn field, acc ->
        case Map.get(acc, field) do
          text when is_binary(text) -> Map.put(acc, field, collapse(text))
          _ -> acc
        end
      end)

    case Map.get(record, :translations) do
      %{} = translations when map_size(translations) > 0 ->
        names = Enum.map(fields, &Atom.to_string/1)
        Map.put(record, :translations, map_translations(translations, names, &collapse/1))

      _ ->
        record
    end
  rescue
    _ -> record
  end

  defp map_translations(translations, names, fun) do
    Map.new(translations, fn
      {lang, %{} = values} ->
        {lang,
         Map.new(values, fn {name, value} ->
           {name, if(name in names, do: fun.(value), else: value)}
         end)}

      other ->
        other
    end)
  end

  @doc """
  The short ref a `#` pick should put in the text for `type` and `uuid`
  (`"#ANDI-42"`), or nil when it has none and the token is what goes in.
  """
  @spec short(String.t(), String.t()) :: String.t() | nil
  def short(type, uuid) when type in @types and is_binary(uuid) do
    case ref_of(type, uuid) do
      nil -> nil
      ref -> "#" <> ref
    end
  rescue
    _ -> nil
  end

  def short(_type, _uuid), do: nil
end
