# Claude plans, DeepSeek codes

Two Claude Code skills and a launcher that split the work between two models. Claude does the
thinking: it inspects your repo, settles the design, writes a plan of small tasks and reviews
every diff. DeepSeek V4.1 Flash, run through OpenCode Go (`opencode run`), does the typing: one
bounded task at a time, under a deny-by-default policy. You get Claude-level judgment on the
plan and the review, at a fraction of the cost for the bulk code writing.

## How it flows

```
you ──▶ /oc-plan ──▶ plan ──▶ you approve ──▶ /oc-execute
                                                  │
              ┌───────────────────────────────────┘
              ▼   for each task:
   DeepSeek writes code
        │
        ▼
   Claude reads the diff
        │
        ▼
   Claude runs the checks
        │
        ▼
   targeted correction (max 3) ──▶ next task ──▶ final report
```

## What's inside

| Path | Role |
|---|---|
| `skills/oc-plan/` | Skill: architecture-first plan, plan template, linter (`scripts/check-plan.py`), review rules |
| `skills/oc-execute/` | Skill: runs an approved plan task by task through the worker |
| `oc-worker/oc-worker.sh` | Launcher: preflight, lock, snapshot, timeout, model check, diff summary |
| `oc-worker/worker-config.json` | Deny-by-default OpenCode policy for the worker |
| `oc-worker/worker-preamble.md` | Rules prepended to every task sent to the worker |
| `oc-worker/test/` | Self-test and an OpenCode stub for offline runs |
| `oc-worker/README.md` | Detailed design, exit codes, limits, test results |
| `install.sh` | Copies everything into `~/.claude/` |

## Requirements

- macOS or Linux, with bash, git, jq, perl and python3
- Claude Code
- OpenCode >= 2.0.10, logged in with access to `opencode-go/deepseek-v4.1-flash`. Log in in a
  terminal, never paste a key into a chat:

```bash
opencode auth login opencode
```

## Install

```bash
git clone https://github.com/theurbanspy/claude-opencode-workflow
```

```bash
cd claude-opencode-workflow && bash install.sh
```

The installer puts the skills in `~/.claude/skills/` and the launcher in `~/.claude/oc-worker/`
(override the root with `CLAUDE_HOME`). An existing copy is moved to `<dest>.bak-<timestamp>`
first. It never touches your OpenCode config or credentials. Then check it:

```bash
bash ~/.claude/oc-worker/test/selftest.sh --live
```

The offline run (without `--live`) is free; `--live` uses a few requests of your quota.

## Use

1. Ask Claude for a plan with `/oc-plan` (or "plan this for OpenCode"). Review and approve it.
2. Say "execute with OpenCode" or run `/oc-execute`.
3. Claude only stops for a migration, a deploy, a new dependency or a change to the plan.
   Nothing is committed, pushed or deployed unless you ask.

Your project's `CLAUDE.md` / `AGENTS.md` win over the skills. For a small edit, just ask Claude
directly; the workflow pays off on multi-file changes.

## Changing the model

The model is pinned in two places: `MODEL=` in `oc-worker/oc-worker.sh` and `"model"` in
`oc-worker/worker-config.json`. Use the exact id shown by `opencode models`. There is never a
fallback model: if the pinned one is unavailable or swapped, the run fails.

## Safety in short

- The worker cannot execute code; Claude reads the diff before running any check.
- A deny-by-default policy plus launcher guards: the run exits with code 7 if HEAD moves, `.git`
  config or hooks change, or a protected path is touched.
- Uncommitted work is snapshotted before each task.
- This is a policy, not an OS sandbox. See "Limits" in `oc-worker/README.md`.

## License

MIT
