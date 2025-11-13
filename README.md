# NightmareBD TrackFix — Final TUI Build (v1)

![TrackFix Banner](https://img.shields.io/badge/TrackFix-v1-blue)

**TrackFix** is a self-contained, terminal-based audio file recovery and metadata fixer. It works with MP3, FLAC, M4A, OGG, and WAV files, fetching metadata and cover art from MusicBrainz and Cover Art Archive, renaming files, and providing a live colorful TUI dashboard.

---

## Features

- Automatic discovery of audio files in a specified folder.
- Fetch metadata: title, album, artist, genre, and year from MusicBrainz.
- Embed album cover art from Cover Art Archive.
- Optional renaming: `Title - Album - Artist`.
- Dry-run and real mode with optional auto-switch.
- Multi-threaded processing with per-thread live progress indicators.
- Colorful TUI with fading log entries.
- Resumable processing via state file `.trackfix_state.json`.
- Optional automatic fix of file permissions.
- Optional deletion of corrupted files.
- Self-contained: single `track_fix.sh` script, no separate Python files required.

---

## Requirements

- Linux or macOS
- Python 3.8+ (virtual environment is automatically created)
- Internet connection for metadata and cover art fetching

---


## Installation & Usage

1. Clone this repository:

```bash
git clone https://github.com/nightmarebd/Music-Recovery.git
cd Music-Recovery
bash track_fix.sh
