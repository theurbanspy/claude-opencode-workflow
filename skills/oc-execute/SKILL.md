---
name: oc-execute
description: >-
  Execute an APPROVED implementation plan in ANY project by delegating each bounded coding task to
  the OpenCode worker (DeepSeek V4.1 Flash via OpenCode Go) through ~/.claude/oc-worker/oc-worker.sh,
  while Claude stays the only orchestrator — it freezes scope, writes task specs, reviews every diff,
  runs the checks, sends real failures back for repair (max 3), and reports. Use when the user
  approves a plan and says "execute with OpenCode", "exécute avec OpenCode", "delegate to
  DeepSeek", "oc-execute", or asks Claude to orchestrate while DeepSeek implements. Do NOT use to
  create or approve a plan, for one-line edits Claude can do faster itself, or for anything that
  deploys, migrates or touches production.
user_invocable: true
version: "2.1.0"
last_updated: "2026-10-20"
---

# oc-execute — Claude orchestrates, DeepSeek implements

Launcher, policy, tests, limits: `~/.claude/oc-worker/` (read `README.md` there once per session
if anything below is unclear). The worker is a separate process (`opencode run`), **not** a Claude
subagent. Claude is the only authority: the worker writes code, Claude decides whether it is right.

**Project rules win.** Read the project's `CLAUDE.md` / `AGENTS.md` first. Anything stricter there
(deploy rules, commit rules, copy rules, design rules) overrides this skill. If the project has a
project-level variant of this skill, use that one.

## 0 · Preconditions (stop if one fails)

- The plan was **approved by the user in this conversation**. Approval covers the plan's scope —
  not deployments, not migrations, not anything in §2.
- `~/.claude/oc-worker/oc-worker.sh --repo <repo> --preflight-only` prints `PREFLIGHT OK`.
  Exit 3/4 → report it (CLI, model, login, network) and stop; never switch model or provider.
- One `--repo` per task = one git work tree. In a monorepo with nested repos, target the right one.

## 1 · Freeze the plan into tasks

**Resuming?** If the run dir already has a PLAN.md whose Execution log covers every task, do not
re-run anything: re-run §8 Regression (other sessions may have changed the tree since), then go
straight to §5. If it covers some tasks, continue at the first one not marked done/BLOCKED.


**Preferred input: a plan written with the `oc-plan` skill** (architecture, decisions, invariants,
worker brief, self-contained tasks). Copy the approved plan to
`~/.oc-runs/<repo-name>/<date>-<slug>/PLAN.md` (unchanged), lint it and emit the task files:

```bash
python3 ~/.claude/skills/oc-plan/scripts/check-plan.py PLAN.md --repo-root <dir> --emit <run dir>/tasks
```

Any ERROR → the plan is not executable as approved: fix wording-only issues, but anything that
changes a decision or scope goes back to the user.

If the approved plan was NOT written with `oc-plan` (a plain Plan Mode plan), convert it with the
`oc-plan` template first — architecture and contracts made explicit, §5 `none` — and show the user
any decision you had to add. Do not hand a vague plan to the worker.

## 2 · Gates the approved plan does NOT cover — ask the user first

Destructive file ops or discarding changes · DB migrations / irreversible data changes · any
deploy, production data access, outbound message or external side effect · auth, authorization,
payment or secrets-handling changes beyond the plan · new dependencies or infra changes · any
change that materially widens scope.

**Never** `git reset --hard`, `git checkout -- <file>`, `git clean`, `git stash` drop/pop,
overwrite user files, commit, push or deploy unless the user explicitly asks in the current
message. Recovery points are the launcher's snapshots, not commits.

## 3 · Before the first task — protect the starting state

For each repo: `git status --short`, current branch, `git stash create` (record the sha in
PLAN.md — a recovery point that changes nothing). If a task's `Files` include a file that is
**already modified**, note it; the review must separate the user's lines from the worker's
(`pre.patch` in the run dir).

Do not edit a repo yourself while a worker runs in it, and do not run two workers on one repo
(the launcher's lock refuses it). Other sessions editing the same repo would blur attribution —
avoid it.

## 4 · The loop — one task at a time

1. **Use the emitted task file** `<run dir>/tasks/T<n>.md` (shared brief + the task). Attach the
   files the task names as "attached" with `--context <file>` (the worker cannot read outside its
   repo).
2. **Run** (Bash, foreground, tool timeout ≥ task timeout + 60 s):
   `~/.claude/oc-worker/oc-worker.sh --repo <repo> --task <T<n>.md> --label T<n> [--context <file>]`
3. **Branch on the exit code:**

   | Exit | Meaning | Action |
   |---|---|---|
   | 0 | worker finished, model verified | step 4 — and read `WORKER SAYS`: `blocked`/`partial` is not done |
   | 4 | provider/infra (quota, login, network, startup hang) | not a repair; stop the plan, report, keep state |
   | 5 | worker error | inspect `stderr.log`; one re-run allowed, counts as an attempt |
   | 6 | MODEL MISMATCH / unverified | treat diff as untrusted; stop, report |
   | 7 | safety violation (HEAD moved, `.git` config/hooks changed, protected path edited, lock) | stop everything, report to the user — do not run any check in that repo |
   | 124 | timeout | inspect partial diff; split the task or re-run (counts as an attempt) |

4. **Review against the plan** following `~/.claude/skills/oc-plan/references/review.md`
   (scope → read the whole diff before running anything → contracts → invariants → patterns →
   tests → quality → Verify → pre-existing changes). The worker cannot execute code: first-pass
   check failures are normal. `PLAN ISSUES` in the worker report → the "Plan issues" procedure
   there, before any correction.
5. **Correct** with the correction-request format from `review.md` (deviations quoted from the
   plan, `file:line`, expected vs found, trimmed real failing output — never an empty block).
   **Max 3 corrections per task.**
6. Still failing after 3 → mark the task **BLOCKED** in PLAN.md (what fails, run dirs, diff left
   in place — do not revert), then continue only with tasks that neither depend on it nor touch
   the same files.

After each task, append a row to the **Execution log** in PLAN.md: task, attempts, status,
Verify result, and **review notes** — one line naming what you flagged or fixed (or "clean").
These notes are the worker's track record: they decide how large later tasks can be.

Do not ask the user to approve routine tasks — continue through the plan.

## 5 · Final review and report

Run the "Final review (aggregate)" of `review.md`: whole diff vs §2 Design and §4 Invariants, §8
integration and regression commands, conformance table. Report simply: what is done, what was verified (checks actually run vs.
code only read), a per-task table (attempts, status), remaining risks, blocked tasks, and exactly
what is **not** committed/pushed/deployed. Update PLAN.md. Offer the commit — do not run it.
