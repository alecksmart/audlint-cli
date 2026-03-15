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
PRINT_INSTALL_GUIDE=0
OS_FAMILY_OVERRIDE=""
DISTRO_ID_OVERRIDE=""

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

resolve_os_family() {
	if [[ -n "$OS_FAMILY_OVERRIDE" ]]; then
		printf '%s' "$OS_FAMILY_OVERRIDE"
		return 0
	fi
	detect_os_family
}

resolve_linux_distro_id() {
	if [[ -n "$DISTRO_ID_OVERRIDE" ]]; then
		printf '%s' "$DISTRO_ID_OVERRIDE"
		return 0
	fi
	detect_linux_distro_id
}

set_platform_override() {
	local raw="${1:-}"
	case "${raw,,}" in
	macos | darwin)
		OS_FAMILY_OVERRIDE="macos"
		DISTRO_ID_OVERRIDE=""
		;;
	debian | ubuntu | fedora)
		OS_FAMILY_OVERRIDE="linux"
		DISTRO_ID_OVERRIDE="${raw,,}"
		;;
	linux)
		OS_FAMILY_OVERRIDE="linux"
		DISTRO_ID_OVERRIDE="unknown"
		;;
	*)
		echo "Error: unsupported platform override: $raw" >&2
		return 1
		;;
	esac
}

print_install_guide() {
	local py_bin="${1:-python3}"
	shift || true
	local -a missing_bins=("$@")
	local os_family distro_id
	os_family="$(resolve_os_family)"
	printf '\nDependency install guidance:\n'
	if [[ "$os_family" == "linux" ]]; then
		distro_id="$(resolve_linux_distro_id)"
		case "$distro_id" in
		ubuntu | debian)
			printf '  Debian/Ubuntu:\n'
			printf '    sudo apt update\n'
			printf '    sudo apt install -y bash sqlite3 ffmpeg sox flac rsync cron tesseract-ocr python3 python3-pip zip\n'
			printf '    %s -m pip install --user numpy opencv-python pytesseract rich dr14meter\n' "$py_bin"
			printf '    sudo systemctl enable --now cron\n'
			;;
		fedora)
			printf '  Fedora:\n'
			printf '    sudo dnf install -y bash sqlite ffmpeg sox flac rsync cronie tesseract python3 python3-pip zip\n'
			printf '    %s -m pip install --user numpy opencv-python pytesseract rich dr14meter\n' "$py_bin"
			printf '    sudo systemctl enable --now crond\n'
			;;
		*)
			printf '  Linux (%s): install the equivalent of:\n' "$distro_id"
			printf '    system packages: bash sqlite3 ffmpeg sox flac rsync crontab tesseract python3 python3-pip zip\n'
			printf '    python packages: numpy opencv-python pytesseract rich dr14meter\n'
			;;
		esac
	elif [[ "$os_family" == "macos" ]]; then
		printf '  macOS (Homebrew):\n'
		printf '    brew install bash sqlite ffmpeg sox flac rsync tesseract python\n'
		printf '    %s -m pip install --user numpy opencv-python pytesseract rich dr14meter\n' "$py_bin"
	else
		printf '  Unknown platform: install required tools manually.\n'
		printf '    system packages: bash sqlite3 ffmpeg sox flac rsync crontab tesseract python3 python3-pip zip\n'
		printf '    python packages: numpy opencv-python pytesseract rich dr14meter\n'
	fi
	if ((${#missing_bins[@]} > 0)); then
		printf '  Missing detected in this run: %s\n' "${missing_bins[*]}"
	fi
}

default_audl_python_bin() {
	if [[ "$(resolve_os_family)" == "linux" ]]; then
		printf '/usr/bin/python3'
	else
		printf 'python3'
	fi
}

show_help() {
	cat <<'EOF'
Usage:
  install.sh [--force] [--dry-run]
  install.sh --print-install-guide [--platform <macos|linux|debian|ubuntu|fedora>]

Description:
  Prompt for configuration values and generate .env in the project root.

Options:
  --force                Overwrite existing .env.
  --dry-run              Print generated .env content to stdout; do not write.
  --print-install-guide  Print dependency install commands for the selected platform and exit.
  --platform             Override platform detection for --print-install-guide.
EOF
}

expand_value() {
	local raw="$1"
	local out=""
	local ch=""
	local next=""
	local rest=""
	local var_name=""
	local i=0
	local len=0

	# Support shell-style paths in prompts without eval/command substitution.
	raw="${raw/#\~/$HOME}"
	len=${#raw}
	while ((i < len)); do
		ch="${raw:i:1}"
		if [[ "$ch" == '$' ]]; then
			next="${raw:i+1:1}"
			if [[ "$next" == '{' ]]; then
				rest="${raw:i+2}"
				if [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*)\} ]]; then
					var_name="${BASH_REMATCH[1]}"
					if [[ -v "$var_name" ]]; then
						out+="${!var_name}"
					else
						out+="\${$var_name}"
					fi
					i=$((i + ${#var_name} + 3))
					continue
				fi
			elif [[ "$next" =~ [A-Za-z_] ]]; then
				rest="${raw:i+1}"
				if [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then
					var_name="${BASH_REMATCH[1]}"
					if [[ -v "$var_name" ]]; then
						out+="${!var_name}"
					else
						out+="\$${var_name}"
					fi
					i=$((i + ${#var_name} + 1))
					continue
				fi
			fi
		fi
		out+="$ch"
		i=$((i + 1))
	done
	printf '%s' "$out"
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

prompt_with_default() {
	local prompt="$1"
	local out_var="$2"
	local default_value="$3"
	local input=""
	printf '%s [%s]: ' "$prompt" "$default_value"
	IFS= read -r input || exit 1
	if [[ -z "$input" ]]; then
		input="$default_value"
	fi
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
		echo "Invalid AUDL_DB_PATH: parent directory does not exist: $parent" >&2
		return 1
	fi
	if [[ -e "$expanded" && ! -r "$expanded" ]]; then
		echo "Invalid AUDL_DB_PATH: file exists but is not readable: $expanded" >&2
		return 1
	fi
	if [[ ! -e "$expanded" && ! -w "$parent" ]]; then
		echo "Invalid AUDL_DB_PATH: file does not exist and parent is not writable: $parent" >&2
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
		echo "Invalid AUDL_MEDIA_PLAYER_PATH: directory does not exist: $expanded" >&2
		return 1
	fi
	return 0
}

validate_optional_writable_dir() {
	local raw="$1"
	local label="${2:-directory}"
	[[ -n "$raw" ]] || return 0
	local expanded
	expanded="$(expand_value "$raw")"
	if [[ ! -d "$expanded" ]]; then
		echo "Invalid $label: directory does not exist: $expanded" >&2
		return 1
	fi
	if [[ ! -w "$expanded" ]]; then
		echo "Invalid $label: directory is not writable: $expanded" >&2
		return 1
	fi
	return 0
}

validate_dir_or_creatable_parent() {
	local raw="$1"
	local label="${2:-directory}"
	local expanded parent
	expanded="$(expand_value "$raw")"
	if [[ -e "$expanded" && ! -d "$expanded" ]]; then
		echo "Invalid $label: path exists but is not a directory: $expanded" >&2
		return 1
	fi
	if [[ -d "$expanded" ]]; then
		return 0
	fi
	parent="$(dirname "$expanded")"
	if [[ ! -d "$parent" ]]; then
		echo "Invalid $label: parent directory does not exist: $parent" >&2
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

prompt_with_default_until_valid_label() {
	local prompt="$1"
	local out_var="$2"
	local default_value="$3"
	local validator="$4"
	local label="$5"
	local value=""
	while true; do
		prompt_with_default "$prompt" value "$default_value"
		if "$validator" "$value" "$label"; then
			printf -v "$out_var" '%s' "$value"
			return 0
		fi
	done
}

render_env() {
	cat <<EOF
AUDL_BIN_PATH="$AUDL_BIN_PATH"
AUDL_PATH="$AUDL_PATH"
AUDL_DB_PATH="$AUDL_DB_PATH"
AUDL_CACHE_PATH="$AUDL_CACHE_PATH"
AUDL_SYNC_DEST="$AUDL_SYNC_DEST"
AUDL_PYTHON_BIN="$AUDL_PYTHON_BIN"
AUDL_MEDIA_PLAYER_PATH="$AUDL_MEDIA_PLAYER_PATH"
AUDL_LASTFM_API_KEY="$AUDL_LASTFM_API_KEY"
AUDL_PARANOIA_MODE=$AUDL_PARANOIA_MODE
AUDL_BACKUP_PATH="$AUDL_BACKUP_PATH"
AUDL_CRON_INTERVAL_MIN=$AUDL_CRON_INTERVAL_MIN
AUDL_TASK_MAX_ALBUMS=$AUDL_TASK_MAX_ALBUMS
AUDL_TASK_MAX_TIME_SEC=$AUDL_TASK_MAX_TIME_SEC
AUDL_TASK_LOG_PATH="$AUDL_TASK_LOG_PATH"
AUDL_CUE2FLAC_OUTPUT_DIR="$AUDL_CUE2FLAC_OUTPUT_DIR"
AUDL_HIDE_SUPPORT_GREETER=$AUDL_HIDE_SUPPORT_GREETER
EOF
}

sanity_check() {
	local ok=1
	printf '\n--- Sanity check ---\n'
	printf 'Platform: %s' "$(resolve_os_family)"
	if [[ "$(resolve_os_family)" == "linux" ]]; then
		printf ' (%s)' "$(resolve_linux_distro_id)"
	fi
	printf '\n'

	# Required system binaries
	# sox/soxi: sox_ng recommended (handles ALAC/AAC duration in M4A containers)
	local bin
	local -a missing_required=()
	for bin in sqlite3 ffmpeg ffprobe sox soxi metaflac dr14meter rsync crontab zip; do
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
	py_expanded="$(expand_value "$AUDL_PYTHON_BIN")"
	local bin_path_expanded
	bin_path_expanded="$(expand_value "$AUDL_BIN_PATH")"
	if command -v "$py_expanded" >/dev/null 2>&1 || [[ -x "$py_expanded" ]]; then
		printf 'OK      AUDL_PYTHON_BIN (%s)\n' "$py_expanded"
	else
		printf 'MISSING AUDL_PYTHON_BIN: %s\n' "$py_expanded"
		ok=0
	fi
	if [[ -d "$bin_path_expanded" ]]; then
		printf 'OK      AUDL_BIN_PATH (%s)\n' "$bin_path_expanded"
	else
		printf 'INFO    AUDL_BIN_PATH will be created on install (%s)\n' "$bin_path_expanded"
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
		printf 'absent  python modules check skipped (AUDL_PYTHON_BIN unavailable)\n'
		missing_spectre+=("python_bin_unavailable")
	fi

	if ((${#missing_spectre[@]} > 0)); then
		printf 'NOTE    audlint-spectre.sh optional deps missing: %s\n' "${missing_spectre[*]}"
	fi

	if [[ -n "$AUDL_SYNC_DEST" ]]; then
		local sync_dest_expanded
		sync_dest_expanded="$(expand_value "$AUDL_SYNC_DEST")"
		if [[ -d "$sync_dest_expanded" && -w "$sync_dest_expanded" ]]; then
			printf '\nOK      AUDL_SYNC_DEST (%s)\n' "$sync_dest_expanded"
		else
			printf '\nWARN    AUDL_SYNC_DEST missing or not writable: %s\n' "$sync_dest_expanded"
		fi
	fi

	printf '\n'
	if [[ "$ok" -eq 1 ]]; then
		printf 'Verdict: READY — all required dependencies found.\n'
	else
		printf 'Verdict: NOT READY — missing required dependencies above.\n'
		printf '         .env will still be written; fix missing tools before running.\n'
	fi
	if ((${#missing_required[@]} > 0 || ${#missing_spectre[@]} > 0)); then
		local -a guidance_missing=()
		local item
		for item in "${missing_required[@]}"; do
			guidance_missing+=("$item")
		done
		for item in "${missing_spectre[@]}"; do
			guidance_missing+=("$item")
		done
		print_install_guide "$py_expanded" "${guidance_missing[@]}"
	fi
	printf -- '--------------------\n'
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--force)
		FORCE=1
		;;
	--dry-run)
		DRY_RUN=1
		;;
	--print-install-guide)
		PRINT_INSTALL_GUIDE=1
		;;
	--platform)
		shift
		[[ $# -gt 0 ]] || {
			echo "Error: --platform requires a value." >&2
			exit 2
		}
		set_platform_override "$1" || exit 2
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

if [[ "$PRINT_INSTALL_GUIDE" == "1" ]]; then
	print_install_guide "python3"
	exit 0
fi

if [[ -f "$ENV_FILE" && "$FORCE" != "1" && "$DRY_RUN" != "1" ]]; then
	echo "Error: $ENV_FILE already exists. Use --force to overwrite." >&2
	exit 1
fi

echo "Enter .env values."
echo "Use literals or shell-style paths (for example \$HOME/...)."
echo

DEFAULT_AUDL_BIN_PATH="${AUDL_BIN_PATH:-\$HOME/.local/bin}"
DEFAULT_AUDL_PATH="${AUDL_PATH:-/Volumes/Music/Library}"
DEFAULT_AUDL_SYNC_DEST="${AUDL_SYNC_DEST:-\$HOME/Desktop/Music}"
DEFAULT_AUDL_MEDIA_PLAYER_PATH="${AUDL_MEDIA_PLAYER_PATH:-/Volumes/Music}"
DEFAULT_AUDL_PARANOIA_MODE="${AUDL_PARANOIA_MODE:-0}"
DEFAULT_AUDL_BACKUP_PATH="${AUDL_BACKUP_PATH:-/Volumes/Music/Backup}"
DEFAULT_AUDL_CRON_INTERVAL_MIN="${AUDL_CRON_INTERVAL_MIN:-20}"
DEFAULT_AUDL_TASK_MAX_ALBUMS="${AUDL_TASK_MAX_ALBUMS:-30}"
DEFAULT_AUDL_TASK_MAX_TIME_SEC="${AUDL_TASK_MAX_TIME_SEC:-1080}"
DEFAULT_AUDL_TASK_LOG_PATH="${AUDL_TASK_LOG_PATH:-\$HOME/audlint-task.log}"
DEFAULT_AUDL_CUE2FLAC_OUTPUT_DIR="${AUDL_CUE2FLAC_OUTPUT_DIR:-/Volumes/Music/Encoded}"
DEFAULT_AUDL_HIDE_SUPPORT_GREETER="${AUDL_HIDE_SUPPORT_GREETER:-0}"
DEFAULT_AUDL_PYTHON_BIN="${AUDL_PYTHON_BIN:-$(default_audl_python_bin)}"

prompt_with_default_until_valid_label "AUDL_BIN_PATH (installed audlint bin directory)" AUDL_BIN_PATH "$DEFAULT_AUDL_BIN_PATH" validate_dir_or_creatable_parent "AUDL_BIN_PATH"
prompt_with_default_until_valid_label "AUDL_PATH (library root directory)" AUDL_PATH "$DEFAULT_AUDL_PATH" validate_existing_dir "AUDL_PATH"
export AUDL_PATH
DEFAULT_AUDL_DB_PATH="${AUDL_DB_PATH:-\$AUDL_PATH/library.sqlite}"
prompt_with_default_until_valid_label "AUDL_DB_PATH path" AUDL_DB_PATH "$DEFAULT_AUDL_DB_PATH" validate_db_path "AUDL_DB_PATH"
AUDL_CACHE_PATH="${AUDL_CACHE_PATH:-\$AUDL_PATH/library.cache}"

prompt_with_default_until_valid_label "AUDL_SYNC_DEST (mounted sync destination path)" AUDL_SYNC_DEST "$DEFAULT_AUDL_SYNC_DEST" validate_optional_writable_dir "AUDL_SYNC_DEST"

prompt_with_default_until_valid_label "AUDL_PYTHON_BIN (command or absolute path)" AUDL_PYTHON_BIN "$DEFAULT_AUDL_PYTHON_BIN" validate_bin "AUDL_PYTHON_BIN"

prompt_with_default_until_valid_label "AUDL_MEDIA_PLAYER_PATH (local mount path)" AUDL_MEDIA_PLAYER_PATH "$DEFAULT_AUDL_MEDIA_PLAYER_PATH" validate_optional_media_path "AUDL_MEDIA_PLAYER_PATH"
prompt_optional "AUDL_LASTFM_API_KEY" AUDL_LASTFM_API_KEY

prompt_with_default_until_valid_label "AUDL_PARANOIA_MODE (0|1)" AUDL_PARANOIA_MODE "$DEFAULT_AUDL_PARANOIA_MODE" validate_secure_mode "AUDL_PARANOIA_MODE"
prompt_with_default_until_valid_label "AUDL_BACKUP_PATH (backup root directory)" AUDL_BACKUP_PATH "$DEFAULT_AUDL_BACKUP_PATH" validate_existing_writable_dir "AUDL_BACKUP_PATH"

prompt_with_default_until_valid_label "AUDL_CRON_INTERVAL_MIN" AUDL_CRON_INTERVAL_MIN "$DEFAULT_AUDL_CRON_INTERVAL_MIN" validate_int_ge_1 "AUDL_CRON_INTERVAL_MIN"
prompt_with_default_until_valid_label "AUDL_TASK_MAX_ALBUMS" AUDL_TASK_MAX_ALBUMS "$DEFAULT_AUDL_TASK_MAX_ALBUMS" validate_int_ge_1 "AUDL_TASK_MAX_ALBUMS"
prompt_with_default_until_valid_label "AUDL_TASK_MAX_TIME_SEC" AUDL_TASK_MAX_TIME_SEC "$DEFAULT_AUDL_TASK_MAX_TIME_SEC" validate_int_ge_0 "AUDL_TASK_MAX_TIME_SEC"
prompt_with_default_until_valid_label "AUDL_TASK_LOG_PATH path" AUDL_TASK_LOG_PATH "$DEFAULT_AUDL_TASK_LOG_PATH" validate_log_path "AUDL_TASK_LOG_PATH"
prompt_with_default_until_valid_label "AUDL_CUE2FLAC_OUTPUT_DIR (output root for cue2flac splits)" AUDL_CUE2FLAC_OUTPUT_DIR "$DEFAULT_AUDL_CUE2FLAC_OUTPUT_DIR" validate_existing_dir "AUDL_CUE2FLAC_OUTPUT_DIR"
AUDL_HIDE_SUPPORT_GREETER="$DEFAULT_AUDL_HIDE_SUPPORT_GREETER"

sanity_check

if [[ "$DRY_RUN" == "1" ]]; then
	render_env
	exit 0
fi

render_env >"$ENV_FILE"
echo "Generated: $ENV_FILE"
