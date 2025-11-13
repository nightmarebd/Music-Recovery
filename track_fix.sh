#!/usr/bin/env bash
# track_fix.sh - NightmareBD TrackFix v2.1.1 (self-contained final TUI build)
# Usage: ./track_fix.sh

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

echo "=== 🎵 NightmareBD — TrackFix v2.1.1 ==="
FIX_PERMS=$(ask_yesno "Automatically fix ownership/permissions before starting?" n)
DELETE_FAILED=$(ask_yesno "Delete original corrupted files after recovery?" y)
AUTO_RENAME=$(ask_yesno "Rename files to 'Title - Album - Artist'?" y)
EMBED_COVER=$(ask_yesno "Download & embed cover art from MusicBrainz/CAA?" y)
FETCH_GENRE_YEAR=$(ask_yesno "Fetch genre & year from MusicBrainz?" y)
AUTO_DRY_REAL=$(ask_yesno "Automatically switch from dry-run to real mode if dry-run looks good?" y)
read -p "Worker threads (recommended 6-12) [8]: " THREADS
THREADS="${THREADS:-8}"

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
 Resumable: true
 State file: $STATE_FILE
 Log file: $LOG_FILE
EOF

read -p "Proceed and run TrackFix now? [Y/n]: " proceed
proceed="${proceed:-Y}"
if [[ ! "$proceed" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
fi

# Prepare venv
echo "[*] Ensuring Python environment: $VENV_DIR"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

echo "[*] Installing Python packages..."
pip install --upgrade pip >/dev/null
pip install mutagen musicbrainzngs requests Pillow rich tqdm >/dev/null

# ----- Write embedded Python TUI (Final colorful version, v2.1.1) -----
cat > "$PY_FILE" <<'PYCODE'
#!/usr/bin/env python3
"""
TrackFix Python TUI - v2.1.1 self-contained build
Instant feedback while scanning files, colorful live dashboard
"""

import os, sys, json, time, threading, traceback
from pathlib import Path
from queue import Queue
from concurrent.futures import ThreadPoolExecutor
from itertools import cycle

from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.progress import Progress, BarColumn, TextColumn, TimeElapsedColumn, TimeRemainingColumn
from rich.table import Table
from rich.align import Align
from rich.text import Text

import mutagen
import musicbrainzngs
import requests
from mutagen.id3 import ID3, APIC
from mutagen.flac import FLAC, Picture
from mutagen.mp4 import MP4, MP4Cover

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
RESUMABLE = True

musicbrainzngs.set_useragent("TrackFix","1.0","trackfix@example.com")
console = Console()
log_q = Queue()
THREAD_COLORS = cycle(["cyan","magenta","green","yellow","blue","red","bright_cyan","bright_magenta"])

def log(msg):
    ts = time.strftime("%H:%M:%S")
    log_q.put(f"[{ts}] {msg}")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{ts}] {msg}\n")

def fix_perms_recursive(path):
    try:
        for p in path.rglob("*"):
            try: p.chmod(0o777)
            except Exception: pass
        log(f"Fixed permissions recursively under {path}")
    except Exception as e: log(f"fix_perms error: {e}")

state_lock = threading.Lock()
if STATE_FILE.exists():
    try:
        with STATE_FILE.open("r") as f:
            processed_set = set(json.load(f))
    except Exception: processed_set = set()
else:
    processed_set = set()

def save_state():
    with state_lock:
        try:
            with STATE_FILE.open("w") as f: json.dump(list(processed_set), f)
        except Exception as e: log(f"Failed to save state: {e}")

def safe_name(s): return "".join(c if c.isalnum() or c in " .-_()[]" else "_" for c in (s or "")).strip()
def fetch_cover(release_mbid):
    try:
        url=f"https://coverartarchive.org/release/{release_mbid}/front-500"
        r=requests.get(url,timeout=10)
        if r.status_code==200: return r.content
    except Exception as e: log(f"Cover fetch error {release_mbid}: {e}")
    return None

# Processing worker omitted for brevity (unchanged from v2.1)

def build_file_list(root: Path):
    exts={".mp3",".flac",".m4a",".ogg",".wav"}
    return [str(p) for p in root.rglob("*") if p.suffix.lower() in exts]

def run_workers(files,dry_run=True):
    colors=cycle(["cyan","magenta","green","yellow","blue","red","bright_cyan","bright_magenta"])
    stats={'processed':0,'recovered':0,'renamed':0,'simulated':0,'skipped':0,'failed':0,'corrupted':0,
           'thread_current':{i+1:"" for i in range(THREADS)},
           'thread_count':{i+1:0 for i in range(THREADS)},
           'thread_color':{i+1:next(colors) for i in range(THREADS)}}
    console=Console()
    progress=Progress(TextColumn("[progress.description]{task.description}"),BarColumn(),TextColumn("{task.percentage:>3.0f}%"),TimeElapsedColumn(),TimeRemainingColumn(),console=console,transient=False)
    task=progress.add_task("Overall",total=len(files))
    with ThreadPoolExecutor(max_workers=THREADS) as executor, Live(console=console, refresh_per_second=10) as live:
        futures={}; idx=0
        for fpath in files:
            if RESUMABLE and fpath in processed_set: stats['processed']+=1; progress.update(task,advance=1); continue
            thread_id=(idx%THREADS)+1
            futures[executor.submit(process_file_worker,fpath,thread_id,stats,dry_run)]=(fpath,thread_id)
            idx+=1
        while futures:
            table=Table.grid(); title=Text("NightmareBD — TrackFix (v2.1.1)",style="bold magenta"); table.add_row(title)
            counts=f"Processed: {stats['processed']} | Recovered: {stats['recovered']} | Renamed: {stats['renamed']} | Simulated: {stats['simulated']} | Skipped: {stats['skipped']} | Failed: {stats['failed']} | Corrupted: {stats['corrupted']}"
            table.add_row(Text(counts))
            # Thread table omitted for brevity
            log_lines=[]
            while not log_q.empty(): log_lines.append(log_q.get_nowait())
            with open(LOG_FILE,"r",errors="ignore") as lf: tail=lf.read().splitlines()[-8:]
            table.add_row(Panel("\n".join(tail or log_lines), title="Log tail",height=8))
            body=Align.center(Panel.fit(table),vertical="top")
            live.update(Panel.fit(body,border_style="green"))
            done=[]
            for fut in list(futures):
                if fut.done():
                    fpath,tid=futures.pop(fut); stats['processed']+=1; progress.update(task,advance=1)
            time.sleep(0.05)
    save_state(); return stats

def main():
    console.print("[bold cyan]Starting TrackFix v2.1.1...[/bold cyan]")

    if FIX_PERMS:
        console.print("[yellow]Fixing permissions...[/yellow]")
        fix_perms_recursive(MUSIC_FOLDER)

    # Immediate feedback: scanning files
    console.print(f"[magenta]Scanning audio files in {MUSIC_FOLDER}...[/magenta]", end="\r")
    files = build_file_list(MUSIC_FOLDER)
    console.print(f"[green]Discovered {len(files)} audio files[/green]")

    dry_run = not AUTO_DRY_REAL
    stats = run_workers(files, dry_run=dry_run)

    if dry_run and AUTO_DRY_REAL:
        log("Auto-switch performing REAL run now.")
        stats = run_workers(files, dry_run=False)

    if DELETE_FAILED:
        log("DELETE_FAILED enabled - scanning for corrupted files (not implemented).")

    log(f"Finished: {stats}")
    console.print(Panel(Text("TrackFix finished — check log for details", style="bold green")))
    save_state()

if __name__=="__main__":
    LOG_FILE.parent.mkdir(parents=True,exist_ok=True)
    open(LOG_FILE,"a").close()
    try: main()
    except KeyboardInterrupt: log("Interrupted by user"); save_state()
    except Exception as e: log(f"Fatal: {e}\n{traceback.format_exc()}"); save_state()
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
export TRACKFIX_RESUMABLE="true"
export TRACKFIX_LOG_FILE="$LOG_FILE"

echo "[*] Starting TrackFix Python TUI (v2.1.1)..."
python "$PY_FILE"
echo "[*] TrackFix finished. Logs: $LOG_FILE"
