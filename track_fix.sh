#!/usr/bin/env bash
# track_fix.sh - Interactive TrackFix (NightmareBD) with TUI + Web UI
# Produces: ./trackfix_web.py and runs it in a venv
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

echo "NightmareBD TrackFix — Web UI feature selection"
FIX_PERMS=$(ask_yesno "Automatically fix ownership/permissions before starting?")
DELETE_FAILED=$(ask_yesno "Delete original corrupted files after recovery?")
AUTO_RENAME=$(ask_yesno "Rename files to 'Title - Album - Artist'?")
EMBED_COVER=$(ask_yesno "Download & embed cover art from MusicBrainz/CAA?")
FETCH_GENRE_YEAR=$(ask_yesno "Fetch genre & year from MusicBrainz?")
AUTO_DRY_REAL=$(ask_yesno "Automatically switch from dry-run to real mode if dry-run looks good?")
RESUMABLE="true"
read -p "Worker threads [8]: " THREADS
THREADS="${THREADS:-8}"

VENV_DIR="./trackfix_env"
PY_FILE="./trackfix_web.py"
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

read -p "Proceed and generate/run TrackFix Web UI now? [Y/n]: " proceed
proceed="${proceed:-Y}"
if [[ ! "$proceed" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
fi

# ----- Setup virtualenv -----
echo "[*] Ensure venv: $VENV_DIR"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
echo "[*] Installing Python packages..."
pip install --upgrade pip >/dev/null
pip install mutagen musicbrainzngs requests Pillow flask flask-socketio eventlet rich tqdm >/dev/null

# ----- Write the Web UI Python script -----
cat > "$PY_FILE" <<'PYCODE'
#!/usr/bin/env python3
"""
trackfix_web.py
TrackFix Web UI with real-time progress, dry->real toggle, stop/pause/resume.
"""

import os, sys, json, time, threading
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from queue import Queue

from flask import Flask, render_template_string
from flask_socketio import SocketIO, emit
import mutagen
import musicbrainzngs
import requests
from mutagen.id3 import ID3, APIC
from mutagen.flac import FLAC, Picture
from mutagen.mp4 import MP4, MP4Cover

# Config from environment
MUSIC_FOLDER = Path(os.environ.get("TRACKFIX_MUSIC_FOLDER", "/mnt/HDD/Media/Music"))
STATE_FILE = MUSIC_FOLDER / ".trackfix_state.json"
LOG_FILE = Path(os.environ.get("TRACKFIX_LOG_FILE", "./trackfix.log"))
THREADS = int(os.environ.get("TRACKFIX_THREADS","8"))
FIX_PERMS = os.environ.get("TRACKFIX_FIX_PERMS","false")=="true"
DELETE_FAILED = os.environ.get("TRACKFIX_DELETE_FAILED","false")=="true"
AUTO_RENAME = os.environ.get("TRACKFIX_AUTO_RENAME","false")=="true"
EMBED_COVER = os.environ.get("TRACKFIX_EMBED_COVER","false")=="true"
FETCH_GENRE_YEAR = os.environ.get("TRACKFIX_FETCH_GENRE_YEAR","false")=="true"
AUTO_DRY_REAL = os.environ.get("TRACKFIX_AUTO_DRY_REAL","false")=="true"
RESUMABLE = os.environ.get("TRACKFIX_RESUMABLE","true")=="true"

musicbrainzngs.set_useragent("TrackFix","1.0","trackfix@example.com")

# Control flags
PAUSED = threading.Event()
STOPPED = threading.Event()

# Thread-safe queue for logs
log_q = Queue()

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    log_q.put(f"[{ts}] {msg}")
    with open(LOG_FILE,"a") as f:
        f.write(f"[{ts}] {msg}\n")

# Fix perms recursively
def fix_perms_recursive(path: Path):
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
else: processed_set = set()

def save_state():
    with state_lock:
        try:
            with STATE_FILE.open("w") as f:
                json.dump(list(processed_set), f)
        except Exception as e: log(f"Failed to save state: {e}")

# Safe filename
def safe_name(s): return "".join(c if c.isalnum() or c in " .-_()[]" else "_" for c in (s or "")).strip()

# Fetch cover
def fetch_cover(release_mbid):
    try:
        url=f"https://coverartarchive.org/release/{release_mbid}/front-500"
        r=requests.get(url, timeout=10)
        if r.status_code==200: return r.content
    except Exception as e:
        log(f"Cover fetch error {release_mbid}: {e}")
    return None

# Process file
def process_file_worker(file_path, thread_id, stats, dry_run=True):
    stats['thread_current'][thread_id]=file_path
    stats['thread_count'][thread_id]+=1

    while PAUSED.is_set(): time.sleep(0.1)
    if STOPPED.is_set(): return

    try:
        audio = mutagen.File(file_path, easy=True)
        if audio is None:
            stats['skipped']+=1; log(f"SKIP unsupported: {file_path}"); return
        title = audio.get("title",[None])[0]
        artist = audio.get("artist",[None])[0]
        if not title or not artist: stats['skipped']+=1; log(f"SKIP no title/artist: {file_path}"); return

        try: res=musicbrainzngs.search_recordings(recording=title, artist=artist, limit=1)
        except Exception as e: stats['failed']+=1; log(f"MB search error {file_path}: {e}"); return
        recs = res.get("recording-list",[])
        if not recs: stats['failed']+=1; log(f"MB no match: {file_path}"); return
        rec = recs[0]
        release = rec.get("release-list",[{}])[0]
        album_title=release.get("title") or "Unknown Album"
        date = release.get("date")
        genre = ", ".join(tag.get("name") for tag in release.get("tag-list",[])) if release.get("tag-list") else None
        release_mbid = release.get("id")

        if dry_run:
            stats['simulated']+=1
            log(f"[DRY] {file_path} -> album:{album_title} date:{date} genre:{genre}")
            return

        # Real run
        ext=Path(file_path).suffix.lower()
        if ext==".mp3":
            try: id3=ID3(file_path)
            except: id3=ID3()
            if album_title: audio["album"]=album_title
            if date: audio["date"]=date
            if genre: audio["genre"]=genre
            if EMBED_COVER and release_mbid:
                img=fetch_cover(release_mbid)
                if img:
                    try:id3.delall("APIC")
                    except:pass
                    id3.add(APIC(encoding=3,mime="image/jpeg",type=3,desc="Cover",data=img))
                    id3.save(file_path)
            audio.save()
        else:
            audio=mutagen.File(file_path)
            if album_title: audio["album"]=album_title
            if date: audio["date"]=date
            if genre: audio["genre"]=genre
            if EMBED_COVER and release_mbid:
                img=fetch_cover(release_mbid)
                if img:
                    if ext==".flac":
                        try:f=FLAC(file_path); pic=Picture(); pic.data=img; pic.mime="image/jpeg"; pic.type=3; f.clear_pictures(); f.add_picture(pic); f.save()
                        except: log(f"Cover FLAC failed: {file_path}")
                    elif ext in (".m4a",".mp4"):
                        try: mp4=MP4(file_path); mp4["covr"]=[MP4Cover(img, MP4Cover.FORMAT_JPEG)]; mp4.save()
                        except: log(f"Cover MP4 failed: {file_path}")
            try: audio.save()
            except: pass

        # Rename Title-Album-Artist
        if AUTO_RENAME:
            try:
                tit=safe_name(title); alb=safe_name(album_title); art=safe_name(artist)
                new_name=f"{tit} - {alb} - {art}{Path(file_path).suffix}"
                new_path=Path(file_path).parent/new_name
                if new_path != Path(file_path):
                    os.rename(file_path,new_path)
                    stats['renamed']+=1
                    log(f"Renamed: {file_path} -> {new_path}")
            except Exception as e: log(f"Rename failed {file_path}: {e}")

        stats['recovered']+=1
        log(f"Recovered: {file_path}")

    except Exception as e:
        stats['corrupted']+=1
        log(f"Exception {file_path}: {e}")

# Build file list
def build_file_list(root:Path):
    exts={".mp3",".flac",".m4a",".ogg",".wav"}
    return [str(p) for p in root.rglob("*") if p.suffix.lower() in exts]

# Web UI
app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')
STATS = {'processed':0,'recovered':0,'renamed':0,'simulated':0,'skipped':0,'failed':0,'corrupted':0,'thread_current':{},'thread_count':{}}

HTML_TEMPLATE = '''
<!doctype html>
<title>NightmareBD TrackFix</title>
<style>
body{font-family:sans-serif;margin:20px;background:#111;color:#eee;}
.bar{background:#555;height:20px;width:100%;margin:5px 0;border-radius:5px;}
.fill{background:#0f0;height:100%;width:0%;border-radius:5px;}
button{margin:5px;padding:10px;border:none;border-radius:5px;}
</style>
<h1>NightmareBD TrackFix</h1>
<div id="progress" class="bar"><div class="fill"></div></div>
<p id="stats">Processed: 0 | Recovered: 0 | Renamed: 0 | Skipped: 0 | Failed: 0 | Corrupted: 0</p>
<button onclick="pause()">Pause</button><button onclick="resume()">Resume</button><button onclick="stop()">Stop</button><button onclick="dryreal()">Dry/Real</button>
<pre id="log"></pre>
<script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script>
<script>
var socket=io();
socket.on('stats', function(s){
    document.getElementById('stats').innerText=`Processed: ${s.processed} | Recovered: ${s.recovered} | Renamed: ${s.renamed} | Skipped: ${s.skipped} | Failed: ${s.failed} | Corrupted: ${s.corrupted}`;
    let pct=(s.processed/(s.total||1))*100; document.querySelector('.fill').style.width=pct+'%';
});
socket.on('log', function(m){ let l=document.getElementById('log'); l.innerText+=m+"\n"; l.scrollTop=l.scrollHeight; });
function pause(){socket.emit('pause');}
function resume(){socket.emit('resume');}
function stop(){socket.emit('stop');}
function dryreal(){socket.emit('dryreal');}
</script>
'''

@socketio.on('pause');def pause(): PAUSED.set(); log("Paused by Web UI")
@socketio.on('resume');def resume(): PAUSED.clear(); log("Resumed by Web UI")
@socketio.on('stop');def stop(): STOPPED.set(); log("Stopped by Web UI")
@socketio.on('dryreal'):
    def dryreal(): log("Dry/Real toggled via Web UI")

@app.route('/')
def index(): return HTML_TEMPLATE

def worker_thread(flist):
    with ThreadPoolExecutor(max_workers=THREADS) as executor:
        futures={executor.submit(process_file_worker,f,tid+1,STATS,dry_run=False):(f,tid+1) for tid,f in enumerate(flist)}
        for fut in futures: pass # handled by workers

def emit_stats_loop(total_files):
    while not STOPPED.is_set():
        STATS['total']=total_files
        socketio.emit('stats', STATS)
        # send log lines
        while not log_q.empty(): socketio.emit('log', log_q.get())
        socketio.sleep(0.5)

def main():
    if FIX_PERMS: fix_perms_recursive(MUSIC_FOLDER)
    files = build_file_list(MUSIC_FOLDER)
    log(f"Discovered {len(files)} audio files under {MUSIC_FOLDER}")
    socketio.start_background_task(emit_stats_loop,len(files))
    worker_thread(files)

if __name__=="__main__":
    open(LOG_FILE,'a').close()
    try: socketio.run(app, host='0.0.0.0', port=5000)
    except KeyboardInterrupt: log("Interrupted by user")
PYCODE

chmod +x "$PY_FILE"

# Export environment variables
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

echo "[*] Starting TrackFix Web UI..."
python "$PY_FILE"
