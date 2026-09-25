#!/usr/bin/env python3
"""scrub_vault.py — audit / scrub the Work second brain for a shareable copy.

The first job (this milestone) is to *identify what we scrub*. Run with
``--report-only`` to scope-filter the vault (default-deny allowlist), run the
tiered regex pre-filter from ``scrub-config.toml``, and write a heat-ranked
``Scrub-Report.md`` + machine-readable ``scrub-candidates.json`` into the
staging dir. ``--report-only`` makes NO changes to the vault and does not build
the scrubbed tree — it only surfaces candidates for review.

``--apply`` builds the scrubbed tree under ``<staging>/vault/``: copies in-scope
files, applies a decisions file (exclude whole files / redact spans), repairs
wiki-links (links to excluded notes are flattened to plain text), and commits
the result to a git repo in the staging dir (the audit trail of what was shared).
Without ``--decisions`` it falls back to a conservative ``--auto`` baseline that
whole-line-redacts every strong regex hit; the skill supplies a surgical
decisions file produced by the LLM judgment pass.

Config: ``scrub-config.toml`` (single source of truth; see that file).
Runs on stdlib only (Python 3.11+ for ``tomllib``).

Usage:
    python3 scripts/scrub_vault.py --report-only
    python3 scripts/scrub_vault.py --apply --auto          # conservative baseline
    python3 scripts/scrub_vault.py --apply --decisions scrub-decisions.json
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tomllib
from datetime import datetime
from pathlib import Path

DEFAULT_CONFIG = Path.home() / ".claude" / "second-brain" / "scrub-config.toml"

STRONG_W = 3
WEAK_W = 1
SNIPPET_MAX = 140          # truncate each shown line to avoid dumping secrets
MAX_DETAIL_LINES = 30      # per-file hit lines rendered in the markdown report


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
def load_config(path: Path) -> dict:
    with path.open("rb") as fh:
        return tomllib.load(fh)


def compile_tiers(cfg: dict) -> list[dict]:
    """Compile each tier's strong/weak patterns once."""
    tiers = []
    for t in cfg.get("tier", []):
        tiers.append(
            {
                "id": t["id"],
                "label": t.get("label", t["id"]),
                "action": t.get("action", "redact"),
                "strong": [re.compile(p, re.IGNORECASE) for p in t.get("strong", [])],
                "weak": [re.compile(p, re.IGNORECASE) for p in t.get("weak", [])],
            }
        )
    return tiers


# --------------------------------------------------------------------------- #
# Scope (default-deny allowlist)
# --------------------------------------------------------------------------- #
def iter_scope(vault: Path, scope: dict) -> tuple[list[Path], list[Path]]:
    """Return (in_scope_md_files, excluded_md_files) under the allowlist.

    excluded_md_files are .md files that live under an included dir but were
    knocked out by exclude_paths — surfaced so the report shows what was
    deliberately dropped (vs. never-considered folders).
    """
    include_dirs = set(scope.get("include_dirs", []))
    include_files = set(scope.get("include_files", []))
    exclude_paths = [p.rstrip("/") for p in scope.get("exclude_paths", [])]
    exclude_globs = scope.get("exclude_globs", [])

    def is_excluded_path(rel: str) -> bool:
        return any(rel == ep or rel.startswith(ep + "/") for ep in exclude_paths)

    def matches_glob(p: Path) -> bool:
        return any(p.match(g) for g in exclude_globs)

    in_scope, excluded = [], []

    # root-level explicit includes
    for name in include_files:
        f = vault / name
        if f.is_file():
            (excluded if is_excluded_path(name) else in_scope).append(f)

    for d in sorted(include_dirs):
        base = vault / d
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*")):
            if not f.is_file() or f.suffix.lower() != ".md":
                continue
            rel = f.relative_to(vault).as_posix()
            if matches_glob(f):
                continue
            (excluded if is_excluded_path(rel) else in_scope).append(f)

    return in_scope, excluded


# --------------------------------------------------------------------------- #
# Scan
# --------------------------------------------------------------------------- #
def snippet(line: str) -> str:
    s = line.strip()
    return s if len(s) <= SNIPPET_MAX else s[:SNIPPET_MAX] + "…"


def scan_file(path: Path, vault: Path, tiers: list[dict]) -> dict:
    rel = path.relative_to(vault).as_posix()
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return {"path": rel, "score": 0, "tiers": {}, "hits": [], "error": "unreadable"}

    hits: list[dict] = []
    tier_counts: dict[str, dict[str, int]] = {}

    for lineno, line in enumerate(text.splitlines(), start=1):
        for tier in tiers:
            for strength, pats in (("strong", tier["strong"]), ("weak", tier["weak"])):
                for pat in pats:
                    m = pat.search(line)
                    if not m:
                        continue
                    hits.append(
                        {
                            "line": lineno,
                            "tier": tier["id"],
                            "strength": strength,
                            "action": tier["action"],
                            "match": m.group(0).strip()[:60],
                            "snippet": snippet(line),
                        }
                    )
                    c = tier_counts.setdefault(tier["id"], {"strong": 0, "weak": 0})
                    c[strength] += 1
                    break  # one hit per (tier, strength) per line is enough signal

    score = sum(c["strong"] * STRONG_W + c["weak"] * WEAK_W for c in tier_counts.values())
    return {"path": rel, "score": score, "tiers": tier_counts, "hits": hits}


def disposition(rec: dict) -> str:
    """Heuristic suggestion for the reviewer — never the final word."""
    strong = sum(c["strong"] for c in rec["tiers"].values())
    if rec["score"] == 0:
        return "clean"
    if strong >= 4 or rec["score"] >= 12:
        return "review → likely EXCLUDE"
    if strong >= 1:
        return "review → redact spans"
    return "low — likely OK (weak signals only)"


# --------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------- #
def build_report(cfg: dict, results: list[dict], excluded: list[str],
                 vault: Path, tiers: list[dict]) -> str:
    flagged = [r for r in results if r["score"] > 0]
    clean = [r for r in results if r["score"] == 0]
    flagged.sort(key=lambda r: r["score"], reverse=True)

    totals = {t["id"]: {"strong": 0, "weak": 0} for t in tiers}
    for r in results:
        for tid, c in r["tiers"].items():
            totals[tid]["strong"] += c["strong"]
            totals[tid]["weak"] += c["weak"]

    L: list[str] = []
    L.append("# Scrub Audit — Work Second Brain (Scrubbed)")
    L.append("")
    L.append(f"_Generated {datetime.now():%Y-%m-%d %H:%M %Z} · `--report-only` (no changes made)_")
    L.append("")
    L.append("> Candidate surfacing only. Regex is recall-oriented — expect false positives "
             "(pricing `$`, \"pipeline **health**\", \"white**board**\"). Adjudicate in review.")
    L.append("")

    # Summary
    L.append("## Summary")
    L.append("")
    L.append(f"- In-scope `.md` files considered: **{len(results)}**")
    L.append(f"- Flagged (≥1 hit): **{len(flagged)}**   ·   Clean: **{len(clean)}**")
    L.append(f"- Knocked out by `exclude_paths`: **{len(excluded)}**")
    L.append("")
    L.append("| Tier | Strong hits | Weak hits |")
    L.append("|---|--:|--:|")
    for t in tiers:
        tt = totals[t["id"]]
        L.append(f"| {t['label']} | {tt['strong']} | {tt['weak']} |")
    L.append("")

    # Scope decisions
    L.append("## Scope (default-deny)")
    L.append("")
    L.append("**Included dirs:** " + ", ".join(f"`{d}`" for d in cfg["scope"]["include_dirs"]))
    L.append("")
    L.append("**Excluded sub-paths** (under an included dir but dropped):")
    for ep in cfg["scope"].get("exclude_paths", []):
        n = sum(1 for e in excluded if e == ep or e.startswith(ep + "/"))
        L.append(f"- `{ep}` — {n} file(s)")
    L.append("")
    L.append("_Everything not under an included dir (Journal/, Meetings/, Kickoffs/, Memory/, "
             "_archive/, root files) is excluded by default and never scanned._")
    L.append("")

    # Heat ranking
    L.append("## Heat ranking (review these top-down)")
    L.append("")
    L.append("| Score | File | comp (s/w) | opinions (s/w) | personal (s/w) | Suggested |")
    L.append("|--:|---|---|---|---|---|")
    for r in flagged:
        def cell(tid: str) -> str:
            c = r["tiers"].get(tid, {"strong": 0, "weak": 0})
            return f"{c['strong']}/{c['weak']}" if (c["strong"] or c["weak"]) else "·"
        L.append(
            f"| {r['score']} | `{r['path']}` | {cell('comp')} | {cell('opinions')} "
            f"| {cell('personal')} | {disposition(r)} |"
        )
    L.append("")

    # Per-file detail (only files with at least one STRONG hit)
    strong_files = [r for r in flagged if any(c["strong"] for c in r["tiers"].values())]
    L.append(f"## Flagged-line detail — files with strong hits ({len(strong_files)})")
    L.append("")
    for r in strong_files:
        L.append(f"### `{r['path']}`  ·  score {r['score']}  ·  {disposition(r)}")
        L.append("")
        shown = [h for h in r["hits"] if h["strength"] == "strong"][:MAX_DETAIL_LINES]
        for h in shown:
            L.append(f"- L{h['line']} · **{h['tier']}** · `{h['match']}` — {h['snippet']}")
        extra = sum(1 for h in r["hits"] if h["strength"] == "strong") - len(shown)
        if extra > 0:
            L.append(f"- …and {extra} more strong hit(s)")
        L.append("")

    # Clean files (collapsed)
    L.append("## Clean in-scope files (no hits)")
    L.append("")
    L.append("<details><summary>" + f"{len(clean)} files" + "</summary>")
    L.append("")
    for r in sorted(clean, key=lambda r: r["path"]):
        L.append(f"- `{r['path']}`")
    L.append("")
    L.append("</details>")
    L.append("")

    L.append("## Needs the user's call")
    L.append("")
    L.append("- Confirm the **scope allowlist** is right (anything important living outside "
             "Topics/DataContext/Analysis/Projects/People?).")
    L.append("- Skim the heat ranking: agree with EXCLUDE vs redact-spans suggestions?")
    L.append("- Tune `scrub-config.toml` patterns for any systematic false positives, then re-run.")
    L.append("")
    return "\n".join(L)


# --------------------------------------------------------------------------- #
# Apply: decisions → redactions → link repair → staging tree → git
# --------------------------------------------------------------------------- #
def build_auto_decisions(results: list[dict]) -> dict:
    """Conservative baseline: whole-line-redact every STRONG regex hit. The skill
    replaces this with surgical, LLM-judged redactions."""
    files: dict[str, dict] = {}
    for r in results:
        lines = sorted({h["line"] for h in r["hits"] if h["strength"] == "strong"})
        if not lines:
            continue
        files[r["path"]] = {
            "action": "redact",
            "redactions": [{"line": ln, "reason": "flagged (auto whole-line)"} for ln in lines],
        }
    return {"auto": True, "files": files}


def apply_redactions(text: str, file_dec: dict | None) -> tuple[str, int]:
    """Apply a file's redactions. A redaction with a `match` replaces that
    substring; without one it blanks the whole line. `line` 0/absent = anywhere."""
    if not file_dec:
        return text, 0
    lines = text.split("\n")
    n = 0
    for r in file_dec.get("redactions", []):
        ln = r.get("line", 0)
        match = r.get("match")
        marker = f"[redacted — {r.get('reason', 'sensitive')}]"
        if ln and 1 <= ln <= len(lines):
            if match and match in lines[ln - 1]:
                lines[ln - 1] = lines[ln - 1].replace(match, marker, 1)
                n += 1
            else:
                lines[ln - 1] = marker
                n += 1
        elif match:                                  # anywhere
            for i, line in enumerate(lines):
                if match in line:
                    lines[i] = line.replace(match, marker)
                    n += 1
    return "\n".join(lines), n


WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")


def flatten_links(text: str, included: set[str]) -> tuple[str, int]:
    """Keep [[links]] whose target is an included note; flatten links to
    excluded/out-of-scope notes to their display text (so no dangling links leak
    a redacted/episodic note name as a clickable reference)."""
    n = 0

    def repl(m: re.Match) -> str:
        nonlocal n
        inner = m.group(1)
        target = inner.split("|")[0].split("#")[0].strip()
        alias = inner.split("|")[1].strip() if "|" in inner else target
        if target in included:
            return m.group(0)
        n += 1
        return alias

    return WIKILINK.sub(repl, text), n


def excluded_by_decisions(decisions: dict) -> list[str]:
    return [p.rstrip("/") for p, d in decisions.get("files", {}).items()
            if d.get("action") == "exclude"]


def git(staging: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(staging), *args],
                          capture_output=True, text=True)


def build_staging(vault: Path, staging: Path, in_scope: list[Path],
                  decisions: dict) -> dict:
    """Write the scrubbed tree to <staging>/vault/ and return apply stats."""
    extra_excl = excluded_by_decisions(decisions)

    def is_excl(rel: str) -> bool:
        return any(rel == e or rel.startswith(e + "/") for e in extra_excl)

    kept = [f for f in in_scope if not is_excl(f.relative_to(vault).as_posix())]
    included_names = {f.stem for f in kept}

    content = staging / "vault"
    if content.exists():
        shutil.rmtree(content)
    content.mkdir(parents=True, exist_ok=True)

    stats = {"files": 0, "redactions": 0, "links_flattened": 0,
             "excluded_by_decisions": len(in_scope) - len(kept)}
    file_decs = decisions.get("files", {})
    for f in kept:
        rel = f.relative_to(vault).as_posix()
        try:
            text = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        text, nred = apply_redactions(text, file_decs.get(rel))
        text, nlink = flatten_links(text, included_names)
        dest = content / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8")
        stats["files"] += 1
        stats["redactions"] += nred
        stats["links_flattened"] += nlink
    return stats


def commit_staging(staging: Path, msg: str) -> str:
    if not (staging / ".git").exists():
        git(staging, "init", "-q")
        git(staging, "config", "user.email", "scrub@local")
        git(staging, "config", "user.name", "scrub-vault")
    git(staging, "add", "-A")
    status = git(staging, "status", "--porcelain")
    if not status.stdout.strip():
        return "no changes"
    git(staging, "commit", "-q", "-m", msg)
    return git(staging, "rev-parse", "--short", "HEAD").stdout.strip()


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--report-only", action="store_true",
                      help="audit and write report; make no changes")
    mode.add_argument("--apply", action="store_true",
                      help="build the scrubbed staging tree and commit it")
    ap.add_argument("--decisions", help="decisions JSON (from the LLM judgment pass)")
    ap.add_argument("--auto", action="store_true",
                    help="with --apply and no --decisions: conservative whole-line baseline")
    ap.add_argument("--config", default=str(DEFAULT_CONFIG), help="path to scrub-config.toml")
    args = ap.parse_args()

    cfg = load_config(Path(args.config).expanduser())
    vault = Path(cfg["vault"]["path"]).expanduser()
    staging = Path(cfg["vault"]["staging"]).expanduser()
    if not vault.is_dir():
        ap.error(f"vault not found: {vault}")

    tiers = compile_tiers(cfg)
    in_scope, excluded = iter_scope(vault, cfg["scope"])
    results = [scan_file(f, vault, tiers) for f in in_scope]
    excluded_rel = [e.relative_to(vault).as_posix() for e in excluded]
    staging.mkdir(parents=True, exist_ok=True)

    if args.report_only:
        report = build_report(cfg, results, excluded_rel, vault, tiers)
        (staging / "Scrub-Report.md").write_text(report + "\n", encoding="utf-8")
        candidates = {
            "generated": datetime.now().isoformat(timespec="seconds"),
            "vault": str(vault),
            "in_scope_count": len(results),
            "excluded_by_scope": excluded_rel,
            "files": sorted(results, key=lambda r: r["score"], reverse=True),
        }
        (staging / "scrub-candidates.json").write_text(json.dumps(candidates, indent=2) + "\n", encoding="utf-8")
        flagged = sum(1 for r in results if r["score"] > 0)
        strong = sum(1 for r in results if any(c["strong"] for c in r["tiers"].values()))
        print(f"scanned {len(results)} in-scope files · {flagged} flagged · {strong} with strong hits")
        print(f"excluded by scope: {len(excluded_rel)}")
        print(f"report:     {staging / 'Scrub-Report.md'}")
        print(f"candidates: {staging / 'scrub-candidates.json'}")
        return 0

    # --apply
    if args.decisions:
        decisions = json.loads(Path(args.decisions).expanduser().read_text())
    elif args.auto:
        decisions = build_auto_decisions(results)
    else:
        ap.error("--apply needs --decisions FILE or --auto")

    stats = build_staging(vault, staging, in_scope, decisions)
    decisions["applied"] = datetime.now().isoformat(timespec="seconds")
    decisions["stats"] = stats
    (staging / "scrub-decisions.json").write_text(json.dumps(decisions, indent=2) + "\n", encoding="utf-8")
    rev = commit_staging(staging, f"scrub apply — {stats['files']} files, "
                                  f"{stats['redactions']} redactions ({decisions.get('auto') and 'auto' or 'decisions'})")

    print(f"staged {stats['files']} files → {staging / 'vault'}")
    print(f"redactions: {stats['redactions']} · links flattened: {stats['links_flattened']} "
          f"· excluded by decisions: {stats['excluded_by_decisions']}")
    print(f"commit: {rev}")
    print(f"review: git -C {staging} show --stat HEAD   (or: git -C {staging} diff HEAD~1)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
