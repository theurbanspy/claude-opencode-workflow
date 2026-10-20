#!/usr/bin/env python3
"""check-plan.py — lint an oc-plan PLAN.md and (optionally) emit one worker task file per task.

  python3 check-plan.py PLAN.md [--repo-root DIR] [--emit OUT_DIR]

Errors (exit 1): missing section/field, open questions left, vague wording in worker-facing text,
unknown dependency, existing-file paths that do not exist, empty Requirements/Acceptance/Verify.
Warnings (exit 0): oversized brief/tasks, many files per task.
--emit writes OUT_DIR/T<n>.md = §6 Worker brief + the task, only if there are no errors.
No dependencies beyond the Python 3 standard library.
"""
import os
import re
import sys

SECTIONS = ["0 · Summary", "1 · Context", "2 · Design", "3 · Decisions", "4 · Invariants & scope",
            "5 · Open questions", "6 · Worker brief", "7 · Tasks", "8 · Verification", "9 · Review focus"]
FIELDS = ["Objective", "Repo", "Depends on", "Files", "Read first", "Requirements", "Do not",
          "Tests to write", "Acceptance", "Verify", "Size"]
NONEMPTY = ["Objective", "Files", "Requirements", "Acceptance", "Verify"]
# Words that hand a decision to the worker. Checked in §6 and §7 only.
VAGUE = [r"\betc\b", r"\bas needed\b", r"\bas appropriate\b", r"\bif necessary\b", r"\bif needed\b",
         r"\bTBD\b", r"\bTODO\b", r"\bmaybe\b", r"\bprobably\b", r"\bsomehow\b", r"\bsomething like\b",
         r"\bor similar\b", r"\bappropriately\b", r"\bproperly\b", r"\bsuitable\b", r"\breasonable\b",
         r"\bwhatever\b", r"\band so on\b", r"\bfeel free\b", r"\bup to you\b", r"\byour choice\b",
         r"\bif you think\b", r"\bconsider\b", r"\bperhaps\b", r"\bpossibly\b", r"\bsome kind of\b",
         r"\.\.\.(?!\w)", r"…"]
MAX_BRIEF_LINES, MAX_TASK_LINES, MAX_FILES = 40, 80, 5


def split_sections(text):
    parts, cur, buf = {}, None, []
    for line in text.splitlines():
        m = re.match(r"^## (\d+ · .+?)\s*$", line)
        if m:
            if cur:
                parts[cur] = "\n".join(buf)
            cur, buf = m.group(1), []
        elif cur:
            buf.append(line)
    if cur:
        parts[cur] = "\n".join(buf)
    return parts


def strip_comments(s):
    return re.sub(r"<!--.*?-->", "", s, flags=re.S)


def split_tasks(body):
    tasks, cur, buf = [], None, []
    for line in body.splitlines():
        m = re.match(r"^### (T\d+)\s+[—-]\s+(.+)$", line)
        if m:
            if cur:
                tasks.append((cur[0], cur[1], "\n".join(buf)))
            cur, buf = (m.group(1), m.group(2)), [line]
        elif cur:
            buf.append(line)
    if cur:
        tasks.append((cur[0], cur[1], "\n".join(buf)))
    return tasks


def field_values(task_text):
    vals, cur = {}, None
    for line in task_text.splitlines()[1:]:
        m = re.match(r"^\*\*([^*]+?):\*\*\s*(.*)$", line)
        if m and m.group(1) in FIELDS:
            cur = m.group(1)
            vals[cur] = m.group(2).strip()
        elif cur:
            vals[cur] += "\n" + line
    return {k: v.strip() for k, v in vals.items()}


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 2
    path = argv[1]
    repo_root = argv[argv.index("--repo-root") + 1] if "--repo-root" in argv else None
    emit = argv[argv.index("--emit") + 1] if "--emit" in argv else None
    text = open(path, encoding="utf-8").read()
    errors, warns = [], []
    secs = {k: strip_comments(v) for k, v in split_sections(text).items()}

    for s in SECTIONS:
        if s not in secs:
            errors.append(f"missing section '## {s}'")
        elif s not in ("9 · Review focus",) and not secs[s].strip():
            errors.append(f"section '## {s}' is empty")

    oq = secs.get("5 · Open questions", "").strip()
    if oq and oq.lower() != "none":
        errors.append("§5 Open questions is not 'none' — resolve them (move answers to §3) before approval")

    brief = secs.get("6 · Worker brief", "").strip()
    if len(brief.splitlines()) > MAX_BRIEF_LINES:
        warns.append(f"§6 Worker brief is {len(brief.splitlines())} lines (> {MAX_BRIEF_LINES}): it is sent with every task")

    tasks = split_tasks(secs.get("7 · Tasks", ""))
    if not tasks:
        errors.append("§7 has no task ('### T1 — title')")
    ids = [t[0] for t in tasks]
    if len(set(ids)) != len(ids):
        errors.append("duplicate task ids")

    def vague_scan(where, s):
        for pat in VAGUE:
            for m in re.finditer(pat, s, flags=re.I):
                line = s[:m.start()].count("\n") + 1
                snippet = s.splitlines()[line - 1].strip()[:90]
                errors.append(f"{where}: vague wording '{m.group(0)}' → decide it in the plan: \"{snippet}\"")

    vague_scan("§6", brief)
    seen = set()
    created = set()  # files marked (new) by earlier tasks: valid "Read first" targets later
    for tid, title, body in tasks:
        f = field_values(body)
        for k in FIELDS:
            if k not in f:
                errors.append(f"{tid}: missing field **{k}:**")
        for k in NONEMPTY:
            if k in f and not f[k]:
                errors.append(f"{tid}: field **{k}:** is empty")
        dep = f.get("Depends on", "none")
        for d in re.findall(r"T\d+", dep):
            if d not in seen:
                errors.append(f"{tid}: depends on {d}, which is not an EARLIER task")
        if re.search(r"\b(above|below|previous task|see T\d+)\b", body, flags=re.I):
            warns.append(f"{tid}: refers to other text ('above', 'see T…'); the worker only sees the brief + this task")
        vague_scan(tid, body)
        files = re.findall(r"`([^`]+)`\s*\((edit|new|delete)\)", f.get("Files", ""))
        if not files:
            errors.append(f"{tid}: **Files:** must list `path` (edit|new|delete)")
        if len(files) > MAX_FILES:
            warns.append(f"{tid}: {len(files)} files (> {MAX_FILES}) — consider splitting")
        if repo_root:
            base = os.path.join(repo_root, f.get("Repo", "").strip("` ") if f.get("Repo", "").strip("` ") not in (".", "") else "")
            for p, mode in files:
                full = os.path.join(base, p)
                if mode in ("edit", "delete") and not os.path.exists(full):
                    errors.append(f"{tid}: {p} marked ({mode}) but does not exist under {base}")
                if mode == "new" and os.path.exists(full):
                    errors.append(f"{tid}: {p} marked (new) but already exists")
            for ref in re.findall(r"`([^`\s]+?\.[A-Za-z0-9]+)(?::\d+(?:-\d+)?)?`", f.get("Read first", "")):
                if not os.path.exists(os.path.join(base, ref)) and ref not in created:
                    errors.append(f"{tid}: Read first `{ref}` not found under {base}")
        n = len(body.splitlines())
        if n > MAX_TASK_LINES:
            warns.append(f"{tid}: {n} lines (> {MAX_TASK_LINES}) — too big for one worker run, split it")
        seen.add(tid)
        created.update(p for p, mode in files if mode == "new")

    for w in warns:
        print(f"WARN  {w}")
    for e in errors:
        print(f"ERROR {e}")
    print(f"{len(tasks)} task(s), {len(errors)} error(s), {len(warns)} warning(s)")
    if errors:
        return 1
    if emit:
        os.makedirs(emit, exist_ok=True)
        for tid, title, body in tasks:
            with open(os.path.join(emit, f"{tid}.md"), "w", encoding="utf-8") as fh:
                fh.write("## Shared brief (applies to every task of this plan)\n\n" + brief.strip()
                         + "\n\n## Your task\n\n" + body.strip() + "\n")
        print(f"emitted {len(tasks)} task file(s) to {emit}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
