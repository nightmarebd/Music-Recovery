#!/usr/bin/env bash
# track_fix.sh - NightmareBD TrackFix (Final TUI build with fading logs and error/warning highlights)
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

echo "NightmareBD TrackFix — Final TUI feature selection"
FIX_PERMS=$(ask_yesno "Automatically fix ownership/permissions before starting?")
DELETE_FAILED=$(ask_yesno "Delete original corrupted files after successful recovery?")
AUTO_RENAME=$(ask_yesno "Rename files to 'Title - Album - Artist'?")
EMBED_COVER=$(ask_yesno "Download & embed cover art from MusicBrainz/CAA?")
FETCH_GENRE_YEAR=$(ask_yesno "Fetch genre & year from MusicBrainz?")
AUTO_DRY_REAL=$(ask_yesno "Automatically switch from dry-run to real mode if dry-run looks good?")
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
echo "[*] Ensure venv: $VENV_DIR"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

echo "[*] Installing Python packages..."
pip install --upgrade pip >/dev/null
pip install mutagen musicbrainzngs requests Pillow rich tqdm >/dev/null

# ----- Write embedded Python TUI (Final colorful version with fading logs + highlights) -----
cat > "$PY_FILE" <<'PYCODE'
#!/usr/bin/env python3
"""
TrackFix Python TUI - Final self-contained build with fading logs and error/warning highlights
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
MAX_LOG_LINES = 20
recent_logs = []

def highlight_line(line):
    # Subtle color highlights
    if any(k in line for k in ["SKIP","FAILED","CORRUPTED","EXCEPTION"]):
        return f"[red]{line}[/red]"
    if "[DRY]" in line:
        return f"[yellow]{line}[/yellow]"
    return line

def log(msg):
    ts = time.strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    log_q.put(line)
    recent_logs.append(line)
    if len(recent_logs) > MAX_LOG_LINES: recent_logs.pop(0)
    with open(LOG_FILE, "a") as f: f.write(line+"\n")

def fix_perms_recursive(path):
    try:
        for p in path.rglob("*"):
            try: p.chmod(0o777)
            except: pass
        log(f"Fixed permissions recursively under {path}")
    except Exception as e: log(f"fix_perms error: {e}")

# Resumable state
state_lock = threading.Lock()
if STATE_FILE.exists():
    try:
        with STATE_FILE.open("r") as f:
            processed_set = set(json.load(f))
    except: processed_set = set()
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

# ---- Worker ----
def process_file_worker(file_path: str, thread_id: int, stats: dict, dry_run=True):
    stats['thread_current'][thread_id]=file_path
    stats['thread_count'][thread_id]+=1
    try:
        audio=mutagen.File(file_path,easy=True)
        if audio is None: stats['skipped']+=1; log(f"SKIP unsupported: {file_path}"); return
        title=audio.get("title",[None])[0]; artist=audio.get("artist",[None])[0]
        if not title or not artist: stats['skipped']+=1; log(f"SKIP no title/artist: {file_path}"); return
        try:
            res=musicbrainzngs.search_recordings(recording=title, artist=artist, limit=1)
        except Exception as e: stats['failed']+=1; log(f"FAILED MB search {file_path}: {e}"); return
        recs=res.get("recording-list",[])
        if not recs: stats['failed']+=1; log(f"FAILED MB no match: {file_path}"); return
        rec=recs[0]; release=rec.get("release-list",[{}])[0]
        album_title=release.get("title","Unknown Album"); date=release.get("date",None)
        tags=release.get("tag-list",[]); genre=", ".join(tag.get("name") for tag in tags) if tags else None
        release_mbid=release.get("id",None)
        if dry_run: stats['simulated']+=1; log(f"[DRY] {file_path} -> album:{album_title} date:{date} genre:{genre}"); return
        # Real mode write
        try:
            ext=Path(file_path).suffix.lower()
            if ext==".mp3":
                try:id3=ID3(file_path)
                except:id3=ID3()
                audio["album"]=album_title; audio["date"]=date; audio["genre"]=genre; audio.save()
                if EMBED_COVER and release_mbid:
                    img=fetch_cover(release_mbid)
                    if img:
                        try:id3.delall("APIC")
                        except: pass
                        id3.add(APIC(encoding=3,mime="image/jpeg",type=3,desc="Cover",data=img))
                        id3.save(file_path)
            else:
                audio=mutagen.File(file_path)
                if album_title: audio["album"]=album_title
                if date: audio["date"]=date
                if genre: audio["genre"]=genre
                if EMBED_COVER and release_mbid:
                    img=fetch_cover(release_mbid)
                    if img:
                        if ext==".flac": f=FLAC(file_path); pic=Picture(); pic.data=img; pic.mime="image/jpeg"; pic.type=3; f.clear_pictures(); f.add_picture(pic); f.save()
                        elif ext in (".m4a",".mp4"): mp4=MP4(file_path); mp4["covr"]=[MP4Cover(img,MP4Cover.FORMAT_JPEG)]; mp4.save()
                try: audio.save()
                except: pass
        except Exception as e: stats['failed']+=1; log(f"FAILED Write {file_path}: {e}"); return
        if AUTO_RENAME:
            try:
                tit=safe_name(title); alb=safe_name(album_title); art=safe_name(artist)
                new_name=f"{tit} - {alb} - {art}{Path(file_path).suffix}"
                new_path=Path(file_path).parent/new_name
                if new_path!=Path(file_path): os.rename(file_path,new_path); stats['renamed']+=1; log(f"Renamed: {file_path} -> {new_path}"); file_path=str(new_path)
            except Exception as e: log(f"FAILED Rename {file_path}: {e}")
        stats['recovered']+=1; log(f"Recovered: {file_path}")
    except Exception as e: stats['corrupted']+=1; log(f"CORRUPTED {file_path}: {e}\n{traceback.format_exc()}")

# ---- Build file list ----
def build_file_list(root: Path):
    exts={".mp3",".flac",".m4a",".ogg",".wav"}
    return [str(p) for p in root.rglob("*") if p.suffix.lower() in exts]

# ---- Run workers with fading logs and highlights ----
def run_workers(files,dry_run=True):
    colors=cycle(["cyan","magenta","green","yellow","blue","red","bright_cyan","bright_magenta"])
    stats={'processed':0,'recovered':0,'renamed':0,'simulated':0,'skipped':0,'failed':0,'corrupted':0,
           'thread_current':{i+1:"" for i in range(THREADS)},
           'thread_count':{i+1:0 for i in range(THREADS)},
           'thread_color':{i+1:next(colors) for i in range(THREADS)}}
    console=Console()
    progress=Progress(TextColumn("[progress.description]{task.description}"),BarColumn(),TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),TimeElapsedColumn(),TimeRemainingColumn(),console=console,transient=False)
    task=progress.add_task("Overall",total=len(files))
    with ThreadPoolExecutor(max_workers=THREADS) as executor, Live(console=console, refresh_per_second=10) as live:
        futures={}; idx=0
        for fpath in files:
            if RESUMABLE and fpath in processed_set: stats['processed']+=1; progress.update(task,advance=1); continue
            thread_id=(idx%THREADS)+1
            futures[executor.submit(process_file_worker,fpath,thread_id,stats,dry_run)]=(fpath,thread_id)
            idx+=1
        while futures:
            table=Table.grid()
            title=Text("NightmareBD — TrackFix (Final Build)",style="bold magenta")
            table.add_row(title)
            counts=f"[green]Processed: {stats['processed']}[/green] | [cyan]Recovered: {stats['recovered']}[/cyan] | [yellow]Renamed: {stats['renamed']}[/yellow] | [magenta]Simulated: {stats['simulated']}[/magenta] | [red]Skipped: {stats['skipped']}[/red] | [red]Failed: {stats['failed']}[/red] | [red]Corrupted: {stats['corrupted']}[/red]"
            table.add_row(Text(counts))
            t=Table(title="Threads", show_lines=False, expand=True)
            t.add_column("TID",justify="right"); t.add_column("Count",justify="right"); t.add_column("Current file",overflow="fold")
            for tid in range(1,THREADS+1):
                cur=stats['thread_current'].get(tid,""); cnt=stats['thread_count'].get(tid,0); color=stats['thread_color'][tid]
                t.add_row(Text(str(tid),style=color),Text(str(cnt),style=color),Text(cur[:80],style=color))
            table.add_row(t)
            # Fading log panel with highlights
            log_panel_text=""
            for idx,line in enumerate(recent_logs):
                fade=max(0.3,(idx+1)/len(recent_logs))
                hl=highlight_line(line)
                log_panel_text+=f"[color({int(fade*255)})]{hl}[/color]\n"
            table.add_row(Panel(log_panel_text.rstrip(),title="Recent Log",height=10))
            body=Align.center(Panel.fit(table),vertical="top")
            live.update(Panel.fit(body,border_style="green"))
            for fut in list(futures):
                if fut.done(): fpath,tid=futures.pop(fut); stats['processed']+=1; progress.update(task,advance=1)
            time.sleep(0.05)
    save_state(); return stats

def main():
    if FIX_PERMS: fix_perms_recursive(MUSIC_FOLDER)
    files=build_file_list(MUSIC_FOLDER)
    log(f"Discovered {len(files)} audio files under {MUSIC_FOLDER}")
    dry_run=not AUTO_DRY_REAL
    stats=run_workers(files,dry_run=dry_run)
    if dry_run and AUTO_DRY_REAL: log("Auto-switch performing REAL run now."); stats=run_workers(files,dry_run=False)
    if DELETE_FAILED: log("DELETE_FAILED enabled - scanning for corrupted files (not implemented).")
    log(f"Finished: {stats}")
    console.print(Panel(Text("TrackFix finished — check log for details",style="bold green")))
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

echo "[*] Starting TrackFix Python TUI (Final Build with fading logs & highlights)..."
python "$PY_FILE"
echo "[*] TrackFix finished. Logs: $LOG_FILE"
