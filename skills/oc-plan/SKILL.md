---
name: oc-plan
description: >-
  Produce an architecture-first, implementation-ready plan that DeepSeek (OpenCode Go worker) can
  execute without making design decisions — Claude inspects the repo, settles architecture,
  contracts and open questions, then writes small self-contained tasks with exact files,
  requirements, tests and verify commands, lints the plan, and presents it for approval; it also
  defines how Claude reviews the worker's code against the plan. Use when the user wants a change
  implemented by DeepSeek/OpenCode ("plan for OpenCode", "plan it for DeepSeek", "oc-plan",
  "prépare un plan pour OpenCode"), or asks for a plan they intend to run with oc-execute. Works in
  Plan Mode. Do NOT use for tiny edits Claude should just make, or to execute a plan (that is
  oc-execute).
user_invocable: true
version: "1.0.0"
last_updated: "2026-10-20"
---

# oc-plan — architecture-first plans for the DeepSeek worker

Division of labour: **Claude decides, DeepSeek types.** Every architectural, product and
technical decision is made here, in the plan; the worker only turns precise instructions into
code. Anything the plan leaves open, the worker will decide badly or inconsistently — so leave
nothing consequential open.

Chain: `oc-plan` (this) → user approval → `oc-execute` (runs tasks with
`~/.claude/oc-worker/oc-worker.sh`, reviews per `references/review.md`). Know the worker's limits
(`~/.claude/oc-worker/README.md`): it sees ONLY the shared brief + its one task (+ `--context`
files), cannot run any code or tests, cannot read outside its repo, and never sees this
conversation.

**Project rules win.** The project's `CLAUDE.md` / `AGENTS.md` (and anything they point to)
override this skill. Reuse their wording in the plan instead of inventing new rules.

## 1 · Inspect before deciding (mandatory)

Do this yourself or with read-only Explore agents; record what you read in §1 "Sources read".

- The project's `CLAUDE.md`, `AGENTS.md`, contributing/architecture docs; the sections on
  conventions, testing, critical rules, and anything about the area being changed (audit logs,
  decision records, known issues).
- The code paths the change touches **and their callers** (grep usages). Find the existing
  pattern for this kind of change (a similar endpoint, component, test) — it becomes the
  exemplar the worker copies (`path:line-range`).
- Existing helpers/abstractions that already do part of the job (search before designing
  anything new). Types, schemas, API clients, formatters, validation utilities.
- How the project verifies changes: real commands from `package.json` / `Makefile` /
  `pyproject.toml` / CI / AGENTS.md. Never invent a command. Note which ones are scoped.
- `git status` of each repo: uncommitted work in files the plan will touch must be declared.

## 2 · Decide the architecture (before any task)

Fill §2 Design with only what the change needs: components and responsibilities, data flow,
dependencies, **exact interfaces and contracts** (signatures with types, HTTP method/path/status
codes/payloads, DB columns and types, error types and exact messages, event names, user-facing
strings copied from the project's source of truth), data model changes, integration points.

Fill §3 Decisions: every non-obvious choice, one line, with the rejected alternative. Prefer the
existing pattern over a new one; a new abstraction must justify itself against reuse of an
existing one. If the project requires research-backed or owner-approved decisions for some
domains (design, money, data…), apply that rule here.

Fill §4 Invariants & scope: what must not change (behaviours, public contracts, outputs, files),
patterns to follow with exemplars, helpers to reuse, explicit out-of-scope list, risk gates.

## 3 · Eliminate ambiguity

List in §5 every missing piece of information, conflicting requirement, edge case and assumption.
Then resolve each one:
- answerable from the code/docs → answer it, move to §3;
- a product, money, data, security or user-visible choice → **ask the user** (one batched
  question, 2–3 options, a recommendation) — never decide it silently;
- minor and reversible → decide, record in §3 as an assumption.
§5 must read exactly `none` before the plan is presented. Edge cases become test cases in tasks.

## 4 · Decompose into worker tasks

Rules that make DeepSeek reliable:
- **Small and single-purpose:** one concern, ≤ 5 files, roughly ≤ 150 changed lines. A new module
  and its tests go in the same task. Order tasks so each one leaves the repo consistent (types
  before users, backend contract before client call, migration task gated).
- **Self-contained:** a task never says "as above" or "like T2". Shared facts go in §6 Worker
  brief (≤ 40 lines, sent with every task); task-specific facts go in the task.
- **Exact, not explanatory:** names, signatures, types, import paths, exact strings, status codes,
  error behaviour, file locations. No rationale in worker-facing text (it lives in §3). No
  vague words — the checker rejects "etc", "as needed", "appropriately", "if necessary", "TBD",
  "…" and similar in §6–§7.
- **Point, don't paste:** reference the exemplar (`Read first`) instead of pasting code. Give a
  snippet (≤ 15 lines) only for logic that is easy to get subtly wrong. If you are about to write
  the whole implementation in the plan, the task is too small for delegation — do it yourself
  and say so in the plan.
- **Pin type-sensitive calls:** the worker cannot run the type checker. For any API with
  overloads, generics or nullable returns (fs, fetch, parsers, ORM queries…), write the exact call
  and options in the requirement (e.g. `readdirSync(dir, { recursive: true, encoding: 'utf8' })`,
  not "read recursively"). If the project's type check does not cover the new files (e.g. tests
  outside `tsconfig` include), give a scoped type-check command in Verify.
- **Tests are specified as cases:** `input → expected` lines the worker must encode in the named
  test file. The worker writes them; Claude runs them (`Verify`).
- **Verify is objective and scoped:** the exact command(s) Claude runs for that task, from §1's
  inspection. Integration and regression checks go in §8.
- **Guards ride along:** during §1 inspection, list the project's source/lint guard tests (tests
  that grep the source for forbidden tokens or regions, e.g. "no `DA` token inside the public
  routes block") and the regions they protect. Every task whose **Files** include a guarded file
  states the guard as a requirement ("inside lines X–Y no token may end in `DA`") and adds the
  guard test to its Verify. A guard the worker does not know about is a plan defect, not a
  worker mistake.
- **Size for the worker's track record:** a task that is purely mechanical and fully specified
  (exact strings, exact call sites) can go up to the ≤ 5 files / ~150 lines limit — do not split
  it further for comfort. Keep tasks small only where judgment or subtle logic is involved.
- **File size is a worker risk too:** cheaper models degrade on large files. A NEW file must be
  planned ≤ ~500 lines (split the module in the plan, not in review). For an existing file of
  more than ~800 lines, the requirement names the exact function/region (`path:start-end`) to
  edit and the worker is told not to restructure the rest; extracting a big file is its own task
  or Claude's own work.
- **Attach context explicitly:** if the worker needs a doc outside its repo (e.g. a parent
  `AGENTS.md`), name it in the task's Requirements as "attached" and note it for `--context`.
- **Risky steps are isolated:** migrations, dependency additions, config/CI changes are their own
  task with a risk gate in §4 (oc-execute asks the user before running them).

## 5 · Write and lint the plan

Use `references/plan-template.md` exactly (section names and field labels are parsed).
Location: in Plan Mode, write it into the plan file; otherwise write
`~/.oc-runs/<repo-name>/<YYYY-MM-DD>-<slug>/PLAN.md`. Then:

```bash
python3 ~/.claude/skills/oc-plan/scripts/check-plan.py <PLAN.md> --repo-root <repo or parent dir>
```

Fix every ERROR. Treat WARNs as smells to fix unless justified in §3. In Plan Mode the checker
can still read the plan file (read-only).

Self-review before presenting (answer each honestly; any "no" → fix the plan):
1. Could two competent developers implement each task and produce interchangeable code?
2. Is every contract the client and server/other modules share written once, in §2 or §6?
3. Does every edge case in §5's history map to a test case?
4. Does any task require the worker to choose a library, a file location, a name, a data shape,
   or an error message? (It must not.)
5. Is anything in scope that the user did not ask for?

## 6 · Present for approval

Follow the project's communication rules (e.g. "explain simply first"). Show: §0 Summary, the key
decisions (§3, highlighting any the user should confirm), out-of-scope, risk gates, the task list
(one line each), and how it will be verified. Then stop: approval is the user's. After approval,
execution is `oc-execute` — which emits the task files with
`check-plan.py PLAN.md --emit <run dir>/tasks` and reviews each result per
`references/review.md`.

## 7 · When the plan changes during execution

The plan is frozen at approval. Corrections from review do not change it. A plan defect found
during execution (by Claude or reported by the worker as `PLAN ISSUES`) is handled per
`references/review.md` "Plan issues": amend §2–§4 and affected tasks, log a dated line in §3,
and get the user's OK again if a contract, invariant, data model, scope or user-visible behaviour
changes.
