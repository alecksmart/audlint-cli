# Additional Tools

| Script | Description |
| --- | --- |
| `bin/any2flac.sh` | Recode a tagged album or folder to FLAC at a chosen profile, optionally bake gain, and finish by applying the shared album-art normalization/status pipeline |
| `bin/audlint-analyze.sh` | FFT-based spectral cutoff analysis — determines ideal recode target (SR/bits) for an album by inspecting source files directly (sox or ffmpeg fallback) |
| `bin/audlint-doctor.sh` | Runtime diagnostics for audlint-cli: validates env, required binaries, paths, and cron integration health |
| `bin/audlint-spectre.sh` | Read exported spectrogram images: detects high-frequency cutoff transition and OCRs top-left stats labels (Peak Amplitude / Dynamic Range) |
| `bin/audlint-value.sh` | DR14 dynamic range + recode target analysis for an album; outputs JSON with grade (S/A/B/C/F), DR total, per-track DR, and spectral recode target |
| `bin/boost_album.sh` | Bake headroom gain into a FLAC or lossy album in-place, then run the shared album-art cleanup/embed pass and print a final `Art: ...` status line |
| `bin/boost_seek.sh` | Walk library and invoke `boost_album.sh` on qualifying albums |
| `bin/clear_tags.sh` | Clear lyrics tags and cached lyrics DB entries for files in the current folder |
| `bin/cover_album.sh` | Standardize one album to a single player-safe `cover.jpg`; manual runs preserve extra cover-like sidecars unless `--cleanup-extra-sidecars` is passed, and `--fetch-missing-art` can pull missing art from MusicBrainz / Cover Art Archive |
| `bin/cover_seek.sh` | Walk albums and invoke `cover_album.sh` with internal sidecar cleanup enabled; guided/Maintenance runs can auto-fetch missing art and long batches finish with a failed-albums summary |
| `bin/cue2flac.sh` | Split a high-res audio file into per-track FLACs using a .cue sheet (FLAC/WAV/WV/APE/DSF/DFF); `--check-upscale` uses album-wide `audlint-analyze` target selection across all referenced sources, and finished albums get the shared artwork/status pass |
| `bin/dff2flac.sh` | Convert a folder of DFF files into tagged FLACs using a sidecar .cue file, then apply the shared artwork normalization/status pass to the finished album |
| `bin/qty_compare.sh` | Compare two albums side-by-side: per-track DR14 grades and overall mastering grade |
| `bin/spectre.sh` | Generate spectrogram PNG files from audio sources (file mode, album mode, and `--all` per-track mode) |
| `bin/tag_writer.sh` | Write metadata tags to audio files across all supported formats (FLAC, MP3, M4A, OGG, Opus, WV, WAV, DSF, WMA) |
