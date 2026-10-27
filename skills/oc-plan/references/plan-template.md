# PLAN — <title>

<!-- Two audiences. Sections 0–5 and 8–9 are for Claude and the user (decisions, rationale,
     review). Sections 6–7 are for the worker: check-plan.py --emit copies §6 + one task into each
     task file, and the worker sees NOTHING else (plus files attached with --context). -->

## 0 · Summary
<!-- 3–6 short sentences a non-engineer can follow: what changes for whom, what does not. -->

## 1 · Context
**Request:** <the user's request, verbatim or faithfully condensed>
**Repos:** <path(s); one git work tree per task>
**Sources read:** <CLAUDE.md, AGENTS.md sections, files and line ranges actually inspected>
**Existing architecture (relevant part only):** <components involved, how data flows today,
with `path:line` references>

## 2 · Design
<!-- The target design. Only what the change needs. Use the subsections that apply. -->
### Components & responsibilities
### Data flow
### Interfaces & contracts
<!-- Exact signatures with types, HTTP method/path/status codes/payload shapes, event names,
     DB columns, error types and messages. The worker copies these verbatim. -->
### Data model changes
### Integration points

## 3 · Decisions
<!-- Every non-obvious choice, settled. One line each: decision — reason — alternative rejected.
     Mark the ones the user confirmed: (user, YYYY-MM-DD). -->
| # | Decision | Reason | Rejected |
|---|---|---|---|

## 4 · Invariants & scope
**Must not change:** <behaviours, public contracts, files, data, outputs that stay identical>
**Patterns to follow:** <pattern → exemplar `path:line-range`>
**Reuse, do not re-implement:** <helper/abstraction → import path>
**Out of scope:** <tempting but excluded changes>
**Risk gates (need explicit user OK during execution):** <migrations, deps, deploy… or "none">

## 5 · Open questions
<!-- Must read exactly "none" before the plan is presented for approval. Resolved items move to
     §3 Decisions. A question you can answer by reading the code is not a question. -->
none

## 6 · Worker brief
<!-- Prepended to EVERY task file. ≤ 40 lines. Imperative, no rationale. Only what every task
     needs: design in 3–5 lines, contracts shared across tasks, invariants, conventions,
     reuse list. Always include this line:
     - Never silence a type, lint or test error (ignore comments, `as any`, skipped tests, empty catch); report it as PLAN ISSUES. -->

## 7 · Tasks

### T1 — <imperative title>
**Objective:** <one sentence: the observable result>
**Repo:** <path>
**Depends on:** none
**Files:** `<path>` (edit) · `<path>` (new)
**Read first:** `<path:line-range>` — <why: pattern to copy / function to call>
**Requirements:**
1. <precise, testable instruction: names, signatures, types, exact strings, error behaviour>
**Do not:** <task-specific prohibitions beyond the brief>
**Tests to write:** `<test file>` — cases: <input → expected output, one per line>
**Acceptance:** <observable criteria Claude will check>
**Verify:** `<command>` (run by Claude; the worker cannot execute code)
**Size:** <n> files, ~<n> lines

## 8 · Verification
**Per task:** the Verify line of each task.
**Integration:** <commands/scenarios proving the tasks work together>
**Regression:** <existing suites that must stay green>
**Edge cases:** <case → where it is tested>
**Manual / visual:** <if any, with the project's QA procedure>

## 9 · Review focus
<!-- What Claude must look at hardest in the diff for THIS plan (see references/review.md). -->
