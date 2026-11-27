# PR 68 review

Reviewed `ce562b9` against `c872b8b`.

| Severity | Finding | Resolution |
| --- | --- | --- |
| BUG - HIGH | A comment edit queued a second LiveView message to change the selected recipients. A second edit or confirmation already in the mailbox could read the old selection and assign or notify the wrong person. | Apply the shared picker validation and update the dialog in the same message handler. |
| BUG - MEDIUM | Two embeds of the same project could toggle each other's trace or change each other's button labels. Both hooks identified a detached menu by its task UUID. | Each hook tracks the actual controls mounted in its list and retains them while the menu is moved under the document body. |
| BUG - MEDIUM | List previews replaced literal text matching their placeholder names. Restoring one code span could also rewrite an earlier span containing a placeholder. | Escape the marker prefix and restore spans in one pass. |
| BUG - MEDIUM | The new copy control sat inside links or buttons on the Hours, API usage, comments and task drawer surfaces. Navigation could take the click and nested controls had ambiguous keyboard behavior. | Render the reference as a native copy button beside the navigation control. |
| BUG - MEDIUM | On the default project page the title opens a drawer through a button. A modified click had no URL to open in a new tab. | Supply the task URL to popup titles and consume modified clicks before LiveView opens the drawer. |

My Projects also truncates each description to one visible line and checks the localized preview before rendering it.
