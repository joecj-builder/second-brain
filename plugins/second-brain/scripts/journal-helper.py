#!/usr/bin/env python3
"""Read-only helper for the second brain's scheduled runs.

The nightly journal and weekly dream run unattended with a narrow allow list
(see sb_write_job_settings in job-lib.sh). Rather than allowing python3, find
or gh in general, the runs may call only this script, as

    python3 -I <plugin>/scripts/journal-helper.py <command> ...

It never writes anything and prints plain text to stdout. Standard library
only. The only process it starts is the GitHub CLI (`gh`), read-only.

Commands:
  sessions --date D | --since D [--until D] [--max-chars N]
      Compact summaries of Claude Code and Claude desktop (Cowork) sessions
      that were active on those dates (local time): title, folder, branch,
      PRs, and the user's prompts with short assistant notes. Scheduled runs
      themselves are skipped.
  modified --root DIR --date D [--ext .md]
      Files under DIR modified on D (local time), relative paths, newest
      first. Skips .git, .obsidian and .trash.
  github --date D
      Pull requests the signed-in GitHub user authored or was involved in
      that were updated on D. Says so and exits 0 if gh is missing or
      signed out.
  github-pr --repo OWNER/REPO --number N
      One PR's description and commits.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import date, datetime, timedelta

HOME = os.path.expanduser("~")
SESSION_ROOTS = [
    ("Claude Code", os.path.join(HOME, ".claude", "projects")),
    ("Claude desktop (Cowork)",
     os.path.join(HOME, "Library", "Application Support", "Claude", "local-agent-mode-sessions")),
]
# First prompts of the scheduled/automatic runs; their transcripts aren't work.
SKIP_PROMPT_PREFIXES = (
    "# Nightly Journal",
    "/second-brain:dream",
    "/second-brain:document --auto",
)
SKIP_DIRS = {".git", ".obsidian", ".trash", "node_modules", "subagents"}
PROMPT_CHARS = 300
ASSISTANT_CHARS = 200
GH_TIMEOUT = 60


def parse_date(s):
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        raise argparse.ArgumentTypeError("want YYYY-MM-DD, got %r" % s)


def day_bounds(d1, d2):
    """Local-time [start, end) timestamps covering d1..d2 inclusive."""
    start = datetime(d1.year, d1.month, d1.day).timestamp()
    end_day = d2 + timedelta(days=1)
    end = datetime(end_day.year, end_day.month, end_day.day).timestamp()
    return start, end


def local_day(ts):
    """ISO timestamp from a transcript ('...Z' = UTC) -> local date, or None."""
    if not isinstance(ts, str) or not ts:
        return None
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone()
    return dt.date()


def clip(text, n):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[: n - 1] + "…"


def walk_jsonl(root, require_projects):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        if require_projects and "/projects" not in dirpath:
            continue
        for name in filenames:
            if name.endswith(".jsonl"):
                yield os.path.join(dirpath, name)


def user_text(content):
    """The typed text of a user entry, or None for tool results and meta."""
    if isinstance(content, list):
        texts = [c.get("text", "") for c in content
                 if isinstance(c, dict) and c.get("type") == "text"]
        content = "\n".join(t for t in texts if t)
    if not isinstance(content, str) or not content.strip():
        return None
    s = content.strip()
    if s.startswith("<command-name>"):
        # A slash command: keep "/name args".
        name = s.split("<command-name>", 1)[1].split("</command-name>", 1)[0]
        args = ""
        if "<command-args>" in s:
            args = s.split("<command-args>", 1)[1].split("</command-args>", 1)[0]
        return (name + " " + args).strip()
    if s.startswith(("<local-command", "<system-reminder>", "<task-notification>",
                     "<command-message>", "[Request interrupted")):
        return None
    return s


def summarize_session(path, d1, d2):
    title = None
    cwd = None
    branch = None
    prs = []
    first_prompt = None
    times = []
    items = []  # ("U"|"A", text)
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return None
    with f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if not isinstance(e, dict):
                continue
            kind = e.get("type")
            if kind == "ai-title" and e.get("aiTitle"):
                title = e["aiTitle"]
                continue
            if kind == "pr-link" and e.get("prUrl"):
                if e["prUrl"] not in prs:
                    prs.append(e["prUrl"])
                continue
            if kind not in ("user", "assistant") or e.get("isSidechain") or e.get("isMeta"):
                continue
            msg = e.get("message") if isinstance(e.get("message"), dict) else {}
            if kind == "user":
                text = user_text(msg.get("content"))
                if text is None:
                    continue
                if first_prompt is None:
                    first_prompt = text
            day = local_day(e.get("timestamp"))
            if day is None or day < d1 or day > d2:
                continue
            cwd = e.get("cwd") or cwd
            branch = e.get("gitBranch") or branch
            times.append(e.get("timestamp"))
            if kind == "user":
                items.append(("U", clip(text, PROMPT_CHARS)))
            else:
                content = msg.get("content")
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text" and block.get("text", "").strip():
                            items.append(("A", clip(block["text"], ASSISTANT_CHARS)))
    if not items or not any(k == "U" for k, _ in items):
        return None
    if first_prompt and first_prompt.lstrip().startswith(SKIP_PROMPT_PREFIXES):
        return None
    return {
        "path": path, "title": title, "cwd": cwd, "branch": branch, "prs": prs,
        "times": times, "items": items,
    }


def hhmm(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%H:%M")
    except (ValueError, AttributeError):
        return "?"


def render_session(s, source, budget):
    head = ["### %s — %s" % (source, s["title"] or "(untitled session)")]
    meta = []
    if s["cwd"]:
        meta.append("folder: " + s["cwd"].replace(HOME, "~", 1))
    if s["branch"] and s["branch"] != "HEAD":
        meta.append("branch: " + s["branch"])
    if s["times"]:
        meta.append("active %s–%s" % (hhmm(min(s["times"])), hhmm(max(s["times"]))))
    meta.append("transcript: " + s["path"].replace(HOME, "~", 1))
    head.append("- " + "; ".join(meta))
    if s["prs"]:
        head.append("- PRs: " + ", ".join(s["prs"]))
    out = "\n".join(head) + "\n"
    # In order, until the budget runs out. The assistant's notes stop at 80%
    # of it, leaving room for the user's prompts (they say what the work was).
    lines = []
    used = len(out)
    dropped = 0
    for kind, text in s["items"]:
        line = ("- user: " if kind == "U" else "  - claude: ") + text + "\n"
        if kind == "A" and used + len(line) > budget * 0.8:
            dropped += 1
            continue
        if used + len(line) > budget:
            dropped += 1
            continue
        lines.append(line)
        used += len(line)
    out += "".join(lines)
    if dropped:
        out += "- … %d more message(s) not shown\n" % dropped
    return out


def cmd_sessions(args):
    if args.date:
        d1 = d2 = args.date
    else:
        d1 = args.since
        d2 = args.until or date.today()
    if d2 < d1:
        sys.exit("--until is before --since")
    start, _ = day_bounds(d1, d2)
    found = []
    for source, root in SESSION_ROOTS:
        if not os.path.isdir(root):
            continue
        for path in walk_jsonl(root, require_projects=(source != "Claude Code")):
            try:
                if os.path.getmtime(path) < start:
                    continue  # not touched since the window began
            except OSError:
                continue
            s = summarize_session(path, d1, d2)
            if s:
                found.append((min(s["times"]), source, s))
    found.sort(key=lambda x: x[0])
    label = d1.isoformat() if d1 == d2 else "%s to %s" % (d1, d2)
    if not found:
        print("No Claude sessions with activity on %s." % label)
        return
    print("# Claude sessions active on %s (%d)\n" % (label, len(found)))
    budget = max(1200, args.max_chars // len(found))
    total = 0
    for i, (_, source, s) in enumerate(found):
        block = render_session(s, source, budget)
        if total + len(block) > args.max_chars:
            print("… %d more session(s) not shown (output cap %d chars)." % (len(found) - i, args.max_chars))
            break
        print(block)
        total += len(block)


def cmd_modified(args):
    root = os.path.abspath(os.path.expanduser(args.root))
    if not os.path.isdir(root):
        sys.exit("No such folder: %s" % root)
    start, end = day_bounds(args.date, args.date)
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if args.ext and not name.endswith(args.ext):
                continue
            path = os.path.join(dirpath, name)
            try:
                m = os.path.getmtime(path)
            except OSError:
                continue
            if start <= m < end:
                hits.append((m, os.path.relpath(path, root)))
    hits.sort(reverse=True)
    if not hits:
        print("No files modified under %s on %s." % (root, args.date))
        return
    print("# %d file(s) modified under %s on %s (newest first)" % (len(hits), root, args.date))
    for m, rel in hits[: args.limit]:
        print("%s  %s" % (datetime.fromtimestamp(m).strftime("%H:%M"), rel))
    if len(hits) > args.limit:
        print("… %d more not shown" % (len(hits) - args.limit))


def gh(argv):
    """Run a read-only gh command; return (ok, stdout or error text)."""
    try:
        p = subprocess.run(["gh"] + argv, capture_output=True, text=True, timeout=GH_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)
    if p.returncode != 0:
        return False, (p.stderr or p.stdout).strip()[:500]
    return True, p.stdout


def gh_ready():
    if not shutil.which("gh"):
        print("GitHub: the gh command isn't installed; skip GitHub.")
        return False
    ok, _ = gh(["auth", "status"])
    if not ok:
        print("GitHub: gh isn't signed in; skip GitHub.")
        return False
    return True


def cmd_github(args):
    if not gh_ready():
        return
    d = args.date.isoformat()
    fields = "repository,number,title,url,state,updatedAt,createdAt,closedAt"
    prs = {}
    errors = []
    for role in ("--author=@me", "--involves=@me"):
        ok, out = gh(["search", "prs", role, "--updated=" + d, "--json", fields, "--limit", "50"])
        if not ok:
            errors.append("%s: %s" % (role, out))
            continue
        try:
            rows = json.loads(out or "[]")
        except ValueError:
            errors.append("%s: unreadable output" % role)
            continue
        for r in rows:
            key = r.get("url")
            if key and key not in prs:
                r["mine"] = role == "--author=@me"
                prs[key] = r
    for e in errors:
        print("GitHub search failed (%s)" % e)
    if not prs:
        if not errors:
            print("No pull requests updated on %s." % d)
        return
    print("# Pull requests updated on %s (%d)" % (d, len(prs)))
    for r in prs.values():
        repo = (r.get("repository") or {}).get("nameWithOwner", "?")
        events = []
        for k, word in (("createdAt", "opened"), ("closedAt", "closed/merged")):
            if (r.get(k) or "").startswith(d):
                events.append(word)
        print("- %s#%s %s — %s [%s]%s%s" % (
            repo, r.get("number"), clip(r.get("title", ""), 150), r.get("url"),
            (r.get("state") or "").lower(),
            " (" + ", ".join(events) + ")" if events else "",
            "" if r["mine"] else " (involved)"))
    print("\nFor detail on one PR: journal-helper.py github-pr --repo OWNER/REPO --number N")


def cmd_github_pr(args):
    if not gh_ready():
        return
    ok, out = gh(["pr", "view", str(args.number), "--repo", args.repo,
                  "--json", "title,body,state,mergedAt,url,commits"])
    if not ok:
        print("Couldn't read %s#%s: %s" % (args.repo, args.number, out))
        return
    try:
        pr = json.loads(out)
    except ValueError:
        print("Couldn't read %s#%s: unreadable output" % (args.repo, args.number))
        return
    print("# %s (%s%s)" % (pr.get("title"), (pr.get("state") or "").lower(),
                           ", merged " + pr["mergedAt"][:10] if pr.get("mergedAt") else ""))
    print(pr.get("url", ""))
    body = (pr.get("body") or "").strip()
    print("\n" + (body[:3000] + ("\n… (description truncated)" if len(body) > 3000 else "")) if body else "\n(no description)")
    commits = pr.get("commits") or []
    if commits:
        print("\n## Commits (%d)" % len(commits))
        for c in commits[-40:]:
            print("- %s %s" % ((c.get("committedDate") or "")[:10], clip(c.get("messageHeadline", ""), 150)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("sessions")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--date", type=parse_date)
    g.add_argument("--since", type=parse_date)
    p.add_argument("--until", type=parse_date)
    p.add_argument("--max-chars", type=int, default=40000)
    p.set_defaults(fn=cmd_sessions)

    p = sub.add_parser("modified")
    p.add_argument("--root", required=True)
    p.add_argument("--date", type=parse_date, required=True)
    p.add_argument("--ext", default=".md", help="only files ending in this ('' for all)")
    p.add_argument("--limit", type=int, default=200)
    p.set_defaults(fn=cmd_modified)

    p = sub.add_parser("github")
    p.add_argument("--date", type=parse_date, required=True)
    p.set_defaults(fn=cmd_github)

    p = sub.add_parser("github-pr")
    p.add_argument("--repo", required=True)
    p.add_argument("--number", type=int, required=True)
    p.set_defaults(fn=cmd_github_pr)

    args = ap.parse_args()
    if args.cmd == "sessions" and args.max_chars < 1000:
        ap.error("--max-chars must be at least 1000")
    args.fn(args)


if __name__ == "__main__":
    main()
