# Reviewing a worker's implementation against the plan

Used by `oc-execute` after every worker run, and once more on the aggregate diff. The plan is the
specification; the worker's report is a claim. Evidence = the diff + checks Claude ran.

## Per task — in this order (stop at the first blocking finding)

1. **Run status.** Launcher exit code and `WORKER SAYS`. `PLAN ISSUES` not `none` → go to
   "Plan issues" below before anything else.
2. **Scope.** `git -C <repo> diff --stat` and the launcher's `FILES CHANGED BY WORKER` vs the
   task's **Files** list. Any extra file = deviation S (scope). Any listed file untouched =
   possible incompleteness.
3. **Read the whole diff before running anything** (checks execute the worker's code). Flag
   changes to build scripts, `package.json` scripts, CI, hooks, config or test helpers not in
   **Files** → stop, do not run checks, treat as S.
4. **Contracts.** For each item of §2 Interfaces and the task's Requirements: grep the exact
   names, signatures, types, strings, status codes. Paraphrase is a deviation C (contract),
   even when "equivalent".
5. **Invariants.** For each §4 "Must not change" item touched by the task: show it still holds
   (diff of the region, a grep, or a regression test). Broken → deviation I (invariant).
6. **Patterns & reuse.** New code follows the named exemplar; listed helpers are imported, not
   re-implemented; no new abstraction, layer, util file or dependency the plan did not name →
   otherwise deviation P (pattern/drift).
7. **Tests.** Every case of **Tests to write** exists and asserts the stated expected value
   (not just "does not throw"). Missing or weakened → deviation T (tests).
8. **Quality.** Error handling, validation, typing, logging, security as required by the task
   and §6 → otherwise deviation Q.
9. **Verify.** Run the task's Verify commands — type check first (the worker writes blind; typing
   slips are the most common first-pass failure). Then the §8 regression suites the task can affect.
   Capture output in a machine-readable form (TAP/JSON reporters) for repair prompts.
10. **Pre-existing changes.** Any file under "PRE-EXISTING DIRTY FILES THE WORKER ALSO CHANGED":
    compare with the run's `pre.patch`; the user's lines must be intact.

13. **Cold second read (tasks on money, authorization or a restricted role only).** Claude wrote
    the plan, so Claude tends to confirm its own spec. For these tasks, hand a read-only subagent
    ONLY the relevant plan excerpt (§2 contracts, §4 invariants, the task), the diff and the Verify
    output — no worker report, no review notes — and ask it to list deviations. Its findings go
    through the normal correction flow. Skip it for ordinary tasks.

Generated code compiling or tests passing is not proof the task is right; steps 2–8 are.

## Deviation classes → action

| Class | Example | Action |
|---|---|---|
| S scope | extra file, unrelated reformat | correction: revert that hunk (worker), or accept if trivial and note it |
| C contract | renamed field, different status code, reworded message | correction, quoting the plan text |
| I invariant | behaviour that must not change did | correction; if the plan forces it → plan issue |
| P drift | new helper duplicating an existing one, new abstraction | correction: use the named one |
| T tests | missing case, assertion too weak | correction listing the exact cases |
| Q quality | swallowed error, missing validation | correction with the expected behaviour |
| F failing check | Verify red | correction with the trimmed failing output |

Deviations that are improvements are still deviations: either reject, or amend the plan
(§3 Decisions, dated) — never accept silently.

## Correction request (= the repair task file)

```
## Correction <k> of 3 — task T<n> "<title>"
The review of your change found these deviations from the approved plan. Fix ONLY these.
Do not change anything else; do not redesign.

1. [C] `src/x.ts:42` — plan requires `createInvoice(input: InvoiceInput): Promise<Invoice>`;
   found `createInvoice(data: any)`. Change the signature to the plan's.
2. [F] check output (trimmed):
   ```
   not ok 3 - rejects empty list
     expected: RangeError 'values must not be empty'
     actual:   returned NaN
   ```
3. [T] missing test case: `[] → RangeError('values must not be empty')` in `test/x.test.js`.

**Files:** <same list as the task, or narrower>
**Acceptance:** all items above resolved; <task Verify> passes.
```

Rules: quote the plan, give `file:line`, state expected vs found, one fix per item, never send
an empty or "make it work" request. Max 3 corrections per task; then the task is BLOCKED (see
oc-execute).

## Plan issues reported by the worker

The worker reports `PLAN ISSUES` instead of improvising when it finds a missing requirement, a
contradiction with the code, or a needed scope change. Claude then:

1. Verifies the claim in the code (the worker can be wrong).
2. If the plan is wrong or incomplete: amend it — §2/§3/§4 + the affected tasks — and log a dated
   line in §3. **If the amendment changes a contract, an invariant, the data model, scope, or a
   user-visible behaviour, ask the user before continuing** (that is a re-approval, not a
   routine task). Otherwise continue.
3. Re-run the task with the amended text (does not count as a correction).

## Final review (aggregate)

After the last task: whole diff per repo vs §2 Design and §4 Invariants (cross-task drift often
only shows here: two tasks each adding a slightly different helper, inconsistent naming), §8
integration + regression commands, and a conformance table in the report:

| Plan item | Where implemented | Evidence (check run / diff read) | Status |
|---|---|---|---|

**Simplify pass (after the conformance table, before the report).** The worker follows the plan
literally and never tidies. On the aggregate diff, look for: the same expression built twice and
pushed to two places (build once, derive the second), copy-pasted blocks that differ by one
value (one block + a ternary), helpers that only forward a call (keep only with a written reason
in a comment), and comments that cite the plan, a task id or an audit section number (`§3-4`,
`T2`) — they rot once the plan is gone. Fix these yourself when they are small and behaviour-
preserving, then re-run the §8 regression commands; otherwise send one correction. Log what you
changed in PLAN.md.
