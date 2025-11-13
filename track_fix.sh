#!/usr/bin/env bash
# track_fix.sh - Interactive TrackFix (NightmareBD) generator + runner
# Produces: ./trackfix_tui.py and runs it in a venv
#
# Usage: ./track_fix.sh
# Default music folder: /mnt/HDD/Media/Music

set -euo pipefail

# ----- Config / prompts -----
DEFAULT_MUSIC_FOLDER="/mnt/HDD/Media/Music"
read -p "Music folder [${DEFAULT_MUSIC_FOLDER}]: " MUSIC_FOLDER
MUSIC_FOLDER="${MUSIC_FOLDER:-$DEFAULT_MUSIC_FOLDER}"
if [ ! -d "$MUSIC_FOLDER" ]; then
  echo "Error: folder does not exist: $MUSIC_FOLDER"
  exit 1
fi

ask_yesno() {
  local prompt="$1"
  local default="${2:-y}"
  while true; do
    read -p "$prompt [y/n] (default: $default): " ans
    ans="${ans:-$default}"
    case "$ans" in
      [Yy]*) echo "true"; return ;;
      [Nn]*) echo "false"; return ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

echo "NightmareBD TrackFix — Interactive feature selection"
FIX_PERMS=$(ask_yesno "Automatically fix ownership/permissions before starting?")
DELETE_FAILED=$(ask_yesno "Delete original corrupted files after successful recovery?")
AUTO_RENAME=$(ask_yesno "Rename files to 'Title - Album - Artist' based on metadata?") # Updated prompt for clarity
EMBED_COVER=$(ask_yesno "Download & embed cover art from MusicBrainz/CAA?")
FETCH_GENRE_YEAR=$(ask_yesno "Fetch genre & year from MusicBrainz?")
AUTO_DRY_REAL=$(ask_yesno "Automatically switch from dry-run to real mode if dry-run looks good?")
RESUMABLE="true"   # always on
read -p "Worker threads (recommended 6-12) [8]: " THREADS
THREADS="${THREADS:-8}"

# Other runtime files
VENV_DIR="./trackfix_env"
PY_FILE="./trackfix_tui.py"
STATE_FILE="${MUSIC_FOLDER}/.trackfix_state.json"
LOG_FILE="./trackfix.log"

echo "Settings:"
cat <<EOF
 Music folder: $MUSIC_FOLDER
 Fix perms: $FIX_PERMS
 Delete failed originals: $DELETE_FAILED
 Auto rename: $AUTO_RENAME
 Embed cover art: $EMBED_COVER
 Fetch genre/year: $FETCH_GENRE_YEAR
 Auto dry->real switch: $AUTO_DRY_REAL
 Threads: $THREADS
 Resumable: $RESUMABLE
 State file: $STATE_FILE
 Log file: $LOG_FILE
EOF

read -p "Proceed and generate/run TrackFix now? [Y/n]: " proceed
proceed="${proceed:-Y}"
if [[ ! "$proceed" =~ ^[Yy] ]]; then
  echo "Aborted."
  exit 0
fi

# ----- Prepare venv and dependencies -----
echo "[*] Ensure venv: $VENV_DIR"
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
# Activate
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

echo "[*] Installing Python packages into venv (mutagen, musicbrainzngs, requests, Pillow, rich, tqdm)..."
pip install --upgrade pip >/dev/null
pip install mutagen musicbrainzngs requests Pillow rich tqdm >/dev/null

# ----- Write the Python TUI worker -----
cat > "$PY_FILE" <<'PYCODE'
#!/usr/bin/env python3
"""
trackfix_tui.py
Interactive multi-threaded TrackFix worker with Rich TUI.

Reads configuration from environment variables set by the wrapper script.
Writes .trackfix_state.json in music folder for resumability.
"""

import os, sys, json, time, traceback
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from queue import Queue
import threading

# Rich for TUI
from rich.live import Live
from rich.table import Table
from rich.console import Console
from rich.panel import Panel
from rich.progress import Progress, BarColumn, TextColumn, TimeElapsedColumn, TimeRemainingColumn
from rich.align import Align
from rich.text import Text

# Audio + metadata
import mutagen
import musicbrainzngs
import requests
from mutagen.id3 import ID3, APIC
from mutagen.flac import FLAC, Picture
from mutagen.mp4 import MP4, MP4Cover

# config from env
MUSIC_FOLDER = Path(os.environ.get("TRACKFIX_MUSIC_FOLDER", "/mnt/HDD/Media/Music"))
STATE_FILE = MUSIC_FOLDER / ".trackfix_state.json"
LOG_FILE = Path(os.environ.get("TRACKFIX_LOG_FILE", "./trackfix.log"))
THREADS = int(os.environ.get("TRACKFIX_THREADS", "8"))
FIX_PERMS = os.environ.get("TRACKFIX_FIX_PERMS", "false") == "true"
DELETE_FAILED = os.environ.get("TRACKFIX_DELETE_FAILED", "false") == "true"
AUTO_RENAME = os.environ.get("TRACKFIX_AUTO_RENAME", "false") == "true"
EMBED_COVER = os.environ.get("TRACKFIX_EMBED_COVER", "false") == "true"
FETCH_GENRE_YEAR = os.environ.get("TRACKFIX_FETCH_GENRE_YEAR", "false") == "true"
AUTO_DRY_REAL = os.environ.get("TRACKFIX_AUTO_DRY_REAL", "false") == "true"
RESUMABLE = os.environ.get("TRACKFIX_RESUMABLE", "true") == "true"

# MusicBrainz useragent (change email if you want)
musicbrainzngs.set_useragent("TrackFix","1.0","trackfix@example.com")

console = Console()
log_q = Queue()

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    log_q.put(f"[{ts}] {msg}")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{ts}] {msg}\n")

# Fix perms helper
def fix_perms_recursive(path: Path):
    try:
        for p in path.rglob("*"):
            try:
                p.chmod(0o777)
            except Exception:
                pass
        log(f"Fixed permissions recursively under {path}")
    except Exception as e:
        log(f"fix_perms error: {e}")

# Resumable state load/save
state_lock = threading.Lock()
if STATE_FILE.exists():
    try:
        with STATE_FILE.open("r") as f:
            processed_set = set(json.load(f))
    except Exception:
        processed_set = set()
else:
    processed_set = set()

def save_state():
    with state_lock:
        try:
            with STATE_FILE.open("w") as f:
                json.dump(list(processed_set), f)
        except Exception as e:
            log(f"Failed to save state: {e}")

# Utility safe filename
def safe_filename(s: str):
    keep = "".join(c if c.isalnum() or c in " .-_()[]&" else "_" for c in s)
    return keep.strip()

# Cover art fetch
def fetch_cover(release_mbid):
    try:
        url = f"https://coverartarchive.org/release/{release_mbid}/front-500"
        r = requests.get(url, timeout=10)
        if r.status_code == 200:
            return r.content
    except Exception as e:
        log(f"Cover fetch error {release_mbid}: {e}")
    return None

# Process single file
def process_file_worker(file_path: str, thread_id: int, stats: dict, dry_run=True):
    """
    Attempts:
     - detect corruption
     - if ok: query MusicBrainz by (title, artist)
     - update metadata (album, date, genre)
     - embed cover (if selected)
     - rename file (if selected)
    """
    stats['thread_current'][thread_id] = file_path
    stats['thread_count'][thread_id] += 1

    try:
        # Quick corruption check: try mutagen open
        audio = mutagen.File(file_path, easy=True)
        if audio is None:
            stats['skipped'] += 1
            log(f"SKIP unsupported: {file_path}")
            return

        # Some corrupted mp3 raise exceptions on loading tags — catch them
        # Gather title/artist
        title = audio.get("title", [None])[0]
        artist = audio.get("artist", [None])[0]

        # If missing tags, mark skipped (we could fallback to fingerprint later)
        if not title or not artist:
            stats['skipped'] += 1
            log(f"SKIP no title/artist: {file_path}")
            return

        # Query MusicBrainz
        try:
            res = musicbrainzngs.search_recordings(recording=title, artist=artist, limit=1)
        except Exception as e:
            log(f"MB search error for {file_path}: {e}")
            stats['failed'] += 1
            return

        recs = res.get("recording-list", [])
        if not recs:
            stats['failed'] += 1
            log(f"MB no match: {file_path}")
            return

        rec = recs[0]
        release = rec.get("release-list", [{}])[0]
        album_title = release.get("title", None) or "Unknown Album"
        date = release.get("date", None)
        tags = release.get("tag-list", [])
        genre = ", ".join(tag.get("name") for tag in tags) if tags else None
        release_mbid = release.get("id", None)

        # Dry-run report (no writes)
        if dry_run:
            stats['simulated'] += 1
            log(f"[DRY] Would update: {file_path} -> album:{album_title} date:{date} genre:{genre}")
            return

        # Real mode: write metadata
        try:
            ext = Path(file_path).suffix.lower()
            if ext == ".mp3":
                # use ID3 if needed
                try:
                    id3 = ID3(file_path)
                except Exception:
                    id3 = ID3()
                # Use easy mutagen for common tags
                audio = mutagen.File(file_path, easy=True)
                if album_title:
                    audio["album"] = album_title
                if date:
                    audio["date"] = date
                if genre:
                    audio["genre"] = genre
                audio.save()
                # embed cover if found & selected
                if EMBED_COVER and release_mbid:
                    img = fetch_cover(release_mbid)
                    if img:
                        try:
                            id3.delall("APIC")
                        except Exception:
                            pass
                        id3.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=img))
                        id3.save(file_path)
            else:
                # FLAC / MP4
                audio = mutagen.File(file_path)
                if album_title:
                    try:
                        audio["album"] = album_title
                    except Exception:
                        pass
                if date:
                    try:
                        audio["date"] = date
                    except Exception:
                        pass
                if genre:
                    try:
                        audio["genre"] = genre
                    except Exception:
                        pass
                # cover embedding for FLAC/MP4
                if EMBED_COVER and release_mbid:
                    img = fetch_cover(release_mbid)
                    if img:
                        if ext == ".flac":
                            try:
                                f = FLAC(file_path)
                                pic = Picture()
                                pic.data = img
                                pic.mime = "image/jpeg"
                                pic.type = 3
                                f.clear_pictures()
                                f.add_picture(pic)
                                f.save()
                            except Exception:
                                log(f"Cover embed FLAC failed: {file_path}")
                        elif ext in (".m4a", ".mp4"):
                            try:
                                mp4 = MP4(file_path)
                                mp4["covr"] = [MP4Cover(img, imageformat=MP4Cover.FORMAT_JPEG)]
                                mp4.save()
                            except Exception:
                                log(f"Cover embed MP4 failed: {file_path}")
                try:
                    audio.save()
                except Exception:
                    pass

        except Exception as e:
            stats['failed'] += 1
            log(f"Write metadata error {file_path}: {e}")
            return

        # Rename if requested
        if AUTO_RENAME:
            try:
                art = safe_name(artist)
                alb = safe_name(album_title)
                tit = safe_name(title)
                new_name = f"{tit} - {alb} - {art}{Path(file_path).suffix}" # Modified to Title-Album-Artist
                new_path = Path(file_path).parent / new_name
                if new_path != Path(file_path):
                    os.rename(file_path, new_path)
                    stats['renamed'] += 1
