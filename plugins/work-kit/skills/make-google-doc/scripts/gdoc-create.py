#!/usr/bin/env python3
"""Create or update a Google Doc from markdown content piped via stdin.

Usage:
    echo "# Hello" | gdoc-create.py --title "My Doc"                                   # → create in My Drive root
    gdoc-create.py --title "Daily Kickoff 2026-04-21" --folder "Daily Kickoffs" < body.md  # → create in named folder
    gdoc-create.py --title "My Doc" --update 1AbC... < body.md                         # → overwrite an existing Doc IN PLACE

Default destination is the user's My Drive root (no folder). Pass --folder to drop the
doc in a named folder (created if missing). Pass --update <FILE_ID> to replace the
content of an existing Doc in place — same file id, same URL, no duplicate (Drive
re-converts the markdown). On --update, --folder is ignored (the doc stays put) and
--title is optional (omit to keep the current name).

Auth: reuses the user's OAuth credentials at ~/.config/gspread/authorized_user.json
(full Drive scope). No service account needed.

Output (stdout): single JSON line with the doc id and web view URL (plus folder_id on create).
    {"id": "1AbC...", "url": "https://docs.google.com/document/d/.../edit"}
"""

import argparse
import io
import json
import sys
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaIoBaseUpload

CRED_PATH = Path.home() / ".config" / "gspread" / "authorized_user.json"
SCOPES = ["https://www.googleapis.com/auth/drive"]


def load_credentials() -> Credentials:
    if not CRED_PATH.exists():
        sys.exit(f"error: credentials not found at {CRED_PATH}")
    creds = Credentials.from_authorized_user_file(str(CRED_PATH), SCOPES)
    if not creds.valid:
        if creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            sys.exit("error: credentials invalid and no refresh token available")
    return creds


def ensure_folder(service, folder_name: str) -> str:
    safe_name = folder_name.replace("'", "\\'")
    q = (
        f"name = '{safe_name}' and "
        "mimeType = 'application/vnd.google-apps.folder' and "
        "trashed = false"
    )
    resp = service.files().list(q=q, fields="files(id,name)", pageSize=10).execute()
    files = resp.get("files", [])
    if files:
        return files[0]["id"]
    meta = {"name": folder_name, "mimeType": "application/vnd.google-apps.folder"}
    created = service.files().create(body=meta, fields="id").execute()
    return created["id"]


def create_doc(service, title: str, body: str, folder_id: str | None, mime: str) -> dict:
    media = MediaIoBaseUpload(
        io.BytesIO(body.encode("utf-8")), mimetype=mime, resumable=False
    )
    meta: dict = {
        "name": title,
        "mimeType": "application/vnd.google-apps.document",
    }
    if folder_id is not None:
        meta["parents"] = [folder_id]
    f = service.files().create(
        body=meta, media_body=media, fields="id,webViewLink"
    ).execute()
    return {"id": f["id"], "url": f["webViewLink"], "folder_id": folder_id}


def update_doc(service, file_id: str, title: str | None, body: str, mime: str) -> dict:
    """Replace an existing Doc's content in place (same id/URL). Drive re-converts
    the uploaded markdown; the file stays in its current folder."""
    media = MediaIoBaseUpload(
        io.BytesIO(body.encode("utf-8")), mimetype=mime, resumable=False
    )
    meta: dict = {"name": title} if title else {}
    f = service.files().update(
        fileId=file_id, body=meta, media_body=media, fields="id,webViewLink"
    ).execute()
    return {"id": f["id"], "url": f["webViewLink"]}


def main() -> int:
    ap = argparse.ArgumentParser(description="Create or update a Google Doc from stdin content.")
    ap.add_argument("--title", default=None, help="Document title (required on create; optional on --update)")
    ap.add_argument(
        "--folder",
        default=None,
        help="Drive folder name (created if missing). Omit to land in My Drive root. Ignored with --update.",
    )
    ap.add_argument(
        "--update",
        default=None,
        metavar="FILE_ID",
        help="Overwrite this existing Doc's content in place (same id/URL).",
    )
    ap.add_argument(
        "--format",
        choices=["markdown", "html", "text"],
        default="markdown",
        help="Source format; Drive converts on import",
    )
    args = ap.parse_args()

    body = sys.stdin.read()
    if not body.strip():
        sys.exit("error: empty stdin; nothing to write")

    mime = {
        "markdown": "text/markdown",
        "html": "text/html",
        "text": "text/plain",
    }[args.format]

    if not args.update and not args.title:
        sys.exit("error: --title is required when creating a new doc")

    creds = load_credentials()
    drive = build("drive", "v3", credentials=creds, cache_discovery=False)

    try:
        if args.update:
            result = update_doc(drive, args.update, args.title, body, mime)
        else:
            folder_id = ensure_folder(drive, args.folder) if args.folder else None
            result = create_doc(drive, args.title, body, folder_id, mime)
    except HttpError as e:
        sys.exit(f"error: drive api failed: {e}")

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
