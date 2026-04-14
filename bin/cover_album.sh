#!/usr/bin/env bash
# cover_album.sh - Standardize album artwork to one player-safe JPEG.

set -Eeuo pipefail

BOOTSTRAP_SOURCE="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
  BOOTSTRAP_SOURCE="$(realpath "$BOOTSTRAP_SOURCE" 2>/dev/null || printf '%s' "$BOOTSTRAP_SOURCE")"
elif command -v readlink >/dev/null 2>&1; then
  LINK_TARGET="$(readlink "$BOOTSTRAP_SOURCE" 2>/dev/null || true)"
  if [[ -n "$LINK_TARGET" ]]; then
    if [[ "$LINK_TARGET" = /* ]]; then
      BOOTSTRAP_SOURCE="$LINK_TARGET"
    else
      BOOTSTRAP_SOURCE="$(cd "$(dirname "$BOOTSTRAP_SOURCE")" && pwd)/$LINK_TARGET"
    fi
  fi
fi
BOOTSTRAP_DIR="$(cd "$(dirname "$BOOTSTRAP_SOURCE")" && pwd)"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/bootstrap.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/env.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/deps.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/ui.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/audio.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/secure_backup.sh"
# shellcheck source=/dev/null
source "$BOOTSTRAP_DIR/../lib/sh/artwork.sh"

bootstrap_resolve_paths "${BASH_SOURCE[0]}"
env_load_files "$REPO_ROOT/.env" "$SCRIPT_DIR/.env" || true
ui_init_colors

TARGET_DIR="."
AUTO_YES=false
DRY_RUN=false
SUMMARY_ONLY=false
CLEANUP_EXTRA_SIDECARS=false

show_help() {
  cat <<EOF
Quick use:
  $(basename "$0")
  $(basename "$0") -y
  $(basename "$0") --dry-run /abs/path/to/album

Usage: $(basename "$0") [TARGET_DIR] [--dry-run] [--yes] [--summary-only] [--cleanup-extra-sidecars]

Options:
  --dry-run       Show the normalized album-art result without writing files.
  -y, --yes       Skip confirmation prompt.
  --summary-only  Print only the final 1-line art status.
  --cleanup-extra-sidecars
                  Remove extra cover/folder/front sidecars after writing cover.jpg.
  -h, --help      Show this help.

Behavior:
  - Picks one canonical cover source from cover/folder/front sidecars or embedded art.
  - Normalizes it to cover.jpg as a JPEG no larger than AUDL_ARTWORK_MAX_DIM.
  - Preserves extra cover-like sidecars unless --cleanup-extra-sidecars is passed.
  - Rewrites tracks so each file keeps one consistent embedded cover.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
  --dry-run)
    DRY_RUN=true
    ;;
  -y | --yes)
    AUTO_YES=true
    ;;
  --summary-only)
    SUMMARY_ONLY=true
    AUTO_YES=true
    ;;
  --cleanup-extra-sidecars)
    CLEANUP_EXTRA_SIDECARS=true
    ;;
  -h | --help)
    show_help
    exit 0
    ;;
  -*)
    printf 'Unknown argument: %s\n' "${1:-}" >&2
    show_help >&2
    exit 2
    ;;
  *)
    TARGET_DIR="${1:-.}"
    ;;
  esac
  shift || true
done

TARGET_DIR="$(path_resolve "$TARGET_DIR" 2>/dev/null || printf '%s' "$TARGET_DIR")"
if [[ ! -d "$TARGET_DIR" ]]; then
  printf 'Not a directory: %s\n' "$TARGET_DIR" >&2
  exit 2
fi

if [[ "$SUMMARY_ONLY" != true ]]; then
  printf '%s\n' "$(ui_wrap "$BLUE" "Album Art Standardization")"
  printf 'Target: %s\n' "$TARGET_DIR"
  printf 'Policy: %s, JPEG, max=%spx, cleanup_extra_sidecars=%s\n' \
    "$(artwork_sidecar_name)" "$(artwork_max_dim)" "$CLEANUP_EXTRA_SIDECARS"
  printf -- '-----------\n'
fi

if [[ "$DRY_RUN" != true && "$AUTO_YES" != true ]]; then
  if [[ ! -t 0 ]]; then
    printf 'Error: confirmation required but stdin is not interactive. Re-run with --yes.\n' >&2
    exit 1
  fi
  printf 'Standardize album art? [y/N] > '
  confirm_choice=""
  if ! tty_read_line confirm_choice; then
    printf 'Cancelled.\n' >&2
    exit 1
  fi
  if [[ "$confirm_choice" != "y" ]]; then
    printf 'Cancelled.\n'
    exit 1
  fi
fi

if [[ "$DRY_RUN" != true ]]; then
  if ! secure_backup_album_tracks_once "$TARGET_DIR" "cover_album artwork normalize"; then
    printf 'Error: %s\n' "${SECURE_BACKUP_LAST_ERROR:-secure backup failed}" >&2
    exit 1
  fi
fi

mode="apply"
if [[ "$DRY_RUN" == true ]]; then
  mode="dry-run"
fi

cleanup_extra_sidecars_flag=0
if [[ "$CLEANUP_EXTRA_SIDECARS" == true ]]; then
  cleanup_extra_sidecars_flag=1
fi

if artwork_standardize_album "$TARGET_DIR" "$mode" "$cleanup_extra_sidecars_flag"; then
  printf '%s\n' "$(artwork_status_summary_colored)"
  exit 0
fi

printf '%s\n' "$(artwork_status_summary_colored)"
exit 1
