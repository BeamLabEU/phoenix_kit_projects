defmodule PhoenixKitProjects.Web.ProjectApiLive do
  @moduledoc """
  `/projects/:id/api` — "Your API key": every member's own page for the
  keys that act for THEM on this project. One click mints a personal key
  (named after them, their role at most, every scope, no expiry); the page
  then shows that key — the public ID, the role it acts with right now,
  last use — with Copy setup prompt, Rotate and Revoke. The token itself
  appears once, in the same modal the owner's page uses.

  Reached from the project header's ⋮ menu; any member may open it
  (`Authz.can?(…, :view)`). Nobody sees anyone else's keys here — the
  project's whole list, shared agents included, is the owner's "API
  access" section on Modules & Features. Shape from a three-seat panel
  (grok, zai, codex, 2026-10-05): a page off the ⋮ menu rather than a tab
  or a card under the task list, self-service for every role, the role
  derived rather than chosen.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.Activity
  alias PhoenixKitProjects.{ApiKeys, Authz, L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.{ApiKey, Project}
  alias PhoenixKitProjects.Web.Api.Docs
  alias PhoenixKitProjects.Web.ApiKeyPanel
  alias PhoenixKitProjects.Web.Components.ConfirmAction
  alias PhoenixKitProjects.Web.Crumbs
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @default_wrapper_class "flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6"
  @confirmable ~w(rotate_api_key revoke_api_key)

  # ── Mount ───────────────────────────────────────────────────────

  @impl true
  def mount(:not_mounted_at_router, %{"id" => id} = session, socket) do
    WebHelpers.maybe_put_locale(session)
    mount(%{"id" => id}, session, socket)
  end

  def mount(%{"id" => id}, session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket =
      socket
      |> WebHelpers.assign_embed_state(session)
      |> WebHelpers.assign_embed_user(session)
      |> WebHelpers.attach_open_embed_hook()
      |> assign(wrapper_class: Map.get(session, "wrapper_class", @default_wrapper_class))

    with %Project{} = project <- Projects.get_project(id) || :not_found,
         true <- not project.is_template || :template,
         true <- allowed?(socket, project) || :forbidden do
      {:ok,
       socket
       |> assign(
         page_title: gettext("Your API key"),
         page_section: gettext("Projects"),
         page_section_path: Paths.projects(),
         page_crumbs:
           Crumbs.project(
             project,
             L10n.current_content_lang(),
             socket.assigns[:phoenix_kit_current_scope]
           ),
         project: project,
         api_token: nil,
         can_manage:
           Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :manage_modules)
       )
       |> load_keys()}
    else
      :not_found -> bounce(socket, gettext("Project not found."))
      :template -> bounce(socket, gettext("Templates don't have API keys."))
      :forbidden -> bounce(socket, gettext("You don't have access to this project."))
    end
  end

  def mount(_params, session, socket) do
    WebHelpers.maybe_put_locale(session)

    socket
    |> WebHelpers.assign_embed_state(session)
    |> bounce(gettext("Project not found."))
  end

  defp bounce(socket, message) do
    {:ok,
     socket
     |> assign(
       project: nil,
       keys: [],
       role: nil,
       api_token: nil,
       can_manage: false,
       wrapper_class: socket.assigns[:wrapper_class] || @default_wrapper_class
     )
     |> put_flash(:error, message)
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  defp allowed?(socket, project) do
    Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :view)
  end

  # The viewer's live keys and the role a new one would act with — nil
  # when they are not a member (a site admin looking in), so nothing can
  # be minted for them.
  defp load_keys(socket) do
    project = socket.assigns.project
    viewer = Activity.actor_uuid(socket)

    assign(socket,
      keys: ApiKeys.list_for_user(project.uuid, viewer),
      role: Authz.effective_role(project, viewer)
    )
  end

  # ── Events ──────────────────────────────────────────────────────

  @impl true
  def handle_event("request_confirm", params, socket),
    do: {:noreply, ConfirmAction.request(socket, params, @confirmable)}

  def handle_event("confirm_action_cancel", _params, socket),
    do: {:noreply, ConfirmAction.clear(socket)}

  def handle_event("confirm_action_ok", _params, socket) do
    case ConfirmAction.take(socket) do
      {nil, socket} -> {:noreply, socket}
      {%{event: event, params: params}, socket} -> handle_event(event, params, socket)
    end
  end

  def handle_event("create_my_key", _params, socket) do
    with {:ok, user} <- viewer(socket),
         {:ok, role} <- member_role(socket),
         {:ok, key, token} <-
           ApiKeys.create(
             socket.assigns.project,
             ApiKeyPanel.personal_attrs(user, role),
             actor_uuid: user.uuid
           ) do
      {:noreply,
       socket
       |> assign(api_token: %{token: token, key: key, action: :created})
       |> load_keys()
       |> put_flash(:info, gettext("Your key is ready — copy it now, it is shown only once."))}
    else
      {:error, :not_a_member} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Only a member of the project can have a key; ask an owner to add you.")
         )}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not create the key."))}
    end
  end

  def handle_event("rotate_api_key", %{"uuid" => uuid}, socket) do
    with %ApiKey{} = key <- own_key(socket, uuid),
         {:ok, key, token} <- ApiKeys.rotate(key, actor_uuid: Activity.actor_uuid(socket)) do
      {:noreply,
       socket
       |> assign(api_token: %{token: token, key: key, action: :rotated})
       |> load_keys()
       |> put_flash(
         :info,
         gettext("Key rotated — the old token stopped working; copy the new one now.")
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not rotate the key."))}
    end
  end

  def handle_event("revoke_api_key", %{"uuid" => uuid}, socket) do
    with %ApiKey{} = key <- own_key(socket, uuid),
         {:ok, _} <- ApiKeys.revoke(key, actor_uuid: Activity.actor_uuid(socket)) do
      {:noreply, socket |> load_keys() |> put_flash(:info, gettext("Key revoked."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not revoke the key."))}
    end
  end

  def handle_event("dismiss_api_token", _params, socket),
    do: {:noreply, assign(socket, api_token: nil)}

  # Only a key that acts for the viewer, on this project. The list is
  # already theirs; this is the check for a crafted event.
  defp own_key(socket, uuid) do
    viewer = Activity.actor_uuid(socket)

    case ApiKeys.get_for_project(socket.assigns.project.uuid, uuid) do
      %ApiKey{user_uuid: ^viewer} = key when is_binary(viewer) -> key
      _ -> nil
    end
  end

  defp member_role(%{assigns: %{role: role}}) when is_atom(role) and not is_nil(role),
    do: {:ok, role}

  defp member_role(_socket), do: {:error, :not_a_member}

  defp viewer(socket) do
    case Activity.actor_uuid(socket) do
      nil -> {:error, :anonymous}
      uuid -> {:ok, Auth.get_user(uuid) || %{uuid: uuid}}
    end
  end

  defp project_name(%Project{} = project),
    do: Project.localized_name(project, L10n.current_content_lang())

  defp role_label(:owner), do: gettext("manager (owners' keys act as managers)")
  defp role_label(role) when is_atom(role), do: Atom.to_string(role)

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <%= if @project do %>
        <.page_header
          title={gettext("Your API key")}
          description={
            gettext(
              "The key your AI uses to work on %{name} as you: it reads and creates tasks, moves them and logs its time, tokens and cost, with your role and in your name.",
              name: project_name(@project)
            )
          }
          embed_mode={@embed_mode}
        >
          <:back_link>
            <.smart_link
              navigate={Paths.project(@project.uuid)}
              emit={{PhoenixKitProjects.Web.ProjectShowLive, %{"id" => @project.uuid}}}
              embed_mode={@embed_mode}
              class="link link-hover text-sm"
            >
              ← {project_name(@project)}
            </.smart_link>
          </:back_link>
        </.page_header>

        <%!-- One card per key acting for the viewer; usually one. --%>
        <div :for={key <- @keys} class="card bg-base-100 border border-base-300">
          <div class="card-body gap-3 p-5">
            <div class="flex items-start justify-between gap-3 flex-wrap">
              <div class="min-w-0">
                <h3 class="font-semibold truncate">{key.name}</h3>
                <div class="font-mono text-xs text-base-content/60 mt-0.5">
                  {gettext("ID")} {ApiKeyPanel.display_id(key)}
                </div>
              </div>
              <div class="flex gap-2 shrink-0">
                <button
                  type="button"
                  id={"my-key-copy-prompt-#{key.uuid}"}
                  phx-hook="CopyToClipboard"
                  data-copy-target={"#api-key-prompt-#{key.uuid}"}
                  class="btn btn-sm btn-primary"
                >
                  <.icon name="hero-clipboard-document" class="w-4 h-4" />
                  <span data-copy-idle>{gettext("Copy setup prompt")}</span>
                  <span data-copy-feedback class="hidden">{gettext("Copied!")}</span>
                </button>
                <.table_row_menu id={"my-key-menu-#{key.uuid}"}>
                  <.table_row_menu_button
                    {ConfirmAction.ask("rotate_api_key",
                      uuid: key.uuid,
                      title: gettext("Rotate key"),
                      message:
                        gettext("Give \"%{name}\" a new token? The current one stops working at once.",
                          name: key.name
                        ),
                      confirm: gettext("Rotate")
                    )}
                    icon="hero-arrow-path"
                    label={gettext("Rotate — get a new token")}
                  />
                  <.table_row_menu_divider />
                  <.table_row_menu_button
                    {ConfirmAction.ask("revoke_api_key",
                      uuid: key.uuid,
                      title: gettext("Revoke key"),
                      message:
                        gettext("Revoke \"%{name}\"? Every call with it will be refused from now on, and this cannot be undone.",
                          name: key.name
                        ),
                      confirm: gettext("Revoke")
                    )}
                    icon="hero-no-symbol"
                    label={gettext("Revoke")}
                    variant="error"
                  />
                </.table_row_menu>
              </div>
            </div>
            <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
              <dt class="text-base-content/60">{gettext("Acts as")}</dt>
              <dd>
                {if @role, do: role_label(@role), else: gettext("nobody — you are not a member")}
              </dd>
              <dt class="text-base-content/60">{gettext("Last used")}</dt>
              <dd>
                <%= if key.last_used_at do %>
                  <.time_ago datetime={key.last_used_at} class="" />
                <% else %>
                  {gettext("never")}
                <% end %>
              </dd>
              <dt class="text-base-content/60">{gettext("Expires")}</dt>
              <dd>
                {if key.expires_at, do: L10n.format_date(key.expires_at), else: gettext("never")}
              </dd>
            </dl>
            <p class="text-xs text-base-content/60">
              {gettext("The token was shown once, when the key was made. Lost it? Rotate the key and paste the new setup prompt to your AI.")}
            </p>
          </div>
        </div>

        <%!-- No key yet: one click. --%>
        <div :if={@keys == []} class="card bg-base-100 border border-base-300">
          <div class="card-body gap-3 p-5">
            <p class="text-sm">
              {gettext("You have no key on this project yet. Create one, paste the setup prompt it gives you to your AI, and it can start working here as you.")}
            </p>
            <div>
              <.button type="button" phx-click="create_my_key" phx-disable-with={gettext("Creating…")}>
                <.icon name="hero-key" class="w-4 h-4" />
                {gettext("Create my key")}
              </.button>
            </div>
            <p :if={is_nil(@role)} class="text-xs text-warning">
              {gettext("You are not a member of this project, so a key cannot act for you here.")}
            </p>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
          <span class="font-medium">{gettext("For your AI:")}</span>
          <a href={Docs.url("/llms.txt")} target="_blank" rel="noopener" class="link link-primary link-hover">
            {gettext("Agent guide")}
          </a>
          <span class="opacity-40">·</span>
          <a href={Docs.url("/openapi.json")} target="_blank" rel="noopener" class="link link-primary link-hover">
            {gettext("OpenAPI spec")}
          </a>
          <span :if={@can_manage} class="opacity-40">·</span>
          <.smart_link
            :if={@can_manage}
            navigate={Paths.modules(@project.uuid)}
            emit={{PhoenixKitProjects.Web.ProjectModulesLive, %{"id" => @project.uuid}}}
            embed_mode={@embed_mode}
            class="link link-hover"
          >
            {gettext("All keys on this project")}
          </.smart_link>
        </div>

        <.api_key_prompts keys={@keys} project_name={project_name(@project)} />
        <.api_token_modal
          id={"my-api-token-#{@project.uuid}"}
          api_token={@api_token}
          project_name={project_name(@project)}
        />
        <.confirm_action_modal confirm={assigns[:confirm_action]} />
      <% end %>
    </div>
    """
  end
end
