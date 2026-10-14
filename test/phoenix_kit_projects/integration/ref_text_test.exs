defmodule PhoenixKitProjects.Integration.RefTextTest do
  @moduledoc """
  Short refs in text (`RefText`): `#KEY-42` typed in a description is
  stored as the mention token of that task, and an edit box shows the
  short ref again.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Mentions.Token
  alias PhoenixKitProjects.{Projects, RefText}
  alias PhoenixKitProjects.Schemas.Assignment

  defp task!(project, attrs \\ %{}) do
    {:ok, a} =
      Projects.create_assignment(
        Map.merge(%{"project_uuid" => project.uuid, "task_uuid" => fixture_task().uuid}, attrs)
      )

    Projects.get_assignment(a.uuid)
  end

  setup do
    # Fixtures are written by trusted code (`RefText`, "Who is writing").
    PhoenixKitProjects.RefText.put_writer(:all)
    project = fixture_project()
    task = task!(project)
    %{project: project, task: task, ref: Assignment.ref(task)}
  end

  describe "expand/1" do
    test "a task ref and a project key become tokens labelled with the ref", ctx do
      text = "See ##{ctx.ref} and ##{ctx.project.key}, then (##{ctx.ref})."
      expanded = RefText.expand(text)

      task_token = "#[project_task:#{ctx.task.uuid}|#{ctx.ref}]"
      project_token = "#[project:#{ctx.project.uuid}|#{ctx.project.key}]"

      assert expanded == "See #{task_token} and #{project_token}, then (#{task_token})."
      # Again, it is the same text: what is a token already is left alone.
      assert RefText.expand(expanded) == expanded
    end

    test "a task ref reads in any case; a bare key only in capitals", ctx do
      assert RefText.expand("##{String.downcase(ctx.ref)}") =~ "#[project_task:#{ctx.task.uuid}|"
      lower = "#" <> String.downcase(ctx.project.key)
      assert RefText.expand(lower) == lower
    end

    test "what names nothing, or is not a ref, stays as typed", ctx do
      for text <- [
            "#todo and #WIP",
            "##{ctx.project.key}-999999",
            "a#{"#"}#{ctx.ref}",
            "https://example.com/x##{ctx.ref}",
            "## #{ctx.ref}",
            "[the task](##{ctx.ref})",
            "[##{ctx.ref}](https://example.com)",
            "\\##{ctx.ref}",
            "`##{ctx.ref}` and ```\n##{ctx.ref}\n```",
            "##{ctx.ref}x",
            "##{ctx.ref}-2",
            "no hash at all",
            ""
          ] do
        assert RefText.expand(text) == text, text
      end

      assert RefText.expand(nil) == nil
    end

    test "a ref inside a URL's query or fragment stays as typed", ctx do
      for text <- [
            "https://example.test/view?tab=##{ctx.project.key}",
            "see x?tab=##{ctx.ref}",
            "a=##{ctx.ref}"
          ] do
        assert RefText.expand(text) == text, text
      end
    end

    test "only a declared writer who may open the project gets a link", ctx do
      text = "See ##{ctx.ref} in ##{ctx.project.key}."
      linked = RefText.expand(text)
      assert linked =~ "#[project_task:#{ctx.task.uuid}|"

      # Nobody declared (the public portal, a job): nothing is resolved.
      RefText.put_writer(nil)
      assert RefText.expand(text) == text

      # A signed-in person with no access to the project.
      outsider = PhoenixKitProjects.LiveCase.fake_scope(permissions: ["projects"])
      RefText.put_writer({:scope, outsider})
      assert RefText.expand(text) == text
      # ...and the box keeps the tokens it cannot read back.
      assert RefText.collapse(linked) == linked

      # An API key: links only within its reach.
      RefText.put_writer({:reach, &(&1 == ctx.project.uuid)})
      assert RefText.expand(text) == linked
      RefText.put_writer({:reach, fn _ -> false end})
      assert RefText.expand(text) == text
    end

    test "an escaped token and a token of another type are left alone", ctx do
      other = "#[crm_interaction:#{Ecto.UUID.generate()}|Kickoff ##{ctx.ref}]"
      escaped = "\\#[project_task:#{ctx.task.uuid}|x]"
      assert RefText.expand("#{other} #{escaped}") == "#{other} #{escaped}"
    end

    test "a retired key resolves and the token carries the current ref", ctx do
      old_ref = ctx.ref

      {:ok, renamed} =
        Projects.update_project(ctx.project, %{
          "key" => ("ZQ" <> ctx.project.key) |> String.slice(0, 10)
        })

      new_ref = "#{renamed.key}-#{ctx.task.number}"

      assert RefText.expand("##{old_ref}") == "#[project_task:#{ctx.task.uuid}|#{new_ref}]"
    end
  end

  describe "collapse/1" do
    test "shows project and task tokens as refs and reads back as the same links", ctx do
      meeting = "#[crm_interaction:#{Ecto.UUID.generate()}|Kickoff]"
      person = "@[user:#{Ecto.UUID.generate()}|Alice]"

      stored =
        "From #{meeting} with #{person}: #[project_task:#{ctx.task.uuid}|An old title], " <>
          "in #[project:#{ctx.project.uuid}|Old name]."

      shown = RefText.collapse(stored)
      assert shown == "From #{meeting} with #{person}: ##{ctx.ref}, in ##{ctx.project.key}."

      assert Enum.map(Token.parse(RefText.expand(shown)), & &1.uuid) ==
               Enum.map(Token.parse(stored), & &1.uuid)
    end

    test "a token that would not read back, or points at nothing, stays a token", ctx do
      glued = "#[project_task:#{ctx.task.uuid}|x]s"
      gone = "#[project_task:#{Ecto.UUID.generate()}|Deleted task]"
      escaped = "\\#[project_task:#{ctx.task.uuid}|x]"

      for text <- [glued, gone, escaped], do: assert(RefText.collapse(text) == text)

      # A plain ref before a token that cannot be shown short: collapsing
      # must not let the link slide from the second place to the first.
      slid = "##{ctx.project.key} x#[project:#{ctx.project.uuid}|old]"
      assert RefText.collapse(slid) == slid
    end
  end

  describe "on a write" do
    test "a description is stored with tokens, whoever writes it", ctx do
      other = task!(ctx.project, %{"description" => "Blocked by ##{ctx.ref}."})
      assert other.description == "Blocked by #[project_task:#{ctx.task.uuid}|#{ctx.ref}]."

      {:ok, updated} =
        Projects.update_assignment_form(other, %{
          "description" => "After ##{ctx.ref}",
          "translations" => %{"et" => %{"description" => "Pärast ##{ctx.ref}"}}
        })

      assert updated.description =~ "#[project_task:#{ctx.task.uuid}|"
      assert updated.translations["et"]["description"] =~ "#[project_task:#{ctx.task.uuid}|"

      {:ok, project} =
        Projects.update_project(ctx.project, %{"description" => "Start at ##{ctx.ref}"})

      assert project.description =~ "#[project_task:#{ctx.task.uuid}|"
    end

    test "validating a form does not touch the text", ctx do
      cs = Projects.change_assignment(ctx.task, %{"description" => "See ##{ctx.ref}"})
      assert Ecto.Changeset.get_change(cs, :description) == "See ##{ctx.ref}"
    end

    test "an edit form's record: untouched text is no change, and saves nothing", ctx do
      {:ok, stored} =
        Projects.update_assignment_form(ctx.task, %{"description" => "See ##{ctx.ref}"})

      shown = RefText.collapse_fields(stored, [:description])
      assert shown.description == "See ##{ctx.ref}"

      cs = Projects.change_assignment(shown, %{"description" => "See ##{ctx.ref}"})
      assert cs.changes == %{}
    end
  end
end
