# spectre.sh

Generate spectrogram images from audio files.

## Purpose

`bin/spectre.sh` is the audio-to-image helper. It only generates spectrogram PNGs.

Use `bin/audlint-spectre.sh` when you want to analyze an existing spectrogram image.
For exact recode decisions, use `bin/audlint-analyze.sh` or `bin/audlint-value.sh`; image analysis can recover the sample-rate family, but exact bit depth is not directly observable from a spectrogram export.

## Usage

```bash
bin/spectre.sh "/path/to/track.flac"
bin/spectre.sh "/path/to/album_dir"
bin/spectre.sh --all "/path/to/album_dir"
```

## Modes

- File mode: `<track>.png` next to the source file.
- Directory mode: `album_spectre.png` in the target directory.
- `--all` directory mode: `album_spectre.png` plus per-track PNG files.

## Dependency check

```bash
bin/spectre.sh --check-deps
```

Required binaries:

- `ffmpeg`
- `ffprobe`

## Environment knobs

- `SPECTRO_WIDTH` (default `1920`)
- `SPECTRO_HEIGHT` (default `1080`)
- `SPECTRO_LEGEND` (default `1`)
