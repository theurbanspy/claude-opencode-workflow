#!/usr/bin/env bash
# oc-worker.sh — run ONE bounded implementation task with OpenCode (DeepSeek V4.1 Flash) inside a
# git repository, and report what happened. Claude is the orchestrator; this script is the only
# way it talks to the OpenCode worker. Global install: ~/.claude/oc-worker (README.md).
#
# Usage:
#   ~/.claude/oc-worker/oc-worker.sh --repo <path> --task <task.md> [options]
#
# Options:
#   --repo <path>        git work tree the worker edits (required)
#   --task <file>        task specification, markdown (required)
#   --context <file>     extra file attached to the prompt (repeatable), e.g. AGENTS.md
#   --timeout <seconds>  hard wall-clock limit (default 900)
#   --label <slug>       short name used in the run directory (default: task file name)
#   --runs-dir <dir>     where run logs go (default: ~/.oc-runs/<repo name>)
#   --preflight-only     check CLI, model, repo and lock, then exit
#
# Exit codes:
#   0   worker finished, model verified (still review the diff: exit 0 ≠ correct)
#   2   usage error
#   3   preflight failed (CLI missing, model not listed, not a git repo, config missing)
#   4   provider/infra failure (quota, auth, network, model unavailable, OpenCode hung at
#       startup twice) — nothing to repair, retry later
#   5   worker failed (OpenCode error, no output)
#   6   MODEL MISMATCH — another model answered; treat the diff as untrusted
#   7   safety violation (another worker holds the lock, HEAD moved, branch changed)
#   124 timeout
#
# Never prints or stores credentials. Never falls back to another model or provider.

set -u
set -o pipefail

MODEL="${OC_WORKER_MODEL:-opencode-go/deepseek-v4.1-flash}"   # exact id; see README.md
AGENT="ocworker"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/worker-config.json"
PREAMBLE="$HERE/worker-preamble.md"
OPENCODE_BIN="${OC_WORKER_OPENCODE_BIN:-opencode}"   # override only for tests

REPO="" TASK="" TIMEOUT=900 LABEL="" RUNS_DIR="" PREFLIGHT_ONLY=0
CONTEXT=()

# Git as the launcher runs it on the target repo: no hooks, no fsmonitor (a worker-planted
# config must not run code in the orchestrator's process).
gsafe() { git -c core.fsmonitor= -c core.hooksPath=/dev/null -c diff.external= -C "$REPO" "$@"; }

die() { local code="$1"; shift; echo "oc-worker: ERROR: $*" >&2; exit "$code"; }
log() { echo "oc-worker: $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    --context) CONTEXT+=("${2:-}"); shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    --runs-dir) RUNS_DIR="${2:-}"; shift 2 ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done

# ---------- preflight -------------------------------------------------------------------------
[ -n "$REPO" ] || die 2 "--repo is required"
[ "$PREFLIGHT_ONLY" = 1 ] || [ -n "$TASK" ] || die 2 "--task is required"
case "$TIMEOUT" in ''|*[!0-9]*) die 2 "--timeout must be an integer (seconds)";; esac

command -v "$OPENCODE_BIN" >/dev/null 2>&1 || die 3 "OpenCode CLI not found ('$OPENCODE_BIN')"
command -v jq >/dev/null 2>&1 || die 3 "jq not found"
command -v perl >/dev/null 2>&1 || die 3 "perl not found (used for the timeout)"
[ -f "$CONFIG" ] || die 3 "worker config missing: $CONFIG"
[ -f "$PREAMBLE" ] || die 3 "worker preamble missing: $PREAMBLE"
[ -d "$REPO" ] || die 3 "repo not found: $REPO"
REPO="$(cd "$REPO" && pwd)"
gsafe rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 3 "not a git work tree: $REPO"
REPO="$(gsafe rev-parse --show-toplevel)"
if [ -n "$TASK" ]; then
  [ -f "$TASK" ] || die 2 "task file not found: $TASK"
  TASK="$(cd "$(dirname "$TASK")" && pwd)/$(basename "$TASK")"
fi
for c in ${CONTEXT[@]+"${CONTEXT[@]}"}; do [ -f "$c" ] || die 2 "context file not found: $c"; done

# The model must be listed exactly. No alias, no fallback.
# Every opencode call outside the worker run uses the worker's policy and a neutral cwd, so a
# config the worker might plant in the repo (opencode.json, .opencode/) is never loaded.
oc_neutral() {
  ( cd "${TMPDIR:-/tmp}" && OPENCODE_CONFIG="$CONFIG" OPENCODE_DISABLE_PROJECT_CONFIG=1 \
      OPENCODE_DISABLE_AUTOUPDATE=1 "$OPENCODE_BIN" "$@" ) < /dev/null
}
MODEL_LIST=""
for _try in 1 2 3; do   # the background service sometimes answers empty for a moment (seen 2026-10-20)
  MODEL_LIST="$(oc_neutral models 2>/dev/null)"
  [ -n "$MODEL_LIST" ] && break
  sleep 3
done
if [ -z "$MODEL_LIST" ]; then
  die 4 "'$OPENCODE_BIN models' returned nothing — provider unreachable (network?) or not logged in (opencode auth list)"
fi
if ! printf '%s\n' "$MODEL_LIST" | grep -qxF "$MODEL"; then
  die 3 "model '$MODEL' is not listed by '$OPENCODE_BIN models' — refusing to run (no fallback)"
fi

# One writer per repository: a lock inside the git dir (never tracked, never committed).
GIT_DIR="$(gsafe rev-parse --absolute-git-dir)"
LOCK="$GIT_DIR/oc-worker.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder="$(cat "$LOCK/pid" 2>/dev/null || echo '?')"
  if [ "$holder" != "?" ] && ! kill -0 "$holder" 2>/dev/null; then
    die 7 "stale lock $LOCK (pid $holder is gone). Inspect, then remove it by hand: rmdir/rm -r '$LOCK'"
  fi
  die 7 "another oc-worker (pid $holder) is writing to $REPO — refusing concurrent writes"
fi
echo $$ > "$LOCK/pid"
cleanup() { rm -rf "$LOCK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$PREFLIGHT_ONLY" = 1 ]; then
  echo "PREFLIGHT OK  model=$MODEL  repo=$REPO  opencode=$("$OPENCODE_BIN" --version 2>/dev/null | head -1)"
  exit 0
fi

# ---------- run directory + pre-state snapshot ------------------------------------------------
[ -n "$RUNS_DIR" ] || RUNS_DIR="$HOME/.oc-runs/$(basename "$REPO")"
[ -n "$LABEL" ] || LABEL="$(basename "$TASK" .md)"
LABEL="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-40)"
RUN="$RUNS_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$LABEL"
mkdir -p "$RUN" || die 3 "cannot create run dir $RUN"

snapshot() { # $1 = prefix (pre|post)
  gsafe rev-parse HEAD > "$RUN/$1.head" 2>/dev/null || echo "(no commits)" > "$RUN/$1.head"
  gsafe symbolic-ref -q --short HEAD > "$RUN/$1.branch" 2>/dev/null || echo "(detached)" > "$RUN/$1.branch"
  gsafe status --porcelain=v1 --untracked-files=all > "$RUN/$1.status"   # human-readable copy only
  # Content hash of every dirty/untracked path, read from NUL-separated status (-z): no quoting,
  # no escaping, so unusual file names (spaces, unicode, "->") cannot dodge the checks.
  # Output: "<hash>  <path>" with the path JSON-escaped only if it contains a control character.
  gsafe status --porcelain=v1 -z --untracked-files=all | python3 -c '
import hashlib, json, os, sys
repo = sys.argv[1]
parts = sys.stdin.buffer.read().split(b"\0")
paths, i = set(), 0
while i < len(parts):
    e = parts[i]; i += 1
    if len(e) < 4: continue
    paths.add(e[3:])
    if e[:1] in (b"R", b"C") or e[1:2] in (b"R", b"C"):
        if i < len(parts) and parts[i]: paths.add(parts[i])
        i += 1
for p in sorted(paths):
    name = p.decode("utf-8", "surrogateescape")
    full = os.path.join(repo.encode(), p)
    h = hashlib.sha1(open(full, "rb").read()).hexdigest() if os.path.isfile(full) else "deleted"
    shown = json.dumps(name) if any(ord(c) < 32 for c in name) else name
    sys.stdout.write(f"{h}  {shown}\n")
' "$REPO" > "$RUN/$1.hashes"
}
snapshot pre
git_fingerprint() { # config, hooks, info, attributes — anything that can make git run code
  ( cd "$GIT_DIR" && find config hooks info -type f 2>/dev/null | sort | xargs shasum 2>/dev/null )
  # core.hooksPath may point inside the work tree (e.g. .githooks/): fingerprint that folder too.
  local hp; hp="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || true)"
  echo "hooksPath=$hp"
  if [ -n "$hp" ]; then
    case "$hp" in /*) ;; *) hp="$REPO/$hp" ;; esac
    [ -d "$hp" ] && ( cd "$hp" && find . -type f | sort | xargs shasum 2>/dev/null )
  fi
  shasum "$REPO/.gitattributes" "$REPO/.gitmodules" 2>/dev/null
}
git_fingerprint > "$RUN/pre.gitdir"
# Recoverable copy of pre-existing tracked changes (a dangling commit; touches no ref, no file).
PRE_STASH="$(gsafe stash create 2>/dev/null || true)"
echo "${PRE_STASH:-none}" > "$RUN/pre.stash-commit"
gsafe diff HEAD --binary > "$RUN/pre.patch" 2>/dev/null || true
# Untracked (non-ignored) files are in neither of the above: copy them, except env files.
# Refuse to run if they cannot be protected (too big to copy).
UNTRACKED_KB="$(gsafe ls-files --others --exclude-standard -z | (cd "$REPO" && xargs -0 du -k 2>/dev/null) | awk '{s+=$1} END {print s+0}')"
if [ "$UNTRACKED_KB" -gt 51200 ]; then
  die 7 "pre-existing untracked files total ${UNTRACKED_KB} KB (> 50 MB): cannot back them up, refusing to let the worker edit"
fi
mkdir -p "$RUN/pre-untracked"
gsafe ls-files --others --exclude-standard | grep -vE '(^|/)\.env($|\.)' | while IFS= read -r f; do
  mkdir -p "$RUN/pre-untracked/$(dirname "$f")" && cp -p "$REPO/$f" "$RUN/pre-untracked/$f"
done
cp "$TASK" "$RUN/task.md"

PROMPT_FILE="$RUN/prompt.md"
cat "$PREAMBLE" "$TASK" > "$PROMPT_FILE"

# ---------- run the worker --------------------------------------------------------------------
ATTACH=()
for c in ${CONTEXT[@]+"${CONTEXT[@]}"}; do ATTACH+=(--file "$c"); done

log "run dir: $RUN"
log "model: $MODEL  repo: $REPO  timeout: ${TIMEOUT}s"
START=$(date +%s)
STARTUP_GRACE="${OC_WORKER_STARTUP_GRACE:-60}"   # normal startup is 3-5 s
run_once() {
  (
    cd "$REPO" || exit 3
    export OPENCODE_CONFIG="$CONFIG"
    export OPENCODE_DISABLE_PROJECT_CONFIG=1     # the target repo's own opencode.json cannot loosen the policy
    export OPENCODE_DISABLE_AUTOUPDATE=1
    # Own process group so the whole tree dies on expiry.
    # 124 = wall-clock timeout; 125 = no output at all within the startup grace (hung before any
    # model call — observed intermittently with --standalone on v2.0.10).
    perl -MPOSIX=:sys_wait_h -e '
      my ($t, $grace, $ev) = splice(@ARGV, 0, 3);
      my $pid = fork();
      die "fork failed" unless defined $pid;
      if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
      my $start = time;
      sub stop { kill "TERM", -$pid; sleep 5; kill "KILL", -$pid; waitpid($pid, 0); exit $_[0]; }
      while (1) {
        my $r = waitpid($pid, WNOHANG);
        if ($r == $pid) { exit(($? & 127) ? 128 + ($? & 127) : $? >> 8); }
        my $el = time - $start;
        stop(124) if $el >= $t;
        stop(125) if $el >= $grace && !(-s $ev);
        select(undef, undef, undef, 0.5);
      }
    ' "$TIMEOUT" "$STARTUP_GRACE" "$RUN/events.jsonl" "$OPENCODE_BIN" run --standalone --auto \
        --agent "$AGENT" -m "$MODEL" --format json \
        --title "oc-worker: $LABEL" \
        ${ATTACH[@]+"${ATTACH[@]}"} \
        -- "$(cat "$PROMPT_FILE")"
  ) < /dev/null > "$RUN/events.jsonl" 2> "$RUN/stderr.log"   # stdin closed: a background process group
}                                                              # reading the tty would be stopped (SIGTTIN)
touch "$RUN/.start-marker"
run_once
RC=$?
if [ "$RC" = 125 ]; then
  log "no output within ${STARTUP_GRACE}s (startup hang, no model call made) — retrying once, same model"
  mv "$RUN/stderr.log" "$RUN/stderr.attempt1.log"
  run_once
  RC=$?
fi
DURATION=$(( $(date +%s) - START ))

# Defence in depth: scrub anything that looks like a credential from the stored logs.
for f in "$RUN/events.jsonl" "$RUN/stderr.log"; do
  perl -pi -e 's/\b(oc_sk_|sk-|lpr_)[A-Za-z0-9_\-]{8,}/$1<redacted>/g' "$f" 2>/dev/null || true
done

# ---------- analyse ---------------------------------------------------------------------------
STATUS="ok"; CODE=0
SESSION="$(jq -r 'select(.sessionID) | .sessionID' "$RUN/events.jsonl" 2>/dev/null | head -1)"
ERR_JSON="$(jq -c 'select(.type=="error") | .error' "$RUN/events.jsonl" 2>/dev/null | head -1)"

if [ "$RC" = 125 ]; then
  STATUS="startup-hang"; CODE=4   # infrastructure: no model call was made, nothing to repair
elif [ "$RC" = 124 ]; then
  STATUS="timeout"; CODE=124
elif [ -n "$ERR_JSON" ]; then
  etype="$(printf '%s' "$ERR_JSON" | jq -r '.type // ""')"
  estat="$(printf '%s' "$ERR_JSON" | jq -r '.status // ""')"
  case "$etype:$estat" in
    provider*|*quota*|*:429|*auth*|*:401|*:403|*network*|*connect*|*timeout*|*model*|*:404|*:5??)
      STATUS="provider-error"; CODE=4 ;;
    *) STATUS="worker-error"; CODE=5 ;;
  esac
elif [ "$RC" != 0 ]; then
  if grep -qiE 'ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|network|fetch failed|unauthori[sz]ed|credential|api key' "$RUN/stderr.log"; then
    STATUS="provider-error"; CODE=4
  else
    STATUS="worker-error"; CODE=5
  fi
elif [ -z "$SESSION" ] || ! jq -e 'select(.type=="text")' "$RUN/events.jsonl" >/dev/null 2>&1; then
  STATUS="worker-error"; CODE=5
fi

# Model verification: every assistant message of the session must come from $MODEL.
MODELS_USED="unknown"
if [ -n "$SESSION" ]; then
  oc_neutral session export "$SESSION" --sanitize > "$RUN/session.json" 2>/dev/null || true
  MODELS_USED="$(jq -r '[.. | objects | select(has("providerID") and has("id") and (.id|type=="string")) | "\(.providerID)/\(.id)"] | unique | join(",")' "$RUN/session.json" 2>/dev/null || echo unknown)"
  rm -f "$RUN/session.json"   # transcript content stays in events.jsonl only
  if [ -n "$MODELS_USED" ] && [ "$MODELS_USED" != "unknown" ] && [ "$MODELS_USED" != "$MODEL" ]; then
    STATUS="MODEL-MISMATCH"; CODE=6
  elif [ "$CODE" = 0 ] && { [ -z "$MODELS_USED" ] || [ "$MODELS_USED" = "unknown" ]; }; then
    STATUS="model-unverified"; CODE=6
  fi
fi

snapshot post
SAFETY=""
[ "$(cat "$RUN/pre.head")" = "$(cat "$RUN/post.head")" ] || SAFETY="${SAFETY}HEAD moved ($(cat "$RUN/pre.head") -> $(cat "$RUN/post.head")); "
[ "$(cat "$RUN/pre.branch")" = "$(cat "$RUN/post.branch")" ] || SAFETY="${SAFETY}branch changed; "
git_fingerprint > "$RUN/post.gitdir"
cmp -s "$RUN/pre.gitdir" "$RUN/post.gitdir" || SAFETY="${SAFETY}.git config/hooks/info changed (see pre.gitdir vs post.gitdir); "
if [ -n "$SAFETY" ]; then STATUS="SAFETY-VIOLATION"; CODE=7; fi

# Files the worker changed = paths whose hash differs between pre and post.
CHANGED="$(diff <(sort "$RUN/pre.hashes") <(sort "$RUN/post.hashes") | sed -nE 's/^[<>] [^ ]+  //p' | sort -u)"
# Of those, which already had uncommitted changes before the run (someone else's work)?
PRE_DIRTY="$(sed -E 's/^[^ ]+  //' "$RUN/pre.hashes" | sort -u)"
TOUCHED_PREEXISTING="$(comm -12 <(printf '%s\n' "$CHANGED" | sed '/^$/d') <(printf '%s\n' "$PRE_DIRTY" | sed '/^$/d'))"
printf '%s\n' "$CHANGED" | sed '/^$/d' > "$RUN/changed-files.txt"
# Protected paths (case-insensitive: macOS filesystems are): the worker must never change the
# orchestrator's rules, its own policy, CI/hooks, or secrets.
PROTECTED="$(grep -iE '(^|/)(\.git/|\.claude/|claude\.md$|agents\.md$|scripts/oc-worker/|\.oc-runs/|\.husky/|\.github/|\.opencode/|opencode\.jsonc?$|\.githooks/|\.pre-commit-config\.ya?ml$|lefthook[^/]*$|\.lintstagedrc[^/]*$|\.envrc$|\.devcontainer/|\.vscode/|\.gitattributes$|\.gitmodules$)|(^|/)\.env' "$RUN/changed-files.txt" || true)"
# Git-ignored paths (node_modules/, .vscode/, build output…) are invisible to the hash snapshot.
# The worker cannot run code, so it has no legitimate reason to change any of them.
IGNORED_CHANGED="$(cd "$REPO" && find . -path ./.git -prune -o -type f -newer "$RUN/.start-marker" -print 2>/dev/null \
  | sed 's|^\./||' | gsafe check-ignore --stdin 2>/dev/null || true)"
if [ -n "$IGNORED_CHANGED" ]; then
  printf '%s\n' "$IGNORED_CHANGED" > "$RUN/ignored-changed.txt"
  PROTECTED="${PROTECTED}${PROTECTED:+
}$(printf '%s' "$IGNORED_CHANGED" | sed 's/$/ (git-ignored)/')"
fi
if [ -n "$PROTECTED" ]; then
  SAFETY="${SAFETY}protected path changed: $(printf '%s' "$PROTECTED" | tr '\n' ' '); "
  STATUS="SAFETY-VIOLATION"; CODE=7
fi
gsafe diff --stat > "$RUN/post.diffstat" 2>/dev/null || true

DENIED="$(jq -r 'select(.type=="tool_use" and .part.state.status=="error") | .part.state.error // empty' "$RUN/events.jsonl" 2>/dev/null | grep -c 'Permission denied' || true)"
jq -r 'select(.type=="text") | .part.text' "$RUN/events.jsonl" > "$RUN/result.md" 2>/dev/null || true

WORKER_STATUS="$(grep -E '^STATUS: *(done|partial|blocked)' "$RUN/result.md" | tail -1 | sed -E 's/^STATUS: *//')"
[ -s "$RUN/changed-files.txt" ] || echo "none" > "$RUN/changed-files.txt"

cat > "$RUN/summary.txt" <<EOF
STATUS: $STATUS
WORKER SAYS: ${WORKER_STATUS:-no report}   (done | partial | blocked — exit 0 does not mean done)
EXIT: $CODE (opencode rc=$RC)
DURATION: ${DURATION}s
MODEL REQUESTED: $MODEL
MODELS ANSWERED: ${MODELS_USED:-unknown}
SESSION: ${SESSION:-none}
REPO: $REPO
PRE-EXISTING STASH COMMIT: ${PRE_STASH:-none}   (restore: git stash apply <sha>)
PRE-EXISTING UNTRACKED BACKUP: $RUN/pre-untracked
PERMISSION DENIALS: ${DENIED:-0}
SAFETY: ${SAFETY:-ok}
ERROR: ${ERR_JSON:-none}
FILES CHANGED BY WORKER:
$(sed 's/^/  /' "$RUN/changed-files.txt")
PRE-EXISTING DIRTY FILES THE WORKER ALSO CHANGED (review carefully):
$(printf '%s\n' "${TOUCHED_PREEXISTING:-none}" | sed 's/^/  /')
EOF

cat "$RUN/summary.txt"
echo "RUN DIR: $RUN"
echo "----- worker report (last 40 lines of $RUN/result.md) -----"
tail -n 40 "$RUN/result.md"
[ "$CODE" = 0 ] || tail -n 15 "$RUN/stderr.log" >&2
exit "$CODE"
