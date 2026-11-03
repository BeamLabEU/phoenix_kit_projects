defmodule PhoenixKitProjects.Web.Components.RichText do
  @moduledoc """
  A description as it was written in the Leaf editor: formatted — bold,
  lists, links, images — with its `@` and `#` mentions resolved for the
  viewer as `<.mention_text>` resolves them (a link, a lock, or the label).

      <.rich_text text={Assignment.localized_description(a, lang)} scope={@phoenix_kit_current_scope} />
      <.rich_text text={…} scope={…} compact />   <%!-- a row or a card: smaller, clamped --%>

  The markdown is rendered with MDEx and the comments' options (hard line
  breaks, so a description written before the editor — plain text with
  newlines — reads exactly as it did) and sanitised by MDEx's allow-list:
  the text is whatever the person typed, so nothing it carries is trusted.
  Mentions are taken out before the render and put back after it, each as
  `<.mention_text>` draws it, so a token's brackets never reach markdown.
  The text's own pictures (`pkfile:` references, `InlineImages`) are
  resolved first, for the viewer.
  """

  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Mentions
  alias PhoenixKit.Mentions.Token
  alias PhoenixKitProjects.InlineImages
  alias PhoenixKitWeb.Components.Core.MentionText

  # MDEx's allow-list keeps `class` and `style` on `div`, `span`, `code`
  # and `pre`: a writer could pin a `position:fixed` box (or the host's
  # `fixed inset-0` classes) over every viewer's page, a sign-in look-alike
  # on the task list. A description styles nothing, so both come off.
  @render_opts [
    render: [hardbreaks: true, unsafe: true],
    sanitize:
      Keyword.put(
        MDEx.Document.default_sanitize_options(),
        :rm_tag_attributes,
        Map.new(~w(div span code pre), &{&1, ~w(class style)})
      )
  ]

  attr(:text, :string, default: nil)
  attr(:scope, :any, default: nil, doc: "the viewer — decides what each mention resolves to")

  attr(:holder, :any,
    default: nil,
    doc: "the record the text belongs to — whose pictures it shows (`InlineImages`)"
  )

  attr(:urls, :map,
    default: nil,
    doc: "pictures already read for a list (`InlineImages.urls_for/3`), so a row reads none"
  )

  attr(:compact, :boolean,
    default: false,
    doc: "smaller text and three lines at most (rows, cards)"
  )

  attr(:allow_request, :boolean, default: true)
  attr(:class, :any, default: nil)

  def rich_text(%{text: text} = assigns) when text in [nil, ""], do: ~H""

  def rich_text(assigns) do
    assigns =
      assign(
        assigns,
        :html,
        to_html(assigns.text, assigns.scope, assigns.allow_request, assigns.holder, assigns.urls)
      )

    ~H"""
    <div class={[
      "pk-rich-text max-w-none break-words",
      "[&_p]:my-1 [&_p:first-child]:mt-0 [&_p:last-child]:mb-0",
      "[&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5 [&_li]:my-0.5",
      "[&_a]:link [&_a]:link-primary [&_strong]:font-semibold",
      "[&_code]:bg-base-200 [&_code]:px-1 [&_code]:rounded",
      "[&_blockquote]:border-l-2 [&_blockquote]:border-base-300 [&_blockquote]:pl-3",
      # The editor saves a picture with its own `width`/`height`; a cap on
      # one side alone squashed it (the boss's 2026-10-31 photo), so the
      # height always follows the width, and a row lets the width follow
      # its height cap instead.
      "[&_img]:max-w-full [&_img]:h-auto [&_img]:object-contain [&_img]:rounded-box [&_img]:my-1",
      @compact && "text-sm line-clamp-3 [&_img]:max-h-24 [&_img]:w-auto",
      @class
    ]}>
      {raw(@html)}
    </div>
    """
  end

  @doc """
  The text as sanitised HTML with its mentions drawn for `scope`. Blank
  text is `""`; a text the renderer refuses comes back escaped.
  """
  @spec to_html(String.t() | nil, term(), boolean(), term(), map() | nil) :: String.t()
  def to_html(text, scope \\ nil, allow_request \\ true, holder \\ nil, urls \\ nil)
  def to_html(text, _scope, _allow, _holder, _urls) when text in [nil, ""], do: ""

  def to_html(text, scope, allow_request, holder, urls) when is_binary(text) do
    # The description's own pictures are kept by file (`pkfile:`): each
    # becomes an address this viewer may open, or is left out.
    text = InlineImages.resolve(text, scope, holder: holder, urls: urls || %{})
    pieces = Token.split(text)
    tokens = for %Token{} = t <- pieces, do: t

    # A fresh nonce per render: the placeholders are put back into HTML
    # the sanitiser already passed, so one the writer could type (into a
    # link or an image address) would splice a mention's markup into an
    # attribute.
    nonce = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    {markdown, _n} =
      Enum.map_reduce(pieces, 0, fn
        %Token{}, n -> {placeholder(nonce, n), n + 1}
        piece, n -> {piece, n}
      end)

    html = render_markdown(IO.iodata_to_binary(markdown), text)

    if tokens == [],
      do: html,
      else: put_mentions(html, tokens, nonce, text, scope, allow_request)
  end

  def to_html(_text, _scope, _allow, _holder, _urls), do: ""

  # Most descriptions are a line or two of plain words, drawn on every row
  # of a list and again on each change: those are put in paragraphs here,
  # as the renderer would (`plain_html/1`), and only text that could mean
  # something to markdown goes through MDEx and its sanitiser.
  defp render_markdown(markdown, text) do
    if plain?(markdown) do
      plain_html(markdown)
    else
      case MDEx.to_html(markdown, @render_opts) do
        {:ok, html} -> html
        {:error, _} -> text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      end
    end
  end

  # Nothing markdown or HTML reads: no markup character, no line starting
  # or ending in white space (indented code, hard breaks), no `1.` list.
  @markup ~r/[\\`*_\[\]()!#<>&~|=+\-:\r]|(?:^|\n)[ \t]|[ \t](?:\n|$)|(?:^|\n)\d+\./

  @doc false
  @spec plain?(String.t()) :: boolean()
  def plain?(markdown), do: not Regex.match?(@markup, markdown)

  @doc false
  # What MDEx renders a plain text as (hard line breaks): paragraphs at
  # blank lines, `<br>` within one.
  @spec plain_html(String.t()) :: String.t()
  def plain_html(markdown) do
    markdown
    |> String.split(~r/\n(?:[ \t]*\n)+/)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map_join("\n", fn para ->
      "<p>" <> (para |> String.trim("\n") |> String.split("\n") |> Enum.join("<br>\n")) <> "</p>"
    end)
  end

  # Letters and digits only: markdown leaves it alone, the sanitiser too.
  defp placeholder(nonce, n), do: "PKMENTION#{nonce}N#{n}X"

  defp put_mentions(html, tokens, nonce, text, scope, allow_request) do
    context = Mentions.context(text, user_uuid: user_uuid(scope), scope: scope)

    tokens
    |> Enum.with_index()
    |> Enum.reduce(html, fn {token, n}, acc ->
      info = Map.get(context, {token.type, token.uuid}, %{state: :missing})

      # Called by hand, so the assigns carry the change-tracking key a
      # component's `assign/3` insists on, and the token's own `text` (the
      # component draws nothing without one; `pieces`, given, spares it the
      # read). Without them every mention raised or came out empty, and the
      # description showed the bare placeholders instead of the names.
      rendered =
        %{
          __changed__: nil,
          pieces: [{token, info}],
          text: token.raw,
          scope: scope,
          class: nil,
          allow_request: allow_request,
          withhold_titles: false,
          rest: %{}
        }
        |> MentionText.mention_text()
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      String.replace(acc, placeholder(nonce, n), rendered, global: false)
    end)
  rescue
    _ -> html
  end

  defp user_uuid(%{user: %{uuid: uuid}}), do: uuid
  defp user_uuid(_), do: nil
end
