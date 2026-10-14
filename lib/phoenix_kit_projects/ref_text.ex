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

  ## Who is writing

  `expand/1` resolves a ref only for a declared writer (`put_writer/1`,
  held in the process dictionary): the admin pages declare the viewer's
  scope as they mount (`Web.Helpers.assign_embed_user/2`), the API its
  key's reach (`Web.Api.Auth`). A ref to a project the writer cannot open
  stays the text it was — otherwise typing `#SECRET-7` and reading the
  result back would say whether it exists, and hand over its uuid. A
  process that declared nobody (the public portal, a background job)
  expands nothing; trusted code declares `:all`.

  The token carries the ref as its label and nothing else, so the
  author's text holds no more than they typed; the title is resolved per
  reader at render, where `ResourceLinks` decides who may see it.
  `collapse/1` shows a ref the text already pointed at, and only when the
  same writer's `expand/1` would read it back as the same links.

  ## What counts as a ref

  A `#` that starts a word, then a key (2–10 of `A–Z0-9`) and, for a task,
  `-` and its number, then the end of the word. A task ref is read in any
  case (`#andi-42`); a bare project key only as typed in capitals, because
  `#todo` is far more often a tag than a project called TODO. A retired key
  resolves like the current one and the token is labelled with the current
  ref.
  """

  alias PhoenixKit.Mentions.Token
  alias PhoenixKitProjects.{Projects, Refs, ResourceLinks}
  alias PhoenixKitProjects.Schemas.{Assignment, Project}

  @types ~w(project project_task)

  # The `#` must start a word: at the start of the text, or after white
  # space or punctuation that opens or separates (`(`, a quote, `,`, `;`,
  # `>`, emphasis marks, a dash). So not after a letter or digit, not
  # inside a URL (`/`, `?`, `=`, `&`, `:`, `.`), not after another `#` (a
  # Markdown heading), a backslash (escaped), or a Markdown link's text
  # `[#…` or target `](#…`. A ref in plain brackets, `(#ANDI-42)`, is one.
  @ref ~r/(?<![^\s("'“‘«,;>*_~{–—])(?<!\]\()#([A-Za-z0-9]{2,10})(?:-([0-9]{1,9}))?(?![\p{L}\p{N}_\-])/u

  # Left exactly as written: fenced and inline code, and URLs.
  @code ~r/```.*?```|`[^`\n]*`|\bhttps?:\/\/\S+/s

  @writer {__MODULE__, :writer}

  @typedoc """
  Who the text is written by: `:all` (trusted code), `{:scope, scope}` (a
  signed-in viewer, asked through `ResourceLinks.visible_resource_uuids/2`),
  or `{:reach, fun}` where `fun.(project_uuid)` says whether the writer may
  open that project (an API key).
  """
  @type writer :: :all | {:scope, term()} | {:reach, (String.t() -> boolean())} | nil

  @doc "Declares who writes text in this process (see the moduledoc). Returns the writer before."
  @spec put_writer(writer()) :: writer()
  def put_writer(writer), do: Process.put(@writer, writer)

  defp may_link?(uuid, project_uuid) do
    case Process.get(@writer) do
      :all -> true
      {:scope, nil} -> false
      {:scope, scope} -> uuid in ResourceLinks.visible_resource_uuids([uuid], scope: scope)
      {:reach, fun} when is_function(fun, 1) -> fun.(project_uuid) == true
      _ -> false
    end
  rescue
    _ -> false
  end

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
         true <- may_link?(project.uuid, project.uuid),
         {:ok, token} <- Token.to_string(:resource, "project", project.uuid, current) do
      token
    else
      _ -> nil
    end
  end

  defp token_for(key, number) do
    with {:task, _, _} <- Refs.parse("#{key}-#{number}"),
         %Assignment{} = a <- Projects.get_assignment("#{key}-#{number}"),
         true <- may_link?(a.uuid, a.project_uuid),
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
      # Saved again, `short` must give the very text a save of `text` would:
      # the same links at the same places (comparing only the list of
      # targets let a link slide from one occurrence to another).
      if placed(expand(short)) == placed(expand(text)), do: short, else: text
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

  # The text with each token reduced to what it points at: labels differ
  # (a renamed key), the place and the target must not.
  defp placed(text) do
    Regex.replace(Token.pattern(), text, fn _whole, esc, trigger, type, uuid, _label ->
      "\0#{esc}#{trigger}#{type}:#{uuid}\0"
    end)
  end

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
