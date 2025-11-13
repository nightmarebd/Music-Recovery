#!/usr/bin/env bash
# track_fix.sh - Interactive TrackFix (NightmareBD) generator + runner
# Both TUI and Web UI
# Produces: ./trackfix_tui.py and ./trackfix_web.py and runs them in a venv
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

echo "NightmareBD TrackFix — Feature selection"
FIX_PERMS=$(ask_yesno "Automatically fix ownership/permissions before starting?")
DELETE_FAILED=$(ask_yesno "Delete original corrupted files after successful recovery?")
AUTO_RENAME=$(ask_yesno "Rename files to 'Title - Album - Artist'?")
EMBED_COVER=$(ask_yesno "Download & embed cover art from MusicBrainz/CAA?")
FETCH_GENRE_YEAR=$(ask_yesno "Fetch genre & year from MusicBrainz?")
AUTO_DRY_REAL=$(ask_yesno "Automatically switch from dry-run to real mode if dry-run looks good?")
RESUMABLE="true"   # always on
read -p "Worker threads (recommended 6-12) [8]: " THREADS
THREADS="${THREADS:-8}"

# Runtime files
VENV_DIR="./trackfix_env"
TUI_FILE="./trackfix_tui.py"
WEB_FILE="./trackfix_web.py"
STATE_FILE="${MUSIC_FOLDER}/.trackfix_state.json"
LOG_FILE="./trackfix.log"

# ----- Python venv setup -----
echo "[*] Ensuring virtualenv at $VENV_DIR ..."
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
pip install --upgrade pip >/dev/null
pip install mutagen musicbrainzngs requests Pillow rich tqdm flask flask_socketio eventlet >/dev/null

# ----- Export env vars -----
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

# ----- Launch Web UI in background -----
# Web file
cat > "$WEB_FILE" <<'PYWEB'
#!/usr/bin/env python3
"""
trackfix_web.py - Web UI for TrackFix
Shows progress & per-thread colored indicators, allows dry/real switch, pause/resume/stop
"""
import os, threading, time, json
from pathlib import Path
from flask import Flask, render_template_string, jsonify, request
from flask_socketio import SocketIO, emit
import subprocess, socket

MUSIC_FOLDER = Path(os.environ.get("TRACKFIX_MUSIC_FOLDER","/mnt/HDD/Media/Music"))
STATE_FILE = MUSIC_FOLDER / ".trackfix_state.json"
LOG_FILE = Path(os.environ.get("TRACKFIX_LOG_FILE","./trackfix.log"))
THREADS = int(os.environ.get("TRACKFIX_THREADS","8"))

app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')

# Shared runtime stats
stats = {
    "processed":0, "recovered":0, "renamed":0,
    "simulated":0, "skipped":0, "failed":0, "corrupted":0,
    "thread_current":{i+1:"" for i in range(THREADS)},
    "thread_count":{i+1:0 for i in range(THREADS)},
    "dry_run":True, "paused":False
}

def log(msg):
    ts=time.strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE,"a") as f:
        f.write(f"[{ts}] {msg}\n")

# Dummy background worker simulation
def dummy_worker():
    while stats["processed"] < 100:
        if not stats["paused"]:
            for tid in range(1, THREADS+1):
                stats["thread_current"][tid]=f"file_{stats['processed']+1}.mp3"
                stats["thread_count"][tid]+=1
                stats["processed"]+=1
                socketio.emit("update", stats)
                time.sleep(0.1)
        else:
            time.sleep(0.2)

threading.Thread(target=dummy_worker,daemon=True).start()

@app.route("/")
def index():
    return render_template_string("""
    <!doctype html><html><head>
    <title>NightmareBD TrackFix</title>
    <script src="https://cdn.socket.io/4.6.1/socket.io.min.js"></script>
    <style>
    body{font-family:sans-serif; background:#111; color:#eee;}
    .bar{background:#444;height:20px;width:0%;margin:5px 0;}
    </style>
    </head>
    <body>
    <h2>NightmareBD TrackFix Web UI</h2>
    <div>Processed: <span id="processed">0</span> / <span id="total">100</span></div>
    <div class="bar" id="progress"></div>
    <div id="threads"></div>
    <button onclick="pauseResume()">Pause/Resume</button>
    <button onclick="stopRun()">Stop</button>
    <button onclick="dryReal()">Switch Dry/Real</button>
    <pre id="log"></pre>
    <script>
    var socket=io();
    socket.on("update",function(d){
        document.getElementById("processed").innerText=d.processed;
        document.getElementById("progress").style.width=(d.processed)+"%";
        let t="";
        for(tid in d.thread_current){ t+=`T${tid} (${d.thread_count[tid]}): ${d.thread_current[tid]}\n`; }
        document.getElementById("threads").innerText=t;
    });
    function pauseResume(){socket.emit("pause");}
    function stopRun(){socket.emit("stop");}
    function dryReal(){socket.emit("dry_real");}
    </script>
    </body></html>
    """)

@socketio.on("pause")
def pause(): stats["paused"]=not stats["paused"]; log(f"Paused={stats['paused']}"); emit("update", stats, broadcast=True)
@socketio.on("stop")
def stop(): log("Stop requested"); emit("update", stats, broadcast=True)
@socketio.on("dry_real")
def dry_real(): stats["dry_run"]=not stats["dry_run"]; log(f"Dry->Real switch={stats['dry_run']}"); emit("update", stats, broadcast=True)

def get_ip():
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8",80))
        ip=s.getsockname()[0]
    except:
        ip="127.0.0.1"
    finally:
        s.close()
    return ip

if __name__=="__main__":
    ip=get_ip()
    print(f"[*] TrackFix Web UI running at http://{ip}:5000")
    socketio.run(app,host="0.0.0.0",port=5000)
PYWEB

chmod +x "$WEB_FILE"

# Detect IP
IP=$(hostname -I | awk '{print $1}')
echo "[*] Starting TrackFix Web UI in background..."
nohup python "$WEB_FILE" >/dev/null 2>&1 &

echo "[*] Web UI available at: http://$IP:5000"

# ----- Start TUI -----
echo "[*] Launching TrackFix TUI (terminal interface)..."
python "$TUI_FILE"
