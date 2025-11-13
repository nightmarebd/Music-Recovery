#!/usr/bin/env bash
# track_fix.sh - NightmareBD TrackFix with Web UI + TUI-like per-thread dashboard
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

echo "NightmareBD TrackFix — Web UI feature selection"
FIX_PERMS=$(ask_yesno "Automatically fix ownership/permissions before starting?" "y")
DELETE_FAILED=$(ask_yesno "Delete original corrupted files after recovery?" "y")
AUTO_RENAME=$(ask_yesno "Rename files to 'Title - Album - Artist' based on metadata?" "y")
EMBED_COVER=$(ask_yesno "Download & embed cover art from MusicBrainz/CAA?" "y")
FETCH_GENRE_YEAR=$(ask_yesno "Fetch genre & year from MusicBrainz?" "y")
AUTO_DRY_REAL=$(ask_yesno "Automatically switch from dry-run to real mode if dry-run looks good?" "y")
read -p "Worker threads (recommended 4-12) [8]: " THREADS
THREADS="${THREADS:-8}"
RESUMABLE="true"

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

# Prepare venv
echo "[*] Ensure venv: $VENV_DIR"
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

echo "[*] Installing Python packages..."
pip install --upgrade pip >/dev/null
pip install mutagen musicbrainzngs requests Pillow rich tqdm flask flask-socketio eventlet >/dev/null

# Generate embedded Web UI Python
cat > "$PY_FILE" <<'PYCODE'
#!/usr/bin/env python3
"""
trackfix_web.py - TrackFix Web UI with per-thread live dashboard
"""
import os, time, json, threading, traceback
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from queue import Queue

from flask import Flask, render_template, jsonify
from flask_socketio import SocketIO, emit

import mutagen
import musicbrainzngs
from mutagen.id3 import ID3, APIC
from mutagen.mp4 import MP4, MP4Cover
from mutagen.flac import FLAC, Picture

# --- Config from env ---
MUSIC_FOLDER = Path(os.environ.get("TRACKFIX_MUSIC_FOLDER", "/mnt/HDD/Media/Music"))
STATE_FILE = MUSIC_FOLDER / ".trackfix_state.json"
LOG_FILE = Path(os.environ.get("TRACKFIX_LOG_FILE", "./trackfix.log"))
THREADS = int(os.environ.get("TRACKFIX_THREADS", "8"))
FIX_PERMS = os.environ.get("TRACKFIX_FIX_PERMS", "false")=="true"
DELETE_FAILED = os.environ.get("TRACKFIX_DELETE_FAILED", "false")=="true"
AUTO_RENAME = os.environ.get("TRACKFIX_AUTO_RENAME", "false")=="true"
EMBED_COVER = os.environ.get("TRACKFIX_EMBED_COVER", "false")=="true"
FETCH_GENRE_YEAR = os.environ.get("TRACKFIX_FETCH_GENRE_YEAR", "false")=="true"
AUTO_DRY_REAL = os.environ.get("TRACKFIX_AUTO_DRY_REAL", "false")=="true"
RESUMABLE = os.environ.get("TRACKFIX_RESUMABLE","true")=="true"

musicbrainzngs.set_useragent("TrackFix","1.0","trackfix@example.com")

app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="eventlet")

# --- Global states ---
PAUSED = threading.Event()
STOPPED = threading.Event()
STATE_LOCK = threading.Lock()
log_queue = Queue()
processed_set = set()
thread_current = {i+1: "" for i in range(THREADS)}
thread_count = {i+1: 0 for i in range(THREADS)}

# --- Utilities ---
def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    log_queue.put(f"[{ts}] {msg}")
    with open(LOG_FILE,"a") as f:
        f.write(f"[{ts}] {msg}\n")

def save_state():
    with STATE_LOCK:
        try:
            with STATE_FILE.open("w") as f:
                json.dump(list(processed_set),f)
        except Exception as e:
            log(f"Failed to save state: {e}")

def safe_name(s):
    return "".join(c if c.isalnum() or c in " .-_()[]" else "_" for c in (s or "")).strip()

def build_file_list(root):
    exts={".mp3",".flac",".m4a",".ogg",".wav"}
    return [str(p) for p in root.rglob("*") if p.suffix.lower() in exts]

# --- File processing ---
def process_file_worker(file_path:str, tid:int, dry_run=True):
    thread_current[tid]=file_path
    thread_count[tid]+=1
    try:
        audio = mutagen.File(file_path,easy=True)
        if audio is None: return
        title=audio.get("title",[None])[0]
        artist=audio.get("artist",[None])[0]
        if not title or not artist: return
        # MusicBrainz query
        try:
            res=musicbrainzngs.search_recordings(recording=title,artist=artist,limit=1)
        except: return
        recs=res.get("recording-list",[])
        if not recs: return
        rec=recs[0]
        release=rec.get("release-list",[{}])[0]
        album_title=release.get("title","Unknown Album")
        date=release.get("date")
        genre=None
        tags=release.get("tag-list",[])
        if tags: genre=", ".join(tag.get("name") for tag in tags)
        # Dry-run
        if dry_run: return
        # Real write
        ext=Path(file_path).suffix.lower()
        if ext==".mp3":
            try:
                id3=ID3(file_path)
            except: id3=ID3()
            if album_title: audio["album"]=album_title
            if date: audio["date"]=date
            if genre: audio["genre"]=genre
            audio.save()
            if EMBED_COVER:
                mbid=release.get("id")
                if mbid:
                    try:
                        import requests
                        img=requests.get(f"https://coverartarchive.org/release/{mbid}/front-500",timeout=10).content
                        id3.delall("APIC")
                        id3.add(APIC(encoding=3,mime="image/jpeg",type=3,desc="Cover",data=img))
                        id3.save(file_path)
                    except: pass
        else:
            audio=mutagen.File(file_path)
            if album_title: audio["album"]=album_title
            if date: audio["date"]=date
            if genre: audio["genre"]=genre
            audio.save()
        if AUTO_RENAME:
            tit=safe_name(title)
            alb=safe_name(album_title)
            art=safe_name(artist)
            new_path=Path(file_path).parent / f"{tit} - {alb} - {art}{Path(file_path).suffix}"
            if new_path!=Path(file_path):
                os.rename(file_path,new_path)
        processed_set.add(file_path)
    except Exception as e:
        log(f"Error {file_path}: {e}\n{traceback.format_exc()}")

def worker_runner(files,dry_run=True):
    with ThreadPoolExecutor(max_workers=THREADS) as executor:
        futures={}
        idx=0
        for f in files:
            if RESUMABLE and f in processed_set: continue
            tid=(idx%THREADS)+1
            fut=executor.submit(process_file_worker,f,tid,dry_run)
            futures[fut]=f
            idx+=1
        while futures:
            done=[]
            for fut in list(futures):
                if fut.done():
                    done.append(fut)
                    futures.pop(fut)
            time.sleep(0.1)

# --- Flask routes ---
@app.route("/")
def index():
    return """
<!DOCTYPE html>
<html>
<head><title>TrackFix Web UI</title>
<style>
body{font-family:sans-serif;background:#111;color:#eee}#progress{width:90%;height:20px;background:#333;margin:10px}#bar{height:100%;width:0%;background:#0f0}table{width:90%;margin:10px;border-collapse:collapse}td,th{padding:5px;border:1px solid #555}</style>
</head>
<body>
<h2>NightmareBD TrackFix Web UI</h2>
<div id="progress"><div id="bar"></div></div>
<table id="threads"><tr><th>Thread</th><th>Current File</th></tr></table>
<button onclick="pause()">Pause</button><button onclick="resume()">Resume</button><button onclick="stop()">Stop</button>
<script src="https://cdn.socket.io/4.5.0/socket.io.min.js"></script>
<script>
var socket=io();
socket.on('update',function(data){
  document.getElementById('bar').style.width=data.percent+'%';
  var tbl=document.getElementById('threads'); tbl.innerHTML='<tr><th>Thread</th><th>Current File</th></tr>';
  for(var tid in data.thread_current){
    tbl.innerHTML+='<tr><td>'+tid+'</td><td>'+data.thread_current[tid]+'</td></tr>';
  }
});
function pause(){socket.emit('pause')}
function resume(){socket.emit('resume')}
function stop(){socket.emit('stop')}
</script>
</body>
</html>
"""

# --- SocketIO events ---
@socketio.on('pause')
def pause():
    PAUSED.set()
    log("Paused by Web UI")

@socketio.on('resume')
def resume():
    PAUSED.clear()
    log("Resumed by Web UI")

@socketio.on('stop')
def stop():
    STOPPED.set()
    log("Stopped by Web UI")

def emit_progress():
    total=len(build_file_list(MUSIC_FOLDER))
    while not STOPPED.is_set():
        processed=len(processed_set)
        percent=int(processed/total*100) if total>0 else 0
        socketio.emit('update',{'percent':percent,'thread_current':thread_current})
        time.sleep(0.2)

def main():
    files=build_file_list(MUSIC_FOLDER)
    if FIX_PERMS:
        for p in MUSIC_FOLDER.rglob("*"):
            try: p.chmod(0o777)
            except: pass
    t=threading.Thread(target=emit_progress,daemon=True)
    t.start()
    worker_runner(files,dry_run=False)

if __name__=="__main__":
    LOG_FILE.parent.mkdir(parents=True,exist_ok=True)
    open(LOG_FILE,"a").close()
    socketio.run(app,host="0.0.0.0",port=5000)
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

echo "[*] Starting TrackFix Web UI..."
python "$PY_FILE"
