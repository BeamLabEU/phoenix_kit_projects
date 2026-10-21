Everything built on dev.greenoak.ee since #51 was merged (2026-10-14), rebased on main after #52 and #53. 25 commits. The code was reviewed by codex and zai, codex re-reviewed the fixes, grok reviewed the page's design, and Max tested each step on dev.

**Two schema versions, V24 and V25.** Hosts need the usual generated migration (`PhoenixKitProjects.Migrations.Schema.up(prefix: …, version: 25)`).

## What is in it

**Max's testing of #51** (the first four commits):
- A plain to-do's form is a title and a status.
- Delete from the task form, with a subtask count.
- A × on each line of the text list (a setting, on by default); drag handles (a setting, off by default).
- New feature flags `waiting` and `dates`.
- A close button on every drawer.
- A crash fix: `and` with text on the left in the task row.

**API keys outside projects (chain V24).** Max: *"make API key stuff more global… set up permissions and what they can see and do per project"*; *"every setting that we already have in the project should also be for the api permissions"*.
- **Grants.** A key reaches projects through grants (`phoenix_kit_project_api_key_grants`): per project, per area, none / read / write. The areas are project, tasks, status, notes, comments, time, AI usage, events and people, plus each extension's (the CRM's client interactions).
- **Resolution.** The nearest grant up a project's tree decides, and an empty grant stops a parent's at that project.
- **Personal keys.** A personal key acts with its person's role on the grant's project, never above manager.
- **Default project.** The key's `project_uuid` is its default ("home"): where a call that names no project acts.
- **Checked where it acts.** Every request is checked against the project it acts in, chosen before the scope check. A field from an area the key cannot read comes back empty, and idempotency keys are per project.
- **`/me`** lists every project the key reaches with its access per area.
- **Comments over the API:** `GET` / `POST /tasks/:id/comments`.
- **The migration** gives every existing key exactly the access it had, and its down restores it. Verified down → up → up on a scratch database.

**Projects › API keys** — a sidebar section with two subtabs (core's three-level sidebar):
- **Keys**:
  - make a key, then set its access per project with a preset or a per-area grid;
  - rotate and revoke;
  - every change confirmed with a flash;
  - filters above five keys (status, kind, person, project, name), each shown only when it tells the keys apart.
- **Usage**:
  - requests counted per key, project and day, with failures and refusals (chain V25), next to the AI time, tokens and cost agents report;
  - a period of 7, 30 or 90 days against the one before, one key or all;
  - a chart by key or by project, failures per day, breakdowns by key and project, and the tasks the reported work went to;
  - which figures and columns show is each viewer's choice (core's column picker).
- Built from core components throughout. The chart palette moves to `Components.VizPalette`, shared with the Hours tab.
- A project's own API pages now only list the keys that reach it and link here.

**Permissions** (Max: *"make sure it's all configurable via permissions… you grant someone an API key and you want them to be able to rotate it. But you don't want them to create any extra keys"*):
- **New sub-keys of `projects`:**
  - `api_keys_create`, `api_keys_edit`, `api_keys_rotate`, `api_keys_revoke` — each on the holder's own keys;
  - `api_keys_manage` — every key, and making keys for anyone or shared.
- **Projects alone** shows a person their own keys and their usage.
- **Carried over:** a one-time grant gives the four own-key rights to every role that already holds `projects`.
- **Project owners** may change or remove their project's row of any key.
- **A personal key stops working** when its person loses the `projects` permission, even while still a member.

AGENTS.md has the full account ("API keys across projects", "API key usage").

## Checks

- 2066 tests, 0 failures, against core main.
- One older test changed to pass against core main: "no user-facing copy calls a task a template" searched the form's raw HTML, and core's date field now draws its calendar in an HTML `<template>` element. It now checks the visible text and the read-out attributes.
- `credo --strict` clean; dialyzer clean (7 skipped, as before).
- et/ru translated; other locales' new strings left empty.
- Live on dev.greenoak.ee: migrated to `pkp_schema:25`, every existing key's grants checked.

## In this folder

- `REVIEW_BRIEF.md` — what the reviewers were asked.
- `CODEX_REVIEW.md`, `ZAI_REVIEW.md` — the code review of V24.
- `CODEX_REREVIEW.md` — the re-review of the fixes.
- `GROK_UX_REVIEW.md` — the page's design.
- `FOLLOW_UP.md` — each finding and what was done.
