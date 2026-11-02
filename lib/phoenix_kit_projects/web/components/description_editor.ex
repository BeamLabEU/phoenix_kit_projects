defmodule PhoenixKitProjects.Web.Components.DescriptionEditor do
  @moduledoc """
  A description written in the Leaf rich-text editor, as the comments'
  composer writes them (the boss's list, item 6): bold, lists, links, and
  `@` people and `#` records offered as they are typed — the mentions the
  plain textarea offered.

  ## In a form

  The editor syncs its markdown into a hidden input of the form under the
  field's own name (`sync_input_name`), so a save posts it like the textarea
  did; its keystrokes also arrive as `{:leaf_changed, …}` messages, which
  `changed/1` reads, so a form that saves as it is changed keeps doing so.
  Leaf only honours its content on the first render, so the editor's id
  carries the language (`editor_id/2`): a language switch mounts a fresh
  one with that language's text.

      <.description_editor
        id={DescriptionEditor.editor_id("assignment-description", @current_lang)}
        name={DescriptionEditor.field_name("assignment", @current_lang, @primary_language, @multilang_enabled)}
        value={…}
        label={gettext("Description")}
        mention_context={…}
      />

      def handle_info({:leaf_changed, _} = msg, socket) do
        case DescriptionEditor.changed(msg) do
          {"assignment-description", lang, markdown} -> …
          _ -> {:noreply, socket}
        end
      end

      def handle_info({:leaf_suggest, _} = msg, socket),
        do: {:noreply, DescriptionEditor.suggest(socket, msg)}

  `uploads: true` turns on pasted and inserted images (`{:leaf_paste_image,
  …}` / `{:leaf_insert_request, …}`): the host stores them and answers with
  `insert_image/3`, so the text holds the stored file's address, never the
  picture itself.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  alias Phoenix.LiveView
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers
  alias PhoenixKitProjects.Web.Mentions

  @doc "The editor's id for one language: `<base>--<lang>` (a code may hold a dash)."
  @spec editor_id(String.t(), String.t() | nil) :: String.t()
  def editor_id(base, lang), do: "#{base}--#{lang || "default"}"

  @doc """
  The field the description posts under: the primary column on the primary
  language's tab (or with one language), the translations map otherwise —
  what `<.translatable_field>` names it.
  """
  @spec field_name(String.t(), String.t() | nil, String.t() | nil, boolean()) :: String.t()
  def field_name(prefix, lang, primary, multilang?) do
    if multilang? and is_binary(lang) and lang != primary,
      do: "#{prefix}[translations][#{lang}][description]",
      else: "#{prefix}[description]"
  end

  @doc """
  A `{:leaf_changed, …}` message as `{base, lang, markdown}` for an editor
  made with `editor_id/2`, or nil.
  """
  @spec changed(term()) :: {String.t(), String.t(), String.t()} | nil
  def changed({:leaf_changed, %{editor_id: id, markdown: markdown}}) when is_binary(id) do
    case String.split(id, "--", parts: 2) do
      [base, lang] -> {base, lang, markdown || ""}
      _ -> nil
    end
  end

  def changed(_), do: nil

  @doc """
  The `@` and `#` suggestions for a `{:leaf_suggest, …}` message: the same
  search the textarea's typeahead used (`Web.Mentions`), answered back to
  the editor. `context` narrows `#` to a project (`%{"project" => uuid}`).
  """
  @spec suggest(LiveView.Socket.t(), term(), map() | nil) :: LiveView.Socket.t()
  def suggest(socket, msg, context \\ nil)

  def suggest(
        socket,
        {:leaf_suggest, %{editor_id: id, trigger: trigger, query: query, seq: seq}},
        context
      )
      when trigger in ["@", "#"] do
    reply =
      Mentions.search_reply(socket, %{
        "kind" => if(trigger == "@", do: "user", else: "resource"),
        "query" => query || "",
        "context" => context
      })

    results =
      Enum.map(reply.results, fn r ->
        %{value: r.token, label: r.title, sublabel: r.subtitle}
      end)

    LiveView.send_update(Leaf,
      id: id,
      action: :suggestions,
      trigger: trigger,
      query: query,
      seq: seq,
      results: results
    )

    socket
  rescue
    _ -> socket
  end

  def suggest(socket, _msg, _context), do: socket

  @doc "Places a stored image in the editor at the cursor."
  @spec insert_image(String.t(), String.t(), String.t()) :: :ok
  def insert_image(editor_id, url, alt \\ "") do
    LiveView.send_update(Leaf, id: editor_id, action: :insert_image, url: url, alt: alt)
    :ok
  end

  @doc """
  The editor inside a form. `name` is the field's name; `value` its
  markdown. The hidden input is drawn here, so a re-render keeps it and the
  form posts it even when the editor was not touched.
  """
  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:value, :string, default: nil)

  attr(:content, :string,
    default: nil,
    doc:
      "what the editor shows, when it differs from `value` (pictures by address); `value` otherwise"
  )

  attr(:label, :string, default: nil)
  attr(:placeholder, :string, default: nil)
  attr(:mention_context, :any, default: nil, doc: "a JSON string or map narrowing `#`")
  attr(:uploads, :boolean, default: false)

  attr(:image_button, :boolean,
    default: nil,
    doc: "the toolbar's image button (default: with `uploads`)"
  )

  attr(:readonly, :boolean, default: false)
  attr(:height, :string, default: "180px")
  attr(:class, :any, default: nil)

  def description_editor(assigns) do
    assigns =
      assign(assigns,
        value: assigns.value || "",
        content: assigns.content || assigns.value || "",
        image_button:
          if(is_nil(assigns.image_button), do: assigns.uploads, else: assigns.image_button),
        suggestions: [
          %{
            trigger: "@",
            min_chars: 0,
            max_results: 8,
            keep_trigger: false,
            label: gettext("People")
          },
          %{
            trigger: "#",
            min_chars: 1,
            max_results: 8,
            keep_trigger: false,
            label: gettext("Records")
          }
        ]
      )

    ~H"""
    <%!-- Leaf's footer ("0 words · 0 chars · 0 min read") is hidden: on a
         description it is clutter, and Leaf writes it in English from its
         own JS with no option to drop it or translate it (the
         walk-through, 2026-10-31). --%>
    <div
      class={["flex flex-col gap-1 [&_div:has(>[data-editor-footer])]:hidden", @class]}
      data-description-editor={@id}
    >
      <span :if={@label} class="label mb-1"><span class="font-semibold">{@label}</span></span>
      <input type="hidden" name={@name} value={@value} data-leaf-sync-input={@id} />
      <.live_component
        module={Leaf}
        id={@id}
        content={@content}
        mode={:visual}
        preset={:simple}
        toolbar={if @image_button, do: [:image], else: []}
        placeholder={@placeholder || ""}
        height={@height}
        min_height="120px"
        debounce={400}
        readonly={@readonly}
        sync_input_name={@name}
        upload_handler={if @uploads, do: :host}
        emit_events={@uploads}
        suggestions={@suggestions}
        loading_text={nil}
      />
    </div>
    """
  end

  @doc """
  The description a form holds for the language whose tab is open: the
  primary column, or that language's translation.
  """
  @spec description_value(Phoenix.HTML.Form.t(), String.t() | nil, String.t() | nil, boolean()) ::
          String.t() | nil
  def description_value(form, lang, primary, multilang?) do
    if multilang? and is_binary(lang) and lang != primary,
      do: WebHelpers.lang_data(form, lang)["description"],
      else: form[:description].value
  end

  @doc """
  The params a changed description stands for: `%{"description" => md}` on
  the primary language's tab, `%{"translations" => %{lang => %{"description"
  => md}}}` otherwise — merged by the form as a posted field would be.
  """
  @spec params(String.t(), String.t() | nil, String.t() | nil, boolean()) :: map()
  def params(markdown, lang, primary, multilang?) do
    if multilang? and is_binary(lang) and lang != primary,
      do: %{"translations" => %{lang => %{"description" => markdown}}},
      else: %{"description" => markdown}
  end

  @doc "A mention context as the search takes it: a JSON string decoded."
  @spec decode_context(term()) :: map() | nil
  def decode_context(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> nil
    end
  end

  def decode_context(%{} = map), do: map
  def decode_context(_), do: nil
end
