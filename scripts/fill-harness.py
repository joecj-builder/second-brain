#!/usr/bin/env python3
"""Fill the templated harness/ with real values for a new machine.

The inverse of sanitize-harness.py: that one strips a live ~/.claude down to
{{placeholders}}; this one expands them back out using scripts/harness-values.toml.

    cp scripts/harness-values.example.toml scripts/harness-values.toml
    $EDITOR scripts/harness-values.toml
    python3 scripts/fill-harness.py            # writes to ./harness-filled
    python3 scripts/fill-harness.py --install  # copies into ~/.claude

Fails loudly rather than producing a half-working config: a missing value stops
the run before anything is written, and any placeholder surviving into the
output is reported as an error.

Nothing is installed without --install, and --install refuses to overwrite an
existing ~/.claude unless --force is given.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HARNESS = REPO_ROOT / "harness"
VALUES = Path(__file__).resolve().parent / "harness-values.toml"
EXAMPLE = Path(__file__).resolve().parent / "harness-values.example.toml"

PLACEHOLDER = re.compile(r"\{\{([a-z_]+)\}\}")

# Files that belong at $HOME rather than inside ~/.claude, and where they go.
# Everything else in harness/ maps into ~/.claude/ at the same relative path.
HOME_TARGETS = {
    "launchd": None,                    # installed separately via launchctl
}


def load_values() -> dict[str, str]:
    if not VALUES.exists():
        sys.exit(
            f"No {VALUES.name} found.\n\n"
            f"  cp {EXAMPLE.relative_to(REPO_ROOT)} {VALUES.relative_to(REPO_ROOT)}\n"
            f"  $EDITOR {VALUES.relative_to(REPO_ROOT)}\n"
        )
    with VALUES.open("rb") as fh:
        return {k: str(v) for k, v in tomllib.load(fh).items()}


def required_placeholders() -> set[str]:
    found: set[str] = set()
    for path in HARNESS.rglob("*"):
        if path.is_file():
            found.update(PLACEHOLDER.findall(path.read_text()))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true",
                        help="copy the filled tree into ~/.claude")
    parser.add_argument("--force", action="store_true",
                        help="with --install, overwrite an existing ~/.claude")
    parser.add_argument("--out", default=str(REPO_ROOT / "harness-filled"),
                        help="output directory (default: ./harness-filled)")
    args = parser.parse_args()

    if not HARNESS.exists():
        sys.exit(f"{HARNESS} not found — are you in the second-brain repo?")

    values = load_values()
    needed = required_placeholders()
    missing = sorted(needed - values.keys())

    if missing:
        print("Missing values in harness-values.toml:\n")
        for name in missing:
            print(f"  {name}")
        print("\nNothing was written.")
        return 1

    unused = sorted(values.keys() - needed)
    if unused:
        print(f"note: {len(unused)} unused value(s): {', '.join(unused)}\n")

    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)

    written = 0
    for src in sorted(HARNESS.rglob("*")):
        if not src.is_file():
            continue
        rel = src.relative_to(HARNESS)
        text = PLACEHOLDER.sub(lambda m: values[m.group(1)], src.read_text())

        leftover = PLACEHOLDER.findall(text)
        if leftover:
            print(f"ERROR: {rel} still contains {set(leftover)}")
            return 2

        dst = out / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(text)
        dst.chmod(src.stat().st_mode)
        written += 1

    print(f"Filled {written} files -> {out}")

    if not args.install:
        print("\nReview it, then re-run with --install to copy into ~/.claude.")
        return 0

    target = Path.home() / ".claude"
    if target.exists() and not args.force:
        print(f"\n{target} already exists. Re-run with --force to overwrite,")
        print("or copy the pieces you want by hand.")
        return 1

    target.mkdir(parents=True, exist_ok=True)
    for rel_name in sorted(p.name for p in out.iterdir()):
        if rel_name in HOME_TARGETS:
            continue
        src = out / rel_name
        dst = target / rel_name
        if src.is_dir():
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst)
        print(f"  -> ~/.claude/{rel_name}")

    print("\nStill to do by hand (see REBUILD.md):")
    print("  - copy launchd/*.plist into ~/Library/LaunchAgents and launchctl load them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
