#!/bin/bash
# ==============================================================
# 🩸 NightmareBD — TrackFix
# Fully Automated Music Metadata Recovery & Renaming Engine
# ==============================================================
# Only change: file rename format → Title - Album - Artist
# ==============================================================

set -e
MUSIC_DIR="/mnt/HDD/Media/Music"
VENV_DIR="./trackfix_env"
STATE_FILE=".trackfix_state.json"
LOG_FILE="./trackfix.log"

clear
echo "────────────────────────────────────────────"
echo "🎧  NightmareBD TrackFix — Music Recovery"
echo "────────────────────────────────────────────"
echo "Music folder: $MUSIC_DIR"
echo "Virtualenv:   $VENV_DIR"
echo "State file:   $STATE_FILE"
echo "Log file:     $LOG_FILE"
echo "────────────────────────────────────────────"

# --- Auto fix permissions before anything ---
echo "[*] Fixing ownership and permissions recursively..."
chown -R nobody:nogroup "$MUSIC_DIR" 2>/dev/null || true
chmod -R 777 "$MUSIC_DIR" 2>/dev/null || true

# --- Ensure Python virtualenv ---
if [ ! -d "$VENV_DIR" ]; then
  echo "[*] Creating virtual environment..."
  python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

echo "[*] Installing/Upgrading required packages..."
pip install --upgrade pip >/dev/null
pip install --upgrade mutagen musicbrainzngs requests Pillow tqdm blessed >/dev/null

# --- Start the main worker Python script ---
python3 - <<'PY'
import os, json, threading, time, queue, musicbrainzngs, mutagen, sys
from mutagen.easyid3 import EasyID3
from mutagen.mp3 import MP3
from PIL import Image
import io, requests
from tqdm import tqdm
from blessed import Terminal

# CONFIG
MUSIC_DIR = "/mnt/HDD/Media/Music"
STATE_FILE = ".trackfix_state.json"
THREADS = 4

term = Terminal()
lock = threading.Lock()
q = queue.Queue()
stats = {"total":0,"processed":0,"recovered":0,"skipped":0,"failed":0,"corrupted":0}

# --- Init MusicBrainz ---
musicbrainzngs.set_useragent("TrackFix", "1.0", "nightmarebd@example.com")

# --- Load or create state ---
processed = set()
if os.path.exists(STATE_FILE):
    with open(STATE_FILE) as f:
        try: processed = set(json.load(f))
        except: processed = set()

# --- Collect files ---
for root, dirs, files in os.walk(MUSIC_DIR):
    for f in files:
        if f.lower().endswith((".mp3",".flac",".m4a",".wav",".ogg")):
            full = os.path.join(root, f)
            if full not in processed:
                q.put(full)
stats["total"] = q.qsize()

def safe_filename(txt):
    import re
    return re.sub(r'[\\/*?:"<>|]', '', txt.strip())

def fetch_metadata(file):
    try:
        audio = MP3(file, ID3=EasyID3)
        title = audio.get('title', [None])[0]
        artist = audio.get('artist', [None])[0]
        album = audio.get('album', [None])[0]

        if not title or not artist:
            name = os.path.basename(file).rsplit('.',1)[0]
            res = musicbrainzngs.search_recordings(recording=name, limit=1)
            if res.get('recording-list'):
                rec = res['recording-list'][0]
                title = rec.get('title', title)
                artist = rec['artist-credit'][0]['artist']['name'] if 'artist-credit' in rec else artist
                album = rec.get('release-list',[{}])[0].get('title', album)
        return {
            "title": title or "Unknown Title",
            "artist": artist or "Unknown Artist",
            "album": album or "Unknown Album"
        }
    except Exception:
        return None

# ✅ File rename pattern fixed: Title - Album - Artist
def rename_file(file, metadata):
    try:
        title = safe_filename(metadata["title"])
        album = safe_filename(metadata["album"])
        artist = safe_filename(metadata["artist"])
        new_name = f"{title} - {album} - {artist}.mp3"
        new_dir = os.path.join(MUSIC_DIR, artist, album)
        os.makedirs(new_dir, exist_ok=True)
        new_path = os.path.join(new_dir, new_name)
        os.rename(file, new_path)
        return new_path
    except Exception:
        return None

def worker(tid):
    while not q.empty():
        file = q.get()
        try:
            meta = fetch_metadata(file)
            if not meta:
                stats["failed"] += 1
                continue
            new_path = rename_file(file, meta)
            if not new_path:
                stats["failed"] += 1
            else:
                stats["recovered"] += 1
            with lock:
                processed.add(file)
                stats["processed"] += 1
                with open(STATE_FILE,"w") as f: json.dump(list(processed), f)
        except Exception:
            stats["failed"] += 1
        q.task_done()

threads = [threading.Thread(target=worker,args=(i+1,)) for i in range(THREADS)]
for t in threads: t.start()

with term.fullscreen(), term.cbreak(), term.hidden_cursor():
    while any(t.is_alive() for t in threads):
        with lock:
            pct = (stats["processed"]/stats["total"]*100) if stats["total"]>0 else 0
            bar = int(pct/2)
            print(term.clear())
            print(term.bold_red("🩸 NightmareBD — TrackFix Dashboard"))
            print(f"Total: {stats['total']} | Processed: {stats['processed']} | Recovered: {stats['recovered']} | Failed: {stats['failed']}")
            print(f"Progress: [{term.red('#'*bar)}{term.white('-'*(50-bar))}] {pct:.2f}%")
            print(term.yellow(f"Threads Active: {sum(t.is_alive() for t in threads)}"))
        time.sleep(1)

for t in threads: t.join()
print(term.green("\n✅ All processing complete!"))
PY
