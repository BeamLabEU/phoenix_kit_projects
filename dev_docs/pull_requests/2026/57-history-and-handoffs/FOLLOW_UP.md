# Follow-up — History, hand-offs and notices

How the panel's findings were resolved. Four rounds: the design (codex,
grok, zai — answered before any code; their answers shaped
`dev_docs/plans/2026-10-25-history-and-handoffs.md`), the built code
(codex, grok, zai), a final sweep before the PR (codex, grok, zai,
kimi), and a read of the fixes that sweep led to (codex, zai). A fifth seat (Mistral) answered the final sweep too; its findings
did not survive checking against the code, except the depth constant, and
its answer is not kept here.

## Round 1 — the design

Adopted as the plan: History read at request time from the rows already
kept (no copy table), the same feed per task in the drawer, every status
change a row (tick rules and rollups included), "your turn" from
dependencies only (never list order), notices written per recipient in
their language, Reopen asking why. Not built, by the plan's choice: a wait
with a due date and reminder, save as template, client approval on the
portal, structured task fields.

## Round 2 — the built code

Fixed in `52eb086`: one hand-off pass per write (a tick over N rows reads
the project once and tells each person once); every notice only to people
who may open the project (team or department members without a grant,
removed members, deactivated accounts); comments waiting for moderation
tell nobody; a recipient with no language set reads the site's; the
reopen reason posted only after the reopen succeeded.

Fixed in `e6612c1` (grok): the Events time fields still said UTC; a team's
reopen reason reached nobody; people mentioned in an API comment or a
reopen reason were never told; who a comment told vanished with core's
activity retention. `c851f10`: a project's completion lists above the task
that completed it.

## Round 3 — the final sweep

Fixed in `1eed9d7`:

- **BUG - MEDIUM** (codex, grok, zai): a tick that also closed the parent
  ran the hand-offs twice — `Handoffs.batch/1` around each status write.
- **BUG - MEDIUM** (codex, grok, kimi, zai): a second Start told everyone
  again — only the call that started the project tells.
- **BUG - HIGH** (codex, kimi): `Notices.decorate/2` wrote a task's line for
  someone who may not open the project — gated on `may_view?/2`.
- **BUG - HIGH** (grok): reopening a team's or department's task told nobody
  without a comment — every task event that names no recipient now tells
  the task's people (`Notices.tell_assignees/2`, called by `Activity.log/2`).
- **BUG - MEDIUM** (codex, grok, zai): "go on" swallowed the person's other
  ready tasks; the on-hold count was unused — separate notices, each with
  its own count.
- **BUG - MEDIUM** (grok, zai): the prerequisite's name was the primary
  language in a translated line — read per reader (`after_uuid`).
- **BUG - MEDIUM** (codex): a department's people left out its teams'
  members — they are included, as "My tasks" counts them.
- **BUG - HIGH** (kimi): a failed change (`db_pending`) read as done in
  History — dropped.
- **BUG - MEDIUM** (codex, kimi): API reopen reason posted where the key's
  role may not comment — gated on `Authz.can_role?/3`.
- **BUG - MEDIUM** (codex, kimi): the task removal row lacked its project —
  stamped.
- **BUG - MEDIUM** (codex): Reopen inside an expanded sub-project opened no
  dialog.
- **BUG - MEDIUM** (codex): the form's first status edit sent two notices.
- **BUG - MEDIUM** (grok): a wall time skipped by daylight saving was
  stored as UTC — refused.
- **NITPICK** (codex, grok, kimi, zai): the drawer's History id was not
  namespaced; actor-less lines did not read "Someone"; Russian agreement
  ("задача «…» выполнена").
- **IMPROVEMENT - MEDIUM** (all): tests for the time-zone layer, the API
  reason, registrations, the ledger gate and the department branch.

Added from the same round's "what is missing" and a check of every event
that should tell someone: handing a task on tells the new and the old
owner; removing a task tells its people; a person's note or new direction
on a task tells its people. The table is in the guide.

Checked and not changed:

- Estonian "„%{task}“ võib alata" (zai) is correct: *alata* is the
  intransitive "begin".
- The doubled @-mention ping (core's and this module's) is fixed: the
  handler claims the mention's delivery, so the box's ping finds it sent.
- The On hold badge now follows the dependencies of every task above.

## Round 4 — the fixes after the sweep

Fixed in `bdf6593`:

- **BUG - HIGH** (codex): History reloaded for a viewer taken off the
  project while the tab was open — access is asked again on every load.
- **BUG - MEDIUM** (codex): a template's task given to a person still
  reached them through core's bridge — the row then names no recipient.
- **BUG - MEDIUM** (codex, zai): handed on and started in one form save
  was two notices; a later edit in the same visit was none.
- **BUG - MEDIUM** (codex): the drawer's delete, the typed list's purge and
  the API's cascade told nobody of the tasks under a deleted one —
  `Notices.removing/4` tells every task the delete took.
- **BUG - MEDIUM** (codex, zai): a PATCH that only moved a task, or linked
  a meeting, said "changed your task" — quiet now; the 500-line batch
  passes `tell: false`.
- **BUG - MEDIUM** (codex): a comment held for moderation told nobody when
  approved — the comments module now calls `on_comment_published/3`
  (its own PR), and this module tells the comment's people then.
- **IMPROVEMENT - MEDIUM** (zai): a deleted note kept its words in the
  notices that quoted it — scrubbed like a comment.
- **NITPICK** (zai): guide drift (`tell_group/3`, `decorate/2`).

Checked and not changed:

- `PubSub.after_commit/1` inside a plain transaction (codex, zai) would
  announce before the outer commit; nothing calls it that way, and its doc
  says it must be the outermost transaction.
- A line deleted in the typed list (zai) is held, not removed — restorable,
  and how cut-and-paste moves a task — so it tells on the final delete.

Also built in this PR from the earlier reviews' open items: see the
seven folders' `FOLLOW_UP.md` (files links batched through core's
`Storage.direct_urls/1`, the PATCH in one transaction, and the rest).

Built with this PR in core (its own PR): V224, the `resource_uuid`
index History and the Activity page read through; notification type
labels shown in the reader's language (`gettext_backend:`).

Open (for the maintainer):

- Per-recipient reads in the notice path (`may_view?/2`, assignee lists):
  a few statements per person told, on writes only; batching them would
  mean a second copy of the authorization rule.
- Timed events typed before this change were stored as if UTC and now show
  shifted by the viewer's offset.

