# Documentation

## Table of Contents

- [Project Layout](#project-layout)
- [Additional Tools](./tools.md)
- [Spectrogram Generation (`spectre.sh`)](./spectre.md)

`docs/tools.md` also covers the album-art maintenance workflow (`cover_album.sh`, `cover_seek.sh`) and the encoder post-process hooks that now normalize or fetch art for finished albums.

## Project Layout

- `bin/`: executable scripts
- `lib/sh/`: shared shell libraries
- `lib/py/`: shared Python helpers
- `test/`: Python and shell tests
- `install.sh`: `.env` generator only
- `Makefile`: single project make entrypoint
