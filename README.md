# audlint-cli

Source-available CLI toolkit centered on interactive music library quality browsing.

## Documentation

- Docs index: [docs/README.md](./docs/README.md)
- Additional tools: [docs/tools.md](./docs/tools.md)
- Spectrogram generation guide: [docs/spectre.md](./docs/spectre.md)

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

1. Install scripts into `~/bin` (or a custom prefix):

```bash
make install
make install PREFIX="$HOME/bin"
```

Installed convenience aliases:
- `auz` -> `audlint-analyze.sh`
- `auv` -> `audlint-value.sh`
- `auq` -> `qty_compare.sh`
- `aus` -> `audlint-spectre.sh`

Installed scripts also include `spectre.sh` (audio -> spectrogram PNG generation).

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

## Profile formats

- Accepted input forms include: `44100/16`, `44.1/16`, `44.1-16`, `44k/16`, `44khz/16`
- Canonical project format: `SR_HZ/BITS` (example: `44100/16`)
- Use `--help-profiles` on profile-aware tools for full details

## Dependencies

Required runtime tools:

- Bash 5 (`bash`, recommended via package manager if system bash is older)
- `sqlite3`
- `ffmpeg`, `ffprobe`
- `sox`, `soxi` — sox_ng recommended; handles ALAC/AAC in M4A containers
- `metaflac` — tag copy after FLAC encode
- `dr14meter` — DR14 dynamic range measurement (installs to `~/.local/bin` via `pip install dr14meter`)
- `rsync`, `ssh` — transfer/sync workflows
- `crontab` (`cron` on Debian/Ubuntu, `cronie` on Fedora) for scheduled maintenance
- Python 3 with `numpy` — FFT spectral analysis
- Python 3 with `opencv-python` (`cv2`) and `pytesseract` + `tesseract` binary — spectrogram image OCR utility (`audlint-spectre.sh`)
- Python 3 with `rich` — table rendering (or set `RICH_TABLE_CMD` to a compatible renderer)

`spectre.sh` (audio spectrogram generation) requires:
- `ffmpeg`, `ffprobe`

Optional development tools:

- `shellcheck` (used by `make lint`)
- `shfmt` (used by `make fmt-check`)

## Credits

Authorship:
- Human author/operator
- OpenAI Codex
- Claude Code (Anthropic)

This project was fully written under direct human command, not AI-assisted authorship.

Used software and open-source projects:
- FFmpeg / ffprobe — [FFmpeg/FFmpeg](https://github.com/FFmpeg/FFmpeg)
- SoX / soxi — [chirlu/sox](https://github.com/chirlu/sox)
- SQLite — [sqlite/sqlite](https://github.com/sqlite/sqlite)
- FLAC / metaflac — [xiph/flac](https://github.com/xiph/flac)
- dr14meter — [pe7ro/dr14meter](https://github.com/pe7ro/dr14meter)
- rsync — [RsyncProject/rsync](https://github.com/RsyncProject/rsync)
- OpenSSH — [openssh/openssh-portable](https://github.com/openssh/openssh-portable)
- Python — [python/cpython](https://github.com/python/cpython)
- NumPy — [numpy/numpy](https://github.com/numpy/numpy)
- Rich — [Textualize/rich](https://github.com/Textualize/rich)
- ShellCheck — [koalaman/shellcheck](https://github.com/koalaman/shellcheck)
- shfmt — [mvdan/sh](https://github.com/mvdan/sh)

## License

This project is released under `Audlint Non-Commercial License v1.1`.
Commercial use is currently not permitted. See `LICENSE`.
