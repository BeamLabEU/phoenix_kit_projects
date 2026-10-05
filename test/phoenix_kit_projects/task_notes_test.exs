defmodule PhoenixKitProjects.TaskNotesTest do
  @moduledoc """
  The notes thread of a task: a comment on its own anchor, with the usage
  the agent reported written to the ledger in the same transaction, both
  pointing at each other.
  """

  use PhoenixKitProjects.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitProjects.{Ledger, Projects, TaskNotes}

  setup do
    {:ok, _} = Settings.update_setting("comments_enabled", "true")
    on_exit(fn -> Settings.update_setting("comments_enabled", "false") end)

    {:ok, user} =
      Auth.register_user(%{
        email: "notes-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    project = fixture_project()
    task = fixture_task(%{"title" => "Wire the notes"})

    {:ok, assignment} =
      Projects.create_assignment(%{
        "project_uuid" => project.uuid,
        "task_uuid" => task.uuid,
        "status" => "todo"
      })

    {:ok, user: user, project: project, assignment: assignment}
  end

  test "a note with usage writes the comment and the ledger rows together, linked both ways",
       %{user: user, project: project, assignment: a} do
    agent = Ecto.UUID.generate()

    {:ok, fields} =
      TaskNotes.validate(
        %{
          "summary" => "Obvious fix broke the import; reverted",
          "content" => "Tried the obvious fix; it broke the import. Reverted.",
          "outcome" => "failed",
          "next_steps" => "Try the batch API",
          "refs" => [
            %{"type" => "commit", "id" => "a1b2c3d", "url" => "https://example.com/c/a1b2c3d"},
            %{"type" => "commit", "id" => "a1b2c3d"},
            %{"type" => "pr", "id" => "42", "label" => "Batch import"}
          ],
          "usage" => %{tokens: 1800, cost_cents: 3, minutes: 4, model: "x-1"}
        },
        "agent_note"
      )

    {:ok, %{note: note, entries: entries}} =
      TaskNotes.create(
        a,
        fields,
        user_uuid: user.uuid,
        label: "ANDI agent",
        actor: %{kind: "ai_agent", uuid: agent},
        metadata: %{"api_key" => agent, "via" => "api"}
      )

    assert note.resource_type == TaskNotes.resource_type()
    assert note.resource_uuid == a.uuid
    assert note.status == "published"
    assert note.author_display_name == "ANDI agent"
    assert note.metadata["kind"] == "agent_note"
    assert note.metadata["api_key"] == agent
    assert note.metadata["usage"]["tokens"] == 1800
    assert note.metadata["usage_label"] == "1.8k tokens · $0.03 · 4m"
    assert note.metadata["summary"] == "Obvious fix broke the import; reverted"
    assert note.metadata["outcome"] == "failed"
    assert note.metadata["next_steps"] == "Try the batch API"
    # Deduped on (type, id) within the note; the url and label survive.
    assert note.metadata["refs"] == [
             %{"type" => "commit", "id" => "a1b2c3d", "url" => "https://example.com/c/a1b2c3d"},
             %{"type" => "pr", "id" => "42", "label" => "Batch import"}
           ]

    assert length(entries) == 3
    assert Enum.sort(Enum.map(entries, & &1.kind)) == ["cost", "time", "tokens"]
    assert Enum.sort(note.metadata["usage"]["entries"]) == Enum.sort(Enum.map(entries, & &1.uuid))

    for e <- entries do
      assert e.assignment_uuid == a.uuid
      assert e.actor_kind == "ai_agent"
      assert e.actor_uuid == agent
      assert e.billable == false
      assert e.metadata["note_uuid"] == note.uuid
      assert e.metadata["entered_by_uuid"] == user.uuid
    end

    assert %{minutes: 4.0, tokens: 1800.0, cost_cents: 3.0} =
             Ledger.totals_for_assignments([a.uuid])[a.uuid]

    assert Ledger.totals_for_project(project.uuid).ai_minutes == 4.0

    assert TaskNotes.count_for_assignments([a.uuid]) == %{a.uuid => 1}
    assert [listed] = TaskNotes.list(a.uuid)
    assert listed.uuid == note.uuid
    assert TaskNotes.to_json(listed).author == "ANDI agent"

    assert TaskNotes.to_json(listed).refs == note.metadata["refs"]

    assert get_in(TaskNotes.decorations([listed]), ["usage_label", "1.8k tokens · $0.03 · 4m"]) ==
             %{label: "1.8k tokens · $0.03 · 4m", on_save: nil}

    latest = TaskNotes.latest(a.uuid)
    assert latest.agent.uuid == note.uuid
    assert latest.redirect == nil

    assert TaskNotes.display_summary(nil, latest) ==
             %{text: "Obvious fix broke the import; reverted", source: :agent}

    assert TaskNotes.display_summary("Human text", latest) ==
             %{text: "Human text", source: :description}
  end

  test "a redirect by a person becomes the direction, and the display summary follows it",
       %{user: user, assignment: a} do
    {:ok, agent_fields} = TaskNotes.validate(%{"summary" => "Rewrote the parser"}, "agent_note")
    {:ok, _} = TaskNotes.create(a, agent_fields, user_uuid: user.uuid)

    {:ok, redirect_fields} =
      TaskNotes.validate(%{"summary" => "No — keep the old parser, fix the encoder"}, "redirect")

    {:ok, %{note: redirect}} =
      TaskNotes.create(a, redirect_fields, user_uuid: user.uuid, kind: "redirect")

    latest = TaskNotes.latest(a.uuid)
    assert latest.redirect.uuid == redirect.uuid
    assert latest.human.uuid == redirect.uuid

    assert TaskNotes.display_summary("", latest) ==
             %{text: "No — keep the old parser, fix the encoder", source: :redirect}
  end

  test "validation names the field: summary required, outcome closed, refs shaped" do
    assert {:error, %{"summary" => [_]}} = TaskNotes.validate(%{"content" => "x"}, "agent_note")

    assert {:error, %{"summary" => [_]}} =
             TaskNotes.validate(%{"summary" => String.duplicate("a", 241)}, "agent_note")

    assert {:error, %{"outcome" => [_]}} =
             TaskNotes.validate(%{"summary" => "s", "outcome" => "won"}, "agent_note")

    assert {:error, %{"outcome" => [_]}} =
             TaskNotes.validate(%{"summary" => "s", "outcome" => "done"}, "redirect")

    assert {:error, %{"content" => [_]}} = TaskNotes.validate(%{}, "note")
    assert {:ok, _} = TaskNotes.validate(%{"usage" => %{tokens: 5}}, "note")

    for bad <- [
          [%{"type" => "Commit", "id" => "x"}],
          [%{"type" => "commit", "id" => ""}],
          [%{"type" => "commit", "id" => "x", "url" => "ftp://host/x"}],
          [%{"type" => "commit", "id" => "x", "url" => "https://user:pw@host/x"}],
          [%{"type" => "commit", "id" => "x", "label" => String.duplicate("l", 121)}],
          ["nope"],
          List.duplicate(%{"type" => "commit", "id" => "x"}, 21)
        ] do
      assert {:error, %{"refs" => [_]}} =
               TaskNotes.validate(%{"summary" => "s", "refs" => bad}, "agent_note")
    end

    assert {:error, %{"kind" => [_]}} = TaskNotes.validate(%{"summary" => "s"}, "rant")
  end

  test "a person's note carries no usage and the kind says so", %{user: user, assignment: a} do
    {:ok, fields} =
      TaskNotes.validate(%{"content" => "Looked at it; nothing to add yet."}, "note")

    {:ok, %{note: note, entries: []}} =
      TaskNotes.create(a, fields, user_uuid: user.uuid, kind: "note")

    assert note.metadata["kind"] == "note"
    refute Map.has_key?(note.metadata, "usage")
    assert TaskNotes.to_json(note).author == user.email
  end

  test "an unknown kind and comments switched off are refused", %{user: user, assignment: a} do
    {:ok, fields} = TaskNotes.validate(%{"content" => "x"}, "note")

    assert {:error, :invalid_kind} =
             TaskNotes.create(a, fields, user_uuid: user.uuid, kind: "rant")

    {:ok, _} = Settings.update_setting("comments_enabled", "false")

    assert {:error, :unavailable} =
             TaskNotes.create(a, fields, user_uuid: user.uuid, kind: "note")
  end
end
