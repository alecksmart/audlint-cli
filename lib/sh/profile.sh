#!/usr/bin/env bash

_profile_trim() {
  printf '%s' "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

_profile_compact_lower() {
  local raw
  raw="$(_profile_trim "${1:-}")"
  raw="${raw,,}"
  raw="${raw//[[:space:]]/}"
  printf '%s' "$raw"
}

profile_bits_normalize() {
  local raw bits
  raw="$(_profile_compact_lower "${1:-}")"
  [[ -n "$raw" ]] || return 1

  case "$raw" in
  32f | f32 | float32 | flt | fltp) printf '32f'; return 0 ;;
  64f | f64 | float64 | double | dbl | dblp) printf '64f'; return 0 ;;
  esac

  if [[ "$raw" =~ ^([0-9]{1,3})(bits?|b)?$ ]]; then
    bits="${BASH_REMATCH[1]}"
    if ((bits > 0)); then
      printf '%s' "$bits"
      return 0
    fi
  fi

  return 1
}

profile_sr_hz_normalize() {
  local raw numeric hz as_hz=0
  raw="$(_profile_compact_lower "${1:-}")"
  [[ -n "$raw" ]] || return 1

  if [[ "$raw" =~ ^([0-9]+([.][0-9]+)?)(khz|k)$ ]]; then
    numeric="${BASH_REMATCH[1]}"
    hz="$(awk -v n="$numeric" 'BEGIN{printf "%.0f", n*1000.0}')"
  elif [[ "$raw" =~ ^([0-9]+([.][0-9]+)?)hz$ ]]; then
    numeric="${BASH_REMATCH[1]}"
    hz="$(awk -v n="$numeric" 'BEGIN{printf "%.0f", n}')"
  elif [[ "$raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    numeric="$raw"
    if [[ "$numeric" == *.* ]]; then
      as_hz="$(awk -v n="$numeric" 'BEGIN{print (n >= 1000.0) ? 1 : 0}')"
      if [[ "$as_hz" == "1" ]]; then
        hz="$(awk -v n="$numeric" 'BEGIN{printf "%.0f", n}')"
      else
        hz="$(awk -v n="$numeric" 'BEGIN{printf "%.0f", n*1000.0}')"
      fi
    else
      if ((numeric >= 1000)); then
        hz="$numeric"
      else
        hz="$((numeric * 1000))"
      fi
    fi
  else
    return 1
  fi

  [[ "$hz" =~ ^[0-9]+$ ]] || return 1
  ((hz > 0)) || return 1
  printf '%s' "$hz"
}

profile_normalize() {
  local raw sr_token bits_token sr_hz bits
  raw="$(_profile_compact_lower "${1:-}")"
  raw="${raw//_/\/}"
  [[ -n "$raw" ]] || return 1

  if [[ "$raw" =~ ^([^/:-]+)[/:-]([^/:-]+)$ ]]; then
    sr_token="${BASH_REMATCH[1]}"
    bits_token="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^([0-9]+([.][0-9]+)?(khz|k)?)([0-9]{2,3}f?)$ ]]; then
    sr_token="${BASH_REMATCH[1]}"
    bits_token="${BASH_REMATCH[4]}"
  else
    return 1
  fi

  sr_hz="$(profile_sr_hz_normalize "$sr_token")" || return 1
  bits="$(profile_bits_normalize "$bits_token")" || return 1
  printf '%s/%s' "$sr_hz" "$bits"
}

profile_is_canonical() {
  local raw
  raw="$(_profile_compact_lower "${1:-}")"
  [[ "$raw" =~ ^[1-9][0-9]*/([1-9][0-9]*|32f|64f)$ ]]
}

profile_print_supported_targets() {
  cat <<'EOF_TARGETS'
Common target profiles:
  44100/16
  44100/24
  48000/24
  88200/24
  96000/24
  176400/24
  192000/24
EOF_TARGETS
}

profile_print_help() {
  cat <<'EOF_HELP'
Accepted profile input forms (fuzzy):
  44100/16
  44.1/16
  44.1-16
  44k/16
  44khz/16

Canonical internal format:
  SR_HZ/BITS  (example: 44100/16)
EOF_HELP
}

profile_cache_file_path() {
  local target="${1:-}"
  if [[ -d "$target" ]]; then
    printf '%s/.sox_album_profile\n' "$target"
  else
    printf '%s\n' "$target"
  fi
}

profile_cache_get() {
  local target="$1"
  local key="$2"
  local profile_file value
  profile_file="$(profile_cache_file_path "$target")"
  [[ -f "$profile_file" ]] || {
    printf ''
    return 0
  }
  value="$(awk -F= -v wanted="$key" '$1 == wanted {print substr($0, index($0, "=") + 1); exit}' "$profile_file" 2>/dev/null || true)"
  _profile_trim "$value"
}

profile_cache_target_profile() {
  local target="$1"
  local target_sr target_bits normalized
  target_sr="$(profile_cache_get "$target" "TARGET_SR")"
  target_bits="$(profile_cache_get "$target" "TARGET_BITS")"
  [[ "$target_sr" =~ ^[0-9]+$ ]] || return 1
  [[ "$target_bits" =~ ^([0-9]+|32f|64f)$ ]] || return 1
  normalized="$(profile_normalize "${target_sr}/${target_bits}" || true)"
  [[ -n "$normalized" ]] || return 1
  printf '%s\n' "$normalized"
}
