# Setup guide: Claude plans, DeepSeek codes

From zero to a working setup. Tested with OpenCode v2.0.10 on macOS and Claude Code 2.1.x.

How it fits together: Claude Code plans and reviews. The `oc-worker` launcher runs OpenCode, which
calls DeepSeek V4.1 Flash through an OpenCode Go subscription. Nothing runs in the background:
no daemon, no extra service, and your own OpenCode config (`~/.config/opencode`) is never changed.
The worker policy is injected per run through `OPENCODE_CONFIG`.

## 1. Prerequisites

- Claude Code, installed and working.
- `bash`, `git`, `jq`, `perl`, `python3` in your `PATH`.
- An **OpenCode Go** subscription (https://opencode.ai). It provides the DeepSeek model.
- OpenCode itself. Install it by following the official instructions at https://opencode.ai.
  Its installer places the binary at `~/.opencode/bin/opencode`; make sure `opencode` is in your `PATH`.

## 2. Log in to OpenCode

Do this in a terminal. Never paste an API key into a chat with an AI.

```bash
opencode auth login opencode
```

Choose "API key (service account)", paste your key in the hidden prompt. You should see
"Connected to OpenCode". Confirm the credential is stored (values are not shown):

```bash
opencode auth list
```

## 3. Check the model is available

```bash
opencode models | grep deepseek-v4.1-flash
```

Expected output:

```
opencode-go/deepseek-v4.1-flash
```

Always use the full `opencode-go/...` id; the launcher does not accept aliases.
If nothing is printed, see Troubleshooting.

## 4. Test the model by hand (optional but useful)

In any scratch git folder:

```bash
opencode run -m opencode-go/deepseek-v4.1-flash "Reply with exactly: PONG"
```

Expected output: `PONG`.

## 5. Install the skills

```bash
git clone https://github.com/theurbanspy/claude-opencode-workflow
```

```bash
cd claude-opencode-workflow
```

```bash
bash install.sh
```

The installer copies:

- `skills/oc-plan` to `~/.claude/skills/oc-plan`
- `skills/oc-execute` to `~/.claude/skills/oc-execute`
- `oc-worker` to `~/.claude/oc-worker`

If a destination already exists it is moved to `<destination>.bak-<timestamp>` first. Set
`CLAUDE_HOME` to install somewhere other than `~/.claude`. It warns if `opencode`, `jq`, `perl`,
`python3` or `git` is missing, and never touches OpenCode config or credentials.

## 6. Verify the install

Offline, free, with a stubbed OpenCode:

```bash
bash ~/.claude/oc-worker/test/selftest.sh
```

Then with the real model (uses a few requests of your quota):

```bash
bash ~/.claude/oc-worker/test/selftest.sh --live
```

All checks must pass. To check only the launcher against one of your repos:

```bash
~/.claude/oc-worker/oc-worker.sh --repo /path/to/your/git/repo --preflight-only
```

Expected output: `PREFLIGHT OK model=... repo=... opencode=...`

## 7. Use it

Restart Claude Code (or open a new session) so it discovers the new skills. Then:

1. Run `/oc-plan` and describe the change. Claude inspects the repo and writes a plan. Review and approve it.
2. Run `/oc-execute` (or say "execute with OpenCode"). Claude hands each task to DeepSeek, reads every
   diff, runs the checks and sends real failures back for repair (3 times at most).

Nothing is committed, pushed or deployed unless you ask. Each run is logged in
`~/.oc-runs/<repo-name>/` (`summary.txt`, `result.md`, `events.jsonl`).

## Troubleshooting

Exit codes are those of `oc-worker.sh`; details are in `oc-worker/README.md`.

| Symptom | Cause and fix |
|---|---|
| `model '...' is not listed` (exit 3) | Not logged in, the subscription lacks the model, or a typo. Run `opencode auth list` and `opencode models`. |
| `Go usage limit exceeded` / provider.quota 429 (exit 4) | Your subscription quota is used up. Wait for the window reset shown in your OpenCode dashboard. The launcher never switches to another model. |
| Provider unreachable, or empty model list (exit 4) | Network problem. Retry. |
| `startup-hang` (exit 4) | OpenCode produced no output within 60 s, twice. Usually transient; retry. |
| Model mismatch (exit 6) | Another model answered, for example a plugin in your global OpenCode config rerouting models. Remove or disable it, and treat that run's diff as untrusted. |
| Safety violation (exit 7) | Read the run's `summary.txt`: the worker touched something protected (or another worker holds the lock). Inspect the repo before continuing. |
| Quota errors persist with several stored logins | OpenCode picks one login and does not say which. Check `opencode auth list` and your OpenCode dashboard. |

### Changing the model

Edit both places, with the exact id shown by `opencode models`:

- `MODEL=` in `~/.claude/oc-worker/oc-worker.sh`
- `"model"` in `~/.claude/oc-worker/worker-config.json`

Then run the live self-test (step 6). There is never a fallback model.

### Reasoning effort

The worker uses the highest reasoning variant, `max`, by default (`VARIANT=` in `~/.claude/oc-worker/oc-worker.sh`). Variants accepted by `deepseek-v4.1-flash` on OpenCode Go: `default`, `low`, `high`, `max`. To try one run with another variant:

```bash
OC_WORKER_VARIANT=high ~/.claude/oc-worker/oc-worker.sh --repo /path/to/repo --task task.md
```

If a variant is refused you get `Variant unavailable` (exit 4).

## Uninstall

```bash
rm -rf ~/.claude/skills/oc-plan ~/.claude/skills/oc-execute ~/.claude/oc-worker
```

To restore a previous copy, move the matching `*.bak-<timestamp>` folder back to its original name.
Optionally delete the run logs in `~/.oc-runs/`.
