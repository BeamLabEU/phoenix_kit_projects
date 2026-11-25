# PR 65 review

Reviewed head `a04494e9` against `a0d95b0c`.

| Severity | Finding | Resolution |
| --- | --- | --- |
| BUG - HIGH | Importing `UserInfo.person_chip/1` prevented compilation with the locked core. Core 3.7.0, 3.8.0 and 3.9.0 all lack that component. | Use the shared chip when available and the released avatar component and mention markup otherwise. |
| BUG - HIGH | Descendant project listings and parent labels traversed through templates. The UUID form of the view check also skipped the template test on the requested project. | Resolve the project for UUID checks and stop the batched visibility walk at each template. The assignment status totals use the same visible project set. |
| BUG - HIGH | Reconnect accepted client-authored frame descriptions, and the browser captured every host's dialogs in document order. Typed values could be applied to another form. | Verify server-issued frame tokens bound to the host and viewer. Restore the stack atomically, capture only dialogs owned by this LiveView, and match the restored tokens before replaying fields. |
| BUG - HIGH | Removing inherited API key access used an update followed by an insert whose error was ignored. The UI could report success after a failed grant write. | Upsert the empty grant on the key/project unique index, update the home and audit record in the same transaction, and surface write errors to the caller. |
| BUG - HIGH | Conversion accepted an earlier top-level assignment after it had been nested or moved into another project. | Recheck the project and parent under the lock before creating the sub-project. |
| BUG - MEDIUM | The group drawer received only the user IDs for the visible avatars. | Keep all distinct account IDs from the batched lookup while retaining the display limit. The rendering test covers five people with four visible faces. |
| BUG - MEDIUM | Project notification titles ignored the recipient's content language. The form zone note also used a strict boolean operator on a nullable viewer zone. | Localize the project title using the recipient's language and handle an unset viewer zone in the form. |
| BUG - HIGH | The precommit dependency audit rejected the lockfile because of a high-severity advisory on `db_connection` 2.10.2. | Update the lockfile to 2.10.3. |

## Dependency behavior

The released comments component through 0.7.0 ignores `composer_start_open`. Those hosts retain the existing click-to-open editor. Automatic opening and core's richer person-card interactions depend on the corresponding host components and JavaScript.
