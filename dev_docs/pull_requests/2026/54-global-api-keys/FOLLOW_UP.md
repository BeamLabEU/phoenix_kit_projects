# Follow-up: how each finding was resolved

Findings from CODEX_REVIEW.md (C1), ZAI_REVIEW.md (Z) and CODEX_REREVIEW.md (C2). Commits are named by subject; all are in this PR.

## Fixed

| Finding | Source | What was done | Commit |
|---|---|---|---|
| `/hours` summed sub-projects a grant stops at (`inherit: false`, or an empty grant on the child) | C1, Z | Each nested project counts only where the key may read time; tokens and cost only where every summed project allows usage | Close access gaps in per-project API keys |
| `tasks:read` alone exposed minutes, tokens, cost, notes, events and interaction ids on tasks and in the briefing | C1 | Serializers read the request's view (`Json.put_view/1`, `may?/1`); a field from an area the key cannot read comes back empty. Documented in the guide | same |
| `Json.project` and the briefing listed sub-projects the key cannot reach | C1 | Filtered by reach | same |
| An unusable home (empty grant, membership ended) blocked every call, also to other projects | C1 | The key still authenticates; calls naming another project are checked there; calls staying home get `no_access` / `membership_ended`; `/me` says `home_refused` | same |
| The interaction link check demanded the interaction read scope on the task's own project before walking up to a parent | C1, Z | Pre-gate removed; each ancestor is checked on its own | same |
| Templates reachable by a grant | C1 | `access_for/2` refuses templates | same |
| `ApiKeys.move/3` replaced a stricter grant (even "no access") on the target | C1, Z | Replaced by `carry_grant/4`: copies the grant that reached the moved project, keeps any grant already there | same |
| The page's creator could change a personal key that acts for someone else; existing grants were not re-checked; a personal key's hidden role cap was editable | C1, Z | Only the key's person or a key manager changes a key; every row change re-checks the project; role only on shared keys. Later split into per-action permissions | same; Make every API key action its own permission |
| `/people` checked the home view only; a malformed `project` param fell back to home | Z | `/people` takes `project`; a non-string `project` is a 404 | same |
| Dead code and stale docs (`effective_role/2`, `get_for_project/2`, `personal_attrs/2`, one-project moduledocs) | C1, Z | Removed; moduledocs and AGENTS.md rewritten | same |
| Migration: write-without-read keys, `down_v24` restoring the original role/scopes, idempotency rows not renamed | C1 | Every write gets its read; down restores the home grant's role and narrows `tasks:read`; stored retry keys renamed to the per-project hash, once. Verified down → up → up on a scratch database | Keep V24 access exact across the upgrade and the rollback |
| Page state lost on re-render ("Add a project" reset) | C1, Z, Max | Both add forms keep their drafts in assigns. Also found: the row's access select sent the preset's label, so every change saved "read only" | Simplify the API keys page and keep what you typed |
| Notes and `/entries` still exposed usage; `/hours` judged child usage by the home grant | C2 | `Json.note/1` hides `usage` without `usage:read`; entries list only readable kinds; `/hours` usage needs every summed project | same as above (second commit of the round) |
| A blocked sub-project still had a row in its parent's task list | C2 | `Json.visible_row?/1` in lists, the briefing and lookups by uuid | same |
| `ProjectMove` offered grants that never reached the project, or a shadowed broader one | C2 | Offers only the grant `access_for/2` picks, and a personal key only when its person is on the project | same |
| Idempotency rename skipped raw 64-hex headers (and could collide) | C2 | Rename keyed on "key has no grants yet" instead of the hex shape | Keep V24 access exact… |
| The page could not grant sub-projects | C2 | Project lists include sub-projects | Simplify the API keys page… |

## Left as is

| Finding | Source | Why |
|---|---|---|
| A personal key reaches a sub-project through its parent's grant even when its person is not a member of the sub-project | Z | Same as before V24: sub-projects mostly have no members of their own, and their parent's members work in them |
| Membership is read on the grant's project, not the target | Z | By design: the grant's project is where the person's role lives |
| Down migration cannot restore pre-V24 retry keys | C2 | The hash is one-way; a retry across a rollback is not recognised. Noted in the migration |
| The ledger's preliminary write check uses any grant | C1 | It only decides whether to look the entry up; the exact check on the entry's project follows, and an entry outside the key's reach is a 404 either way |
| Extension `get`/`update` trust the provider to scope by project | C1 | Contract of `Extensions.ApiProvider`; the CRM provider scopes by the context's project |

## Grok's UX points

Adopted: generic name hint; default project only from the second project; sub-projects switch moved into Details; a custom grant read as one line; Rotate/Revoke confirm that the old token dies at once. Not adopted: collapsing the presets to four (Max asked for the per-module presets such as "Interactions, read only").
