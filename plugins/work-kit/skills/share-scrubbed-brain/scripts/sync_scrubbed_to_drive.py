#!/usr/bin/env python3
"""Sync the scrubbed second-brain tree (<staging>/vault/) to a Google Drive folder.

Idempotent, manifest-based, diffed:
  - mirrors the folder hierarchy under a single Drive root folder
  - each .md becomes a Google Doc (Drive converts markdown on import)
  - first run creates; later runs UPDATE IN PLACE only files whose content changed
    (sha256 in the manifest), TRASH Docs whose source file is gone, skip the rest
  - rewrites `[[wiki-links]]` (which the scrub step already narrowed to in-share
    notes) into real Doc-to-Doc hyperlinks, so navigation survives in Drive
  - on first run, optionally shares the root folder with a coverage group

SAFETY: this publishes content. Only run it on a tree the scrub step produced
from an LLM-judged decisions file that the user has reviewed — never on a `--auto`
baseline (regex-only scrubs leak; see scrub_vault.py). Use --dry-run first.

Auth: reuses the user's OAuth at ~/.config/gspread/authorized_user.json (Drive scope).
Config: scrub-config.toml ([vault].staging, [drive].folder_name/share_with/share_role).

Usage:
    python3 scripts/sync_scrubbed_to_drive.py --dry-run
    python3 scripts/sync_scrubbed_to_drive.py
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import tomllib
from datetime import datetime
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaIoBaseUpload

DEFAULT_CONFIG = Path.home() / ".claude" / "second-brain" / "scrub-config.toml"
CRED_PATH = Path.home() / ".config" / "gspread" / "authorized_user.json"
SCOPES = ["https://www.googleapis.com/auth/drive"]
DOC_MIME = "application/vnd.google-apps.document"
FOLDER_MIME = "application/vnd.google-apps.folder"
WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")


# --------------------------------------------------------------------------- #
# Auth + Drive primitives
# --------------------------------------------------------------------------- #
def load_credentials() -> Credentials:
    if not CRED_PATH.exists():
        raise SystemExit(f"error: credentials not found at {CRED_PATH}")
    creds = Credentials.from_authorized_user_file(str(CRED_PATH), SCOPES)
    if not creds.valid:
        if creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            raise SystemExit("error: credentials invalid and no refresh token")
    return creds


def ensure_folder(svc, name: str, parent: str | None) -> str:
    safe = name.replace("'", "\\'")
    q = (f"name = '{safe}' and mimeType = '{FOLDER_MIME}' and trashed = false"
         + (f" and '{parent}' in parents" if parent else ""))
    found = svc.files().list(q=q, fields="files(id)", pageSize=1).execute().get("files", [])
    if found:
        return found[0]["id"]
    meta = {"name": name, "mimeType": FOLDER_MIME}
    if parent:
        meta["parents"] = [parent]
    return svc.files().create(body=meta, fields="id").execute()["id"]


def media(body: str) -> MediaIoBaseUpload:
    return MediaIoBaseUpload(io.BytesIO(body.encode("utf-8")),
                             mimetype="text/markdown", resumable=False)


def create_doc(svc, title: str, body: str, parent: str) -> dict:
    f = svc.files().create(
        body={"name": title, "mimeType": DOC_MIME, "parents": [parent]},
        media_body=media(body), fields="id,webViewLink").execute()
    return {"id": f["id"], "url": f["webViewLink"]}


def update_doc(svc, file_id: str, body: str) -> None:
    svc.files().update(fileId=file_id, media_body=media(body), fields="id").execute()


def trash(svc, file_id: str) -> None:
    svc.files().update(fileId=file_id, body={"trashed": True}).execute()


def share(svc, folder_id: str, emails: list[str], role: str) -> None:
    for email in emails:
        try:
            svc.permissions().create(
                fileId=folder_id, sendNotificationEmail=False,
                body={"type": "user", "role": role, "emailAddress": email}).execute()
        except HttpError as e:
            print(f"  ! share failed for {email}: {e}")


# --------------------------------------------------------------------------- #
# Sync
# --------------------------------------------------------------------------- #
def sha(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def rewrite_links(text: str, name_to_url: dict[str, str]) -> str:
    def repl(m: re.Match) -> str:
        inner = m.group(1)
        target = inner.split("|")[0].split("#")[0].strip()
        alias = inner.split("|")[1].strip() if "|" in inner else target
        url = name_to_url.get(target)
        return f"[{alias}]({url})" if url else alias
    return WIKILINK.sub(repl, text)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="show planned actions, no API calls")
    ap.add_argument("--no-links", action="store_true", help="skip wiki-link → hyperlink rewriting")
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    args = ap.parse_args()

    cfg = tomllib.loads(Path(args.config).expanduser().read_text())
    staging = Path(cfg["vault"]["staging"]).expanduser()
    content = staging / "vault"
    if not content.is_dir():
        raise SystemExit(f"error: no scrubbed tree at {content} — run scrub_vault.py --apply first")
    drive_cfg = cfg.get("drive", {})
    root_name = drive_cfg.get("folder_name", "Work Second Brain (Scrubbed)")

    mds = sorted(p for p in content.rglob("*.md"))
    manifest_path = staging / ".gdoc-manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    manifest.setdefault("files", {})
    manifest.setdefault("_folders", {})

    print(f"{len(mds)} scrubbed files in {content}")
    if args.dry_run:
        have = set(manifest["files"])
        want = {p.relative_to(content).as_posix() for p in mds}
        print(f"[dry-run] create: {len(want - have)} · present: {len(want & have)} · trash: {len(have - want)}")
        for rel in sorted(want - have)[:40]:
            print(f"  + {rel}")
        return 0

    creds = load_credentials()
    svc = build("drive", "v3", credentials=creds, cache_discovery=False)

    # root + nested folders (cache ids in manifest)
    root_id = manifest.get("_root", {}).get("id") or ensure_folder(svc, root_name, None)
    manifest["_root"] = {"id": root_id, "url": f"https://drive.google.com/drive/folders/{root_id}"}

    def folder_for(rel_dir: str) -> str:
        if rel_dir in ("", "."):
            return root_id
        if rel_dir in manifest["_folders"]:
            return manifest["_folders"][rel_dir]
        parent = folder_for(str(Path(rel_dir).parent)) if Path(rel_dir).parent != Path(rel_dir) else root_id
        fid = ensure_folder(svc, Path(rel_dir).name, parent)
        manifest["_folders"][rel_dir] = fid
        return fid

    # Phase 1 — ensure every Doc exists (raw body), collect name→url
    name_to_url: dict[str, str] = {}
    created = 0
    for p in mds:
        rel = p.relative_to(content).as_posix()
        title = p.stem
        raw = p.read_text(encoding="utf-8")
        entry = manifest["files"].get(rel)
        if not entry:
            res = create_doc(svc, title, raw, folder_for(str(Path(rel).parent)))
            entry = {"id": res["id"], "url": res["url"], "hash": None, "title": title}
            manifest["files"][rel] = entry
            created += 1
        name_to_url[title] = entry["url"]

    # Phase 2 — write final content (links rewritten) only where changed
    updated = 0
    for p in mds:
        rel = p.relative_to(content).as_posix()
        entry = manifest["files"][rel]
        body = p.read_text(encoding="utf-8")
        if not args.no_links:
            body = rewrite_links(body, name_to_url)
        h = sha(body)
        if entry.get("hash") != h:
            update_doc(svc, entry["id"], body)
            entry["hash"] = h
            updated += 1

    # Deletions — source gone → trash the Doc
    want = {p.relative_to(content).as_posix() for p in mds}
    trashed = 0
    for rel in [r for r in manifest["files"] if r not in want]:
        trash(svc, manifest["files"][rel]["id"])
        del manifest["files"][rel]
        trashed += 1

    # Sharing (idempotent; only meaningful first time)
    share_with = drive_cfg.get("share_with", [])
    if share_with:
        share(svc, root_id, share_with, drive_cfg.get("share_role", "reader"))

    manifest["_synced"] = datetime.now().isoformat(timespec="seconds")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"created {created} · updated {updated} · trashed {trashed}")
    print(f"folder: {manifest['_root']['url']}")
    if share_with:
        print(f"shared with: {', '.join(share_with)} ({drive_cfg.get('share_role','reader')})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
