#!/usr/bin/env bash
set -euo pipefail

# install.sh
# ---------
# Purpose:
# - Generate a project-root .env file for audlint-cli runtime scripts.
#
# Scope:
# - Prompt-driven configuration only.
# - This script does NOT install binaries, dependencies, or symlinks.
#
# Safety:
# - Existing .env is protected unless --force is provided.
# - --dry-run prints generated .env to stdout and never writes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

FORCE=0
DRY_RUN=0

detect_os_family() {
	local uname_s
	uname_s="$(uname -s 2>/dev/null || printf 'unknown')"
	case "${uname_s,,}" in
	darwin) printf 'macos' ;;
	linux) printf 'linux' ;;
	*) printf 'unknown' ;;
	esac
}

detect_linux_distro_id() {
	local distro="unknown"
	if [[ -r /etc/os-release ]]; then
		distro="$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print tolower($2)}' /etc/os-release | head -n1)"
	fi
	[[ -n "$distro" ]] || distro="unknown"
	printf '%s' "$distro"
}

print_dependency_guidance() {
	local -a missing_bins=("$@")
	((${#missing_bins[@]} > 0)) || return 0

	local os_family distro_id
	os_family="$(detect_os_family)"
	printf '\nDependency install guidance:\n'
	if [[ "$os_family" == "linux" ]]; then
		distro_id="$(detect_linux_distro_id)"
		case "$distro_id" in
		ubuntu | debian)
			printf '  Debian/Ubuntu:\n'
			printf '    sudo apt update\n'
			printf '    sudo apt install -y bash ffmpeg sox flac sqlite3 rsync openssh-client cron python3 python3-pip\n'
			printf '    python3 -m pip install --user dr14meter\n'
			printf '    sudo systemctl enable --now cron\n'
			;;
		fedora)
			printf '  Fedora:\n'
			printf '    sudo dnf install -y bash ffmpeg sox flac sqlite rsync openssh-clients cronie python3 python3-pip\n'
			printf '    python3 -m pip install --user dr14meter\n'
			printf '    sudo systemctl enable --now crond\n'
			;;
		*)
			printf '  Linux (%s): install missing tools with your package manager.\n' "$distro_id"
			printf '  Required: bash ffmpeg sox flac sqlite3 rsync ssh crontab python3 + dr14meter\n'
			;;
		esac
	elif [[ "$os_family" == "macos" ]]; then
		printf '  macOS (Homebrew):\n'
		printf '    brew install bash ffmpeg sox flac sqlite rsync openssh\n'
		printf '    python3 -m pip install --user dr14meter\n'
	else
		printf '  Unknown platform: install required tools manually.\n'
	fi
	printf '  Missing detected in this run: %s\n' "${missing_bins[*]}"
}

print_spectre_optional_guidance() {
	local py_bin="$1"
	local os_family distro_id
	os_family="$(detect_os_family)"
	printf '\nOptional install guidance (audlint-spectre.sh only):\n'
	if [[ "$os_family" == "linux" ]]; then
		distro_id="$(detect_linux_distro_id)"
		case "$distro_id" in
		ubuntu | debian)
			printf '  Debian/Ubuntu:\n'
			printf '    sudo apt update\n'
			printf '    sudo apt install -y tesseract-ocr\n'
			;;
		fedora)
			printf '  Fedora:\n'
			printf '    sudo dnf install -y tesseract\n'
			;;
		*)
			printf '  Linux (%s): install tesseract with your package manager.\n' "$distro_id"
			;;
		esac
	elif [[ "$os_family" == "macos" ]]; then
		printf '  macOS (Homebrew):\n'
		printf '    brew install tesseract\n'
	else
		printf '  Unknown platform: install tesseract manually.\n'
	fi
	printf '  Python packages:\n'
	printf '    %s -m pip install opencv-python numpy pytesseract\n' "$py_bin"
}

show_help() {
	cat <<'EOF'
Usage:
  install.sh [--force] [--dry-run]

Description:
  Prompt for configuration values and generate .env in the project root.

Options:
  --force     Overwrite existing .env.
  --dry-run   Print generated .env content to stdout; do not write.
EOF
}

expand_value() {
	local raw="$1"
	# Safely expand $HOME and ~ only; no eval on arbitrary user input.
	raw="${raw/#\~/$HOME}"
	raw="${raw//\$HOME/$HOME}"
	printf '%s' "$raw"
}

prompt_required() {
	local prompt="$1"
	local out_var="$2"
	local input=""
	while true; do
		printf '%s: ' "$prompt"
		IFS= read -r input || exit 1
		if [[ -z "$input" ]]; then
			echo "Value is required." >&2
			continue
		fi
		printf -v "$out_var" '%s' "$input"
		return 0
	done
}

prompt_optional() {
	local prompt="$1"
	local out_var="$2"
	local input=""
	printf '%s (optional): ' "$prompt"
	IFS= read -r input || exit 1
	printf -v "$out_var" '%s' "$input"
}

validate_existing_dir() {
	local raw="$1"
	local label="$2"
	local expanded
	expanded="$(expand_value "$raw")"
	if [[ ! -d "$expanded" ]]; then
		echo "Invalid $label: directory does not exist: $expanded" >&2
		return 1
	fi
	if [[ ! -r "$expanded" ]]; then
		echo "Invalid $label: directory is not readable: $expanded" >&2
		return 1
	fi
	return 0
}

validate_existing_writable_dir() {
	local raw="$1"
	local label="$2"
	local expanded
	expanded="$(expand_value "$raw")"
	if [[ ! -d "$expanded" ]]; then
		echo "Invalid $label: directory does not exist: $expanded" >&2
		return 1
	fi
	if [[ ! -r "$expanded" ]]; then
		echo "Invalid $label: directory is not readable: $expanded" >&2
		return 1
	fi
	if [[ ! -w "$expanded" ]]; then
		echo "Invalid $label: directory is not writable: $expanded" >&2
		return 1
	fi
	return 0
}

validate_db_path() {
	local raw="$1"
	local expanded parent
	expanded="$(expand_value "$raw")"
	parent="$(dirname "$expanded")"
	if [[ ! -d "$parent" ]]; then
		echo "Invalid LIBRARY_DB: parent directory does not exist: $parent" >&2
		return 1
	fi
	if [[ -e "$expanded" && ! -r "$expanded" ]]; then
		echo "Invalid LIBRARY_DB: file exists but is not readable: $expanded" >&2
		return 1
	fi
	if [[ ! -e "$expanded" && ! -w "$parent" ]]; then
		echo "Invalid LIBRARY_DB: file does not exist and parent is not writable: $parent" >&2
		return 1
	fi
	return 0
}

validate_bin() {
	local raw="$1"
	local label="$2"
	local expanded
	expanded="$(expand_value "$raw")"
	if [[ "$expanded" == */* ]]; then
		if [[ ! -x "$expanded" ]]; then
			echo "Invalid $label: executable not found: $expanded" >&2
			return 1
		fi
	else
		if ! command -v "$expanded" >/dev/null 2>&1; then
			echo "Invalid $label: command not found on PATH: $expanded" >&2
			return 1
		fi
	fi
	return 0
}

validate_file_readable() {
	local raw="$1"
	local label="$2"
	local expanded
	expanded="$(expand_value "$raw")"
	if [[ ! -f "$expanded" ]]; then
		echo "Invalid $label: file not found: $expanded" >&2
		return 1
	fi
	if [[ ! -r "$expanded" ]]; then
		echo "Invalid $label: file is not readable: $expanded" >&2
		return 1
	fi
	return 0
}

validate_optional_file_readable() {
	local raw="$1"
	local label="$2"
	[[ -n "$raw" ]] || return 0
	validate_file_readable "$raw" "$label"
}

validate_optional_media_path() {
	local raw="$1"
	[[ -n "$raw" ]] || return 0
	local expanded
	expanded="$(expand_value "$raw")"
	if [[ ! -d "$expanded" ]]; then
		echo "Invalid MEDIA_PLAYER_PATH: directory does not exist: $expanded" >&2
		return 1
	fi
	return 0
}

validate_int_ge_1() {
	local raw="$1"
	local label="$2"
	if [[ ! "$raw" =~ ^[0-9]+$ ]] || [[ "$raw" == "0" ]]; then
		echo "Invalid $label: expected integer >= 1." >&2
		return 1
	fi
	return 0
}

validate_int_ge_0() {
	local raw="$1"
	local label="$2"
	if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
		echo "Invalid $label: expected integer >= 0." >&2
		return 1
	fi
	return 0
}

validate_secure_mode() {
	local raw="$1"
	local label="$2"
	if [[ "$raw" != "0" && "$raw" != "1" ]]; then
		echo "Invalid $label: expected 0 or 1." >&2
		return 1
	fi
	return 0
}

validate_log_path() {
	local raw="$1"
	local label="${2:-log path}"
	local expanded parent
	expanded="$(expand_value "$raw")"
	parent="$(dirname "$expanded")"
	if [[ ! -d "$parent" ]]; then
		echo "Invalid $label: parent directory does not exist: $parent" >&2
		return 1
	fi
	if [[ ! -w "$parent" ]]; then
		echo "Invalid $label: parent directory is not writable: $parent" >&2
		return 1
	fi
	return 0
}

prompt_until_valid() {
	local prompt="$1"
	local out_var="$2"
	local validator="$3"
	local value=""
	while true; do
		prompt_required "$prompt" value
		if "$validator" "$value"; then
			printf -v "$out_var" '%s' "$value"
			return 0
		fi
	done
}

prompt_until_valid_label() {
	local prompt="$1"
	local out_var="$2"
	local validator="$3"
	local label="$4"
	local value=""
	while true; do
		prompt_required "$prompt" value
		if "$validator" "$value" "$label"; then
			printf -v "$out_var" '%s' "$value"
			return 0
		fi
	done
}

prompt_optional_until_valid() {
	local prompt="$1"
	local out_var="$2"
	local validator="$3"
	local value=""
	while true; do
		prompt_optional "$prompt" value
		if "$validator" "$value"; then
			printf -v "$out_var" '%s' "$value"
			return 0
		fi
	done
}

prompt_optional_until_valid_label() {
	local prompt="$1"
	local out_var="$2"
	local validator="$3"
	local label="$4"
	local value=""
	while true; do
		prompt_optional "$prompt" value
		if "$validator" "$value" "$label"; then
			printf -v "$out_var" '%s' "$value"
			return 0
		fi
	done
}

render_env() {
	cat <<EOF
SRC="$SRC"
LIBRARY_DB="$LIBRARY_DB"
DST_USER_HOST="$DST_USER_HOST"
DST_PATH="$DST_PATH"
SSH_KEY="$SSH_KEY"
PYTHON_BIN="$PYTHON_BIN"
TABLE_PYTHON_BIN="$TABLE_PYTHON_BIN"
MEDIA_PLAYER_PATH="$MEDIA_PLAYER_PATH"
LASTFM_API_KEY="$LASTFM_API_KEY"
<<<<<<< HEAD
QTY_SEEK_MAX_ALBUMS=$QTY_SEEK_MAX_ALBUMS
QTY_SEEK_LOG="$QTY_SEEK_LOG"
=======
SECURE_MODE=$SECURE_MODE
LIB_BACKUP="$LIB_BACKUP"
AUDLINT_CRON_INTERVAL_MIN=$AUDLINT_CRON_INTERVAL_MIN
AUDLINT_TASK_MAX_ALBUMS=$AUDLINT_TASK_MAX_ALBUMS
AUDLINT_TASK_MAX_TIME_SEC=$AUDLINT_TASK_MAX_TIME_SEC
AUDLINT_TASK_LOG="$AUDLINT_TASK_LOG"
>>>>>>> develop
CUE2FLAC_OUTPUT_DIR="$CUE2FLAC_OUTPUT_DIR"
EOF
}

sanity_check() {
	local ok=1
	printf '\n--- Sanity check ---\n'
	printf 'Platform: %s' "$(detect_os_family)"
	if [[ "$(detect_os_family)" == "linux" ]]; then
		printf ' (%s)' "$(detect_linux_distro_id)"
	fi
	printf '\n'

	# Required system binaries
	# sox/soxi: sox_ng recommended (handles ALAC/AAC duration in M4A containers)
	local bin
<<<<<<< HEAD
	for bin in sqlite3 ffmpeg ffprobe sox metaflac rsync ssh; do
=======
	local -a missing_required=()
	for bin in sqlite3 ffmpeg ffprobe sox soxi metaflac dr14meter rsync ssh crontab; do
>>>>>>> develop
		if command -v "$bin" >/dev/null 2>&1; then
			printf 'OK      %s (%s)\n' "$bin" "$(command -v "$bin")"
		else
			printf 'MISSING %s\n' "$bin"
			ok=0
			missing_required+=("$bin")
		fi
	done

	# Python binary from prompt
	local py_expanded
	py_expanded="$(expand_value "$PYTHON_BIN")"
	if command -v "$py_expanded" >/dev/null 2>&1 || [[ -x "$py_expanded" ]]; then
		printf 'OK      PYTHON_BIN (%s)\n' "$py_expanded"
	else
		printf 'MISSING PYTHON_BIN: %s\n' "$py_expanded"
		ok=0
	fi

	# Optional tag-writer tools
	printf '\n'
	for bin in vorbiscomment AtomicParsley eyeD3 wvtag; do
		if command -v "$bin" >/dev/null 2>&1; then
			printf 'OK      %s (optional)\n' "$bin"
		else
			printf 'absent  %s (optional — some tag actions limited)\n' "$bin"
		fi
	done

	# Optional audlint-spectre dependencies
	printf '\n'
	local -a missing_spectre=()
	if command -v tesseract >/dev/null 2>&1; then
		printf 'OK      tesseract (optional; audlint-spectre.sh)\n'
	else
		printf 'absent  tesseract (optional; audlint-spectre.sh unavailable)\n'
		missing_spectre+=("tesseract")
	fi
	local mod
	if command -v "$py_expanded" >/dev/null 2>&1 || [[ -x "$py_expanded" ]]; then
		for mod in cv2 numpy pytesseract; do
			if "$py_expanded" -c "import $mod" >/dev/null 2>&1; then
				printf 'OK      python:%s (optional; audlint-spectre.sh)\n' "$mod"
			else
				printf 'absent  python:%s (optional; audlint-spectre.sh unavailable)\n' "$mod"
				missing_spectre+=("python:$mod")
			fi
		done
	else
		printf 'absent  python modules check skipped (PYTHON_BIN unavailable)\n'
		missing_spectre+=("python_bin_unavailable")
	fi

	if ((${#missing_spectre[@]} > 0)); then
		printf 'NOTE    audlint-spectre.sh optional deps missing: %s\n' "${missing_spectre[*]}"
		print_spectre_optional_guidance "$py_expanded"
	fi

	# SSH key if provided
	if [[ -n "$SSH_KEY" ]]; then
		local sk_expanded
		sk_expanded="$(expand_value "$SSH_KEY")"
		if [[ -f "$sk_expanded" && -r "$sk_expanded" ]]; then
			printf '\nOK      SSH_KEY (%s)\n' "$sk_expanded"
		else
			printf '\nWARN    SSH_KEY not found: %s\n' "$sk_expanded"
		fi
	fi

	printf '\n'
	if [[ "$ok" -eq 1 ]]; then
		printf 'Verdict: READY — all required dependencies found.\n'
	else
		printf 'Verdict: NOT READY — missing required dependencies above.\n'
		printf '         .env will still be written; fix missing tools before running.\n'
		print_dependency_guidance "${missing_required[@]}"
	fi
	printf '--------------------\n'
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--force)
		FORCE=1
		;;
	--dry-run)
		DRY_RUN=1
		;;
	-h | --help)
		show_help
		exit 0
		;;
	*)
		echo "Error: unknown option: $1" >&2
		show_help
		exit 2
		;;
	esac
	shift
done

if [[ -f "$ENV_FILE" && "$FORCE" != "1" && "$DRY_RUN" != "1" ]]; then
	echo "Error: $ENV_FILE already exists. Use --force to overwrite." >&2
	exit 1
fi

echo "Enter .env values."
echo "Use literals or shell-style paths (for example \$HOME/...)."
echo

prompt_until_valid_label "SRC (library root directory)" SRC validate_existing_dir "SRC"
export SRC
prompt_until_valid "LIBRARY_DB path" LIBRARY_DB validate_db_path

prompt_optional "DST_USER_HOST (for sync action, e.g. user@host)" DST_USER_HOST
prompt_optional "DST_PATH (remote destination path)" DST_PATH
prompt_optional_until_valid_label "SSH_KEY path" SSH_KEY validate_optional_file_readable "SSH_KEY"

prompt_until_valid_label "PYTHON_BIN (command or absolute path)" PYTHON_BIN validate_bin "PYTHON_BIN"
TABLE_PYTHON_BIN="$PYTHON_BIN"

prompt_optional_until_valid "MEDIA_PLAYER_PATH (local mount path)" MEDIA_PLAYER_PATH validate_optional_media_path
prompt_optional "LASTFM_API_KEY" LASTFM_API_KEY

<<<<<<< HEAD
prompt_until_valid_label "QTY_SEEK_MAX_ALBUMS" QTY_SEEK_MAX_ALBUMS validate_int_ge_1 "QTY_SEEK_MAX_ALBUMS"
prompt_until_valid "QTY_SEEK_LOG path" QTY_SEEK_LOG validate_log_path
=======
prompt_until_valid_label "SECURE_MODE (0|1)" SECURE_MODE validate_secure_mode "SECURE_MODE"
prompt_until_valid_label "LIB_BACKUP (backup root directory)" LIB_BACKUP validate_existing_writable_dir "LIB_BACKUP"

prompt_until_valid_label "AUDLINT_CRON_INTERVAL_MIN" AUDLINT_CRON_INTERVAL_MIN validate_int_ge_1 "AUDLINT_CRON_INTERVAL_MIN"
prompt_until_valid_label "AUDLINT_TASK_MAX_ALBUMS" AUDLINT_TASK_MAX_ALBUMS validate_int_ge_1 "AUDLINT_TASK_MAX_ALBUMS"
prompt_until_valid_label "AUDLINT_TASK_MAX_TIME_SEC" AUDLINT_TASK_MAX_TIME_SEC validate_int_ge_0 "AUDLINT_TASK_MAX_TIME_SEC"
prompt_until_valid_label "AUDLINT_TASK_LOG path" AUDLINT_TASK_LOG validate_log_path "AUDLINT_TASK_LOG"
>>>>>>> develop
prompt_until_valid_label "CUE2FLAC_OUTPUT_DIR (output root for cue2flac splits)" CUE2FLAC_OUTPUT_DIR validate_existing_dir "CUE2FLAC_OUTPUT_DIR"

sanity_check

if [[ "$DRY_RUN" == "1" ]]; then
	render_env
	exit 0
fi

render_env >"$ENV_FILE"
echo "Generated: $ENV_FILE"
