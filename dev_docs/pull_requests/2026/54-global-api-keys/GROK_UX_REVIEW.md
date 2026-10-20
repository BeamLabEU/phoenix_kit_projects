# Grok UX review of the API keys page

`grok` (Grok 4.3), no tools, a written description of the page and Max's first feedback, 2026-10-16.

**1. What to ship for a–c**

**a.** Placeholder: `e.g. Research agent`. The name is the agent’s job. Who it acts for is already the badge.

**b.** Drop the Home column. With one project, one line under the table: “Calls that omit a project use **Greenoak**.” At two or more projects, one control on the card, not a radio per row: “When a call omits the project, use [Greenoak ▾].”

**c.** Remove the Sub-projects column. Coverage stays on. Inside the per-area panel, at the bottom: a checked box, “Also cover sub-projects,” with the helper “Turn off only if this key must not see work nested under this project.”

**d** is a bug, not a preference. “Add a project” must keep its own state. A change to another row’s access must not clear the project or the preset the person already picked. Give that pair its own form, outside the row forms.

**2. Picking access**

Replace the ~23-option select with four choices: **Full · Read only · No access · Custom**. Custom opens the area grid you already have. Group the areas so the grid is scannable: Work (Tasks, Task status, Notes, Comments, Time), People (People, Client interactions), Admin (Project, Events, AI usage). Each area is None / Read / Write.

On the closed row, show the grant, not the word Custom: `Full`, or `Read only`, or `Custom — Tasks: write · Comments: read · 8 no access`. A project×area matrix is too much for a key that usually has one project. Presets start the grant; the summary is what you read later.

**3. “Home”**

“Home” reads as a landing page. The behavior is a default project: the project used when the call has no `?project=`. Label it **Default project**. Show it only once the key reaches a second project, as the single card-level select in (b). With one project, the sentence is enough.

**4. First key and the token modal**

A first-time user meets two editors for one decision (“Starts in project” / “Access there”, then a different table), plus Acts for, Shared, role, sub-projects, and Home before they have a second project. Hide those until the key needs them. Empty state: name the agent, pick one project, pick Full or Read only, create, paste into the agent.

The modal, in this order:

- The token, a Copy button, and “Shown once. Put it in the agent’s secret. It cannot be shown again; rotate the key to replace it.”
- One plain sentence from the grant: “Can read and change tasks, notes, and comments in Greenoak. Cannot see other projects.”
- Then, secondary: “Paste this into the agent.” The prompt names the project, the base URL, and `Authorization: Bearer`. It tells the agent not to ask the user to paste the key back into the chat. Say that anyone who receives this prompt receives the secret.
- After close, the card shows “Not used yet” and can show the setup steps again, without the token.

Rotate and Revoke need a confirm line: rotate cuts the old token off immediately, and the agent stops until the new one is pasted.

**5. Top five**

1. Stop row edits from clearing “Add a project”; that form keeps its own project and access.
2. Cut access to Full, Read only, No access, and Custom, and show a one-line grant summary on each project row.
3. Remove the Sub-projects column (always on; the off switch lives inside Custom) and replace the Home column with “Default project,” shown only from the second project.
4. Make the create card use those same four access choices, a generic name placeholder, and a modal that leads with the one-time token and a plain-language grant.
5. Hide Acts for, shared role, default project, and sub-project override until there is something to decide, and confirm Rotate/Revoke with the fact that the current token dies immediately.
