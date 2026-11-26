# PR 66 review

Reviewed `4b51e85` against `b4ffd87`.

| Severity | Finding | Fix |
| --- | --- | --- |
| BUG - HIGH | The Hours page traversed every descendant of a project. A member could see ledger entries beneath a template even though the project page denied access there. Selecting a project rebuilt the same unrestricted set. | Use the shared project visibility resolver and intersect the selected subtree with the viewer's allowed projects on both Hours pages. |
| BUG - HIGH | Reconnect compared only the assignment's second-precision timestamp. A linked task rename or two different assignment states saved in the same second could leave that timestamp unchanged and allow a stale draft to overwrite newer text. | Derive the form version from the saved assignment fields and linked task words. |
| BUG - MEDIUM | Batched API access accepted uppercase UUIDs during validation but keyed the project lookup by the lowercase database value. The caller could receive a refusal for a valid grant. | Resolve each canonical UUID once and return the answer under the caller's original key. |
| IMPROVEMENT - MEDIUM | Listing reachable projects for a key walked each inheriting grant separately. Query count grew with grant count even when all the trees had the same depth. | Walk the granted roots together, then apply the existing nearest-grant rule. |
