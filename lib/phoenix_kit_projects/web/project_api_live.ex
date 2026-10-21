defmodule PhoenixKitProjects.Web.ProjectApiLive do
  @moduledoc """
  `/projects/:id/api` — "Your API key": every member's own, READ-ONLY view
  of the keys that act for THEM and reach this project — what each may do
  here (its access per area, `PhoenixKitProjects.ApiAccess`, and the role
  it acts with), whether that comes from a grant on this project or on a
  project above it, and when it was last used, with Copy setup prompt.

  Since V24 a key is not a project's: one key can reach several projects,
  each with its own access, and it is made, changed, rotated and revoked
  on the global Projects → API keys page (`Web.ApiKeysLive`). This page
  links there — "Manage your API keys", and "New key for this project"
  with this project filled in. Nothing here can change a key: a key that
  drives other projects is not this project's to end.

  Reached from the project header's ⋮ menu; any member may open it
  (`Authz.can?(…, :view)`).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitProjects.Gettext
  use PhoenixKitProjects.Web.Components

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitProjects.{Activity, ApiAccess, ApiKeys, Authz, L10n, Paths, Projects}
  alias PhoenixKitProjects.Schemas.{ApiKey, Project}
  alias PhoenixKitProjects.Web.Api.Docs
  alias PhoenixKitProjects.Web.ApiKeyPanel
  alias PhoenixKitProjects.Web.Crumbs
  alias PhoenixKitProjects.Web.Helpers, as: WebHelpers

  @default_wrapper_class "flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6"

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
       # Section, trail and key: the one helper for a page under a project.
       |> assign(Crumbs.under_project(project, socket.assigns[:phoenix_kit_current_scope]))
       |> assign(
         page_title: gettext("Your API key"),
         project: project,
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
       can_manage: false,
       wrapper_class: socket.assigns[:wrapper_class] || @default_wrapper_class
     )
     |> put_flash(:error, message)
     |> WebHelpers.close_or_navigate(Paths.projects())}
  end

  defp allowed?(socket, project) do
    Authz.can?(socket.assigns[:phoenix_kit_current_scope], project, :view)
  end

  # The viewer's keys that reach this project, each with what it may do
  # here: `%{key, access, source, home}` — `access` nil when the key's grant
  # here is unusable (the viewer left the project the grant is on).
  defp load_keys(socket) do
    project = socket.assigns.project
    viewer = Activity.actor_uuid(socket)

    keys =
      project.uuid
      |> ApiKeys.list_reaching()
      |> Enum.filter(&(is_binary(viewer) and &1.user_uuid == viewer))
      |> Enum.map(&row(&1, project))

    assign(socket, keys: keys)
  end

  @doc false
  # One key as a row of this page (shared with the Modules page's list).
  def row(%ApiKey{} = key, %Project{} = project) do
    access =
      case ApiKeys.access_for(key, project.uuid) do
        {:ok, access} -> access
        _ -> nil
      end

    source =
      case access do
        %{grant: %{project_uuid: uuid}} when uuid == project.uuid -> :direct
        %{grant: %{project_uuid: uuid}} -> {:inherited, Projects.get_project(uuid)}
        _ -> nil
      end

    home = key.project_uuid && Projects.get_project(key.project_uuid)
    %{key: key, access: access, source: source, home: home}
  end

  @doc false
  # "Full", "Read only", "Client interactions, read only", … or "Custom".
  def access_label(nil), do: gettext("No access here")

  def access_label(%{scopes: scopes}) do
    preset = ApiAccess.preset_of(scopes)

    Enum.find_value(ApiAccess.presets(), gettext("Custom"), fn {key, label, _grid} ->
      if key == preset, do: label
    end)
  end

  @doc false
  def source_label(:direct), do: gettext("set on this project")

  def source_label({:inherited, %Project{} = from}),
    do: gettext("from %{project}", project: project_name(from))

  def source_label(_), do: gettext("not usable here")

  @doc false
  # The global API keys page; with a project, its "new key" form starts
  # on that project.
  def keys_page(nil), do: Routes.path("/admin/projects/api-keys")
  def keys_page(project_uuid), do: Routes.path("/admin/projects/api-keys?project=#{project_uuid}")

  defp project_name(%Project{} = project),
    do: Project.localized_name(project, L10n.current_content_lang())

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
              "The keys your AI uses to work on %{name} as you, with your role and in your name. One key can reach several projects, each with its own access; you set that on the API keys page.",
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

        <%!-- Read-only (V24): a key is made, changed, rotated and revoked on
             the global API keys page — it may drive other projects too. --%>
        <div class="flex flex-wrap gap-2">
          <.link navigate={keys_page(@project.uuid)} class="btn btn-sm btn-primary">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New key for this project")}
          </.link>
          <.link navigate={keys_page(nil)} class="btn btn-sm">
            <.icon name="hero-key" class="w-4 h-4" /> {gettext("Manage your API keys")}
          </.link>
        </div>

        <div :for={row <- @keys} id={"my-key-#{row.key.uuid}"} class="card bg-base-100 border border-base-300">
          <div class="card-body gap-3 p-5">
            <div class="flex items-start justify-between gap-3 flex-wrap">
              <div class="min-w-0">
                <h3 class="font-semibold truncate">{row.key.name}</h3>
                <div class="font-mono text-xs text-base-content/60 mt-0.5">
                  {gettext("ID")} {ApiKeyPanel.display_id(row.key)}
                </div>
              </div>
              <button
                type="button"
                id={"my-key-copy-prompt-#{row.key.uuid}"}
                phx-hook="CopyToClipboard"
                data-copy-target={"#api-key-prompt-#{row.key.uuid}"}
                class="btn btn-sm btn-primary shrink-0"
              >
                <.icon name="hero-clipboard-document" class="w-4 h-4" />
                <span data-copy-idle>{gettext("Copy setup prompt")}</span>
                <span data-copy-feedback class="hidden">{gettext("Copied!")}</span>
              </button>
            </div>
            <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
              <dt class="text-base-content/60">{gettext("Access here")}</dt>
              <dd>
                {access_label(row.access)}
                <span :if={row.access} class="text-base-content/60">
                  · {gettext("acts as %{role}", role: row.access.role)} · {source_label(row.source)}
                </span>
              </dd>
              <dt class="text-base-content/60">{gettext("Home project")}</dt>
              <dd>{if row.home, do: project_name(row.home), else: "—"}</dd>
              <dt class="text-base-content/60">{gettext("Last used")}</dt>
              <dd>
                <%= if row.key.last_used_at do %>
                  <.time_ago datetime={row.key.last_used_at} class="" />
                <% else %>
                  {gettext("never")}
                <% end %>
              </dd>
              <dt class="text-base-content/60">{gettext("Expires")}</dt>
              <dd>
                {if row.key.expires_at, do: L10n.format_date(row.key.expires_at), else: gettext("never")}
              </dd>
            </dl>
            <p class="text-xs text-base-content/60">
              {gettext("The token was shown once, when the key was made. Lost it? Rotate the key on the API keys page and paste the new setup prompt to your AI.")}
            </p>
          </div>
        </div>

        <div :if={@keys == []} class="card bg-base-100 border border-base-300">
          <div class="card-body gap-3 p-5">
            <p class="text-sm">
              {gettext("None of your keys reach this project. Make one with \"New key for this project\", or give an existing key access here on the API keys page.")}
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
            {gettext("All keys reaching this project")}
          </.smart_link>
        </div>

        <%!-- The prompt behind each Copy setup prompt: it names the key's
             home project; the token is not stored, so its place is held. --%>
        <div class="hidden">
          <textarea :for={row <- @keys} id={"api-key-prompt-#{row.key.uuid}"} readonly>{ApiKeyPanel.setup_prompt(
            (row.home && project_name(row.home)) || project_name(@project),
            row.key,
            nil
          )}</textarea>
        </div>
      <% end %>
    </div>
    """
  end
end
