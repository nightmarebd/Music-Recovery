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
AUTO_RENAME=$(ask_yesno "Rename files to 'Title - Album - Artist' based on metadata?")
EMBED_COVER=$(ask_yesno "Download & embed cover art from MusicBrainz/CAA?")
FETCH_GENRE_YEAR=$(ask_yesno "Fetch genre & year from MusicBrainz?")
AUTO_DRY_REAL=$(ask_yesno "Automatically switch from dry-run to real mode if dry-run looks good?")
RESUMABLE="true"   # always on
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

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

echo "[*] Installing Python packages into venv (mutagen, musicbrainzngs, requests, Pillow, rich, tqdm)..."
pip install --upgrade pip >/dev/null
pip install mutagen musicbrainzngs requests Pillow rich tqdm >/dev/null

# ----- Write Python worker -----
cat > "$PY_FILE" <<'PYCODE'
#!/usr/bin/env python3
"""
trackfix_tui.py — NightmareBD version
Multi-threaded interactive TrackFix worker with Rich TUI.
"""

import os, sys, json, time, traceback, threading
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
import mutagen, musicbrainzngs, requests
from mutagen.id3 import ID3, APIC
from mutagen.flac import FLAC, Picture
from mutagen.mp4 import MP4, MP4Cover

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

musicbrainzngs.set_useragent("TrackFix", "1.0", "trackfix@example.com")

console = Console()
log_q = Queue()

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    log_q.put(f"[{ts}] {msg}")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{ts}] {msg}\n")

def safe_name(s):
    return "".join(c if c.isalnum() or c in " .-_()[]" else "_" for c in (s or "")).strip()

# Load or init state
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

def fetch_cover(release_mbid):
    try:
        url = f"https://coverartarchive.org/release/{release_mbid}/front-500"
        r = requests.get(url, timeout=10)
        if r.status_code == 200:
            return r.content
    except Exception as e:
        log(f"Cover fetch error {release_mbid}: {e}")
    return None

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

        if dry_run:
            stats['simulated'] += 1
            log(f"[DRY] Would update: {file_path} -> album:{album_title} date:{date} genre:{genre}")
            return

        try:
            ext = Path(file_path).suffix.lower()
            audio = mutagen.File(file_path, easy=True)
            if album_title: audio["album"] = album_title
            if date: audio["date"] = date
            if genre: audio["genre"] = genre
            audio.save()

            if EMBED_COVER and release_mbid:
                img = fetch_cover(release_mbid)
                if img:
                    if ext == ".mp3":
                        try:
                            id3 = ID3(file_path)
                            id3.delall("APIC")
                            id3.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=img))
                            id3.save(file_path)
                        except Exception as e:
                            log(f"Cover embed failed MP3: {e}")
                    elif ext == ".flac":
                        try:
                            f = FLAC(file_path)
                            pic = Picture()
                            pic.data = img
                            pic.mime = "image/jpeg"
                            pic.type = 3
                            f.clear_pictures()
                            f.add_picture(pic)
                            f.save()
                        except Exception as e:
                            log(f"Cover embed FLAC failed: {e}")
                    elif ext in (".m4a", ".mp4"):
                        try:
                            mp4 = MP4(file_path)
                            mp4["covr"] = [MP4Cover(img, imageformat=MP4Cover.FORMAT_JPEG)]
                            mp4.save()
                        except Exception as e:
                            log(f"Cover embed MP4 failed: {e}")
        except Exception as e:
            stats['failed'] += 1
            log(f"Write metadata error {file_path}: {e}")
            return

        if AUTO_RENAME:
            try:
                art = safe_name(artist)
                alb = safe_name(album_title)
                tit = safe_name(title)
                new_name = f"{tit} - {alb} - {art}{Path(file_path).suffix}"
                new_path = Path(file_path).parent / new_name
                if new_path != Path(file_path):
                    os.rename(file_path, new_path)
                    stats['renamed'] += 1
                    log(f"Renamed: {file_path} -> {new_path}")
                    file_path = str(new_path)
            except Exception as e:
                log(f"Rename failed {file_path}: {e}")

        stats['recovered'] += 1
        log(f"Recovered: {file_path}")

    except Exception as e:
        stats['corrupted'] += 1
        log(f"Processing exception {file_path}: {e}\n{traceback.format_exc()}")

def build_file_list(root: Path):
    exts = {".mp3", ".flac", ".m4a", ".ogg", ".wav"}
    return [str(p) for p in root.rglob("*") if p.suffix.lower() in exts]

def run_workers(files, dry_run=True):
    stats = {
        'processed': 0, 'recovered': 0, 'renamed': 0,
        'simulated': 0, 'skipped': 0, 'failed': 0, 'corrupted': 0,
        'thread_current': {i+1: "" for i in range(THREADS)},
        'thread_count': {i+1: 0 for i in range(THREADS)},
    }

    progress = Progress(
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
        TimeElapsedColumn(),
        TimeRemainingColumn(),
        console=console,
    )
    task = progress.add_task("Overall", total=len(files))

    with ThreadPoolExecutor(max_workers=THREADS) as executor, Live(console=console, refresh_per_second=10) as live:
        futures = {executor.submit(process_file_worker, f, (i % THREADS)+1, stats, dry_run): f for i, f in enumerate(files)}
        while futures:
            table = Table.grid()
            table.add_row(Text("NightmareBD — TrackFix", style="bold magenta"))
            counts = f"Processed: {stats['processed']} | Recovered: {stats['recovered']} | Renamed: {stats['renamed']} | Simulated: {stats['simulated']} | Skipped: {stats['skipped']} | Failed: {stats['failed']} | Corrupted: {stats['corrupted']}"
            table.add_row(Text(counts, style="yellow"))
            t = Table(title="Threads", expand=True)
            t.add_column("TID", justify="right")
            t.add_column("Count", justify="right")
            t.add_column("Current file")
            for tid in range(1, THREADS+1):
                t.add_row(str(tid), str(stats['thread_count'][tid]), stats['thread_current'][tid][:80])
            table.add_row(t)
            with open(LOG_FILE, "r", errors="ignore") as lf:
                tail = lf.read().splitlines()[-8:]
            table.add_row(Panel("\n".join(tail), title="Log tail", height=8))
            live.update(Panel.fit(table, border_style="green"))

            done = [f for f in futures if f.done()]
            for f in done:
                futures.pop(f)
                stats['processed'] += 1
                progress.update(task, advance=1)
            time.sleep(0.1)
    save_state()
    return stats

def main():
    if FIX_PERMS:
        for p in MUSIC_FOLDER.rglob("*"): 
            try: p.chmod(0o777)
            except: pass
        log(f"Permissions fixed under {MUSIC_FOLDER}")
    files = build_file_list(MUSIC_FOLDER)
    log(f"Discovered {len(files)} audio files under {MUSIC_FOLDER}")
    dry_run = True
    stats = run_workers(files, dry_run=dry_run)
    log(f"Finished: {stats}")
    console.print(Panel(Text("TrackFix finished — check log for details", style="bold green")))
    save_state()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Interrupted by user")
        save_state()
    except Exception as e:
        log(f"Fatal: {e}\n{traceback.format_exc()}")
        save_state()
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
export TRACKFIX_RESUMABLE="$RESUMABLE"
export TRACKFIX_LOG_FILE="$LOG_FILE"

echo "[*] Starting TrackFix Python TUI..."
python "$PY_FILE"
echo "[*] TrackFix finished. Logs: $LOG_FILE"
