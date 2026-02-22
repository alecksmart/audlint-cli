# audlint-cli

Source-available CLI toolkit centered on interactive music library quality browsing.

## Scope
- Primary tool: `bin/audlint.sh`
- Browser-integrated actions are included:
  - maintenance scan: `bin/qty_seek.sh`
  - recode helper: `bin/any2flac.sh`
  - lyrics workflow: `bin/lyrics_seek.sh`, `bin/lyrics_album.sh`
  - transfer sync: `bin/sync_music.sh`

## Project layout
- `bin/`: executable scripts
- `lib/sh/`: shared shell libraries
- `lib/py/`: shared Python helpers
- `test/`: Python and shell tests
- `install.sh`: `.env` generator only
- `Makefile`: single project make entrypoint

## Quick start
1. Generate `.env`:
```bash
./install.sh
```
2. Run tests:
```bash
make test
```
3. Launch browser:
```bash
bin/audlint.sh
```

## Runtime requirements
- Bash 5 (`/opt/homebrew/bin/bash`)
- `sqlite3`
- `ffmpeg`, `ffprobe`
- Python with `numpy`
- Python with `rich` (or set `RICH_TABLE_CMD` to a compatible renderer)

## Notes
- `LIBRARY_DB` defaults to `$SRC/library.sqlite`.
- The browser can run in read-only DB mode, but mutation actions require write access.

## License
This project is released under `Audlint Non-Commercial License v1.1`.
Commercial use is currently not permitted. See `LICENSE`.

## Feedback
Bug reports and feature requests are welcome via GitHub Issues.
