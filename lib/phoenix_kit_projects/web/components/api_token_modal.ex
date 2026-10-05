defmodule PhoenixKitProjects.Web.Components.ApiTokenModal do
  @moduledoc """
  The two pieces of the key pages that carry a setup prompt: the
  "copy it now" modal a creation or rotation opens (the token, the prompt
  with the token embedded, the reference links) and the hidden textareas
  behind every live row's "Copy setup prompt" (the same prompt with the
  token's place held). Shared by the owner's list on Modules & Features
  and every member's "Your API key" page, so the two say the same thing.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitProjects.Gettext

  import PhoenixKitWeb.Components.Core.Button
  import PhoenixKitWeb.Components.Core.Modal

  alias PhoenixKitProjects.Web.Api.Docs
  alias PhoenixKitProjects.Web.ApiKeyPanel

  attr(:id, :string, required: true)
  attr(:api_token, :map, default: nil, doc: "`%{token, key, action}` or nil when closed")
  attr(:project_name, :string, required: true)

  @doc "The token modal; renders nothing while `api_token` is nil. Closes with `dismiss_api_token`."
  def api_token_modal(assigns) do
    ~H"""
    <.modal
      :if={@api_token}
      show
      id={@id}
      on_close="dismiss_api_token"
      max_width="lg"
    >
      <:title>
        {if @api_token.action == :rotated,
          do: gettext("Key rotated — copy the new token now"),
          else: gettext("Key created — copy it now")}
      </:title>
      <div class="flex flex-col gap-4">
        <p class="text-sm">
          {gettext("This is the only time the token is shown; only its hash is stored. Lose it and you rotate the key.")}
        </p>
        <div class="flex flex-col gap-1">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            {gettext("Token for \"%{name}\"", name: @api_token.key.name)}
          </span>
          <div class="flex items-center gap-2">
            <input
              id="api-token-value"
              type="text"
              readonly
              value={@api_token.token}
              class="input input-sm input-bordered font-mono text-xs w-full"
            />
            <button
              type="button"
              id="api-token-copy"
              phx-hook="CopyToClipboard"
              data-copy-target="#api-token-value"
              class="btn btn-sm btn-primary whitespace-nowrap"
            >
              <span data-copy-idle>{gettext("Copy token")}</span>
              <span data-copy-feedback class="hidden">{gettext("Copied!")}</span>
            </button>
          </div>
        </div>
        <div class="flex flex-col gap-1">
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            {gettext("Set up your AI")}
          </span>
          <p class="text-xs text-base-content/60">
            {gettext("Paste this to your AI as its first message. It carries the token, so treat the paste like the token itself.")}
          </p>
          <textarea
            id="api-token-prompt"
            readonly
            rows="9"
            class="textarea textarea-bordered textarea-sm font-mono text-xs w-full leading-snug"
          >{ApiKeyPanel.setup_prompt(@project_name, @api_token.key, @api_token.token)}</textarea>
          <div>
            <button
              type="button"
              id="api-token-prompt-copy"
              phx-hook="CopyToClipboard"
              data-copy-target="#api-token-prompt"
              class="btn btn-sm"
            >
              <span data-copy-idle>{gettext("Copy setup prompt")}</span>
              <span data-copy-feedback class="hidden">{gettext("Copied!")}</span>
            </button>
          </div>
        </div>
        <p class="text-xs text-base-content/60">
          <a href={Docs.url("/llms.txt")} target="_blank" rel="noopener" class="link link-hover">
            {gettext("Agent guide")}
          </a>
          <span class="opacity-40">·</span>
          <a href={Docs.url("/openapi.json")} target="_blank" rel="noopener" class="link link-hover">
            {gettext("OpenAPI spec")}
          </a>
        </p>
      </div>
      <:actions>
        <.button type="button" phx-click="dismiss_api_token">{gettext("Done — I saved it")}</.button>
      </:actions>
    </.modal>
    """
  end

  attr(:keys, :list, required: true)
  attr(:project_name, :string, required: true)

  @doc "The hidden prompt textareas, one per live key, targeted by the rows' copy buttons."
  def api_key_prompts(assigns) do
    ~H"""
      <%!-- The setup prompt behind each live row's "Copy setup prompt":
           the same text as the creation modal's, with the token's place
           held — it is not stored. --%>
      <div class="hidden">
        <textarea
          :for={key <- Enum.reject(@keys, & &1.revoked_at)}
          id={"api-key-prompt-#{key.uuid}"}
          readonly
        >{ApiKeyPanel.setup_prompt(@project_name, key, nil)}</textarea>
      </div>
    """
  end
end
