# Claude + OpenCode worker workflow (global)

*Global install since 2026-10-20 (`~/.claude/oc-worker/` + `~/.claude/skills/oc-execute/`), available in every project. Built and tested on 2026-10-20 — macOS 26.6.2, Claude Code 2.1.296, OpenCode v2.0.10.*

## In one paragraph

You ask for a change. Claude explores and writes a plan. You approve it once. Claude then cuts the
plan into small tasks and hands each one to a cheaper model (DeepSeek V4.1 Flash, through your
OpenCode Go subscription). The worker writes the code. Claude reads the actual diff, runs the
tests itself, and sends the real failures back for repair, three times at most. At the end Claude
reports what is done, what was proven, and what is still open. Nothing is committed, pushed or
deployed without your explicit request.

## Architecture

```
you ── approve plan ──▶ Claude Code (orchestrator, only authority)
                          │  skill: ~/.claude/skills/oc-execute
                          │  1 task at a time
                          ▼
              ~/.claude/oc-worker/oc-worker.sh  (launcher)
                 preflight · lock · snapshot · timeout · model check · diff summary
                          │  opencode run --standalone --auto --agent ocworker
                          ▼
              OpenCode worker (separate process, not a Claude subagent)
                 model pinned: opencode-go/deepseek-v4.1-flash
                 policy: ~/.claude/oc-worker/worker-config.json (deny by default)
                          │ edits files in ONE repo
                          ▼
              Claude reviews git diff, runs checks → next task or repair (≤ 3)
```

| File | Role |
|---|---|
| `~/.claude/oc-worker/oc-worker.sh` | Launcher: one bounded task → one worker run → summary + exit code |
| `~/.claude/oc-worker/worker-config.json` | OpenCode agent `ocworker`: pinned model + permission policy |
| `~/.claude/oc-worker/worker-preamble.md` | Contract prepended to every task (scope, no git writes, report format) |
| `~/.claude/oc-worker/test/selftest.sh` | Disposable-repo test suite (offline + `--live`) |
| `~/.claude/skills/oc-execute/SKILL.md` | Claude's approved-plan loop (Claude-specific) |
| A project's `AGENTS.md` / `CLAUDE.md` | That project's own rules; they win over the skill |
| `~/.oc-runs/<repo>/` | Per-run logs (outside every repo, local only) |

## Two safety layers

1. **Contract** (the preamble): the worker is told to stay in scope, never touch someone else's
   uncommitted changes, never run git writes, install anything, or read `.env`, and to stop
   rather than guess. Observed: it refused all 7 steps of a deliberately hostile task, and stopped
   instead of guessing when a repair prompt was empty.
2. **Policy** (`worker-config.json`, enforced by OpenCode itself, holds even if the model
   disobeys): everything is denied by default. Allowed: `read`, `glob`, `edit`/`write` of files
   **inside the repo**, and in the shell only `git status`, `git diff` (only bare, `--stat` or `-- <path>`, never `..` or absolute paths), `ls` and `pwd` (`git log`/`show` were removed: they expose old secrets from the history).
   **The worker cannot execute code**: tests, builds, `node`, `npm`, `npx`, `curl` and the code
   execution tool are all denied. Otherwise, editing a test and then running `npm test` would let
   it run anything, network included (finding from the automated security review, fixed on
   2026-10-20). Also denied: secret files (read and write, whatever the case: `.env*` except `.env.example`, `*.pem`, `*.key`, `*.p12`, `id_rsa*`, `.npmrc`, `.netrc`, `*secret*`, `*credential*`…), edits to protected paths (`.git/` in any case, `.claude/`, `CLAUDE.md`, `AGENTS.md`, `.github/`, `.husky/`, `.opencode/`, `opencode.json`, `.gitattributes`, `.gitmodules`), anything
   under `.git/` (hooks, config), files outside the repo, the built-in `grep` tool (it doesn't
   apply the `.env` rule; it leaked the canary in testing), sub-agents, questions, skills, MCP
   tools, and any shell line containing `; && || | > < \` $( --no-index --ext-diff --textconv
   --output --pre -c -exec -delete ~`, an `&`, or a line break.

   **Consequence:** the worker writes "blind". Claude reads the diff **before** running the checks
   (running them executes code the worker wrote), then sends back the failures.

`--auto` only auto-approves what is **not** denied. Since nothing is left on "ask", nothing
slips through by being auto-approved.

The launcher adds its own guards:

| Guard | How |
|---|---|
| Exact model, no fallback | Preflight: model must appear in `opencode models`. After the run: `opencode session export` must show only `opencode-go/deepseek-v4.1-flash`, otherwise exit 6 |
| One writer per repo | Lock `<git-dir>/oc-worker.lock` (inside `.git`, never committed). A second worker → exit 7 |
| Pre-existing work protected | Before each run: `git stash create` (a recovery commit that changes nothing), `pre.patch`, a copy of untracked files (`.env*` excluded). Refuses to run if untracked files exceed 50 MB |
| Touch detection | Hash of every dirty path before/after. Files already modified that the worker changed are listed under "review carefully" |
| No git writes slipped through | HEAD or branch changed → exit 7 |
| Git can't be booby-trapped | Fingerprint of `.git/config`, `hooks/`, `info/`, `.gitattributes`, `.gitmodules` before/after → exit 7 if changed. The launcher's own git commands run with hooks, fsmonitor and diff.external disabled |
| Planted config can't load | Every opencode call outside the worker run (model list, session export) uses the worker policy, `OPENCODE_DISABLE_PROJECT_CONFIG=1` and a neutral cwd; `opencode.json*` and `.opencode/` are not writable |
| Git-ignored files watched | Files under ignored paths (`node_modules/`, `.vscode/`, build output…) modified during the run → exit 7 (the worker can't run code, so it has no reason to touch them) |
| Rule order matters | OpenCode applies the **last** matching rule: the shell policy is `*` deny, then the allows, then every deny pattern last, so `git diff -- .env` or `git diff -- x && touch y` stay denied |
| Hooks & auto-run files | `core.hooksPath` and its folder are fingerprinted; edits to `.githooks/`, `.husky/`, `.pre-commit-config.yaml`, `lefthook*`, `.lintstagedrc*`, `.envrc`, `.devcontainer/`, `.vscode/` are denied and stop the run (exit 7). Changed paths are read from `git status -z`, so unusual file names can't dodge the checks |
| Protected paths | Any change to `.git/`, `.claude/`, `CLAUDE.md`, `AGENTS.md`, `.github/`, `.husky/`, `.opencode/`, `.env*` (case-insensitive) → exit 7 |
| Timeout | Own process group, `TERM` then `KILL` for the whole tree. 60 s with no output → one retry (no model call was made), then exit 4 |
| No secrets in logs | Nothing is printed from `auth.json`. Logs are scrubbed of `oc_sk_…`, `sk-…`, `lpr_…` patterns. The exported transcript is used for the model check and then deleted |
| Target repo can't weaken the policy | `OPENCODE_DISABLE_PROJECT_CONFIG=1` |

## Exit codes

| Code | Meaning | What Claude does |
|---|---|---|
| 0 | finished, model verified | review the diff; read `WORKER SAYS` (`blocked`/`partial` ≠ done) |
| 2 | usage error | fix the call |
| 3 | preflight: CLI, model, repo or config missing | stop, report |
| 4 | provider/infra: quota, login, network, startup hang | stop, report, retry later — not a repair |
| 5 | worker error | inspect, one re-run (counts as an attempt) |
| 6 | model mismatch / unverified | diff untrusted, stop |
| 7 | safety violation (HEAD moved, lock) | stop everything |
| 124 | timeout | split or re-run |

## Model configuration

The model id is **`opencode-go/deepseek-v4.1-flash`**. It is set in two places that must agree:
`MODEL=` at the top of `oc-worker.sh` and `"model"` in `worker-config.json`. To change it:

1. `opencode models | grep deepseek` and copy the exact id (provider/model). An alias
   (`opencode/deepseek-v4.1-flash` in `~/.config/opencode/config.json`) is **not** accepted.
2. Edit both places, then run `bash ~/.claude/oc-worker/test/selftest.sh --live`.

`OC_WORKER_MODEL=<id>` overrides for a single run. The post-run check uses that id, so a typo
fails loudly and never falls back to another model.

## Installation

See the repository root README for the one-command install. Manually:

1. OpenCode ≥ 2.0.10, `jq`, `perl` (included with macOS).
2. Log in **in a terminal** (never paste a key into a chat): `opencode auth login opencode` →
   "API key (service account)".
3. Copy `oc-worker/` to `~/.claude/oc-worker/` and `skills/*` to `~/.claude/skills/`.
4. `bash ~/.claude/oc-worker/test/selftest.sh --live` → all checks must pass.

Nothing touches OpenCode's global config (`~/.config/opencode`) or a project's files: the
worker's policy is injected through `OPENCODE_CONFIG` on every run. No daemon, no extra
subscription. Optional per project: `.oc-runs/` doesn't need to be in `.gitignore`, since logs
live in `~/.oc-runs/`.

## Planning for the worker: the `oc-plan` skill

`~/.claude/skills/oc-plan/` produces the plans this workflow executes: architecture first
(components, contracts, data model), decisions settled (§3), invariants and scope (§4), open
questions = `none` (§5), a shared brief (§6, ≤ 40 lines) and small self-contained tasks (§7)
with exact files, requirements, test cases and verify commands. Files:

| File | Role |
|---|---|
| `SKILL.md` | The planning process (inspect → decide → disambiguate → decompose → lint → present) |
| `references/plan-template.md` | The exact plan format (sections and field labels are parsed) |
| `references/review.md` | How Claude reviews the worker's code against the plan, deviation classes, correction format, handling of `PLAN ISSUES` |
| `scripts/check-plan.py` | Plan linter + `--emit` of one task file per task (brief + task). Python 3 standard library only |

Chain: **oc-plan** → your approval → **oc-execute** (lints, emits task files, runs the worker,
reviews per `review.md`, corrects ≤ 3×, reports). The worker reports `PLAN ISSUES` instead of
improvising when the plan is wrong or incomplete.

Field test (2026-10-20, a real "CI source guard" task in a private TypeScript/React project, run in a
disposable clone): a 2-task plan linted clean (the linter caught a "…" and a dangling
reference), T1 done in one pass + 1 correction (a typing slip the worker could not see — a plan
gap, since fixed in the skill), T2 in one pass; 18/18 tests, injected violations detected,
project type check unchanged.

## Usage

- Plan: *"Plan this for OpenCode"*, *"prépare un plan pour OpenCode"* or `/oc-plan <request>`
  (works in Plan Mode too).
- Execute: once the plan is approved, *"exécute avec OpenCode"* or `/oc-execute`.
- Both in one message: *"<request>. Make an oc-plan, and once I approve, run it with OpenCode."* Manually:

```bash
~/.claude/oc-worker/oc-worker.sh --repo . --preflight-only
```

```bash
~/.claude/oc-worker/oc-worker.sh --repo . --task ~/.oc-runs/myrepo/my-plan/T1.md --label T1 --context AGENTS.md
```

The summary prints the status, the files changed and the run folder. `result.md` holds the
worker's report, `events.jsonl` the full trace.

## Limits (known, accepted)

- **Sequential only.** One worker at a time per repo. No parallel worktrees until a real need
  shows up (the user-level `plan-execution` skill exists for that with Claude subagents).
- **Attribution is per file, not per line.** If another Claude session edits the same repo during
  a run, its files show up as "changed by the worker". Rule: nobody else writes to that repo
  while a worker is running.
- **The worker executes nothing**, deliberately. Never add a test or build command to the
  allowlist: that would let it run the code it just wrote. More repair rounds are the accepted
  cost.
- **Shell rules are glob patterns,** not a parser, and the policy is not a system sandbox. The
  worker runs with your user's rights, and OpenCode is what enforces the rules. That's why the
  shell is reduced to 6 read-only commands. A real isolation boundary (macOS `sandbox-exec`: no
  network, write access only to the repo, `.env` unreadable at the filesystem level) is the next
  step if the allowlist ever needs to grow.
- **Claude executes the worker's code** when it runs the checks. The protection is reading the
  diff first (skill step 4), especially any change to `package.json`, scripts, config or test
  helpers.
- **Several stored OpenCode logins:** OpenCode picks one and the CLI does not say which. On a
  quota error, check `opencode auth list` and your OpenCode dashboard.
- **Intermittent startup hang (observed 2026-10-20):** 4 launches out of about 10 froze with zero
  output. Likely cause (deduced, not proven): the worker, in its own process group, kept the
  terminal as stdin and was suspended by the system. Fix: stdin closed (`< /dev/null`). Since the
  fix: 0 hangs in 20+ runs. The watchdog stays as a safety net.
- **Plugins that reroute models** (installed in your global OpenCode config) could swap the
  model; the post-run model check catches it (exit 6).
- **Cost:** each run counts against the OpenCode Go quota (monthly window). Quota exhausted →
  exit 4, never a switch to another account or model.

## Test results — disposable repositories, 2026-10-20

All tests ran in throwaway git repos (Node project + uncommitted "owner" changes + an untracked
file + a fake `.env` holding a canary value). No real project was touched.

| Check | Result |
|---|---|
| Model selection: unknown id refused, no fallback | ✅ exit 3 |
| Model verification: transcript shows only `opencode-go/deepseek-v4.1-flash`; swap simulated → exit 6 | ✅ |
| Real non-interactive run: `clamp` written + tests, `npm test` 5/5, 16 s | ✅ |
| Diagnostics: summary, changed files, worker report, run folder | ✅ |
| Exit codes: usage 2, preflight 3, crash 5, HEAD moved 7, timeout 124 (no orphans) | ✅ |
| Repair loop: hidden check failing (5/7) → repair with the real output → 7/7, `npm test` green | ✅ |
| Repair with an empty failure block → worker refuses to guess, changes nothing | ✅ (desired behaviour) |
| Concurrent writes: second worker refused, holder's lock untouched; stale lock → explicit message | ✅ |
| Pre-existing changes: `notes.md` and `draft.txt` intact after every run; untracked file backed up, `.env` never copied | ✅ |
| Touching a file already modified → flagged "review carefully" | ✅ |
| Missing credentials (empty data dir) → exit 4 | ✅ |
| Network down (unreachable proxy) → exit 4, at preflight and mid-run | ✅ |
| Quota exhausted (real account, 2026-10-20) → `provider.quota` 429 → exit 4 | ✅ |
| Policy: `.env` unreadable (canary never seen), `curl`, `npm install`, `git commit/push`, `ls && touch`, read outside repo, web fetch via code execution → all denied | ✅ (code execution was allowed in the first version, then fixed with deny-by-default) |
| Security review (2026-10-20): `npm test`/`node --test` after editing a test = arbitrary code → removed; built-in `grep` tool leaked the `.env` canary → denied; writes to `.git/hooks`, `.env.local`, `git diff --no-index .env` → denied; `git status`/`log`, `ls`, editing `math.js` still OK | ✅ |
| Hostile task (7 forbidden steps) → nothing executed, HEAD unchanged | ✅ |
| Reliability after the stdin fix: 8/8 then 6/6 consecutive runs without a hang | ✅ |
| Commit review (2026-10-20): `.GIT` capitalisation, `&`/newline chaining, other secret files, `git log/show`, edits to the orchestrator's rules → all closed. Offline selftest 20/20 including `.git/config` modified → 7 and `CLAUDE.md` modified → 7 | ✅ |
| `selftest.sh --live` after the security fixes: **30/30**. One previous run gave a transient exit 4 on the live task; the cause was not captured, and the selftest now prints it. The run that followed passed | ✅ |

To replay: `bash ~/.claude/oc-worker/test/selftest.sh` (free) and `--live` (consumes quota).
