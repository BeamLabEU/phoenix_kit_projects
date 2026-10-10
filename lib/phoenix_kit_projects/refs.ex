defmodule PhoenixKitProjects.Refs do
  @moduledoc """
  The short names people and agents use instead of a uuid: a project's
  **key** (`ANDI`) and a task's **ref** (`ANDI-42` — the key and the
  task's number in that project).

  The uuid stays the identity of every row and stays valid everywhere; a
  ref is a locator on top of it. A project's key can be renamed (the old
  one keeps resolving, see `Projects.project_by_ref/1`), so anything that
  STORES a pointer stores the uuid and shows the ref.

  Designed with a four-seat panel (codex, grok, zai, gemini, 2026-10-10),
  who agreed on: one key per project — a sub-project has its own, because
  it can be moved out or under another project and its refs must not
  change; old keys never handed to another project; numbers per project
  from a counter the database owns (chain V22), never reused; and one
  strict parser — a uuid, a key, or `KEY-number`, nothing looser.

  This module is the pure part: the shape of a key, the parser, and the
  key suggested from a project's name. The lookups live in
  `PhoenixKitProjects.Projects`.
  """

  @min 2
  @max 10

  # Words a URL segment under `/admin/projects/` already means. A key
  # resolves case-insensitively, so `NEW` would be `new`.
  @reserved ~w(NEW LIST EDIT TASKS TEMPLATES OVERVIEW HOURS API SETTINGS ADMIN
               FILES MEMBERS MODULES ACTIVITY BOARD GANTT CALENDAR COMMENTS)

  @key_regex ~r/^[A-Z0-9]{2,10}$/
  @ref_regex ~r/^([A-Za-z0-9]{2,10})-([0-9]{1,9})$/

  @type parsed ::
          {:uuid, String.t()} | {:project, String.t()} | {:task, String.t(), pos_integer()}

  @doc "The shortest and longest a key may be."
  @spec key_length() :: {pos_integer(), pos_integer()}
  def key_length, do: {@min, @max}

  @doc "A key as it is stored and shown: trimmed, upper-cased. `nil` for a blank."
  @spec normalize_key(term()) :: String.t() | nil
  def normalize_key(key) when is_binary(key) do
    case key |> String.trim() |> String.upcase() do
      "" -> nil
      k -> k
    end
  end

  def normalize_key(_), do: nil

  @doc """
  Is `key` (already normalized) a key a project may have: #{@min}–#{@max}
  of `A-Z0-9`, at least one letter (so it never reads as a number), and
  not a word the admin's URLs already use.
  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key) do
    Regex.match?(@key_regex, key) and String.match?(key, ~r/[A-Z]/) and not reserved?(key)
  end

  def valid_key?(_), do: false

  @doc "Is `key` one of the reserved URL words."
  @spec reserved?(String.t()) :: boolean()
  def reserved?(key) when is_binary(key), do: String.upcase(key) in @reserved
  def reserved?(_), do: false

  @doc ~S|A task's ref: `"ANDI-42"`. `nil` when either part is missing.|
  @spec task_ref(String.t() | nil, integer() | nil) :: String.t() | nil
  def task_ref(key, number) when is_binary(key) and is_integer(number), do: "#{key}-#{number}"
  def task_ref(_, _), do: nil

  @doc """
  Reads what somebody typed, pasted or put in a URL: a uuid, a project key
  or a task ref — exactly one of those, in that order, or `:error`. Never a
  uuid prefix, never a bare number, never an external id.
  """
  @spec parse(term()) :: parsed() | :error
  def parse(value) when is_binary(value) do
    value = String.trim(value)

    # The 36-character text form only: `Ecto.UUID.cast/1` also takes any 16
    # raw bytes, which a 16-letter word is.
    case byte_size(value) == 36 && Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:uuid, uuid}
      _ -> parse_ref(value)
    end
  end

  def parse(_), do: :error

  defp parse_ref(value) do
    case Regex.run(@ref_regex, value) do
      [_, key, number] ->
        parse_task(String.upcase(key), String.to_integer(number))

      nil ->
        # Shape first, on what was typed: upcasing "ß" gives "SS", which
        # would pass for a key nobody wrote.
        if Regex.match?(~r/^[A-Za-z0-9]{2,10}$/, value) and key_shaped?(String.upcase(value)),
          do: {:project, String.upcase(value)},
          else: :error
    end
  end

  defp parse_task(key, number) when number > 0 do
    if key_shaped?(key), do: {:task, key, number}, else: :error
  end

  defp parse_task(_key, _number), do: :error

  # The shape only — a reserved word is still looked up (it finds nothing),
  # so an old key that later became reserved would keep resolving.
  defp key_shaped?(key), do: Regex.match?(@key_regex, key) and String.match?(key, ~r/[A-Z]/)

  @doc """
  The key suggested for a project called `name`, free of `taken?` (a
  function saying whether a candidate is already somebody's key or old
  key):

    * a leading acronym is kept — `"ANDI Manager"` → `ANDI`, and a short
      one takes the initials after it: `"3D editor"` → `3DE`;
    * several words give their initials — `"Phoenix Kit"` and
      `"PhoenixKit"` → `PK`;
    * one word gives itself when short, else its first three letters —
      `"Shop"` → `SHOP`, `"Kitchen"` → `KIT`;
    * letters are transliterated first (`"Köök"` → `KOOK`,
      `"Редактор"` → `RED`); a name with nothing usable gives `PRJ`;
    * a taken or reserved key gets the lowest free number glued on
      (`KIT2`).
  """
  @spec suggest_key(String.t() | nil, (String.t() -> boolean())) :: String.t()
  def suggest_key(name, taken? \\ fn _ -> false end) when is_function(taken?, 1) do
    base = name |> base_key() |> ensure_letter() |> pad() |> String.slice(0, @max)
    free(base, taken?)
  end

  defp base_key(name) when is_binary(name) do
    case String.valid?(name) && words(name) do
      false ->
        "PRJ"

      [] ->
        "PRJ"

      [first | rest] = all ->
        cond do
          acronym?(first) and String.length(first) >= 3 -> upcase(first)
          acronym?(first) -> upcase(first) <> initials(rest, @max)
          rest == [] -> one_word(first)
          true -> initials(all, 5)
        end
    end
  end

  defp base_key(_), do: "PRJ"

  # `PhoenixKit` is two words; so is `phoenix_kit` and `phoenix-kit`.
  defp words(name) do
    name
    |> transliterate()
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.split(~r/[^A-Za-z0-9]+/, trim: true)
  end

  # Written in capitals (or digits) by whoever named the project: `ANDI`,
  # `CRM`, `3D`.
  defp acronym?(word) do
    len = String.length(word)
    len >= 2 and len <= 6 and word == String.upcase(word) and not (word =~ ~r/^[0-9]+$/)
  end

  defp one_word(word) do
    word = upcase(word)
    if String.length(word) <= 4, do: word, else: String.slice(word, 0, 3)
  end

  defp initials(words, limit) do
    words |> Enum.take(limit) |> Enum.map_join(&(&1 |> String.first() |> upcase()))
  end

  defp upcase(s), do: String.upcase(s)

  defp ensure_letter(key), do: if(key =~ ~r/[A-Z]/, do: key, else: "P" <> key)
  defp pad(key), do: if(String.length(key) < @min, do: key <> "X", else: key)

  defp free(base, taken?) do
    if usable?(base, taken?) do
      base
    else
      2..9999
      |> Enum.find_value(fn n ->
        suffix = Integer.to_string(n)
        candidate = String.slice(base, 0, @max - String.length(suffix)) <> suffix
        if usable?(candidate, taken?), do: candidate
      end) || random_key(taken?)
    end
  end

  # Every numbered form of the base is taken (some ten thousand projects of
  # one name): a key nobody chose beats no key at all.
  defp random_key(taken?) do
    candidate =
      "P" <>
        (6 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false) |> binary_part(0, 9))

    if usable?(candidate, taken?), do: candidate, else: random_key(taken?)
  end

  defp usable?(key, taken?), do: valid_key?(key) and not taken?.(key)

  @cyrillic %{
    "а" => "a",
    "б" => "b",
    "в" => "v",
    "г" => "g",
    "д" => "d",
    "е" => "e",
    "ё" => "e",
    "ж" => "zh",
    "з" => "z",
    "и" => "i",
    "й" => "i",
    "к" => "k",
    "л" => "l",
    "м" => "m",
    "н" => "n",
    "о" => "o",
    "п" => "p",
    "р" => "r",
    "с" => "s",
    "т" => "t",
    "у" => "u",
    "ф" => "f",
    "х" => "h",
    "ц" => "c",
    "ч" => "ch",
    "ш" => "sh",
    "щ" => "sh",
    "ъ" => "",
    "ы" => "y",
    "ь" => "",
    "э" => "e",
    "ю" => "yu",
    "я" => "ya"
  }

  # Latin letters lose their marks (`ö` → `o`, `š` → `s`); Cyrillic goes
  # through a plain letter map that keeps a word's case; anything else is
  # left for the word splitter to drop.
  defp transliterate(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.graphemes()
    |> Enum.map_join(&cyrillic/1)
  end

  defp cyrillic(grapheme) do
    lower = String.downcase(grapheme)

    case Map.fetch(@cyrillic, lower) do
      {:ok, latin} -> if grapheme == lower, do: latin, else: String.upcase(latin)
      :error -> grapheme
    end
  end
end
