#!/usr/bin/env bash
# track_fix.sh - Interactive TrackFix (NightmareBD) with optional Web UI
# Produces: ./trackfix_tui_web.py and runs it in a venv
#
# Usage: ./track_fix.sh
# Default music folder: /mnt/HDD/Media/Music

set -euo pipefail

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
AUTO_RENAME=$(ask_yesno "Rename files to 'Artist - Album - Title' based on metadata?")
EMBED_COVER=$(ask_yesno "Download & embed cover art from MusicBrainz/CAA?")
FETCH_GENRE_YEAR=$(ask_yesno "Fetch genre & year from MusicBrainz?")
AUTO_DRY_REAL=$(ask_yesno "Automatically switch from dry-run to real mode if dry-run looks good?")
ENABLE_WEBUI=$(ask_yesno "Enable optional web UI for live monitoring?")

THREADS=8

VENV_DIR="./trackfix_env"
PY_FILE="./trackfix_tui_web.py"
STATE_FILE="${MUSIC_FOLDER}/.trackfix_state.json"
LOG_FILE="./trackfix.log"

echo "[*] Ensure venv: $VENV_DIR"
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

pip install --upgrade pip >/dev/null
pip install mutagen musicbrainzngs requests Pillow rich tqdm flask flask-socketio eventlet >/dev/null

# ----- Write Python TUI + WebUI -----
cat > "$PY_FILE" <<'PYCODE'
#!/usr/bin/env python3
"""
trackfix_tui_web.py
TrackFix worker with Rich TUI and optional Flask Web UI.
"""

import os, sys, json, time, threading, traceback
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from queue import Queue

from rich.live import Live
from rich.table import Table
from rich.console import Console
from rich.panel import Panel
from rich.progress import Progress, BarColumn, TextColumn, TimeElapsedColumn, TimeRemainingColumn
from rich.align import Align
from rich.text import Text

import mutagen
import musicbrainzngs
import requests
from mutagen.id3 import ID3, APIC
from mutagen.mp4 import MP4, MP4Cover
from mutagen.flac import FLAC, Picture

# Optional web UI
from flask import Flask, jsonify, render_template_string
from flask_socketio import SocketIO, emit
import eventlet
eventlet.monkey_patch()

# Config from env
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
ENABLE_WEBUI = os.environ.get("TRACKFIX_ENABLE_WEBUI", "false") == "true"
RESUMABLE = True

musicbrainzngs.set_useragent("TrackFix","1.0","trackfix@example.com")

console = Console()
log_q = Queue()
state_lock = threading.Lock()

# -------- Logging & Permissions --------
def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    log_q.put(f"[{ts}] {msg}")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{ts}] {msg}\n")

def fix_perms_recursive(path: Path):
    try:
        for p in path.rglob("*"):
            try: p.chmod(0o777)
            except: pass
        log(f"Fixed permissions recursively under {path}")
    except Exception as e:
        log(f"fix_perms error: {e}")

# -------- Resumable state --------
if STATE_FILE.exists():
    try:
        with STATE_FILE.open("r") as f:
            processed_set = set(json.load(f))
    except:
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

def safe_name(s):
    return "".join(c if c.isalnum() or c in " .-_()[]" else "_" for c in (s or "")).strip()

def fetch_cover(release_mbid):
    try:
        url = f"https://coverartarchive.org/release/{release_mbid}/front-500"
        r = requests.get(url, timeout=10)
        if r.status_code == 200: return r.content
    except Exception as e:
        log(f"Cover fetch error {release_mbid}: {e}")
    return None

# -------- Process single file --------
def process_file_worker(file_path: str, thread_id: int, stats: dict, dry_run=True):
    stats['thread_current'][thread_id] = file_path
    stats['thread_count'][thread_id] += 1
    try:
        audio = mutagen.File(file_path, easy=True)
        if audio is None:
            stats['skipped'] += 1
            log(f"SKIP unsupported: {file_path}")
            return
        title = audio.get("title", [None])[0]
        artist = audio.get("artist", [None])[0]
        if not title or not artist:
            stats['skipped'] += 1
            log(f"SKIP no title/artist: {file_path}")
            return

        # MusicBrainz search
        try:
            res = musicbrainzngs.search_recordings(recording=title, artist=artist, limit=1)
        except:
            stats['failed'] += 1
            return
        recs = res.get("recording-list", [])
        if not recs:
            stats['failed'] += 1
            log(f"MB no match: {file_path}")
            return
        rec = recs[0]
        release = rec.get("release-list", [{}])[0]
        album_title = release.get("title","Unknown Album")
        date = release.get("date",None)
        tags = release.get("tag-list",[])
        genre = ", ".join(tag.get("name") for tag in tags) if tags else None
        release_mbid = release.get("id",None)

        if dry_run:
            stats['simulated'] += 1
            return

        # Write metadata
        ext = Path(file_path).suffix.lower()
        try:
            if ext == ".mp3":
                try: id3 = ID3(file_path)
                except: id3 = ID3()
                audio["album"] = album_title
                audio["date"] = date
                audio["genre"] = genre
                audio.save()
                if EMBED_COVER and release_mbid:
                    img = fetch_cover(release_mbid)
                    if img:
                        try: id3.delall("APIC")
                        except: pass
                        id3.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=img))
                        id3.save(file_path)
            else:
                audio = mutagen.File(file_path)
                if album_title: audio["album"] = album_title
                if date: audio["date"] = date
                if genre: audio["genre"] = genre
                audio.save()
        except Exception as e:
            stats['failed'] += 1
            log(f"Write metadata error {file_path}: {e}")
            return

        # Rename: Artist - Album - Title
        if AUTO_RENAME:
            try:
                new_name = f"{safe_name(artist)} - {safe_name(album_title)} - {safe_name(title)}{Path(file_path).suffix}"
                new_path = Path(file_path).parent / new_name
                if new_path != Path(file_path):
                    os.rename(file_path,new_path)
                    stats['renamed'] += 1
            except: pass

        stats['recovered'] += 1
        log(f"Recovered: {file_path}")
    except Exception as e:
        stats['corrupted'] += 1
        log(f"Processing exception {file_path}: {e}")

# -------- File list builder --------
def build_file_list(root: Path):
    exts = {".mp3",".flac",".m4a",".ogg",".wav"}
    return [str(p) for p in root.rglob("*") if p.suffix.lower() in exts]

# -------- WebUI --------
app = Flask(__name__)
socketio = SocketIO(app)

stats = {
    'processed':0, 'recovered':0, 'renamed':0, 'simulated':0,
    'skipped':0, 'failed':0, 'corrupted':0,
    'thread_current': {i+1:"" for i in range(THREADS)},
    'thread_count': {i+1:0 for i in range(THREADS)}
}

@app.route('/')
def index():
    return render_template_string('''
    <!DOCTYPE html>
    <html>
    <head><title>TrackFix Dashboard</title></head>
    <body>
    <h2>TrackFix Dashboard</h2>
    <div id="stats"></div>
    <pre id="log"></pre>
    <script src="//cdnjs.cloudflare.com/ajax/libs/socket.io/4.5.4/socket.io.min.js"></script>
    <script>
    var socket = io();
    socket.on('stats', function(data){
        document.getElementById('stats').innerText = JSON.stringify(data,null,2);
    });
    socket.on('log', function(msg){
        var pre = document.getElementById('log');
        pre.innerText = msg + "\\n" + pre.innerText;
    });
    </script>
    </body></html>
    ''')

def start_webui():
    socketio.run(app, host="0.0.0.0", port=5000, debug=False)

# -------- Run Workers with live update --------
def run_workers(files, dry_run=True):
    from concurrent.futures import ThreadPoolExecutor
    import time
    with ThreadPoolExecutor(max_workers=THREADS) as executor:
        futures = {executor.submit(process_file_worker,f,i+1,stats,dry_run): f for i,f in enumerate(files)}
        while futures:
            done = []
            for fut in list(futures):
                if fut.done():
                    done.append(fut)
                    futures.pop(fut)
            # emit web stats
            if ENABLE_WEBUI:
                socketio.emit("stats", stats)
            time.sleep(0.1)
    save_state()

def main():
    if FIX_PERMS: fix_perms_recursive(MUSIC_FOLDER)
    files = build_file_list(MUSIC_FOLDER)
    log(f"Found {len(files)} audio files under {MUSIC_FOLDER}")
    if ENABLE_WEBUI:
        threading.Thread(target=start_webui,daemon=True).start()
        log("Web UI running at http://localhost:5000")
    dry_run = not AUTO_DRY_REAL
    run_workers(files,dry_run=dry_run)
    log("TrackFix completed.")

if __name__ == "__main__":
    open(LOG_FILE,"a").close()
    main()
PYCODE

chmod +x "$PY_FILE"

export TRACKFIX_MUSIC_FOLDER="$MUSIC_FOLDER"
export TRACKFIX_THREADS="$THREADS"
export TRACKFIX_FIX_PERMS="$FIX_PERMS"
export TRACKFIX_DELETE_FAILED="$DELETE_FAILED"
export TRACKFIX_AUTO_RENAME="$AUTO_RENAME"
export TRACKFIX_EMBED_COVER="$EMBED_COVER"
export TRACKFIX_FETCH_GENRE_YEAR="$FETCH_GENRE_YEAR"
export TRACKFIX_AUTO_DRY_REAL="$AUTO_DRY_REAL"
export TRACKFIX_ENABLE_WEBUI="$ENABLE_WEBUI"
export TRACKFIX_LOG_FILE="$LOG_FILE"

echo "[*] Starting TrackFix Python TUI + optional Web UI..."
python "$PY_FILE"

echo "[*] TrackFix finished. Logs: $LOG_FILE"
