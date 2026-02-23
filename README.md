# audlint-cli

Source-available CLI toolkit centered on interactive music library quality browsing.

## Scope
- Primary tool: `bin/audlint.sh`
- Browser-integrated actions are included:
  - maintenance scan: `bin/qty_seek.sh`
  - recode helper: `bin/any2flac.sh`
  - lyrics workflow: `bin/lyrics_seek.sh`, `bin/lyrics_album.sh`
  - transfer sync: `bin/sync_music.sh`

## Additional tools

| Script | Description |
| --- | --- |
| `bin/boost_album.sh` | Bake headroom gain into a FLAC or lossy album in-place; handles Opus/Ogg cover edge cases |
| `bin/boost_seek.sh` | Walk library and invoke `boost_album.sh` on qualifying albums with stdin forwarded correctly |
| `bin/clear_tags.sh` | Clear lyrics tags and cached lyrics DB entries for files in the current folder |
| `bin/cue2flac.sh` | Split a high-res audio file into per-track FLACs using a .cue sheet (FLAC/WAV/WV/APE/DSF/DFF) |
| `bin/dff2flac.sh` | Convert a folder of DFF files into tagged FLACs using a sidecar .cue file |
| `bin/qty_compare.sh` | Compare two albums side-by-side using spectre quality metrics |
| `bin/qty_test.sh` | Per-file audio analysis: dynamic range, true peak, bit depth, and frequency cutoff grading |
| `bin/spectre.sh` | Spectrogram + header + recode recommendation + batch summary for an album folder |
| `bin/tag_writer.sh` | Write metadata tags to audio files across all supported formats (FLAC, MP3, M4A, OGG, Opus, WV, WAV, DSF, WMA) |

## Project layout
- `bin/`: executable scripts
- `lib/sh/`: shared shell libraries
- `lib/py/`: shared Python helpers
- `test/`: Python and shell tests
- `install.sh`: `.env` generator only
- `Makefile`: single project make entrypoint

## Quick start
1. Install scripts into your `~/bin` (or custom prefix):
```bash
make install
# or:
make install PREFIX="$HOME/bin"
```
2. Generate `.env`:
```bash
./install.sh
```
3. Run tests:
```bash
make test
```
4. Launch browser:
```bash
audlint.sh
```

## Dependencies
Required runtime tools:
- Bash 5 (`/opt/homebrew/bin/bash`)
- `sqlite3`
- `ffmpeg`, `ffprobe`
- `rsync` and `ssh` (for transfer/sync workflows)
- Python with `numpy`
- Python with `rich` (or set `RICH_TABLE_CMD` to a compatible renderer)

Optional development tools:
- `shellcheck` (used by `make lint`)
- `shfmt` (used by `make fmt-check`)

## Notes
- `LIBRARY_DB` defaults to `$SRC/library.sqlite`.
- The browser can run in read-only DB mode, but mutation actions require write access.

## License
This project is released under `Audlint Non-Commercial License v1.1`.
Commercial use is currently not permitted. See `LICENSE`.

## Credits
Migration assisted by [OpenAI Codex](https://openai.com/blog/openai-codex).
Ongoing development assisted by [Claude Code](https://claude.ai/code) (Anthropic).

## Feedback
Bug reports and feature requests are welcome via GitHub Issues.
