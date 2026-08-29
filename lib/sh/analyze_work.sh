#!/usr/bin/env bash

# Invocation-scoped external analyzer work evidence. The entry command owns
# lifecycle; callers may safely source this library without enabling it.

audlint_analyze_work_init() {
  AUDLINT_ANALYZE_WORK_EVENTS="$(mktemp -t audlint_analyze_work.XXXXXX)" || return 1
  export AUDLINT_ANALYZE_WORK_EVENTS
}

audlint_analyze_work_cleanup() {
  if [[ -n "${AUDLINT_ANALYZE_WORK_EVENTS:-}" ]]; then
    rm -f "$AUDLINT_ANALYZE_WORK_EVENTS"
  fi
}

audlint_analyze_work_record_metadata_probe() {
  local tool="${1:-}"
  [[ "$tool" == "ffprobe" || "$tool" == "soxi" ]] || return 0
  [[ -n "${AUDLINT_ANALYZE_WORK_EVENTS:-}" ]] || return 0
  printf 'metadata:%s\n' "$tool" >>"$AUDLINT_ANALYZE_WORK_EVENTS" 2>/dev/null || true
}

audlint_analyze_work_finalize_json() {
  local json_path="$1"
  local finalized python_bin
  python_bin="${PYTHON_BIN:-python3}"
  finalized="$(mktemp -t audlint_analyze_json.XXXXXX)" || return 1
  if ! "$python_bin" - "$json_path" "${AUDLINT_ANALYZE_WORK_EVENTS:-}" >"$finalized" <<'PY'
import json
import sys
from collections import Counter

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)

events = Counter()
if sys.argv[2]:
    try:
        with open(sys.argv[2], encoding="ascii") as fh:
            events.update(line.strip() for line in fh if line.strip())
    except OSError:
        pass

ffprobe_count = events["metadata:ffprobe"]
soxi_count = events["metadata:soxi"]
segment_count = events["decode:segment"]
full_count = events["decode:full"]
payload.update(
    track_count=len(payload.get("tracks", [])),
    metadata_probe_count=ffprobe_count + soxi_count,
    metadata_probe_counts={"ffprobe": ffprobe_count, "soxi": soxi_count},
    decode_operation_count=segment_count + full_count,
    decode_operation_counts={"segment": segment_count, "full": full_count},
)
print(json.dumps(payload))
PY
  then
    rm -f "$finalized"
    return 1
  fi
  if ! mv -f "$finalized" "$json_path"; then
    rm -f "$finalized"
    return 1
  fi
}
