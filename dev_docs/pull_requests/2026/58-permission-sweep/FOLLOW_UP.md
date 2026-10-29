# Follow-up — PR #58 (permission sweep)

How each finding in `CLAUDE_REVIEW.md` stands against the current code. The
findings are codex's two rounds, checked by Claude, plus the two found while
gating the AI-translate modal. Re-verified 2026-10-29; paths are under
`lib/phoenix_kit_projects/`. The PR's commits: `82db490` (the sub-keys),
`13b6a01`, `5fa56dc`, `4feb121`, `05d447b` (the fixes), merged in `2a10448`.

## Fixed (pre-existing)

- ~~BUG - HIGH — a `manage_library` holder could delete or promote a private project's one-off from TasksLive~~ — `one_off_allowed?/3` asks every project using the task for its own rule (`:view` to promote, `:delete_tasks` to delete), `web/tasks_live.ex:573-580`. `13b6a01`.
- ~~BUG - HIGH (round 2) — the same through the task form (`ad_hoc: false` promotes)~~ — a one-off opens and saves only with `:edit_tasks` on every project using it (`one_off_editable?`, `web/task_form_live.ex:100-113`). `5fa56dc`.
- ~~BUG - MEDIUM — outline rename trusted a cached right~~ — the library half is re-asked live (`library_right?/1` → `Authz.manage_library?/1`, `web/outline_list.ex:296-298`, `:535-536`). `13b6a01`.
- ~~BUG - MEDIUM — the one-off lens scope was computed at mount~~ — `one_off_scope/1` runs on every load (`web/tasks_live.ex:195-203`). `13b6a01`.
- ~~BUG - MEDIUM — library writes worked with the module off~~ — `Authz.manage_library?/1` requires `PhoenixKitProjects.enabled?()` (`authz.ex:244-246`), and every library write goes through it (`web/tasks_live.ex:297-312`). `13b6a01`.
- ~~BUG - MEDIUM — every backfill could set its flag after a failed lookup or grant~~ — one fail-closed `backfill_sub_keys/3` (`lib/phoenix_kit_projects.ex:326-329`, `:353-412`): a read that raises returns `{:error, :lookup_failed}`, and the flag is written only when every grant returned `{:ok, _}`. `13b6a01`.
- ~~NITPICK — a fixture test asserted over its own fake scope~~ — replaced in `test/phoenix_kit_projects/web/permission_subkeys_test.exs` (with `test/support/live_case.ex`). `13b6a01`.
- ~~BUG - HIGH — `TemplateFormLive :edit` loaded and saved any project id~~ — `only_template/1` (`web/template_form_live.ex:194`), and the module key is checked at mount (`can_use_templates?`, `:94-100`). `05d447b`.
- ~~BUG - MEDIUM — the assignment and project forms checked their right only at mount~~ — `Web.WriteGate` (`web/write_gate.ex:24-47`) is mounted on the assignment, project and template forms. It re-checks every write event, `confirm_action_ok` included (`web/project_form_live.ex:726-729`). The autosave timer asks `WriteGate.allowed?/1` itself (`web/assignment_form_live.ex:2856-2867`). `05d447b`.
- ~~BUG - MEDIUM — `AITranslate.Embed` dispatched its six modal events with no permission check~~ — `Web.AITranslateGate` (`web/ai_translate_gate.ex`) is mounted on the task, assignment, template and project forms. `4feb121`.

## Notes

- The calendar test "reloads on a projects PubSub broadcast" fails on `main` as well (date-dependent).
- Projects moderation (comments) goes to project owners and managers.

## Open

None.
