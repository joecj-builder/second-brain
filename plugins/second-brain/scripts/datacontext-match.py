#!/usr/bin/env python3
"""Match text (a subagent brief, a task) against the vault's DataContext notes.

Run with `python3 -I` (no network, stdlib only). Two modes:

  datacontext-match.py --vault <vault> [--scores] [--json] "<text>"
      Print the matching notes (CLI mode, for testing and for the protocol skill).

  datacontext-match.py --vault <vault> --hook <inject|remind|deny|off>
      PreToolUse hook on the Agent tool: read the hook JSON on stdin and print
      the hook's JSON reply (or nothing). Never fails the Agent call: on any
      error it prints nothing and exits 0.

Matching: each note's filename, frontmatter `name`, `description` and optional
`keywords:` list (falling back to the first heading when there's no
description) are tokenized and compared with the text. Tokens are weighted by
how rare they are across the vault (IDF), keyword hits count double, and a
multi-word keyword that appears as a phrase in the text adds a bonus. Notes
under `working-with-user/` (preferences, not data) need a higher score.
"""

import json
import math
import os
import re
import sys

MAX_NOTES = 5
MAX_CHARS = 1500
MIN_SCORE = 6.0
MIN_SCORE_PREFS = 12.0          # DataContext/working-with-user/
MIN_DISTINCT = 2                # distinct matching tokens, unless a whole keyword hits
PREFS_DIR = "working-with-user"
HEAD_BYTES = 6000               # frontmatter + first heading is all we read

INSTRUCTION = ("Read these before defining metrics or writing SQL; follow an "
               "existing source of truth over re-deriving.")

STOPWORDS = set("""
a about above after again against all also am an and any are as at be because
been before being below between both but by can cannot could did do does doing
done down during each either else etc even ever every few for from further get
gets got had has have having he her here hers him his how i if in into is it
its itself just let like made make makes many may me might more most much must
my need needs no nor not now of off on once one only or other our ours out over
own per please same see she should so some such than that the their theirs them
then there these they this those through to too under until up upon us use used
uses using very via want was way we well were what when where whether which
while who whom why will with within without would yes yet you your yours
add adds added build builds building built change changes check checks create
creates file files find first fix give go keep know last look make new next
note notes read run runs say set show sure take tell thing things try work
works write writes written step steps task tasks part parts item items line
lines value values code app apps tool tools brief subagent agent agents claude
return returns report result results output input name names list lists page
place same right left top bottom real full small big good bad one two three
md txt json yaml yml http https www com io vs versus etc
""".split())

TOKEN_RE = re.compile(r"[a-z0-9_]+")


def stem(tok):
    if len(tok) > 4 and tok.endswith("ies"):
        return tok[:-3] + "y"
    if len(tok) > 3 and tok.endswith("s") and not tok.endswith("ss") and not tok.endswith("us"):
        return tok[:-1]
    return tok


def tokens(text):
    """Ordered token list (lowercased, stemmed, stopwords and 1-char tokens dropped).
    snake_case identifiers yield the whole identifier plus its parts."""
    out = []
    for raw in TOKEN_RE.findall(text.lower()):
        parts = [raw]
        if "_" in raw:
            parts += [p for p in raw.split("_") if p]
        for p in parts:
            p = p.strip("_")
            if len(p) < 2 or p in STOPWORDS or p.isdigit():
                continue
            out.append(stem(p))
    return out


def parse_note(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        head = fh.read(HEAD_BYTES)
    lines = head.splitlines()
    fm = {}
    keywords = []
    body_start = 0
    if lines and lines[0].strip() == "---":
        end = None
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                end = i
                break
        if end is not None:
            body_start = end + 1
            key = None
            for line in lines[1:end]:
                m = re.match(r"^(\s*)([A-Za-z_][\w-]*):\s*(.*)$", line)
                if m:
                    key = m.group(2).lower()
                    val = m.group(3).strip()
                    if key == "keywords":
                        if val.startswith("["):
                            keywords += [k.strip().strip("'\"") for k in val.strip("[]").split(",")]
                        elif val:
                            keywords += [k.strip().strip("'\"") for k in val.split(",")]
                    elif key in ("name", "description") and not m.group(1):
                        fm[key] = "" if val in (">", "|", ">-", "|-") else val.strip("'\"")
                    continue
                stripped = line.strip()
                if key == "keywords" and stripped.startswith("- "):
                    keywords.append(stripped[2:].strip().strip("'\""))
                elif key in ("name", "description") and stripped and line[:1].isspace():
                    fm[key] = (fm.get(key, "") + " " + stripped.strip("'\"")).strip()
    keywords = [k for k in keywords if k]
    if not fm.get("description"):
        for line in lines[body_start:]:
            if line.startswith("#"):
                fm["description"] = line.lstrip("#").strip()
                break
    return fm.get("name", ""), fm.get("description", ""), keywords


def load_notes(vault):
    root = os.path.join(vault, "DataContext")
    notes = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith((".", "_"))]
        for fn in sorted(filenames):
            if not fn.endswith(".md"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                name, desc, kws = parse_note(path)
            except OSError:
                continue
            stem_name = fn[:-3]
            ident = set(tokens(stem_name.replace("-", " ")) + tokens(name.replace("-", " ")))
            kw_tokens = set()
            kw_single = set()           # one-token keywords: a hit on one counts on its own
            phrases = []
            for k in kws:
                t = tokens(k.replace("-", " "))
                kw_tokens.update(t)
                if len(t) == 1:
                    kw_single.add(t[0])
                elif len(t) >= 2:
                    phrases.append(t)
            notes.append({
                "path": path,
                "rel": os.path.relpath(path, vault),
                "slug": name or stem_name,
                "description": desc,
                "prefs": os.sep + PREFS_DIR + os.sep in path,
                "ident": ident,
                "kw": kw_tokens,
                "kw_single": kw_single,
                "desc": set(tokens(desc)),
                "phrases": phrases,
            })
    return notes


def contains_seq(seq, sub):
    n = len(sub)
    return any(seq[i:i + n] == sub for i in range(len(seq) - n + 1))


def score_notes(text, notes):
    q = tokens(text)
    qset = set(q)
    if not qset or not notes:
        return []
    df = {}
    for n in notes:
        for t in n["ident"] | n["kw"] | n["desc"]:
            df[t] = df.get(t, 0) + 1
    total = len(notes)
    scored = []
    for n in notes:
        score = 0.0
        hits = []
        strong = False                  # a whole one-word keyword hit
        for t in qset:
            if t in n["kw"]:
                mult = 2.0
            elif t in n["ident"]:
                mult = 1.5
            elif t in n["desc"]:
                mult = 1.0
            else:
                continue
            w = math.log((total + 1) / (df[t] + 0.5))
            score += w * mult
            hits.append(t)
            strong = strong or t in n["kw_single"]
        phrase_hits = [p for p in n["phrases"] if contains_seq(q, p)]
        score += 3.0 * len(phrase_hits)
        floor = MIN_SCORE_PREFS if n["prefs"] else MIN_SCORE
        if score >= floor and (len(hits) >= MIN_DISTINCT or phrase_hits or strong):
            scored.append((score, n, sorted(hits)))
    scored.sort(key=lambda x: (-x[0], x[1]["rel"]))
    return scored[:MAX_NOTES]


def render(matches, vault, mention_vault=True):
    head = "[second-brain] DataContext notes in the vault that match this brief"
    head += f" (vault: {vault}):" if mention_vault else ":"
    lines = [head]
    budget = MAX_CHARS - len(head) - len(INSTRUCTION) - 4
    for _, n, _ in matches:
        entry = f"- {n['path']} ({n['slug']}): {n['description']}"
        if len(entry) > budget:
            room = budget - len(n["path"]) - len(n["slug"]) - 10
            if room < 40:
                break
            entry = f"- {n['path']} ({n['slug']}): {n['description'][:room].rstrip()}…"
        lines.append(entry)
        budget -= len(entry) + 1
    lines.append(INSTRUCTION)
    return "\n".join(lines)


def hook(vault, mode):
    if mode == "off":
        return
    data = json.load(sys.stdin)
    tool_input = data.get("tool_input") or {}
    prompt = tool_input.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return
    if "[second-brain] DataContext notes" in prompt:
        return  # already injected (or Claude pasted the block itself)
    matches = score_notes(prompt + " " + str(tool_input.get("description", "")), load_notes(vault))
    # Notes the brief already names don't need repeating.
    matches = [m for m in matches
               if m[1]["rel"] not in prompt and os.path.basename(m[1]["path"])[:-3] not in prompt]
    if not matches:
        return
    block = render(matches, vault)
    if mode == "inject":
        new_input = dict(tool_input)
        new_input["prompt"] = prompt.rstrip() + "\n\n" + block
        out = {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": new_input,
            "additionalContext": "second-brain added these DataContext notes to the subagent's brief:\n" + block,
        }}
    elif mode == "deny":
        out = {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": block + "\nSubagents can't see the vault: put these "
                "paths and their key rules in the prompt, then launch the subagent again.",
        }}
    else:  # remind
        out = {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": block + "\nSubagents can't see the vault: if this subagent "
                "defines metrics or writes queries, include these paths in its prompt.",
        }}
    print(json.dumps(out))


def main(argv):
    vault = None
    mode = None
    show_scores = False
    as_json = False
    text = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--vault":
            vault = argv[i + 1]; i += 2; continue
        if a == "--hook":
            mode = argv[i + 1]; i += 2; continue
        if a == "--scores":
            show_scores = True
        elif a == "--json":
            as_json = True
        else:
            text.append(a)
        i += 1
    if mode is not None:
        try:
            if vault and os.path.isdir(os.path.join(vault, "DataContext")):
                hook(vault, mode if mode in ("inject", "remind", "deny", "off") else "inject")
        except Exception:
            pass
        return 0
    if not vault or not os.path.isdir(os.path.join(vault, "DataContext")):
        print("No vault DataContext folder found (set SECOND_BRAIN_VAULT).", file=sys.stderr)
        return 1
    query = " ".join(text) if text else sys.stdin.read()
    matches = score_notes(query, load_notes(vault))
    if as_json:
        print(json.dumps([{"path": n["path"], "name": n["slug"], "description": n["description"],
                           "score": round(s, 2), "hits": h} for s, n, h in matches], indent=2))
    elif show_scores:
        for s, n, h in matches:
            print(f"{s:6.2f}  {n['rel']}  [{', '.join(h)}]")
    elif matches:
        print(render(matches, vault, mention_vault=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
