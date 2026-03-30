#!/usr/bin/env python3
"""Helper routines for bin/audlint-analyze.sh."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
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
CD_FAMILY_SR_HZ = 44100
STUDIO_48_FAMILY_SR_HZ = 48000
CD_NYQUIST_HZ = 22050.0
STUDIO_48_NYQUIST_HZ = 24000.0
NEAR_48_FAMILY_RATIO = 0.88
CD_FAMILY_TARGETS_HZ = (44100, 88200, 176400)
STUDIO_48_FAMILY_TARGETS_HZ = (48000, 96000, 192000)
EXACT_MIN_WINDOWS = 24
EXACT_WINDOW_MULTIPLIER = 2
MAX_ANALYSIS_SR_HZ = 192000
PCM_BYTES_PER_SAMPLE = 4


@dataclass(frozen=True)
class TrackMeta:
    sr: float | None
    dur: float | None
    bits: int | None
    channels: int | None
    analysis_sr: int | None
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


def prefer_ffmpeg_decode(path: str, soxi_duration: float | None) -> bool:
    if not HAS_FFMPEG:
        return False
    suffix = os.path.splitext(path)[1].lower()
    if suffix == ".ape":
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
    if codec.startswith("dsd") and (bits is None or bits < 24):
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
    channels = parse_positive_int(meta.get("channels"))
    if channels is None:
        channels = parse_positive_int(str(ffprobe_stream(path, "channels") or ""))
    analysis_sr = capped_analysis_sample_rate(sr)
    return TrackMeta(
        sr=sr,
        dur=dur,
        bits=bits,
        channels=channels,
        analysis_sr=analysis_sr,
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


def decode_track_pcm(
    path: str,
    track_meta: TrackMeta,
    window_sec: float,
    decode_channels: int,
) -> DecodedTrack | None:
    analysis_sr = track_meta.analysis_sr
    if analysis_sr is None or analysis_sr <= 0:
        return None

    decode_channels = 2 if decode_channels >= 2 else 1
    timeout_sec = decode_timeout_sec(window_sec, track_meta.dur)

    ffmpeg_cmd = [
        "ffmpeg",
        "-v",
        "error",
        "-i",
        path,
    ]
    if decode_channels >= 2:
        ffmpeg_cmd.extend(["-filter:a", "pan=stereo|c0=c0|c1=c1", "-ac", "2"])
    else:
        ffmpeg_cmd.extend(["-ac", "1"])
    ffmpeg_cmd.extend(["-ar", str(int(analysis_sr)), "-f", "f32le", "-"])

    sox_cmd = ["sox", path, "-t", "f32", "-c", str(decode_channels), "-r", str(int(analysis_sr)), "-"]
    if decode_channels >= 2:
        sox_cmd.extend(["remix", "1", "2"])

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
                f"analysis_sr={analysis_sr} channels={decode_channels} frames={frames}"
            )
        return DecodedTrack(
            path=path,
            pcm_path=pcm_path,
            source_sr=track_meta.sr,
            analysis_sr=int(analysis_sr),
            dur=track_meta.dur,
            channels=decode_channels,
            frames=frames,
        )
    return None


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
    dur = track_meta.dur
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
        }

    frame_shape = (decoded_track.frames, decoded_track.channels)
    pcm = np.memmap(decoded_track.pcm_path, dtype=np.float32, mode="r", shape=frame_shape)
    window_frames = max(1, int(round(window_sec * analysis_sr)))
    min_frames = max(1, int(analysis_sr))
    cutoffs: list[float] = []

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
            db = 20.0 * np.log10(np.maximum(mag / peak, 1e-12))
            idx = (db >= thresh_rel_db).nonzero()[0]
            if idx.size == 0:
                continue
            k = int(idx.max())
            freq = (k / (mag.size - 1)) * (analysis_sr / 2.0)
            cutoffs.append(float(freq))
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


def analysis_confidence(cutoffs_hz: list[float], windows_requested: int) -> str:
    if not cutoffs_hz:
        return "low"
    windows_used = len(cutoffs_hz)
    if windows_used < min(3, max(1, windows_requested)):
        return "low"
    if windows_used < 3:
        return "low"
    median_cutoff = statistics.median(cutoffs_hz)
    if median_cutoff <= 0:
        return "low"
    spread_hz = max(cutoffs_hz) - min(cutoffs_hz)
    spread_ratio = spread_hz / max(float(median_cutoff), 1.0)
    if windows_used >= 8 and spread_ratio <= 0.12:
        return "high"
    if windows_used >= 5 and spread_ratio <= 0.25:
        return "medium"
    return "low"


def select_track_analysis_from_decoded(
    decoded_track: DecodedTrack | None,
    track_meta: TrackMeta,
    window_sec: float,
    max_windows: int,
    thresh_rel_db: float,
    analysis_mode: str = FAST_ANALYSIS_MODE,
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
    mono_result["confidence"] = analysis_confidence(mono_result["cutoffs_hz"], int(mono_result["windows_requested"]))

    series_results: list[dict[str, object]] = [mono_result]
    channel_cutoffs: dict[str, float | None] = {"mono": mono_result.get("cutoff_hz")}

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
                result["confidence"] = analysis_confidence(result["cutoffs_hz"], int(result["windows_requested"]))
                series_results.append(result)
                channel_cutoffs[channel_mode] = result.get("cutoff_hz")
        else:
            channel_cutoffs["left"] = None
            channel_cutoffs["right"] = None

    valid_results = [result for result in series_results if result.get("cutoff_hz") is not None]
    if valid_results:
        selected = max(
            valid_results,
            key=lambda result: (
                float(result["cutoff_hz"]),
                confidence_rank(str(result["confidence"])),
                int(result["windows_used"]),
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
        "analysis_confidence": selected.get("confidence", "low"),
        "selected_channel": selected.get("channel_mode", "mono"),
        "windows_requested": selected.get("windows_requested", 0),
        "windows_used": selected.get("windows_used", 0),
        "window_cutoffs_hz": selected_cutoffs,
        "channel_cutoffs_hz": channel_cutoffs,
    }


def select_track_analysis(
    path: str,
    window_sec: float,
    max_windows: int,
    thresh_rel_db: float,
    track_meta: TrackMeta | None = None,
    analysis_mode: str = FAST_ANALYSIS_MODE,
) -> dict[str, object]:
    track_meta = track_meta or audio_meta(path)
    decode_channels = 1
    if normalize_analysis_mode(analysis_mode) in {AUTO_ANALYSIS_MODE, EXACT_ANALYSIS_MODE} and (track_meta.channels or 0) >= 2:
        decode_channels = 2
    decoded_track = decode_track_pcm(path, track_meta, window_sec, decode_channels)
    try:
        return select_track_analysis_from_decoded(
            decoded_track,
            track_meta,
            window_sec,
            max_windows,
            thresh_rel_db,
            analysis_mode=analysis_mode,
        )
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


def resolve_recode_decision(cutoff_hz: float | None, sr_in: float, headroom_hz: int) -> dict[str, object]:
    source_sr = int(sr_in)
    source_family = source_family_sr(source_sr)
    standard_family = classify_standard_family_sr(cutoff_hz, source_sr, headroom_hz)
    effective = effective_cutoff_hz(cutoff_hz, headroom_hz)
    selected_target_sr = classify_family_target_sr(cutoff_hz, source_sr, headroom_hz)
    fake_upscale = bool(selected_target_sr is not None and source_sr > selected_target_sr)
    target_sr = int(selected_target_sr) if fake_upscale and selected_target_sr is not None else source_sr
    decision = "keep_source"

    if fake_upscale:
        decision = "downgrade_fake_upscale"
    else:
        ceiling_candidates = family_target_ladder_hz(source_family)
        if ceiling_candidates:
            family_ceiling_sr = int(ceiling_candidates[-1])
            if source_sr > family_ceiling_sr:
                target_sr = family_ceiling_sr
                decision = "cap_highres_ceiling"

    return {
        "source_sr": source_sr,
        "source_family_sr": source_family,
        "standard_family_sr": standard_family,
        "effective_cutoff_hz": effective,
        "fake_upscale": fake_upscale,
        "target_sr": target_sr,
        "decision": decision,
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
    effective_analysis_mode = analysis_mode

    prepared_tracks: list[tuple[str, TrackMeta, DecodedTrack | None]] = []
    try:
        for path in files:
            track_meta = audio_meta(path)
            decode_channels = 1
            if requested_analysis_mode in {AUTO_ANALYSIS_MODE, EXACT_ANALYSIS_MODE} and (track_meta.channels or 0) >= 2:
                decode_channels = 2
            decoded_track = decode_track_pcm(path, track_meta, window_sec, decode_channels)
            prepared_tracks.append((path, track_meta, decoded_track))

        track_analyses: list[tuple[str, TrackMeta, dict[str, object]]] = []
        if requested_analysis_mode == AUTO_ANALYSIS_MODE:
            fast_track_analyses: list[tuple[str, TrackMeta, dict[str, object]]] = []
            for path, track_meta, decoded_track in prepared_tracks:
                track_analysis = select_track_analysis_from_decoded(
                    decoded_track,
                    track_meta,
                    window_sec,
                    max_windows,
                    thresh_rel_db,
                    analysis_mode=FAST_ANALYSIS_MODE,
                )
                fast_track_analyses.append((path, track_meta, track_analysis))

            if any(track_analysis["analysis_confidence"] == "low" for _path, _meta, track_analysis in fast_track_analyses):
                effective_analysis_mode = EXACT_ANALYSIS_MODE
                for path, track_meta, decoded_track in prepared_tracks:
                    track_analysis = select_track_analysis_from_decoded(
                        decoded_track,
                        track_meta,
                        window_sec,
                        max_windows,
                        thresh_rel_db,
                        analysis_mode=EXACT_ANALYSIS_MODE,
                    )
                    track_analyses.append((path, track_meta, track_analysis))
            else:
                effective_analysis_mode = FAST_ANALYSIS_MODE
                track_analyses = fast_track_analyses
        else:
            effective_analysis_mode = requested_analysis_mode
            for path, track_meta, decoded_track in prepared_tracks:
                track_analysis = select_track_analysis_from_decoded(
                    decoded_track,
                    track_meta,
                    window_sec,
                    max_windows,
                    thresh_rel_db,
                    analysis_mode=effective_analysis_mode,
                )
                track_analyses.append((path, track_meta, track_analysis))

        tracks = []
        auto_exact_fallback = requested_analysis_mode == AUTO_ANALYSIS_MODE and effective_analysis_mode == EXACT_ANALYSIS_MODE
        for path, track_meta, track_analysis in track_analyses:
            sr_in = track_meta.sr
            bits_in = track_meta.bits
            cutoff = track_analysis["cutoff_hz"]
            if sr_in is None:
                continue
            decision = resolve_recode_decision(cutoff, sr_in, headroom_hz)
            tracks.append(
                {
                    "file": path,
                    "sr_in": int(sr_in) if sr_in else None,
                    "bits_in": int(bits_in) if bits_in else None,
                    "channels_in": int(track_meta.channels) if track_meta.channels else None,
                    "requested_analysis_mode": requested_analysis_mode,
                    "analysis_mode": effective_analysis_mode,
                    "auto_exact_fallback": auto_exact_fallback,
                    "analysis_confidence": track_analysis["analysis_confidence"],
                    "selected_channel": track_analysis["selected_channel"],
                    "windows_requested": int(track_analysis["windows_requested"]),
                    "windows_used": int(track_analysis["windows_used"]),
                    "window_cutoffs_hz": track_analysis["window_cutoffs_hz"],
                    "channel_cutoffs_hz": track_analysis["channel_cutoffs_hz"],
                    "cutoff_hz": cutoff,
                    "effective_cutoff_hz": decision["effective_cutoff_hz"],
                    "source_family_sr": decision["source_family_sr"],
                    "standard_family_sr": decision["standard_family_sr"],
                    "fake_upscale": decision["fake_upscale"],
                    "tgt_sr": decision["target_sr"],
                    "decision": decision["decision"],
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
        album_family_sr = fake_track_families[0] if len(fake_track_families) == 1 else None
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

        print(
            json.dumps(
                {
                    "requested_analysis_mode": requested_analysis_mode,
                    "analysis_mode": effective_analysis_mode,
                    "auto_exact_fallback": auto_exact_fallback,
                    "album_confidence": album_confidence,
                    "album_sr": int(album_sr),
                    "album_bits": int(album_bits),
                    "album_fake_upscale": album_fake_upscale,
                    "album_has_fake_upscale_tracks": album_has_fake_upscale_tracks,
                    "album_family_sr": int(album_family_sr) if album_family_sr is not None else None,
                    "album_decision": album_decision,
                    "tracks": tracks,
                }
            )
        )
        return 0
    finally:
        for _path, _track_meta, decoded_track in prepared_tracks:
            cleanup_decoded_track(decoded_track)


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
