defmodule PhoenixKitProjects.Web.DescriptionEditorTest do
  @moduledoc """
  Descriptions are written in the Leaf editor (the boss's list, item 6) —
  task popup, project and sub-project, task library and template — and
  shown formatted (`Web.Components.RichText`), safely, with mentions
  resolved and a plain-text description of before reading as it did.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKitProjects.Projects
  alias PhoenixKitProjects.Web.Components.{DescriptionEditor, RichText}

  setup %{conn: conn} do
    me = embed_user_uuid!()
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Seal the worktop", "ad_hoc" => true},
        %{}
      )

    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: me)), project: project, a: a}
  end

  defp editor_id(html, base) do
    [id] =
      Regex.run(~r/data-description-editor="(#{base}--[^"]+)"/, html, capture: :all_but_first)

    id
  end

  describe "showing a description" do
    test "markdown is formatted, plain text keeps its lines, and scripts go" do
      assert RichText.to_html("**Oak** only") =~ "<strong>Oak</strong>"
      assert RichText.to_html("line one\nline two") =~ ~r/line one<br\s*\/?>\s*line two/
      refute RichText.to_html("<script>alert(1)</script>hi") =~ "<script"
      refute RichText.to_html("[x](javascript:alert(1))") =~ "javascript:"
      assert RichText.to_html(nil) == ""
    end

    # The mentions go back in after the sanitiser: a placeholder the writer
    # types into a link must not receive a mention's markup.
    test "a typed placeholder never takes a mention's markup" do
      uuid = Ecto.UUID.generate()

      for typed <- ["PKMENTION0X", "PKMENTIONN0X"] do
        html = RichText.to_html("[a](#{typed}) ![i](#{typed}) @[user:#{uuid}|Ann]")
        refute html =~ ~r/(href|src)="[^"]*(<|Ann)/
        assert html =~ "Ann"
      end
    end

    test "a mention in a description is drawn as its name, never as a placeholder" do
      html = RichText.to_html("Call @[user:#{Ecto.UUID.generate()}|Ann] **today**")
      assert html =~ "Ann"
      assert html =~ "<strong>today</strong>"
      refute html =~ "PKMENTION"
    end
  end

  describe "the read view carries no layout" do
    test "a writer's style or class cannot pin a box over the page" do
      html =
        RichText.to_html(
          ~S|<span style="position:fixed;inset:0">x</span> <div class="fixed inset-0">y</div>| <>
            "\n\n<pre class=\"fixed\"><code class=\"fixed\">z</code></pre>"
        )

      refute html =~ "position:fixed"
      refute html =~ "class="
      refute html =~ "style="
      assert html =~ "x" and html =~ "y" and html =~ "z"
    end
  end

  describe "the editor never renders raw HTML" do
    # Leaf renders its markdown with MDEx `unsafe: true` into a
    # contenteditable: a stored `<img onerror>` would run for whoever opens
    # the form (a portal submission, an API key, a hand-made post).
    test "safe_content shows a tag as text, and leaves code and markdown alone" do
      assert DescriptionEditor.safe_content("x <img src=x onerror=alert(1)> y") ==
               "x &lt;img src=x onerror=alert(1)> y"

      # An unclosed block opener would carry the next line's tag along.
      refute DescriptionEditor.safe_content("<div\n<img src=x onerror=1>") =~ "<img"
      # Escaped backticks open no code span: the tag inside is live.
      refute DescriptionEditor.safe_content("\\`<img src=x onerror=1>\\`") =~ "<img"

      for kept <- [
            "**Oak**, oiled @[user:0190a3b4-0000-7000-8000-000000000001|Ann]",
            "a `<img src=x>` b",
            "```\n<b>code</b>\n```",
            "x<sup>2</sup> and H<sub>2</sub>O"
          ] do
        assert DescriptionEditor.safe_content(kept) == kept
      end
    end

    test "a stored description's tag reaches the task form's editor as text", ctx do
      evil = ~S|Call them <img src=x onerror="alert(1)"> today|

      {:ok, _} =
        Projects.update_task(Projects.get_task(ctx.a.task_uuid), %{"description" => evil})

      {:ok, _view, html} =
        live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

      refute html =~ ~s(<img src="x" onerror)
      refute html =~ ~s(<img src=x onerror)
      assert html =~ "Call them"
    end
  end

  describe "writing one" do
    test "the task popup's description is the editor, and what it sends is saved", ctx do
      {:ok, view, html} =
        live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

      refute html =~ ~s(<textarea name="assignment[description]")
      assert html =~ ~s(name="assignment[description]")
      id = editor_id(html, "assignment-description")

      send(view.pid, {:leaf_changed, %{editor_id: id, markdown: "**Oak**, oiled", html: ""}})
      render(view)
      view |> form("#assignment-form") |> render_submit()

      # A one-off task keeps its words on the task itself.
      a = Projects.get_assignment(ctx.a.uuid)
      assert "**Oak**, oiled" in [a.description, Projects.get_task(a.task_uuid).description]
    end

    test "the project form saves what the editor sends", ctx do
      {:ok, view, html} = live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/edit")
      id = editor_id(html, "project-description")

      send(view.pid, {:leaf_changed, %{editor_id: id, markdown: "- one\n- two", html: ""}})
      render(view)
      view |> form("#project-form") |> render_submit()

      assert Projects.get_project(ctx.project.uuid).description == "- one\n- two"
    end

    test "the task library and template forms carry the editor", ctx do
      for {path, base} <- [
            {"/en/admin/projects/tasks/new", "task-description"},
            {"/en/admin/projects/templates/new", "template-description"},
            {"/en/admin/projects/#{ctx.project.uuid}/assignments/new?kind=subproject",
             "subproject-description"}
          ] do
        {:ok, _view, html} = live(ctx.conn, path)
        assert editor_id(html, base), path
      end
    end
  end

  describe "plain text skips the markdown renderer" do
    @opts [
      render: [hardbreaks: true, unsafe: true],
      sanitize:
        Keyword.put(MDEx.Document.default_sanitize_options(), :rm_tag_attributes, %{
          "div" => ["style"]
        })
    ]

    test "and draws what the renderer would" do
      for text <- [
            "Call them",
            "Line one\nline two",
            "Para one\n\nPara two\nmore",
            "\n\nAfter blank lines\n\n\n",
            "Õun, \"jutumärgid\" ja it's 2026 / 5% {x}",
            "www.example.com and a.b"
          ] do
        assert RichText.plain?(text), text
        assert RichText.to_html(text) == MDEx.to_html!(text, @opts), text
      end
    end

    test "but anything markdown or HTML could read goes through it" do
      for text <- [
            "**bold**",
            "a <b>tag</b>",
            "1. first",
            "    code",
            "hard  \nbreak",
            "Title\n===",
            "x & y",
            "[a](b)"
          ],
          do: refute(RichText.plain?(text), text)
    end
  end
end
