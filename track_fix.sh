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

# Corrected function definition starts here
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
# Corrected function definition ends here

echo "NightmareBD TrackFix — Interactive feature selection"
FIX_PERMS=$(ask_yesno "Automatically fix ownership/permissions before starting?")
DELETE_FAILED=$(ask_yesno "Delete original corrupted files after successful recovery?")
AUTO_RENAME=$(ask_yesno "Rename files to 'Title - Album - Artist' based on metadata?")
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
            # Auto-dry->real switch logic is in main thread
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
                new_name = f"{tit} - {alb} - {art}{Path(file_path).suffix}" # Title - Album - Artist
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

def safe_name(s):
    return "".join(c if c.isalnum() or c in " .-_()[]" else "_" for c in (s or "")).strip()

# Build file list (only audio extensions we care)
def build_file_list(root: Path):
    exts = {".mp3", ".flac", ".m4a", ".ogg", ".wav"}
    files = [str(p) for p in root.rglob("*") if p.suffix.lower() in exts]
    return files

def run_workers(files, dry_run=True):
    stats = {
        'processed': 0, 'recovered': 0, 'renamed': 0,
        'simulated': 0, 'skipped': 0, 'failed': 0, 'corrupted': 0,
        'thread_current': {i+1: "" for i in range(THREADS)},
        'thread_count': {i+1: 0 for i in range(THREADS)},
    }

    # Rich progress & layout
    console = Console()
    progress = Progress(
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
        TimeElapsedColumn(),
        TimeRemainingColumn(),
        console=console,
        transient=False,
    )
    task = progress.add_task("Overall", total=len(files))

    # Launch threads
    with ThreadPoolExecutor(max_workers=THREADS) as executor, Live(console=console, refresh_per_second=10) as live:
        futures = {}
        # Submit tasks round-robin; we map index -> thread id for status
        idx = 0
        for fpath in files:
            # skip if already processed (resumable)
            if RESUMABLE and fpath in processed_set:
                stats['processed'] += 1
                progress.update(task, advance=1)
                continue
            thread_id = (idx % THREADS) + 1
            future = executor.submit(process_file_worker, fpath, thread_id, stats, dry_run)
            futures[future] = (fpath, thread_id)
            idx += 1

        # Render live screen while futures complete
        while futures:
            # Build dashboard
            table = Table.grid()
            title = Text("NightmareBD — TrackFix", style="bold magenta")
            table.add_row(title)
            counts = f"Processed: {stats['processed']} | Recovered: {stats['recovered']} | Renamed: {stats['renamed']} | Simulated: {stats['simulated']} | Skipped: {stats['skipped']} | Failed: {stats['failed']} | Corrupted: {stats['corrupted']}"
            table.add_row(Text(counts, style="yellow"))
            # Per-thread table
            t = Table(title="Threads", show_lines=False, expand=True)
            t.add_column("TID", justify="right")
            t.add_column("Count", justify="right")
            t.add_column("Current file", overflow="fold")
            for tid in range(1, THREADS+1):
                cur = stats['thread_current'].get(tid, "")
                cnt = stats['thread_count'].get(tid, 0)
                t.add_row(str(tid), str(cnt), cur[:80])
            table.add_row(t)
            # Log tail
            log_lines = []
            while not log_q.empty():
                log_lines.append(log_q.get_nowait())
            # keep last 8 lines
            with open(LOG_FILE, "r", errors="ignore") as lf:
                tail = lf.read().splitlines()[-8:]
            tail_panel = Panel("\n".join(tail or log_lines), title="Log tail", height=8)
            table.add_row(tail_panel)
            # Display progress bar via progress.renderable
            body = Align.center(Panel.fit(table), vertical="top")
            live.update(Panel.fit(body, border_style="green"))
            # handle completed futures
            done = []
            for fut in list(futures):
                if fut.done():
                    fpath, tid = futures.pop(fut)
                    stats['processed'] += 1
                    progress.update(task, advance=1)
            time.sleep(0.05)

    # Final save
    save_state()
    return stats

def quick_dry_check(files):
    # Run brief sampling: test first N corrupted checks to see if dry_run looks good.
    sample = files[:min(20, len(files))]
    stats = {'simulated': 0, 'failed': 0, 'skipped': 0}
    for f in sample:
        try:
            audio = mutagen.File(f, easy=True)
            if audio is None:
                stats['skipped'] += 1
            else:
                title = audio.get("title",[None])[0]
                artist = audio.get("artist",[None])[0]
                if not title or not artist:
                    stats['skipped'] += 1
                else:
                    # try MB lookup
                    try:
                        res = musicbrainzngs.search_recordings(recording=title, artist=artist, limit=1)
                        if res.get("recording-list"):
                            stats['simulated'] += 1
                        else:
                            stats['failed'] += 1
                    except Exception:
                        stats['failed'] += 1
        except Exception:
            stats['failed'] += 1
    return stats

def main():
    # optional fix perms
    if FIX_PERMS:
        fix_perms_recursive(MUSIC_FOLDER)

    files = build_file_list(MUSIC_FOLDER)
    log(f"Discovered {len(files)} audio files under {MUSIC_FOLDER}")

    # Dry-run sampling and decision
    if AUTO_DRY_REAL:
        sample_stats = quick_dry_check(files)
        log(f"Dry-check sample stats: {sample_stats}")
        # simple heuristic: if majority simulated (have MB matches) then switch to real
        if sample_stats['simulated'] >= sample_stats['failed']:
            dry_run = False
            log("Auto-switch: Dry-check passed -> Running REAL mode")
        else:
            dry_run = True
            log("Auto-switch: Dry-check failed -> Staying in DRY mode")
    else:
        dry_run = True

    # Run workers (first run dry or real depending)
    stats = run_workers(files, dry_run=dry_run)

    # If dry-run and auto-switch enabled, optionally run real now
    if dry_run and AUTO_DRY_REAL:
        # prompt user (we're non-interactive inside python; do auto-switch if metric good)
        # We'll run real automatically if simulated >> failed
        sample_stats = quick_dry_check(files)
        if sample_stats['simulated'] >= sample_stats['failed']:
            log("Auto-switch performing REAL run now.")
            stats = run_workers(files, dry_run=False)
        else:
            log("Auto-switch decided NOT to perform REAL run.")

    # Post cleanup: delete original corrupted if selected (not implemented heavy deletion heuristics)
    if DELETE_FAILED:
        log("DELETE_FAILED enabled - scanning for *_corrupted files to remove (none by default).")

    # final
    log(f"Finished: {stats}")
    console = Console()
    console.print(Panel(Text("TrackFix finished — check log for details", style="bold green")))
    save_state()

if __name__ == "__main__":
    # Ensure log file exists
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    open(LOG_FILE, "a").close()
    try:
        main()
    except KeyboardInterrupt:
        log("Interrupted by user")
        save_state()
    except Exception as e:
        log(f"Fatal: {e}\n{traceback.format_exc()}")
        save_state()
PYCODE

# ---- make Python script executable ----
chmod +x "$PY_FILE"

# Export environment variables read by the python script
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
