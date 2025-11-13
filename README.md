# NightmareBD Music Recovery /Track Fix

**Track Fix** is a fully automated, multi-threaded music metadata recovery and organization tool.  
It fetches metadata (Artist, Album, Title, Year, Genre, Cover Art) from MusicBrainz, renames files, fixes permissions, deletes corrupted files, and provides a real-time interactive console GUI with live progress stats.

---

## Features

- **NightmareBD ASCII banner** on startup.
- **Dynamic music folder selection** at runtime.
- **Resumable** using `.processed_files.json` to continue after crashes.
- **Multi-threaded processing** (8 threads by default) for speed.
- **Fetches metadata**: Artist, Album, Title, Year, Genre.
- **Fetches album cover art** and embeds in audio files.
- **Auto renames files** to `Artist - Album - Title`.
- **Auto deletes corrupted/unreadable files**.
- **Auto fixes permissions and ownership** (`chown nobody:nogroup`, `chmod 777` recursively).
- **Interactive console GUI** with live stats, progress per thread, and file counts.
- **Dry-run / Real mode** integrated; automatically switches between modes if needed.
- Supports multiple formats: **MP3, FLAC, M4A/MP4, OGG**.
- **Crash-resume support** ensures you never lose progress.

---

## Requirements

- Python 3.13+  
- Bash shell  
- `pip` (will be auto-installed if missing)  
- Internet connection (for MusicBrainz metadata and cover art)

---

## Installation & Usage

1. Clone this repository:

```bash
git clone https://github.com/nightmarebd/track_fix.git](https://github.com/nightmarebd/Music-Recovery/blob/main/track_fix.sh
cd track_fix
bash track_fix.git
