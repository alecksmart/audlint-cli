#!/usr/bin/env python3
"""Helper routines for bin/audlint-analyze.sh."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import hashlib
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import tempfile


HAS_FFPROBE = shutil.which("ffprobe") is not None
HAS_FFMPEG = shutil.which("ffmpeg") is not None
DEFAULT_DECODE_TIMEOUT_SEC = 20.0
AUTO_ANALYSIS_MODE = "auto"
FAST_ANALYSIS_MODE = "fast"
EXACT_ANALYSIS_MODE = "exact"
ANALYSIS_STRATEGY_FAST = "fast"
ANALYSIS_STRATEGY_SEGMENT = "segment"
ANALYSIS_STRATEGY_FULL = "full"
CD_FAMILY_SR_HZ = 44100
STUDIO_48_FAMILY_SR_HZ = 48000
CD_NYQUIST_HZ = 22050.0
STUDIO_48_NYQUIST_HZ = 24000.0
NEAR_48_FAMILY_RATIO = 0.88
SAME_FAMILY_DOWNGRADE_MIN_RATIO = 0.72
CD_FAMILY_TARGETS_HZ = (44100, 88200, 176400)
STUDIO_48_FAMILY_TARGETS_HZ = (48000, 96000, 192000)
EXACT_MIN_WINDOWS = 24
EXACT_WINDOW_MULTIPLIER = 2
MAX_ANALYSIS_SR_HZ = 192000
PCM_BYTES_PER_SAMPLE = 4
STRATEGY_CONFIG_VERSION = "hybrid-v2"
SEGMENT_EXPENSIVE_CODECS = {
    "ape",
    "dst",
    "wavpack",
    "wv",
    "dsf",
    "dff",
    "dsd_lsbf",
    "dsd_msbf",
    "dsd_lsbf_planar",
    "dsd_msbf_planar",
}
SEGMENT_EXPENSIVE_SUFFIXES = {".ape", ".wv", ".dsf", ".dff"}
SEGMENT_DURATION_THRESHOLD_SEC = 15.0 * 60.0
SEGMENT_SIZE_THRESHOLD_BYTES = 250 * 1024 * 1024
SEGMENT_CUE_IMAGE_THRESHOLD_BYTES = 100 * 1024 * 1024
SEGMENT_FAST_COUNT = 4
SEGMENT_EXACT_COUNT = 6
SEGMENT_MIN_SECONDS = 6.0
SEGMENT_MAX_SECONDS = 12.0
SEGMENT_CONSISTENCY_TOLERANCE_HZ = 2500.0
SEGMENT_BOUNDARY_AMBIGUITY_HZ = 1500.0
SEGMENT_STRONG_MAJORITY_RATIO = 0.75
SEGMENT_ACCEPT_MAJORITY_RATIO = 0.6
SEGMENT_EARLY_ACCEPT_MIN = 3
SEGMENT_LARGE_DOWNGRADE_RATIO = 2.5
SEGMENT_BRICKWALL_DROP_DB = 14.0
HF_GUARD_PEAK_DB_THRESHOLD = -78.0
HF_GUARD_OCCUPANCY_THRESHOLD = 0.002
HF_GUARD_ENERGY_RATIO_THRESHOLD = 1e-4


@dataclass(frozen=True)
class TrackMeta:
    sr: float | None
    dur: float | None
    bits: int | None
    channels: int | None
    analysis_sr: int | None
    codec: str | None
    size_bytes: int
    has_sibling_cue: bool
    prefer_ffmpeg_first: bool


@dataclass(frozen=True)
class DecodedTrack:
    path: str
    pcm_path: str
    source_sr: float | None
    analysis_sr: int
    dur: float | None
    channels: int
    frames: int
    source_start_sec: float


def usage() -> str:
    return (
        "Usage:\n"
        "  audlint_analyze.py source-fingerprint <album_dir> <sample_bytes> <file...>\n"
        "  audlint_analyze.py config-fingerprint <ruleset> <headroom_hz> <thresh_rel_db> <window_sec> <max_windows> <fp_sample_bytes> <fp_mode>\n"
        "  audlint_analyze.py analyze <headroom_hz> <thresh_rel_db> <window_sec> <max_windows> [auto|fast|exact] <file...>"
    )


def cmd_source_fingerprint(argv: list[str]) -> int:
    if len(argv) < 3:
        print(usage(), file=sys.stderr)
        return 2
    album_dir = argv[0]
    sample_bytes = int(argv[1])
    files = sorted(argv[2:])

    h = hashlib.sha256()
    h.update(b"audlint-analyze-source-fingerprint-v1\0")
    h.update(str(sample_bytes).encode("ascii", "strict"))
    h.update(b"\0")

    for path in files:
        rel = os.path.relpath(path, album_dir)
        st = os.stat(path, follow_symlinks=True)
        h.update(rel.encode("utf-8", "surrogateescape"))
        h.update(b"\0")
        h.update(str(st.st_size).encode("ascii", "strict"))
        h.update(b"\0")
        h.update(str(st.st_mtime_ns).encode("ascii", "strict"))
        h.update(b"\0")

        with open(path, "rb") as fh:
            head = fh.read(sample_bytes)
            if st.st_size > sample_bytes:
                fh.seek(max(0, st.st_size - sample_bytes))
                tail = fh.read(sample_bytes)
            else:
                tail = b""

        h.update(hashlib.blake2b(head, digest_size=16).digest())
        h.update(hashlib.blake2b(tail, digest_size=16).digest())

    print(h.hexdigest())
    return 0


def cmd_config_fingerprint(argv: list[str]) -> int:
    if len(argv) != 7:
        print(usage(), file=sys.stderr)
        return 2
    parts = [
        "audlint-analyze-config-fingerprint-v1",
        f"ruleset={argv[0]}",
        f"headroom_hz={argv[1]}",
        f"thresh_rel_db={argv[2]}",
        f"window_sec={argv[3]}",
        f"max_windows={argv[4]}",
        f"fp_sample_bytes={argv[5]}",
        f"fp_mode={argv[6]}",
        f"strategy_config={STRATEGY_CONFIG_VERSION}",
        f"segment_codecs={','.join(sorted(SEGMENT_EXPENSIVE_CODECS))}",
        f"segment_suffixes={','.join(sorted(SEGMENT_EXPENSIVE_SUFFIXES))}",
        f"segment_duration_threshold_sec={SEGMENT_DURATION_THRESHOLD_SEC}",
        f"segment_size_threshold_bytes={SEGMENT_SIZE_THRESHOLD_BYTES}",
        f"segment_cue_image_threshold_bytes={SEGMENT_CUE_IMAGE_THRESHOLD_BYTES}",
        f"segment_fast_count={SEGMENT_FAST_COUNT}",
        f"segment_exact_count={SEGMENT_EXACT_COUNT}",
        f"segment_min_seconds={SEGMENT_MIN_SECONDS}",
        f"segment_max_seconds={SEGMENT_MAX_SECONDS}",
        f"segment_consistency_tolerance_hz={SEGMENT_CONSISTENCY_TOLERANCE_HZ}",
        f"segment_boundary_ambiguity_hz={SEGMENT_BOUNDARY_AMBIGUITY_HZ}",
        f"segment_strong_majority_ratio={SEGMENT_STRONG_MAJORITY_RATIO}",
        f"segment_accept_majority_ratio={SEGMENT_ACCEPT_MAJORITY_RATIO}",
        f"segment_early_accept_min={SEGMENT_EARLY_ACCEPT_MIN}",
        f"segment_large_downgrade_ratio={SEGMENT_LARGE_DOWNGRADE_RATIO}",
        f"segment_brickwall_drop_db={SEGMENT_BRICKWALL_DROP_DB}",
        f"hf_guard_peak_db_threshold={HF_GUARD_PEAK_DB_THRESHOLD}",
        f"hf_guard_occupancy_threshold={HF_GUARD_OCCUPANCY_THRESHOLD}",
        f"hf_guard_energy_ratio_threshold={HF_GUARD_ENERGY_RATIO_THRESHOLD}",
    ]
    joined = "\n".join(parts).encode("utf-8", "strict")
    print(hashlib.sha256(joined).hexdigest())
    return 0


def soxi(field: str, path: str) -> float | None:
    proc = subprocess.run(["soxi", field, path], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    try:
        return float(proc.stdout.strip())
    except Exception:
        return None


def ffprobe_audio_json(path: str) -> dict[str, str]:
    if not HAS_FFPROBE:
        return {}
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_name,sample_rate,bits_per_raw_sample,bits_per_sample,sample_fmt,channels",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            path,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return {}
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}
    streams = payload.get("streams") or []
    if not streams:
        return {}
    stream = streams[0] or {}
    fmt = payload.get("format") or {}
    result: dict[str, str] = {}
    for key in ("codec_name", "sample_rate", "bits_per_raw_sample", "bits_per_sample", "sample_fmt", "channels"):
        value = stream.get(key)
        if value not in (None, "", "N/A"):
            result[key] = str(value)
    duration = fmt.get("duration")
    if duration not in (None, "", "N/A"):
        result["duration"] = str(duration)
    return result


def ffprobe_stream(path: str, field: str) -> float | None:
    if not HAS_FFPROBE:
        return None
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            f"stream={field}",
            "-of",
            "default=nokey=1:noprint_wrappers=1",
            path,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    for line in proc.stdout.splitlines():
        try:
            value = float(line.strip())
            return value if value > 0 else None
        except Exception:
            continue
    return None


def ffprobe_stream_text(path: str, field: str) -> str | None:
    if not HAS_FFPROBE:
        return None
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            f"stream={field}",
            "-of",
            "default=nokey=1:noprint_wrappers=1",
            path,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    for line in proc.stdout.splitlines():
        value = line.strip()
        if value:
            return value
    return None


def ffprobe_duration(path: str) -> float | None:
    if not HAS_FFPROBE:
        return None
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=nokey=1:noprint_wrappers=1",
            path,
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    for line in proc.stdout.splitlines():
        try:
            return float(line.strip())
        except Exception:
            continue
    return None


def sibling_cue_exists(path: str) -> bool:
    try:
        dirname = os.path.dirname(path) or "."
        return any(entry.lower().endswith(".cue") for entry in os.listdir(dirname))
    except OSError:
        return False


def prefer_ffmpeg_decode(path: str, soxi_duration: float | None) -> bool:
    if not HAS_FFMPEG:
        return False
    suffix = os.path.splitext(path)[1].lower()
    if suffix in SEGMENT_EXPENSIVE_SUFFIXES:
        return True
    return soxi_duration is None or soxi_duration <= 0


def parse_positive_float(raw: str | None) -> float | None:
    if raw is None:
        return None
    text = str(raw).strip()
    if not text:
        return None
    try:
        value = float(text)
    except ValueError:
        return None
    return value if value > 0 else None


def parse_positive_int(raw: str | None) -> int | None:
    value = parse_positive_float(raw)
    if value is None:
        return None
    rounded = int(value)
    return rounded if rounded > 0 else None


def sample_fmt_to_bits(sample_fmt: str | None) -> int | None:
    if not sample_fmt:
        return None
    sample_fmt = sample_fmt.strip().lower()
    if sample_fmt in {"s16", "s16p"}:
        return 16
    if sample_fmt in {"s24", "s24p"}:
        return 24
    if sample_fmt in {"s32", "s32p", "flt", "fltp"}:
        return 32
    if sample_fmt in {"dbl", "dblp"}:
        return 64
    return None


def normalize_source_bits(codec: str | None, bits: int | None) -> int | None:
    codec = (codec or "").strip().lower()
    if (codec.startswith("dsd") or codec == "dst") and (bits is None or bits < 24):
        return 24
    return bits if bits and bits > 0 else None


def probe_source_bits(path: str, meta: dict[str, str] | None = None) -> int | None:
    meta = meta or ffprobe_audio_json(path)
    codec = meta.get("codec_name", "") or (ffprobe_stream_text(path, "codec_name") or "")
    bits = parse_positive_int(meta.get("bits_per_raw_sample"))
    if bits is None:
        bits = parse_positive_int(meta.get("bits_per_sample"))
    if bits is None:
        bits = ffprobe_stream(path, "bits_per_raw_sample") or ffprobe_stream(path, "bits_per_sample")
    if bits is None:
        bits = sample_fmt_to_bits(meta.get("sample_fmt") or ffprobe_stream_text(path, "sample_fmt"))
    return normalize_source_bits(codec, bits)


def capped_analysis_sample_rate(sr: float | None) -> int | None:
    if sr is None or sr <= 0:
        return None
    return min(int(round(sr)), MAX_ANALYSIS_SR_HZ)


def audio_meta(path: str) -> TrackMeta:
    meta = ffprobe_audio_json(path)
    sr = parse_positive_float(meta.get("sample_rate"))
    if sr is None:
        sr = soxi("-r", path)
    soxi_dur = soxi("-D", path)
    dur = soxi_dur if soxi_dur and soxi_dur > 0 else parse_positive_float(meta.get("duration"))
    if dur is None or dur <= 0:
        dur = ffprobe_duration(path)
    bits = probe_source_bits(path, meta)
    codec = (meta.get("codec_name") or ffprobe_stream_text(path, "codec_name") or "").strip().lower() or None
    channels = parse_positive_int(meta.get("channels"))
    if channels is None:
        channels = parse_positive_int(str(ffprobe_stream(path, "channels") or ""))
    analysis_sr = capped_analysis_sample_rate(sr)
    try:
        size_bytes = os.stat(path, follow_symlinks=True).st_size
    except OSError:
        size_bytes = 0
    return TrackMeta(
        sr=sr,
        dur=dur,
        bits=bits,
        channels=channels,
        analysis_sr=analysis_sr,
        codec=codec,
        size_bytes=size_bytes,
        has_sibling_cue=sibling_cue_exists(path),
        prefer_ffmpeg_first=prefer_ffmpeg_decode(path, soxi_dur),
    )


def decode_timeout_sec(window_sec: float, duration_sec: float | None = None) -> float:
    raw = os.environ.get("AUDLINT_ANALYZE_DECODE_TIMEOUT_SEC", "").strip()
    if raw:
        try:
            timeout = float(raw)
        except ValueError:
            timeout = DEFAULT_DECODE_TIMEOUT_SEC
        return timeout if timeout > 0 else DEFAULT_DECODE_TIMEOUT_SEC

    baseline = max(DEFAULT_DECODE_TIMEOUT_SEC, window_sec * 4.0)
    if duration_sec and duration_sec > 0:
        baseline = max(baseline, min(duration_sec * 2.0, 300.0))
    return baseline


def debug_enabled() -> bool:
    raw = os.environ.get("AUDLINT_ANALYZE_DEBUG", "").strip().lower()
    return raw not in {"", "0", "false", "no", "off"}


def debug(message: str) -> None:
    if debug_enabled():
        print(message, file=sys.stderr)


def run_decode_command_to_file(cmd: list[str], timeout_sec: float) -> str | None:
    fd, pcm_path = tempfile.mkstemp(prefix="audlint_analyze_", suffix=".pcm")
    os.close(fd)
    try:
        with open(pcm_path, "wb") as fh:
            proc = subprocess.run(
                cmd,
                stdout=fh,
                stderr=subprocess.DEVNULL,
                timeout=timeout_sec,
                check=False,
            )
        if proc.returncode != 0 or os.path.getsize(pcm_path) <= 0:
            os.unlink(pcm_path)
            return None
        return pcm_path
    except (OSError, subprocess.SubprocessError):
        if os.path.exists(pcm_path):
            os.unlink(pcm_path)
        return None


def decode_pcm_span(
    path: str,
    track_meta: TrackMeta,
    decode_channels: int,
    span_sec: float,
    start_sec: float | None = None,
    duration_sec: float | None = None,
) -> DecodedTrack | None:
    analysis_sr = track_meta.analysis_sr
    if analysis_sr is None or analysis_sr <= 0:
        return None

    decode_channels = 2 if decode_channels >= 2 else 1
    timeout_sec = decode_timeout_sec(span_sec, duration_sec or track_meta.dur)

    ffmpeg_cmd = [
        "ffmpeg",
        "-v",
        "error",
    ]
    if start_sec is not None:
        ffmpeg_cmd.extend(["-ss", f"{max(0.0, start_sec):.6f}"])
    if duration_sec is not None:
        ffmpeg_cmd.extend(["-t", f"{max(0.0, duration_sec):.6f}"])
    ffmpeg_cmd.extend(["-i", path])
    if decode_channels >= 2:
        ffmpeg_cmd.extend(["-filter:a", "pan=stereo|c0=c0|c1=c1", "-ac", "2"])
    else:
        ffmpeg_cmd.extend(["-ac", "1"])
    ffmpeg_cmd.extend(["-ar", str(int(analysis_sr)), "-f", "f32le", "-"])

    sox_cmd = ["sox", path, "-t", "f32", "-c", str(decode_channels), "-r", str(int(analysis_sr)), "-"]
    if decode_channels >= 2:
        sox_cmd.extend(["remix", "1", "2"])
    if start_sec is not None or duration_sec is not None:
        sox_cmd.extend(["trim", f"{max(0.0, start_sec or 0.0):.6f}"])
        if duration_sec is not None:
            sox_cmd.append(f"{max(0.0, duration_sec):.6f}")

    commands: list[list[str]] = []
    if track_meta.prefer_ffmpeg_first and HAS_FFMPEG:
        commands.append(ffmpeg_cmd)
        commands.append(sox_cmd)
    else:
        commands.append(sox_cmd)
        if HAS_FFMPEG:
            commands.append(ffmpeg_cmd)

    for cmd in commands:
        pcm_path = run_decode_command_to_file(cmd, timeout_sec)
        if not pcm_path:
            continue
        frame_width = PCM_BYTES_PER_SAMPLE * decode_channels
        pcm_size = os.path.getsize(pcm_path)
        frames = pcm_size // frame_width
        if frame_width <= 0 or frames <= 0:
            os.unlink(pcm_path)
            continue
        if debug_enabled():
            debug(
                f"decoded track={os.path.basename(path)} sr_in={track_meta.sr} "
                f"analysis_sr={analysis_sr} channels={decode_channels} frames={frames} "
                f"start={0.0 if start_sec is None else start_sec:.3f} "
                f"duration={'full' if duration_sec is None else f'{duration_sec:.3f}'}"
            )
        return DecodedTrack(
            path=path,
            pcm_path=pcm_path,
            source_sr=track_meta.sr,
            analysis_sr=int(analysis_sr),
            dur=duration_sec if duration_sec is not None else track_meta.dur,
            channels=decode_channels,
            frames=frames,
            source_start_sec=0.0 if start_sec is None else float(start_sec),
        )
    return None


def decode_track_pcm(
    path: str,
    track_meta: TrackMeta,
    window_sec: float,
    decode_channels: int,
) -> DecodedTrack | None:
    return decode_pcm_span(path, track_meta, decode_channels, window_sec)


def decode_segment_pcm(
    path: str,
    track_meta: TrackMeta,
    segment_start_sec: float,
    segment_duration_sec: float,
    decode_channels: int,
) -> DecodedTrack | None:
    return decode_pcm_span(
        path,
        track_meta,
        decode_channels,
        segment_duration_sec,
        start_sec=segment_start_sec,
        duration_sec=segment_duration_sec,
    )


def cleanup_decoded_track(decoded_track: DecodedTrack | None) -> None:
    if decoded_track is None:
        return
    try:
        os.unlink(decoded_track.pcm_path)
    except FileNotFoundError:
        pass


def normalize_analysis_mode(raw_mode: str | None) -> str:
    mode = (raw_mode or "").strip().lower()
    if mode == EXACT_ANALYSIS_MODE:
        return EXACT_ANALYSIS_MODE
    if mode == FAST_ANALYSIS_MODE:
        return FAST_ANALYSIS_MODE
    return AUTO_ANALYSIS_MODE


def effective_max_windows(max_windows: int, analysis_mode: str) -> int:
    analysis_mode = normalize_analysis_mode(analysis_mode)
    if analysis_mode == EXACT_ANALYSIS_MODE:
        return max(max_windows * EXACT_WINDOW_MULTIPLIER, EXACT_MIN_WINDOWS)
    return max_windows


def build_window_starts(dur: float, window_sec: float, max_windows: int) -> list[float]:
    nwin = min(max_windows, max(1, int(dur // window_sec)))
    starts: list[float] = []
    if nwin == 1:
        starts = [max(0.0, (dur - window_sec) * 0.5)]
    else:
        for idx in range(nwin):
            t = (dur - window_sec) * (0.1 + 0.8 * (idx / (nwin - 1)))
            starts.append(max(0.0, min(t, max(0.0, dur - window_sec))))
    return starts


def choose_analysis_strategy(path: str, track_meta: TrackMeta) -> tuple[str, str]:
    codec = (track_meta.codec or "").strip().lower()
    suffix = os.path.splitext(path)[1].lower()
    reasons: list[str] = []

    if codec in SEGMENT_EXPENSIVE_CODECS or suffix in SEGMENT_EXPENSIVE_SUFFIXES:
        reasons.append(f"expensive_codec:{codec or suffix}")
    if track_meta.has_sibling_cue and track_meta.size_bytes >= SEGMENT_CUE_IMAGE_THRESHOLD_BYTES:
        reasons.append("cue_backed_large_image")
    if track_meta.dur and track_meta.dur >= SEGMENT_DURATION_THRESHOLD_SEC:
        reasons.append(f"long_duration:{int(track_meta.dur)}s")
    if track_meta.size_bytes >= SEGMENT_SIZE_THRESHOLD_BYTES:
        reasons.append(f"large_file:{track_meta.size_bytes}")

    if reasons:
        return ANALYSIS_STRATEGY_SEGMENT, ",".join(reasons)
    return ANALYSIS_STRATEGY_FAST, "normal_source"


def segment_count_for_mode(analysis_mode: str) -> int:
    analysis_mode = normalize_analysis_mode(analysis_mode)
    if analysis_mode == EXACT_ANALYSIS_MODE:
        return SEGMENT_EXACT_COUNT
    return SEGMENT_FAST_COUNT


def segment_duration_for_window(window_sec: float) -> float:
    return max(SEGMENT_MIN_SECONDS, min(SEGMENT_MAX_SECONDS, float(window_sec)))


def build_segment_starts(dur: float | None, segment_sec: float, segment_count: int) -> list[float]:
    if dur is None or dur <= 0:
        return [0.0]
    usable = max(0.0, dur - segment_sec)
    if usable <= 0:
        return [0.0]

    count = min(segment_count, max(1, int(dur // max(segment_sec, 1.0))))
    if count <= 1:
        return [usable * 0.5]

    starts: list[float] = []
    for idx in range(count):
        ratio = 0.08 + (0.84 * (idx / (count - 1)))
        starts.append(max(0.0, min(usable * ratio, usable)))
    return starts


def guard_band_start_hz(sr_in: float | None) -> float | None:
    family_sr = source_family_sr(sr_in)
    if family_sr == CD_FAMILY_SR_HZ:
        return CD_NYQUIST_HZ
    if family_sr == STUDIO_48_FAMILY_SR_HZ:
        return STUDIO_48_NYQUIST_HZ
    return None


def required_segment_votes(sample_count: int, ratio: float = SEGMENT_ACCEPT_MAJORITY_RATIO) -> int:
    if sample_count <= 0:
        return 0
    return max(2, int(math.ceil(sample_count * ratio)))


def decision_boundary_distance_hz(cutoff_hz: float | None, sr_in: float, headroom_hz: int) -> float | None:
    target_sr = classify_family_target_sr(cutoff_hz, sr_in, headroom_hz)
    if target_sr is None or int(target_sr) >= int(sr_in):
        return None
    effective = effective_cutoff_hz(cutoff_hz, headroom_hz)
    if effective is None:
        return None
    return abs(float(effective) - (float(target_sr) / 2.0))


def segment_consistency_ratio(cutoffs_hz: list[float], tolerance_hz: float = SEGMENT_CONSISTENCY_TOLERANCE_HZ) -> float:
    if not cutoffs_hz:
        return 0.0
    median_cutoff = float(statistics.median(cutoffs_hz))
    consistent = sum(1 for cutoff in cutoffs_hz if abs(float(cutoff) - median_cutoff) <= tolerance_hz)
    return consistent / float(len(cutoffs_hz))


def select_channel_signal(window_frames, channel_mode: str):
    import numpy as np

    if window_frames.ndim == 1:
        return np.asarray(window_frames, dtype=np.float32)
    if window_frames.shape[1] <= 1:
        return np.asarray(window_frames[:, 0], dtype=np.float32)
    if channel_mode == "left":
        return np.asarray(window_frames[:, 0], dtype=np.float32)
    if channel_mode == "right":
        return np.asarray(window_frames[:, 1], dtype=np.float32)
    return np.asarray(np.mean(window_frames[:, :2], axis=1), dtype=np.float32)


def analyze_cutoff_series_from_decoded(
    decoded_track: DecodedTrack | None,
    track_meta: TrackMeta,
    window_sec: float,
    max_windows: int,
    thresh_rel_db: float,
    channel_mode: str = "mono",
) -> dict[str, object]:
    sr = track_meta.sr
    dur = decoded_track.dur if decoded_track is not None else track_meta.dur
    analysis_sr = track_meta.analysis_sr

    if decoded_track is None or analysis_sr is None or not dur:
        return {
            "sr": sr,
            "analysis_sr": analysis_sr,
            "dur": dur,
            "channel_mode": channel_mode,
            "cutoff_hz": None,
            "cutoffs_hz": [],
            "windows_requested": 0,
            "windows_used": 0,
            "hf_energy_ratio": 0.0,
            "hf_peak_db": None,
            "hf_present": False,
            "hf_present_windows": 0,
            "shape_drop_db": None,
            "window_hf_energy_ratios": [],
            "window_shape_drop_dbs": [],
        }

    starts = build_window_starts(dur, window_sec, max_windows)

    try:
        import numpy as np
    except Exception:
        return {
            "sr": sr,
            "analysis_sr": analysis_sr,
            "dur": dur,
            "channel_mode": channel_mode,
            "cutoff_hz": None,
            "cutoffs_hz": [],
            "windows_requested": len(starts),
            "windows_used": 0,
            "hf_energy_ratio": 0.0,
            "hf_peak_db": None,
            "hf_present": False,
            "hf_present_windows": 0,
            "shape_drop_db": None,
            "window_hf_energy_ratios": [],
            "window_shape_drop_dbs": [],
        }

    if decoded_track.frames <= 0:
        return {
            "sr": sr,
            "analysis_sr": analysis_sr,
            "dur": dur,
            "channel_mode": channel_mode,
            "cutoff_hz": None,
            "cutoffs_hz": [],
            "windows_requested": len(starts),
            "windows_used": 0,
            "hf_energy_ratio": 0.0,
            "hf_peak_db": None,
            "hf_present": False,
            "hf_present_windows": 0,
            "shape_drop_db": None,
            "window_hf_energy_ratios": [],
            "window_shape_drop_dbs": [],
        }

    frame_shape = (decoded_track.frames, decoded_track.channels)
    pcm = np.memmap(decoded_track.pcm_path, dtype=np.float32, mode="r", shape=frame_shape)
    window_frames = max(1, int(round(window_sec * analysis_sr)))
    min_frames = max(1, int(analysis_sr))
    cutoffs: list[float] = []
    hf_energy_ratios: list[float] = []
    hf_peak_dbs: list[float] = []
    hf_present_windows = 0
    shape_drop_dbs: list[float] = []
    guard_band_hz = guard_band_start_hz(sr)
    nyquist_hz = analysis_sr / 2.0
    freqs = None

    try:
        for t0 in starts:
            max_start_frame = max(0, decoded_track.frames - window_frames)
            start_frame = int(round(t0 * analysis_sr))
            start_frame = max(0, min(start_frame, max_start_frame))
            stop_frame = min(decoded_track.frames, start_frame + window_frames)
            if stop_frame - start_frame < min_frames:
                continue

            window_data = pcm[start_frame:stop_frame]
            x = select_channel_signal(window_data, channel_mode)
            if x.size < min_frames:
                continue
            x = x - float(np.mean(x))
            window = np.hanning(x.size)
            spectrum = np.fft.rfft(x * window)
            mag = np.abs(spectrum)
            peak = mag.max() if mag.size else 0.0
            if peak <= 0:
                continue
            if freqs is None or len(freqs) != mag.size:
                freqs = np.linspace(0.0, nyquist_hz, mag.size, dtype=np.float64)
            db = 20.0 * np.log10(np.maximum(mag / peak, 1e-12))
            idx = (db >= thresh_rel_db).nonzero()[0]
            if idx.size == 0:
                continue
            k = int(idx.max())
            freq = (k / (mag.size - 1)) * (analysis_sr / 2.0)
            cutoffs.append(float(freq))

            if guard_band_hz is not None and guard_band_hz < nyquist_hz and freqs is not None:
                guard_mask = freqs >= guard_band_hz
                if guard_mask.any():
                    guard_mag = mag[guard_mask]
                    guard_db = db[guard_mask]
                    total_energy = float(np.sum(mag * mag))
                    guard_energy = float(np.sum(guard_mag * guard_mag))
                    guard_ratio = (guard_energy / total_energy) if total_energy > 0 else 0.0
                    guard_peak_db = float(np.max(guard_db)) if guard_db.size else -120.0
                    guard_occupancy = float(np.mean(guard_db >= HF_GUARD_PEAK_DB_THRESHOLD)) if guard_db.size else 0.0
                    hf_energy_ratios.append(guard_ratio)
                    hf_peak_dbs.append(guard_peak_db)
                    if (
                        guard_peak_db >= HF_GUARD_PEAK_DB_THRESHOLD
                        or guard_occupancy >= HF_GUARD_OCCUPANCY_THRESHOLD
                        or guard_ratio >= HF_GUARD_ENERGY_RATIO_THRESHOLD
                    ):
                        hf_present_windows += 1

            if freqs is not None and freq > 3000.0:
                pre_mask = (freqs >= max(0.0, freq - 2000.0)) & (freqs < max(0.0, freq - 500.0))
                post_mask = (freqs >= min(nyquist_hz, freq + 500.0)) & (freqs < min(nyquist_hz, freq + 2500.0))
                if pre_mask.any() and post_mask.any():
                    pre_mean_db = float(np.mean(db[pre_mask]))
                    post_mean_db = float(np.mean(db[post_mask]))
                    shape_drop_dbs.append(pre_mean_db - post_mean_db)
    finally:
        del pcm

    if debug_enabled():
        debug(
            f"analyzed track={os.path.basename(decoded_track.path)} mode={channel_mode} "
            f"windows={len(cutoffs)}/{len(starts)}"
        )

    return {
        "sr": sr,
        "analysis_sr": analysis_sr,
        "dur": dur,
        "channel_mode": channel_mode,
        "cutoff_hz": float(statistics.median(cutoffs)) if cutoffs else None,
        "cutoffs_hz": cutoffs,
        "windows_requested": len(starts),
        "windows_used": len(cutoffs),
        "hf_energy_ratio": float(statistics.median(hf_energy_ratios)) if hf_energy_ratios else 0.0,
        "hf_peak_db": float(max(hf_peak_dbs)) if hf_peak_dbs else None,
        "hf_present": bool(hf_present_windows > 0),
        "hf_present_windows": hf_present_windows,
        "shape_drop_db": float(statistics.median(shape_drop_dbs)) if shape_drop_dbs else None,
        "window_hf_energy_ratios": hf_energy_ratios,
        "window_shape_drop_dbs": shape_drop_dbs,
    }


def analyze_cutoff_series(
    path: str,
    window_sec: float,
    max_windows: int,
    thresh_rel_db: float,
    track_meta: TrackMeta | None = None,
    channel_mode: str = "mono",
) -> dict[str, object]:
    track_meta = track_meta or audio_meta(path)
    decode_channels = 2 if channel_mode in {"left", "right"} and (track_meta.channels or 0) >= 2 else 1
    decoded_track = decode_track_pcm(path, track_meta, window_sec, decode_channels)
    try:
        return analyze_cutoff_series_from_decoded(
            decoded_track,
            track_meta,
            window_sec,
            max_windows,
            thresh_rel_db,
            channel_mode=channel_mode,
        )
    finally:
        cleanup_decoded_track(decoded_track)


def analyze_cutoff(
    path: str,
    window_sec: float,
    max_windows: int,
    thresh_rel_db: float,
    track_meta: TrackMeta | None = None,
) -> tuple[float | None, float | None, float | None]:
    result = analyze_cutoff_series(path, window_sec, max_windows, thresh_rel_db, track_meta)
    return result["sr"], result["dur"], result["cutoff_hz"]


def confidence_rank(confidence: str) -> int:
    if confidence == "high":
        return 3
    if confidence == "medium":
        return 2
    return 1


def statistical_confidence(
    cutoffs_hz: list[float],
    windows_requested: int,
    analysis_strategy: str = ANALYSIS_STRATEGY_FULL,
) -> str:
    if not cutoffs_hz:
        return "low"
    windows_used = len(cutoffs_hz)
    min_windows = min(3, max(1, windows_requested))
    if analysis_strategy == ANALYSIS_STRATEGY_SEGMENT:
        min_windows = min(2, max(1, windows_requested))
    if windows_used < min_windows:
        return "low"
    if windows_used < 3:
        if analysis_strategy != ANALYSIS_STRATEGY_SEGMENT:
            return "low"
    median_cutoff = statistics.median(cutoffs_hz)
    if median_cutoff <= 0:
        return "low"
    spread_hz = max(cutoffs_hz) - min(cutoffs_hz)
    spread_ratio = spread_hz / max(float(median_cutoff), 1.0)
    if analysis_strategy == ANALYSIS_STRATEGY_SEGMENT:
        if windows_used >= 4 and spread_ratio <= 0.12:
            return "high"
        if windows_used >= 3 and spread_ratio <= 0.25:
            return "medium"
        return "low"
    if windows_used >= 8 and spread_ratio <= 0.12:
        return "high"
    if windows_used >= 5 and spread_ratio <= 0.25:
        return "medium"
    return "low"


def analysis_confidence(
    cutoffs_hz: list[float],
    windows_requested: int,
    analysis_strategy: str = ANALYSIS_STRATEGY_FULL,
) -> str:
    return statistical_confidence(cutoffs_hz, windows_requested, analysis_strategy)


def segment_starts_for_mode(dur: float | None, window_sec: float, analysis_mode: str) -> tuple[float, list[float]]:
    segment_duration = segment_duration_for_window(window_sec)
    exact_starts = build_segment_starts(dur, segment_duration, SEGMENT_EXACT_COUNT)
    normalized_mode = normalize_analysis_mode(analysis_mode)
    if normalized_mode == FAST_ANALYSIS_MODE:
        return segment_duration, exact_starts[: min(SEGMENT_FAST_COUNT, len(exact_starts))]
    return segment_duration, exact_starts


def classify_segment_sample(
    result: dict[str, object],
    track_meta: TrackMeta,
    headroom_hz: int,
    *,
    segment_index: int,
    source_start_sec: float,
) -> dict[str, object]:
    cutoff_hz = result.get("cutoff_hz")
    hf_present = bool(result.get("hf_present", False))
    shape_drop_db = result.get("shape_drop_db")
    boundary_distance_hz = None
    decision_hint: dict[str, object] | None = None
    classification = "uncertain"
    classification_reason = "no_cutoff"
    decision_target_sr_hint = int(track_meta.sr) if track_meta.sr else None

    if cutoff_hz is not None and track_meta.sr is not None:
        decision_hint = resolve_recode_decision(float(cutoff_hz), float(track_meta.sr), headroom_hz)
        boundary_distance_hz = decision_boundary_distance_hz(float(cutoff_hz), float(track_meta.sr), headroom_hz)
        decision_target_sr_hint = int(decision_hint["target_sr"]) if decision_hint.get("target_sr") is not None else decision_target_sr_hint
        if bool(decision_hint.get("fake_upscale")):
            if hf_present:
                classification = "full-band"
                classification_reason = "hf_presence_guard"
            elif boundary_distance_hz is not None and boundary_distance_hz <= SEGMENT_BOUNDARY_AMBIGUITY_HZ:
                classification = "uncertain"
                classification_reason = "boundary_ambiguity"
            elif shape_drop_db is not None and float(shape_drop_db) >= SEGMENT_BRICKWALL_DROP_DB:
                classification = "cutoff-limited"
                classification_reason = "brickwall_cutoff"
            else:
                classification = "uncertain"
                classification_reason = "gradual_rolloff"
        else:
            classification = "full-band"
            classification_reason = "full_band_signal"

    return {
        "segment_index": segment_index,
        "source_start_sec": source_start_sec,
        "cutoff_hz": cutoff_hz,
        "hf_energy_ratio": float(result.get("hf_energy_ratio", 0.0) or 0.0),
        "hf_peak_db": result.get("hf_peak_db"),
        "hf_present": hf_present,
        "shape_drop_db": shape_drop_db,
        "windows_requested": int(result.get("windows_requested", 0)),
        "windows_used": int(result.get("windows_used", 0)),
        "decision_hint": decision_hint,
        "decision_target_sr_hint": decision_target_sr_hint,
        "classification": classification,
        "classification_reason": classification_reason,
        "boundary_ambiguous": bool(boundary_distance_hz is not None and boundary_distance_hz <= SEGMENT_BOUNDARY_AMBIGUITY_HZ),
        "boundary_distance_hz": boundary_distance_hz,
    }


def summarize_segment_samples(
    segment_samples: list[dict[str, object]],
    track_meta: TrackMeta,
    headroom_hz: int,
) -> dict[str, object]:
    cutoffs = [float(sample["cutoff_hz"]) for sample in segment_samples if sample.get("cutoff_hz") is not None]
    statistical = statistical_confidence(cutoffs, len(segment_samples), ANALYSIS_STRATEGY_SEGMENT)
    consistency_ratio = segment_consistency_ratio(cutoffs)
    classification_counts = Counter(str(sample.get("classification", "uncertain")) for sample in segment_samples)
    cutoff_limited_samples = [sample for sample in segment_samples if sample.get("classification") == "cutoff-limited"]
    full_band_samples = [sample for sample in segment_samples if sample.get("classification") == "full-band"]
    downgrade_targets = [
        int(sample["decision_target_sr_hint"])
        for sample in cutoff_limited_samples
        if sample.get("decision_target_sr_hint") is not None and track_meta.sr is not None and int(sample["decision_target_sr_hint"]) < int(track_meta.sr)
    ]
    target_counts = Counter(downgrade_targets)
    majority_target_sr, majority_target_count = (None, 0)
    if target_counts:
        majority_target_sr, majority_target_count = target_counts.most_common(1)[0]
    decisive_samples = len(cutoff_limited_samples) + len(full_band_samples)
    sample_count = len(segment_samples)
    required_votes = required_segment_votes(max(sample_count, decisive_samples))
    target_agreement = (majority_target_count / float(len(cutoff_limited_samples))) if cutoff_limited_samples else 0.0
    family_inconsistent = len(target_counts) > 1
    strong_minor_target = any(count >= 2 for target, count in target_counts.items() if target != majority_target_sr)
    hf_guard_present = any(bool(sample.get("hf_present")) for sample in segment_samples)
    boundary_ambiguous = any(bool(sample.get("boundary_ambiguous")) for sample in segment_samples)
    large_downgrade = bool(
        majority_target_sr is not None
        and track_meta.sr is not None
        and majority_target_sr > 0
        and (float(track_meta.sr) / float(majority_target_sr)) >= SEGMENT_LARGE_DOWNGRADE_RATIO
    )

    decision_confidence = "low"
    decision_reason = "fallback_due_to_no_signal"
    fallback_reason = "fallback_due_to_no_signal"
    allow_fake_upscale = False

    if cutoffs:
        downgrade_consistent = (
            majority_target_sr is not None
            and majority_target_count >= required_votes
            and not family_inconsistent
            and not strong_minor_target
            and not boundary_ambiguous
            and not hf_guard_present
            and len(full_band_samples) == 0
            and consistency_ratio >= SEGMENT_ACCEPT_MAJORITY_RATIO
        )
        if downgrade_consistent and large_downgrade:
            downgrade_consistent = (
                majority_target_count == len(segment_samples)
                and consistency_ratio >= SEGMENT_STRONG_MAJORITY_RATIO
                and statistical != "low"
            )

        if downgrade_consistent:
            decision_confidence = (
                "high"
                if (
                    majority_target_count >= max(SEGMENT_EARLY_ACCEPT_MIN, required_votes)
                    and consistency_ratio >= SEGMENT_STRONG_MAJORITY_RATIO
                    and statistical != "low"
                )
                else "medium"
            )
            decision_reason = "accepted_by_consistency" if consistency_ratio >= SEGMENT_STRONG_MAJORITY_RATIO else "accepted_by_majority_vote"
            fallback_reason = None
            allow_fake_upscale = True
        elif family_inconsistent:
            decision_confidence = "low"
            decision_reason = "fallback_due_to_family_inconsistency"
            fallback_reason = decision_reason
        elif boundary_ambiguous and not hf_guard_present and len(full_band_samples) == 0:
            decision_confidence = "low"
            decision_reason = "fallback_due_to_boundary_ambiguity"
            fallback_reason = decision_reason
        else:
            keep_source_votes = len(full_band_samples)
            keep_source_stable = (
                keep_source_votes >= required_votes
                or hf_guard_present
                or (majority_target_count == 0 and consistency_ratio >= SEGMENT_ACCEPT_MAJORITY_RATIO)
                or (majority_target_count >= required_votes and (hf_guard_present or keep_source_votes > 0))
            )
            if keep_source_stable:
                decision_confidence = (
                    "high"
                    if keep_source_votes >= max(SEGMENT_EARLY_ACCEPT_MIN, required_votes) and consistency_ratio >= SEGMENT_ACCEPT_MAJORITY_RATIO
                    else "medium"
                )
                decision_reason = "accepted_by_consistency" if consistency_ratio >= SEGMENT_ACCEPT_MAJORITY_RATIO or hf_guard_present else "accepted_by_majority_vote"
                fallback_reason = None
                allow_fake_upscale = False
            else:
                decision_confidence = "low"
                decision_reason = "fallback_due_to_disagreement"
                fallback_reason = decision_reason

    return {
        "cutoff_hz": float(statistics.median(cutoffs)) if cutoffs else None,
        "cutoffs_hz": cutoffs,
        "statistical_confidence": statistical,
        "decision_confidence": decision_confidence,
        "decision_reason": decision_reason,
        "fallback_reason": fallback_reason,
        "allow_fake_upscale": allow_fake_upscale,
        "consistency_ratio": consistency_ratio,
        "classification_counts": dict(classification_counts),
        "hf_guard_present": hf_guard_present,
        "boundary_ambiguous": boundary_ambiguous,
        "majority_target_sr": majority_target_sr,
        "majority_target_count": majority_target_count,
        "segments_used": len(cutoffs),
        "segment_classifications": [str(sample.get("classification", "uncertain")) for sample in segment_samples],
        "segment_classification_reasons": [str(sample.get("classification_reason", "")) for sample in segment_samples],
    }


def collect_segment_channel_result(
    path: str,
    track_meta: TrackMeta,
    window_sec: float,
    thresh_rel_db: float,
    headroom_hz: int,
    channel_mode: str,
    decode_channels: int,
    starts: list[float],
    segment_duration: float,
    decoded_tracks: list[DecodedTrack] | None = None,
) -> tuple[dict[str, object], list[DecodedTrack]]:
    decoded_tracks = decoded_tracks or []
    segment_samples: list[dict[str, object]] = []
    windows_requested = 0
    windows_used = 0
    for idx, start_sec in enumerate(starts):
        if idx >= len(decoded_tracks):
            decoded_track = decode_segment_pcm(
                path,
                track_meta,
                start_sec,
                segment_duration,
                decode_channels,
            )
            if decoded_track is None:
                continue
            decoded_tracks.append(decoded_track)
        decoded_track = decoded_tracks[idx]
        result = analyze_cutoff_series_from_decoded(
            decoded_track,
            track_meta,
            window_sec,
            1,
            thresh_rel_db,
            channel_mode=channel_mode,
        )
        windows_requested += int(result.get("windows_requested", 0))
        windows_used += int(result.get("windows_used", 0))
        segment_samples.append(
            classify_segment_sample(
                result,
                track_meta,
                headroom_hz,
                segment_index=idx,
                source_start_sec=decoded_track.source_start_sec,
            )
        )
        summary = summarize_segment_samples(segment_samples, track_meta, headroom_hz)
        if summary["decision_confidence"] == "high" and len(segment_samples) >= min(SEGMENT_EARLY_ACCEPT_MIN, len(starts)):
            debug(
                f"segment early-exit track={os.path.basename(path)} mode={channel_mode} "
                f"segments={len(segment_samples)}/{len(starts)} reason={summary['decision_reason']}"
            )
            break

    summary = summarize_segment_samples(segment_samples, track_meta, headroom_hz)
    if debug_enabled():
        debug(
            f"segment-summary track={os.path.basename(path)} mode={channel_mode} "
            f"stat={summary['statistical_confidence']} decision={summary['decision_confidence']} "
            f"reason={summary['decision_reason']} classes={summary['classification_counts']} "
            f"consistency={summary['consistency_ratio']:.2f}"
        )
        for sample in segment_samples:
            debug(
                f"segment-sample track={os.path.basename(path)} mode={channel_mode} "
                f"idx={int(sample['segment_index']) + 1} start={sample['source_start_sec']:.2f}s "
                f"cutoff={sample.get('cutoff_hz')} class={sample['classification']} "
                f"hf={int(bool(sample.get('hf_present')))} reason={sample['classification_reason']}"
            )

    return (
        {
            "sr": track_meta.sr,
            "analysis_sr": track_meta.analysis_sr,
            "dur": track_meta.dur,
            "channel_mode": channel_mode,
            "cutoff_hz": summary["cutoff_hz"],
            "cutoffs_hz": summary["cutoffs_hz"],
            "windows_requested": windows_requested,
            "windows_used": windows_used,
            "segments_requested": len(segment_samples),
            "segments_budget": len(starts),
            "segments_used": summary["segments_used"],
            "confidence": summary["statistical_confidence"],
            "decision_confidence": summary["decision_confidence"],
            "decision_reason": summary["decision_reason"],
            "fallback_reason": summary["fallback_reason"],
            "allow_fake_upscale": summary["allow_fake_upscale"],
            "consistency_ratio": summary["consistency_ratio"],
            "segment_classifications": summary["segment_classifications"],
            "segment_classification_reasons": summary["segment_classification_reasons"],
            "hf_present": summary["hf_guard_present"],
            "classification_counts": summary["classification_counts"],
        },
        decoded_tracks,
    )


def select_track_analysis_from_decoded(
    decoded_track: DecodedTrack | None,
    track_meta: TrackMeta,
    window_sec: float,
    max_windows: int,
    thresh_rel_db: float,
    analysis_mode: str = FAST_ANALYSIS_MODE,
    analysis_strategy: str = ANALYSIS_STRATEGY_FULL,
) -> dict[str, object]:
    analysis_mode = normalize_analysis_mode(analysis_mode)
    requested_windows = effective_max_windows(max_windows, analysis_mode)

    mono_result = analyze_cutoff_series_from_decoded(
        decoded_track,
        track_meta,
        window_sec,
        requested_windows,
        thresh_rel_db,
        channel_mode="mono",
    )
    mono_result["confidence"] = analysis_confidence(
        mono_result["cutoffs_hz"],
        int(mono_result["windows_requested"]),
        analysis_strategy,
    )
    mono_result["decision_confidence"] = mono_result["confidence"]
    mono_result["decision_reason"] = (
        "accepted_by_consistency" if mono_result["confidence"] != "low" else "fallback_due_to_disagreement"
    )
    mono_result["fallback_reason"] = None if mono_result["confidence"] != "low" else "fallback_due_to_disagreement"
    mono_result["allow_fake_upscale"] = True

    series_results: list[dict[str, object]] = [mono_result]
    channel_cutoffs: dict[str, float | None] = {"mono": mono_result.get("cutoff_hz")}
    segments_requested = int(mono_result.get("segments_requested", 0))
    segments_used = int(mono_result.get("segments_used", 0))

    if analysis_mode == EXACT_ANALYSIS_MODE and (track_meta.channels or 0) >= 2:
        mono_low_confidence = mono_result["confidence"] == "low"
        if mono_low_confidence:
            for channel_mode in ("left", "right"):
                result = analyze_cutoff_series_from_decoded(
                    decoded_track,
                    track_meta,
                    window_sec,
                    requested_windows,
                    thresh_rel_db,
                    channel_mode=channel_mode,
                )
                result["confidence"] = analysis_confidence(
                    result["cutoffs_hz"],
                    int(result["windows_requested"]),
                    analysis_strategy,
                )
                result["decision_confidence"] = result["confidence"]
                result["decision_reason"] = (
                    "accepted_by_consistency" if result["confidence"] != "low" else "fallback_due_to_disagreement"
                )
                result["fallback_reason"] = None if result["confidence"] != "low" else "fallback_due_to_disagreement"
                result["allow_fake_upscale"] = True
                series_results.append(result)
                channel_cutoffs[channel_mode] = result.get("cutoff_hz")
                segments_requested = max(segments_requested, int(result.get("segments_requested", 0)))
                segments_used = max(segments_used, int(result.get("segments_used", 0)))
        else:
            channel_cutoffs["left"] = None
            channel_cutoffs["right"] = None

    valid_results = [result for result in series_results if result.get("cutoff_hz") is not None]
    if valid_results:
        selected = max(
            valid_results,
            key=lambda result: (
                confidence_rank(str(result.get("decision_confidence", result.get("confidence", "low")))),
                confidence_rank(str(result["confidence"])),
                int(result["windows_used"]),
                float(result["cutoff_hz"]),
            ),
        )
    else:
        selected = mono_result

    selected_cutoffs = [float(value) for value in selected.get("cutoffs_hz", [])]
    return {
        "sr": track_meta.sr,
        "analysis_sr": track_meta.analysis_sr,
        "dur": track_meta.dur,
        "cutoff_hz": selected.get("cutoff_hz"),
        "analysis_mode": analysis_mode,
        "analysis_strategy": analysis_strategy,
        "analysis_confidence": selected.get("decision_confidence", selected.get("confidence", "low")),
        "statistical_confidence": selected.get("confidence", "low"),
        "decision_confidence": selected.get("decision_confidence", selected.get("confidence", "low")),
        "decision_reason": selected.get("decision_reason", "accepted_by_consistency"),
        "fallback_reason": selected.get("fallback_reason"),
        "allow_fake_upscale": bool(selected.get("allow_fake_upscale", True)),
        "selected_channel": selected.get("channel_mode", "mono"),
        "windows_requested": selected.get("windows_requested", 0),
        "windows_used": selected.get("windows_used", 0),
        "window_cutoffs_hz": selected_cutoffs,
        "channel_cutoffs_hz": channel_cutoffs,
        "segments_requested": segments_requested,
        "segments_used": segments_used,
        "decode_operations": 1 if decoded_track is not None else 0,
    }


def select_track_analysis_from_segments(
    path: str,
    track_meta: TrackMeta,
    window_sec: float,
    thresh_rel_db: float,
    headroom_hz: int,
    decode_channels: int,
    analysis_mode: str = FAST_ANALYSIS_MODE,
    decoded_tracks: list[DecodedTrack] | None = None,
) -> tuple[dict[str, object], list[DecodedTrack]]:
    analysis_mode = normalize_analysis_mode(analysis_mode)
    segment_duration, starts = segment_starts_for_mode(track_meta.dur, window_sec, analysis_mode)
    decoded_tracks = decoded_tracks or []

    mono_result, decoded_tracks = collect_segment_channel_result(
        path,
        track_meta,
        window_sec,
        thresh_rel_db,
        headroom_hz,
        "mono",
        decode_channels,
        starts,
        segment_duration,
        decoded_tracks=decoded_tracks,
    )

    series_results: list[dict[str, object]] = [mono_result]
    channel_cutoffs: dict[str, float | None] = {"mono": mono_result.get("cutoff_hz")}
    segments_budget = int(mono_result.get("segments_budget", len(starts)))
    segments_requested = int(mono_result.get("segments_requested", 0))
    segments_used = int(mono_result.get("segments_used", 0))

    if analysis_mode == EXACT_ANALYSIS_MODE and (track_meta.channels or 0) >= 2:
        mono_low_confidence = mono_result.get("decision_confidence", mono_result.get("confidence", "low")) == "low"
        if mono_low_confidence:
            for channel_mode in ("left", "right"):
                result, decoded_tracks = collect_segment_channel_result(
                    path,
                    track_meta,
                    window_sec,
                    thresh_rel_db,
                    headroom_hz,
                    channel_mode,
                    decode_channels,
                    starts,
                    segment_duration,
                    decoded_tracks=decoded_tracks,
                )
                series_results.append(result)
                channel_cutoffs[channel_mode] = result.get("cutoff_hz")
                segments_budget = max(segments_budget, int(result.get("segments_budget", len(starts))))
                segments_requested = max(segments_requested, int(result.get("segments_requested", 0)))
                segments_used = max(segments_used, int(result.get("segments_used", 0)))
        else:
            channel_cutoffs["left"] = None
            channel_cutoffs["right"] = None

    valid_results = [result for result in series_results if result.get("cutoff_hz") is not None]
    if valid_results:
        selected = max(
            valid_results,
            key=lambda result: (
                confidence_rank(str(result.get("decision_confidence", result.get("confidence", "low")))),
                confidence_rank(str(result["confidence"])),
                int(result["windows_used"]),
                float(result["cutoff_hz"]),
            ),
        )
    else:
        selected = mono_result

    selected_cutoffs = [float(value) for value in selected.get("cutoffs_hz", [])]
    return (
        {
            "sr": track_meta.sr,
            "analysis_sr": track_meta.analysis_sr,
            "dur": track_meta.dur,
            "cutoff_hz": selected.get("cutoff_hz"),
            "analysis_mode": analysis_mode,
            "analysis_strategy": ANALYSIS_STRATEGY_SEGMENT,
            "analysis_confidence": selected.get("decision_confidence", selected.get("confidence", "low")),
            "statistical_confidence": selected.get("confidence", "low"),
            "decision_confidence": selected.get("decision_confidence", selected.get("confidence", "low")),
            "decision_reason": selected.get("decision_reason", "accepted_by_consistency"),
            "fallback_reason": selected.get("fallback_reason"),
            "allow_fake_upscale": bool(selected.get("allow_fake_upscale", True)),
            "selected_channel": selected.get("channel_mode", "mono"),
            "windows_requested": selected.get("windows_requested", 0),
            "windows_used": selected.get("windows_used", 0),
            "window_cutoffs_hz": selected_cutoffs,
            "channel_cutoffs_hz": channel_cutoffs,
            "segments_requested": segments_requested,
            "segments_budget": segments_budget,
            "segments_used": segments_used,
            "segment_classifications": selected.get("segment_classifications", []),
            "segment_classification_reasons": selected.get("segment_classification_reasons", []),
            "consistency_ratio": selected.get("consistency_ratio"),
            "decode_operations": len(decoded_tracks),
        },
        decoded_tracks,
    )


def cleanup_decoded_tracks(decoded_tracks: list[DecodedTrack]) -> None:
    for decoded_track in decoded_tracks:
        cleanup_decoded_track(decoded_track)


def decode_channels_for_mode(requested_analysis_mode: str, channels: int | None) -> int:
    if normalize_analysis_mode(requested_analysis_mode) in {AUTO_ANALYSIS_MODE, EXACT_ANALYSIS_MODE} and (channels or 0) >= 2:
        return 2
    return 1


def should_segment_fallback_to_full(track_analysis: dict[str, object]) -> bool:
    return str(track_analysis.get("decision_confidence", track_analysis.get("analysis_confidence", "low"))) == "low"


def analyze_track(
    path: str,
    headroom_hz: int,
    window_sec: float,
    max_windows: int,
    thresh_rel_db: float,
    requested_analysis_mode: str,
) -> tuple[TrackMeta, dict[str, object], str, bool]:
    track_meta = audio_meta(path)
    strategy, strategy_reason = choose_analysis_strategy(path, track_meta)
    decode_channels = decode_channels_for_mode(requested_analysis_mode, track_meta.channels)

    debug(
        f"strategy track={os.path.basename(path)} strategy={strategy} reason={strategy_reason} "
        f"codec={track_meta.codec or 'unknown'} size={track_meta.size_bytes} dur={track_meta.dur}"
    )

    effective_analysis_mode = normalize_analysis_mode(requested_analysis_mode)
    auto_exact_fallback = False
    strategy_fallback_to_full = False
    track_analysis: dict[str, object]

    if strategy == ANALYSIS_STRATEGY_SEGMENT:
        fast_decodes: list[DecodedTrack] = []
        exact_decodes: list[DecodedTrack] = []
        segment_probe_analysis: dict[str, object] | None = None
        try:
            normalized_mode = normalize_analysis_mode(requested_analysis_mode)
            if normalized_mode == AUTO_ANALYSIS_MODE:
                track_analysis, fast_decodes = select_track_analysis_from_segments(
                    path,
                    track_meta,
                    window_sec,
                    thresh_rel_db,
                    headroom_hz,
                    decode_channels,
                    analysis_mode=FAST_ANALYSIS_MODE,
                )
                effective_analysis_mode = FAST_ANALYSIS_MODE
            elif normalized_mode == EXACT_ANALYSIS_MODE:
                track_analysis = {
                    "analysis_confidence": "low",
                    "decision_confidence": "low",
                    "decision_reason": "fallback_due_to_disagreement",
                }
            else:
                track_analysis, fast_decodes = select_track_analysis_from_segments(
                    path,
                    track_meta,
                    window_sec,
                    thresh_rel_db,
                    headroom_hz,
                    decode_channels,
                    analysis_mode=FAST_ANALYSIS_MODE,
                )
                effective_analysis_mode = FAST_ANALYSIS_MODE

            if normalized_mode == AUTO_ANALYSIS_MODE and track_analysis.get("decision_confidence", track_analysis["analysis_confidence"]) == "low":
                auto_exact_fallback = True
                effective_analysis_mode = EXACT_ANALYSIS_MODE
                track_analysis, exact_decodes = select_track_analysis_from_segments(
                    path,
                    track_meta,
                    window_sec,
                    thresh_rel_db,
                    headroom_hz,
                    decode_channels,
                    analysis_mode=EXACT_ANALYSIS_MODE,
                    decoded_tracks=fast_decodes,
                )
            elif normalized_mode == EXACT_ANALYSIS_MODE:
                effective_analysis_mode = EXACT_ANALYSIS_MODE
                track_analysis, exact_decodes = select_track_analysis_from_segments(
                    path,
                    track_meta,
                    window_sec,
                    thresh_rel_db,
                    headroom_hz,
                    decode_channels,
                    analysis_mode=EXACT_ANALYSIS_MODE,
                )

            segment_probe_analysis = dict(track_analysis)
            if effective_analysis_mode == EXACT_ANALYSIS_MODE and should_segment_fallback_to_full(track_analysis):
                full_decoded = decode_track_pcm(path, track_meta, window_sec, decode_channels)
                try:
                    full_analysis = select_track_analysis_from_decoded(
                        full_decoded,
                        track_meta,
                        window_sec,
                        max_windows,
                        thresh_rel_db,
                        analysis_mode=EXACT_ANALYSIS_MODE,
                        analysis_strategy=ANALYSIS_STRATEGY_FULL,
                    )
                finally:
                    cleanup_decoded_track(full_decoded)
                full_analysis["decode_operations"] = int(full_analysis.get("decode_operations", 0)) + len(exact_decodes or fast_decodes)
                full_analysis["segments_requested"] = int(segment_probe_analysis.get("segments_requested", 0))
                full_analysis["segments_budget"] = int(segment_probe_analysis.get("segments_budget", segment_probe_analysis.get("segments_requested", 0)))
                full_analysis["segments_used"] = int(segment_probe_analysis.get("segments_used", 0))
                full_analysis["allow_fake_upscale"] = bool(full_analysis.get("allow_fake_upscale", True)) and bool(
                    segment_probe_analysis.get("allow_fake_upscale", True)
                )
                full_analysis["strategy_fallback_to_full"] = True
                full_analysis["analysis_strategy_reason"] = strategy_reason
                full_analysis["initial_analysis_strategy"] = strategy
                full_analysis["segment_probe_analysis_mode"] = str(segment_probe_analysis.get("analysis_mode", effective_analysis_mode))
                full_analysis["segment_probe_analysis_confidence"] = str(
                    segment_probe_analysis.get("analysis_confidence", "low")
                )
                full_analysis["segment_probe_statistical_confidence"] = str(
                    segment_probe_analysis.get("statistical_confidence", segment_probe_analysis.get("analysis_confidence", "low"))
                )
                full_analysis["segment_probe_decision_confidence"] = str(
                    segment_probe_analysis.get("decision_confidence", segment_probe_analysis.get("analysis_confidence", "low"))
                )
                full_analysis["segment_probe_decision_reason"] = str(
                    segment_probe_analysis.get("decision_reason", "fallback_due_to_disagreement")
                )
                full_analysis["segment_probe_fallback_reason"] = segment_probe_analysis.get("fallback_reason")
                full_analysis["segment_probe_selected_channel"] = str(
                    segment_probe_analysis.get("selected_channel", "mono")
                )
                full_analysis["segment_probe_cutoff_hz"] = segment_probe_analysis.get("cutoff_hz")
                full_analysis["segment_probe_windows_requested"] = int(
                    segment_probe_analysis.get("windows_requested", 0)
                )
                full_analysis["segment_probe_windows_used"] = int(segment_probe_analysis.get("windows_used", 0))
                full_analysis["segment_probe_window_cutoffs_hz"] = list(
                    segment_probe_analysis.get("window_cutoffs_hz", [])
                )
                full_analysis["segment_probe_channel_cutoffs_hz"] = dict(
                    segment_probe_analysis.get("channel_cutoffs_hz", {})
                )
                full_analysis["segment_probe_segments_requested"] = int(
                    segment_probe_analysis.get("segments_requested", 0)
                )
                full_analysis["segment_probe_segments_budget"] = int(
                    segment_probe_analysis.get("segments_budget", segment_probe_analysis.get("segments_requested", 0))
                )
                full_analysis["segment_probe_segments_used"] = int(
                    segment_probe_analysis.get("segments_used", 0)
                )
                full_analysis["segment_probe_decode_operations"] = len(exact_decodes or fast_decodes)
                full_analysis["segment_probe_consistency_ratio"] = segment_probe_analysis.get("consistency_ratio")
                full_analysis["segment_probe_classifications"] = list(
                    segment_probe_analysis.get("segment_classifications", [])
                )
                full_analysis["segment_probe_classification_reasons"] = list(
                    segment_probe_analysis.get("segment_classification_reasons", [])
                )
                track_analysis = full_analysis
                strategy_fallback_to_full = True
                debug(f"strategy-fallback track={os.path.basename(path)} from=segment to=full")
            else:
                track_analysis["strategy_fallback_to_full"] = False
                track_analysis["analysis_strategy_reason"] = strategy_reason
                track_analysis["initial_analysis_strategy"] = strategy

            return track_meta, track_analysis, effective_analysis_mode, auto_exact_fallback
        finally:
            cleanup_decoded_tracks(exact_decodes)
            cleanup_decoded_tracks(fast_decodes)

    decoded_track = decode_track_pcm(path, track_meta, window_sec, decode_channels)
    try:
        if normalize_analysis_mode(requested_analysis_mode) == AUTO_ANALYSIS_MODE:
            track_analysis = select_track_analysis_from_decoded(
                decoded_track,
                track_meta,
                window_sec,
                max_windows,
                thresh_rel_db,
                analysis_mode=FAST_ANALYSIS_MODE,
                analysis_strategy=ANALYSIS_STRATEGY_FAST,
            )
            if track_analysis["analysis_confidence"] == "low":
                auto_exact_fallback = True
                effective_analysis_mode = EXACT_ANALYSIS_MODE
                track_analysis = select_track_analysis_from_decoded(
                    decoded_track,
                    track_meta,
                    window_sec,
                    max_windows,
                    thresh_rel_db,
                    analysis_mode=EXACT_ANALYSIS_MODE,
                    analysis_strategy=ANALYSIS_STRATEGY_FAST,
                )
            else:
                effective_analysis_mode = FAST_ANALYSIS_MODE
        else:
            effective_analysis_mode = normalize_analysis_mode(requested_analysis_mode)
            track_analysis = select_track_analysis_from_decoded(
                decoded_track,
                track_meta,
                window_sec,
                max_windows,
                thresh_rel_db,
                analysis_mode=effective_analysis_mode,
                analysis_strategy=ANALYSIS_STRATEGY_FAST,
            )

        track_analysis["strategy_fallback_to_full"] = False
        track_analysis["analysis_strategy_reason"] = strategy_reason
        track_analysis["initial_analysis_strategy"] = strategy
        return track_meta, track_analysis, effective_analysis_mode, auto_exact_fallback
    finally:
        cleanup_decoded_track(decoded_track)


def source_family_sr(sr_in: float | int | None) -> int | None:
    if sr_in is None:
        return None
    sr = int(round(float(sr_in)))
    if sr <= 0:
        return None
    if sr % STUDIO_48_FAMILY_SR_HZ == 0:
        return STUDIO_48_FAMILY_SR_HZ
    if sr % CD_FAMILY_SR_HZ == 0:
        return CD_FAMILY_SR_HZ
    return None


def consistent_album_family_sr(tracks: list[dict[str, object]]) -> int | None:
    families = sorted(
        {
            int(track["standard_family_sr"])
            for track in tracks
            if track.get("standard_family_sr") is not None
        }
    )
    return families[0] if len(families) == 1 else None


def effective_cutoff_hz(cutoff_hz: float | None, headroom_hz: int) -> float | None:
    if cutoff_hz is None:
        return None
    return max(0.0, float(cutoff_hz) + float(headroom_hz))


def family_target_ladder_hz(family_sr: int | None) -> tuple[int, ...]:
    if family_sr == CD_FAMILY_SR_HZ:
        return CD_FAMILY_TARGETS_HZ
    if family_sr == STUDIO_48_FAMILY_SR_HZ:
        return STUDIO_48_FAMILY_TARGETS_HZ
    return ()


def should_guard_low_confidence_downgrade(
    decision_confidence: str | None,
    decision_reason: str | None,
    fallback_reason: object | None,
) -> bool:
    if decision_confidence != "low":
        return False
    reasons = {
        str(decision_reason or "").strip(),
        str(fallback_reason or "").strip(),
    }
    return any(
        reason in {
            "fallback_due_to_disagreement",
            "fallback_due_to_family_inconsistency",
            "fallback_due_to_boundary_ambiguity",
        }
        for reason in reasons
        if reason
    )


def should_guard_same_family_rung_downgrade(
    effective_hz: float | None,
    source_sr: int,
    source_family: int | None,
    standard_family: int | None,
    selected_target_sr: int | None,
) -> bool:
    if effective_hz is None or selected_target_sr is None:
        return False
    if source_family is None or standard_family is None or source_family != standard_family:
        return False
    if selected_target_sr >= source_sr:
        return False
    ceiling_candidates = family_target_ladder_hz(source_family)
    if not ceiling_candidates:
        return False
    family_ceiling_sr = int(ceiling_candidates[-1])
    if source_sr > family_ceiling_sr:
        return False
    target_nyquist_hz = float(selected_target_sr) / 2.0
    if target_nyquist_hz <= 0:
        return False
    return (float(effective_hz) / target_nyquist_hz) < SAME_FAMILY_DOWNGRADE_MIN_RATIO


def classify_standard_family_sr(cutoff_hz: float | None, sr_in: float, headroom_hz: int) -> int | None:
    effective = effective_cutoff_hz(cutoff_hz, headroom_hz)
    if effective is None:
        return None
    source_family = source_family_sr(sr_in)
    if source_family == STUDIO_48_FAMILY_SR_HZ and effective >= (STUDIO_48_NYQUIST_HZ * NEAR_48_FAMILY_RATIO) and effective <= STUDIO_48_NYQUIST_HZ:
        return STUDIO_48_FAMILY_SR_HZ
    if effective <= CD_NYQUIST_HZ:
        return CD_FAMILY_SR_HZ
    if effective <= STUDIO_48_NYQUIST_HZ:
        return STUDIO_48_FAMILY_SR_HZ
    if source_family in {CD_FAMILY_SR_HZ, STUDIO_48_FAMILY_SR_HZ}:
        return source_family
    return None


def classify_family_target_sr(cutoff_hz: float | None, sr_in: float, headroom_hz: int) -> int | None:
    effective = effective_cutoff_hz(cutoff_hz, headroom_hz)
    family_sr = classify_standard_family_sr(cutoff_hz, sr_in, headroom_hz)
    if effective is None or family_sr is None:
        return None

    for target_sr in family_target_ladder_hz(int(family_sr)):
        nyquist_hz = float(target_sr) / 2.0
        if family_sr == STUDIO_48_FAMILY_SR_HZ and target_sr == STUDIO_48_FAMILY_SR_HZ:
            if effective >= (STUDIO_48_NYQUIST_HZ * NEAR_48_FAMILY_RATIO) and effective <= STUDIO_48_NYQUIST_HZ:
                return int(target_sr)
        if effective <= nyquist_hz:
            return int(target_sr)
    return None


def resolve_recode_decision(
    cutoff_hz: float | None,
    sr_in: float,
    headroom_hz: int,
    decision_context: dict[str, object] | None = None,
) -> dict[str, object]:
    source_sr = int(sr_in)
    source_family = source_family_sr(source_sr)
    ceiling_candidates = family_target_ladder_hz(source_family)
    family_ceiling_sr = int(ceiling_candidates[-1]) if ceiling_candidates else None
    standard_family = classify_standard_family_sr(cutoff_hz, source_sr, headroom_hz)
    effective = effective_cutoff_hz(cutoff_hz, headroom_hz)
    selected_target_sr = classify_family_target_sr(cutoff_hz, source_sr, headroom_hz)
    fake_upscale = bool(selected_target_sr is not None and source_sr > selected_target_sr)
    target_sr = int(selected_target_sr) if fake_upscale and selected_target_sr is not None else source_sr
    decision = "keep_source"
    decision_confidence = None
    decision_reason = None
    fallback_reason = None
    downgrade_guarded = False

    if decision_context is not None:
        decision_confidence = str(decision_context.get("decision_confidence", "")).strip() or None
        decision_reason = str(decision_context.get("decision_reason", "")).strip() or None
        fallback_reason = decision_context.get("fallback_reason")

    if fake_upscale:
        allow_fake_upscale = True if decision_context is None else bool(decision_context.get("allow_fake_upscale", True))
        if should_guard_low_confidence_downgrade(decision_confidence, decision_reason, fallback_reason):
            allow_fake_upscale = False
            downgrade_guarded = True
            standard_family = source_family
            if decision_reason in {None, "", "fallback_due_to_disagreement", "fallback_due_to_family_inconsistency", "fallback_due_to_boundary_ambiguity"}:
                decision_reason = "guard_low_confidence_downgrade"
        elif should_guard_same_family_rung_downgrade(effective, source_sr, source_family, standard_family, selected_target_sr):
            allow_fake_upscale = False
            downgrade_guarded = True
            standard_family = source_family
            if decision_reason in {None, ""}:
                decision_reason = "guard_same_family_midband_rolloff"
        if allow_fake_upscale:
            decision = "downgrade_fake_upscale"
        else:
            fake_upscale = False
            target_sr = source_sr
            downgrade_guarded = True
    if family_ceiling_sr is not None and target_sr > family_ceiling_sr:
        target_sr = family_ceiling_sr
        if decision != "downgrade_fake_upscale":
            decision = "cap_highres_ceiling"

    return {
        "source_sr": source_sr,
        "source_family_sr": source_family,
        "standard_family_sr": standard_family,
        "effective_cutoff_hz": effective,
        "fake_upscale": fake_upscale,
        "target_sr": target_sr,
        "decision": decision,
        "decision_confidence": decision_confidence,
        "decision_reason": decision_reason,
        "fallback_reason": fallback_reason,
        "downgrade_guarded": downgrade_guarded,
    }


def map_to_target_sr(cutoff_hz: float | None, sr_in: float, headroom_hz: int) -> int:
    return int(resolve_recode_decision(cutoff_hz, sr_in, headroom_hz)["target_sr"])


def cmd_analyze(argv: list[str]) -> int:
    if len(argv) < 5:
        print(usage(), file=sys.stderr)
        return 2

    headroom_hz = int(argv[0])
    thresh_rel_db = float(argv[1])
    window_sec = float(argv[2])
    max_windows = int(argv[3])
    analysis_mode = AUTO_ANALYSIS_MODE
    files = argv[4:]
    if files and files[0] in {AUTO_ANALYSIS_MODE, FAST_ANALYSIS_MODE, EXACT_ANALYSIS_MODE}:
        analysis_mode = normalize_analysis_mode(files[0])
        files = files[1:]
    if not files:
        print(usage(), file=sys.stderr)
        return 2

    requested_analysis_mode = analysis_mode
    track_results: list[tuple[str, TrackMeta, dict[str, object], str, bool]] = []
    for path in files:
        track_meta, track_analysis, effective_analysis_mode, auto_exact_fallback = analyze_track(
            path,
            headroom_hz,
            window_sec,
            max_windows,
            thresh_rel_db,
            requested_analysis_mode,
        )
        track_results.append((path, track_meta, track_analysis, effective_analysis_mode, auto_exact_fallback))

    tracks = []
    for path, track_meta, track_analysis, effective_analysis_mode, auto_exact_fallback in track_results:
        sr_in = track_meta.sr
        bits_in = track_meta.bits
        cutoff = track_analysis["cutoff_hz"]
        if sr_in is None:
            continue
        decision = resolve_recode_decision(cutoff, sr_in, headroom_hz, track_analysis)
        tracks.append(
            {
                "file": path,
                "sr_in": int(sr_in) if sr_in else None,
                "bits_in": int(bits_in) if bits_in else None,
                "channels_in": int(track_meta.channels) if track_meta.channels else None,
                "requested_analysis_mode": requested_analysis_mode,
                "analysis_mode": effective_analysis_mode,
                "auto_exact_fallback": auto_exact_fallback,
                "analysis_strategy": track_analysis.get("analysis_strategy", ANALYSIS_STRATEGY_FAST),
                "analysis_strategy_reason": track_analysis.get("analysis_strategy_reason", ""),
                "initial_analysis_strategy": track_analysis.get("initial_analysis_strategy", track_analysis.get("analysis_strategy", ANALYSIS_STRATEGY_FAST)),
                "strategy_fallback_to_full": bool(track_analysis.get("strategy_fallback_to_full")),
                "analysis_confidence": track_analysis["analysis_confidence"],
                "statistical_confidence": track_analysis.get("statistical_confidence", track_analysis["analysis_confidence"]),
                "decision_confidence": track_analysis.get("decision_confidence", track_analysis["analysis_confidence"]),
                "decision_reason": track_analysis.get("decision_reason"),
                "fallback_reason": track_analysis.get("fallback_reason"),
                "selected_channel": track_analysis["selected_channel"],
                "windows_requested": int(track_analysis["windows_requested"]),
                "windows_used": int(track_analysis["windows_used"]),
                "window_cutoffs_hz": track_analysis["window_cutoffs_hz"],
                "channel_cutoffs_hz": track_analysis["channel_cutoffs_hz"],
                "segments_requested": int(track_analysis.get("segments_requested", 0)),
                "segments_budget": (
                    int(track_analysis["segments_budget"]) if track_analysis.get("segments_budget") is not None else None
                ),
                "segments_used": int(track_analysis.get("segments_used", 0)),
                "segment_classifications": track_analysis.get("segment_classifications"),
                "segment_classification_reasons": track_analysis.get("segment_classification_reasons"),
                "consistency_ratio": track_analysis.get("consistency_ratio"),
                "decode_operations": int(track_analysis.get("decode_operations", 0)),
                "segment_probe_analysis_mode": track_analysis.get("segment_probe_analysis_mode"),
                "segment_probe_analysis_confidence": track_analysis.get("segment_probe_analysis_confidence"),
                "segment_probe_statistical_confidence": track_analysis.get("segment_probe_statistical_confidence"),
                "segment_probe_decision_confidence": track_analysis.get("segment_probe_decision_confidence"),
                "segment_probe_decision_reason": track_analysis.get("segment_probe_decision_reason"),
                "segment_probe_fallback_reason": track_analysis.get("segment_probe_fallback_reason"),
                "segment_probe_selected_channel": track_analysis.get("segment_probe_selected_channel"),
                "segment_probe_cutoff_hz": track_analysis.get("segment_probe_cutoff_hz"),
                "segment_probe_windows_requested": (
                    int(track_analysis["segment_probe_windows_requested"])
                    if track_analysis.get("segment_probe_windows_requested") is not None
                    else None
                ),
                "segment_probe_windows_used": (
                    int(track_analysis["segment_probe_windows_used"])
                    if track_analysis.get("segment_probe_windows_used") is not None
                    else None
                ),
                "segment_probe_window_cutoffs_hz": track_analysis.get("segment_probe_window_cutoffs_hz"),
                "segment_probe_channel_cutoffs_hz": track_analysis.get("segment_probe_channel_cutoffs_hz"),
                "segment_probe_segments_requested": (
                    int(track_analysis["segment_probe_segments_requested"])
                    if track_analysis.get("segment_probe_segments_requested") is not None
                    else None
                ),
                "segment_probe_segments_budget": (
                    int(track_analysis["segment_probe_segments_budget"])
                    if track_analysis.get("segment_probe_segments_budget") is not None
                    else None
                ),
                "segment_probe_segments_used": (
                    int(track_analysis["segment_probe_segments_used"])
                    if track_analysis.get("segment_probe_segments_used") is not None
                    else None
                ),
                "segment_probe_decode_operations": (
                    int(track_analysis["segment_probe_decode_operations"])
                    if track_analysis.get("segment_probe_decode_operations") is not None
                    else None
                ),
                "segment_probe_consistency_ratio": track_analysis.get("segment_probe_consistency_ratio"),
                "segment_probe_classifications": track_analysis.get("segment_probe_classifications"),
                "segment_probe_classification_reasons": track_analysis.get("segment_probe_classification_reasons"),
                "cutoff_hz": cutoff,
                "effective_cutoff_hz": decision["effective_cutoff_hz"],
                "source_family_sr": decision["source_family_sr"],
                "standard_family_sr": decision["standard_family_sr"],
                "fake_upscale": decision["fake_upscale"],
                "tgt_sr": decision["target_sr"],
                "decision": decision["decision"],
                "downgrade_guarded": decision["downgrade_guarded"],
            }
        )

    if not tracks:
        print(json.dumps({"error": "no_tracks"}))
        return 0

    album_sr = max(track["tgt_sr"] for track in tracks if track["tgt_sr"] is not None)
    album_confidence = min(
        (track["analysis_confidence"] for track in tracks),
        key=confidence_rank,
    )
    fake_track_families = sorted(
        {
            int(track["standard_family_sr"])
            for track in tracks
            if track.get("fake_upscale") and track.get("standard_family_sr") is not None
        }
    )
    album_has_fake_upscale_tracks = any(bool(track.get("fake_upscale")) for track in tracks)
    album_fake_upscale = album_has_fake_upscale_tracks
    album_family_sr = consistent_album_family_sr(tracks)
    album_decision = "keep_source"
    if any(track.get("decision") == "downgrade_fake_upscale" for track in tracks):
        album_decision = "downgrade_fake_upscale"
    elif any(track.get("decision") == "cap_highres_ceiling" for track in tracks):
        album_decision = "cap_highres_ceiling"
    bits_list = [track["bits_in"] for track in tracks if track["bits_in"]]
    album_bits = 24
    if bits_list:
        album_bits = min(24, max(bits_list))
        album_bits = 16 if album_bits < 16 else album_bits
    album_analysis_mode = EXACT_ANALYSIS_MODE if any(track["analysis_mode"] == EXACT_ANALYSIS_MODE for track in tracks) else FAST_ANALYSIS_MODE
    album_auto_exact_fallback = any(bool(track["auto_exact_fallback"]) for track in tracks)
    album_strategy_fallback_to_full = any(bool(track.get("strategy_fallback_to_full")) for track in tracks)
    album_analysis_strategies = sorted({str(track.get("analysis_strategy", ANALYSIS_STRATEGY_FAST)) for track in tracks})

    print(
        json.dumps(
            {
                "requested_analysis_mode": requested_analysis_mode,
                "analysis_mode": album_analysis_mode,
                "auto_exact_fallback": album_auto_exact_fallback,
                "album_confidence": album_confidence,
                "album_sr": int(album_sr),
                "album_bits": int(album_bits),
                "album_fake_upscale": album_fake_upscale,
                "album_has_fake_upscale_tracks": album_has_fake_upscale_tracks,
                "album_family_sr": int(album_family_sr) if album_family_sr is not None else None,
                "album_decision": album_decision,
                "album_analysis_strategies": album_analysis_strategies,
                "album_strategy_fallback_to_full": album_strategy_fallback_to_full,
                "tracks": tracks,
            }
        )
    )
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print(usage(), file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "source-fingerprint":
        return cmd_source_fingerprint(rest)
    if cmd == "config-fingerprint":
        return cmd_config_fingerprint(rest)
    if cmd == "analyze":
        return cmd_analyze(rest)
    print(usage(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
