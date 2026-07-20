defmodule PhoenixKitProjects.Test.Layouts do
  @moduledoc """
  Minimal layouts for the LiveView test endpoint. Real layouts live in
  the host app and the phoenix_kit core — these just wrap LiveView
  content in an HTML shell so Phoenix.LiveViewTest can render it.

  `app/1` renders flash divs so smoke tests can assert flash content
  via `render(view) =~ "Saved."` after click events.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <%!-- Breadcrumb-consumer fixture (quality-sweep playbook "Test
         pattern"): the real consumer is core's admin layout, which
         forwards page_title/page_section(+_path)/page_action into the
         header breadcrumb. Rendering them here lets module tests pin
         the PRODUCER half of that chain — an LV that stops setting one
         of these assigns fails a rendered-output assertion instead of
         silently losing its breadcrumb in the real admin. --%>
    <div id="test-breadcrumb" data-page-title={assigns[:page_title]}>
      <span :if={assigns[:page_section]} data-crumb-section={assigns[:page_section]}>
        {assigns[:page_section]}
      </span>
      <a
        :if={assigns[:page_action]}
        data-crumb-action
        href={assigns[:page_action][:navigate]}
        title={assigns[:page_action][:label]}
      >
        {assigns[:page_action][:label]}
      </a>
    </div>
    <div id="test-flashes">
      <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info" data-flash-kind="info">
        {msg}
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :error)} id="flash-error" data-flash-kind="error">
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :warning)}
        id="flash-warning"
        data-flash-kind="warning"
      >
        {msg}
      </div>
    </div>
    {@inner_content}
    """
  end

  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
