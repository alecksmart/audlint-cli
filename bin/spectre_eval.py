#!/usr/bin/env python3
"""
spectre_eval.py — analyze a PCM WAV excerpt and print metrics + recommendation.
Improved: more robust spectral estimation, multi-segment analysis, safer DSD checks.
"""

import json
import re
import subprocess
import sys
import wave

import numpy as np

def read_wav_mono(path):
    with wave.open(path, 'rb') as w:
        nchan = w.getnchannels()
        sr    = w.getframerate()
        nfrm  = w.getnframes()
        sampw = w.getsampwidth()
        raw   = w.readframes(nfrm)

    if sampw == 2:
        arr = np.frombuffer(raw, dtype='<i2').astype(np.float32) / (2**15)
    elif sampw == 3:
        a = np.frombuffer(raw, dtype=np.uint8).reshape(-1,3)
        b = (a[:,2].astype(np.int32)<<16) | (a[:,1].astype(np.int32)<<8) | a[:,0].astype(np.int32)
        b = np.where(b & 0x800000, b | ~0xFFFFFF, b)
        arr = b.astype(np.float32) / (2**23)
    elif sampw == 4:
        arr = np.frombuffer(raw, dtype='<i4').astype(np.float32) / (2**31)
    else:
        arr = np.frombuffer(raw, dtype='<i2').astype(np.float32) / (2**15)

    if nchan > 1:
        arr = arr.reshape(-1, nchan).mean(axis=1)
    return sr, arr

def moving_average(x, n=7):
    if n <= 1: return x
    k = n//2
    y = np.convolve(x, np.ones(n)/n, mode='same')
    y[:k] = y[k]; y[-k:] = y[-k-1]
    return y

def band_energy_spectrum(x, sr, nfft=16384, hop=None):
    if hop is None: hop = nfft // 2
    win = np.hanning(nfft)
    if len(x) < nfft: x = np.pad(x, (0, nfft-len(x)))
    frames = max(1, 1 + (len(x) - nfft)//hop)
    acc = None
    for i in range(frames):
        s = i*hop
        S = np.fft.rfft(x[s:s+nfft]*win)
        P = (np.abs(S)**2)
        acc = P if acc is None else acc + P
    spec = acc / frames
    freqs = np.fft.rfftfreq(nfft, 1.0/sr)
    return freqs, spec

def aggregate_spectrum(x, sr, nfft=16384, hop=None, seg_dur=10.0, segs=4):
    # Compute multiple segment spectra and median-combine for robustness.
    n = len(x)
    seg_len = int(seg_dur * sr)
    if seg_len <= 0 or n < seg_len:
        freqs, spec = band_energy_spectrum(x, sr, nfft=nfft, hop=hop)
        return freqs, spec

    # Evenly spaced segments across the excerpt.
    if segs < 1: segs = 1
    max_start = max(0, n - seg_len)
    if segs == 1:
        starts = [max_start // 2]
    else:
        starts = [int(round(i * max_start / (segs - 1))) for i in range(segs)]

    specs = []
    freqs = None
    for s in starts:
        freqs, spec = band_energy_spectrum(x[s:s+seg_len], sr, nfft=nfft, hop=hop)
        specs.append(spec)
    spec_med = np.median(np.stack(specs, axis=0), axis=0)
    return freqs, spec_med

def estimate_fmax(freqs, spec, nyq_hz):
    spec_db = 10*np.log10(np.maximum(spec, 1e-20))
    spec_db = moving_average(spec_db, 7)

    # Noise floor: median in the top band (60%-95% of Nyquist)
    hi_lo = 0.60 * nyq_hz
    hi_hi = 0.95 * nyq_hz
    m = (freqs >= hi_lo) & (freqs <= hi_hi)
    noise_db = np.median(spec_db[m]) if m.any() else np.median(spec_db)

    # Require energy meaningfully above noise floor.
    thr = noise_db + 8.0
    above = spec_db > thr

    # Require short runs of bins to avoid single-bin spikes.
    run = np.convolve(above.astype(np.int32), np.ones(3, dtype=np.int32), mode='same') >= 3
    idx = np.where(run)[0]
    fmax = float(freqs[idx].max()) if idx.size else 0.0
    return fmax, spec_db, noise_db

def detect_dsd_noise(freqs, spec_db, nyq_hz, noise_db):
    # DSD noise typically starts its steep climb between 25kHz and 55kHz.
    # If Nyquist is too low, we can't detect it reliably.
    if nyq_hz < 50000:
        return False, "LOW"
    lo, hi = 25000, 55000
    m = (freqs >= lo) & (freqs <= hi)
    if m.sum() < 10:
        return False, "LOW"
    x = freqs[m]; y = spec_db[m]
    A = np.vstack([x, np.ones_like(x)]).T
    slope, _ = np.linalg.lstsq(A, y, rcond=None)[0]

    # Compare mid-band vs high-band tilt (DSD rises with frequency).
    mid_lo, mid_hi = 5000, 10000
    mm = (freqs >= mid_lo) & (freqs <= mid_hi)
    mid_db = np.median(spec_db[mm]) if mm.any() else np.median(spec_db)
    hf_db = np.median(y)

    slope_per_khz = slope * 1000.0
    tilt_db = hf_db - mid_db

    if slope_per_khz > 0.03 and tilt_db > 10.0:
        return True, "HIGH"
    if slope_per_khz > 0.015 and tilt_db > 6.0:
        return True, "MED"
    return False, "LOW"

def detect_upsample(freqs, spec_db, nyq_hz, noise_db, thr_db, fmax_hz):
    # Likely upsample if there's a steep low-pass cutoff well below Nyquist
    # and the highest band sits near the noise floor.
    if nyq_hz <= 0:
        return False, 0.0, "LOW"

    # High-frequency band check: should be close to noise floor.
    hi_lo = 0.80 * nyq_hz
    hi_hi = 0.95 * nyq_hz
    mh = (freqs >= hi_lo) & (freqs <= hi_hi)
    hf_db = np.median(spec_db[mh]) if mh.any() else np.median(spec_db)
    hf_near_noise = (hf_db - noise_db) < 6.0

    # Find cutoff as last frequency with sustained energy above threshold.
    above = spec_db > thr_db
    run = np.convolve(above.astype(np.int32), np.ones(3, dtype=np.int32), mode='same') >= 3
    idx = np.where(run)[0]
    if idx.size == 0:
        return False, 0.0, "LOW"
    cutoff_hz = float(freqs[idx].max())
    if fmax_hz > 0:
        cutoff_hz = min(cutoff_hz, fmax_hz)

    # Cutoff must be substantially below Nyquist to suspect upsample.
    if cutoff_hz >= 0.67 * nyq_hz:
        return False, cutoff_hz, "LOW"

    # Check for a steep negative slope around the cutoff.
    band = 4000.0
    lo = max(0.0, cutoff_hz - band)
    hi = min(nyq_hz, cutoff_hz + band)
    m = (freqs >= lo) & (freqs <= hi)
    if m.sum() < 10:
        return False, cutoff_hz, "LOW"
    x = freqs[m]; y = spec_db[m]
    A = np.vstack([x, np.ones_like(x)]).T
    slope, _ = np.linalg.lstsq(A, y, rcond=None)[0]
    slope_per_khz = slope * 1000.0

    steep_drop = slope_per_khz < -2.5
    very_low_cutoff = cutoff_hz < (0.60 * nyq_hz)
    if hf_near_noise and steep_drop and very_low_cutoff:
        return True, cutoff_hz, "HIGH"
    if hf_near_noise and (steep_drop or very_low_cutoff):
        return True, cutoff_hz, "MED"
    return False, cutoff_hz, "LOW"

def confidence_from_fmax(fmax_khz):
    # Lower confidence if fmax sits close to decision boundaries.
    boundaries = [20.0, 30.0, 55.0]
    dist = min(abs(fmax_khz - b) for b in boundaries)
    if dist < 2.0:
        return "LOW"
    if dist < 5.0:
        return "MED"
    return "HIGH"

def recommend_by_fmax(fmax_khz, is_44k_family):
    if fmax_khz < 20.0:
        return "Standard Definition → Store as 48/24" if not is_44k_family else "Standard Definition → Store as 44.1/24"
    if fmax_khz < 30.0:
        return "Hi-Res (entry) → Store as 48/24" if not is_44k_family else "Hi-Res (entry) → Store as 44.1/24"
    if fmax_khz < 55.0:
        return "Hi-Res (mid) → Store as 96/24" if not is_44k_family else "Hi-Res (mid) → Store as 88.2/24"
    return "Ultra Hi-Res → Store as 192/24" if not is_44k_family else "Ultra Hi-Res → Store as 176.4/24"


QUALITY_RULES = {
    "fake_hires_penalty": 5.0,
    "clipped_penalty": 2.0,
    "loudness_war_penalty": 1.0,
    "loudnorm_deadband_db": 0.3,
    "default_spectral_seconds": 75.0,
    "default_loudness_window_seconds": 180.0,
    "default_loudness_window_count": 3,
    "default_full_loudness_scan_max_seconds": 900.0,
}

GRADE_RANK = {"F": 0, "C": 1, "B": 2, "A": 3, "S": 4}
INV_GRADE_RANK = {v: k for k, v in GRADE_RANK.items()}
_RE_NUM = r"[-+]?(?:\d+(?:\.\d+)?|\.\d+)"


def _run_cmd(cmd):
    p = subprocess.run(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return p.returncode, p.stdout, p.stderr


def _run_cmd_bytes(cmd):
    p = subprocess.run(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return p.returncode, p.stdout, p.stderr.decode("utf-8", errors="replace")


def _probe_audio(file_path):
    rc, out, err = _run_cmd([
        "ffprobe",
        "-v", "error",
        "-select_streams", "a:0",
        "-show_entries", "stream=sample_rate,bits_per_sample,bits_per_raw_sample:format=duration",
        "-of", "json",
        file_path,
    ])
    if rc != 0:
        raise RuntimeError(f"ffprobe failed: {err.strip()}")
    payload = json.loads(out)
    streams = payload.get("streams", [])
    if not streams:
        raise RuntimeError("No audio stream found.")
    s = streams[0]
    fmt = payload.get("format", {})
    sample_rate = int(s.get("sample_rate") or 0)
    bit_depth = int(s.get("bits_per_sample") or s.get("bits_per_raw_sample") or 0)
    duration = float(fmt.get("duration") or 0.0)
    return sample_rate, bit_depth, duration


def _clip_window_start(duration_s, window_s, position):
    if duration_s <= 0 or duration_s <= window_s:
        return 0.0
    usable = max(0.0, duration_s - window_s)
    pos = min(1.0, max(0.0, position))
    return usable * pos


def _window_starts(duration_s, window_s, count):
    count = max(1, int(count))
    if duration_s <= 0 or duration_s <= window_s:
        return [0.0]
    if count == 1:
        return [round(_clip_window_start(duration_s, window_s, 0.5), 3)]
    usable = max(0.0, duration_s - window_s)
    starts = []
    for idx in range(count):
        pos = 0.12 + (0.88 - 0.12) * (idx / (count - 1))
        starts.append(round(usable * pos, 3))
    dedup = []
    for s in starts:
        if not dedup or abs(dedup[-1] - s) > 0.001:
            dedup.append(s)
    return dedup


def _extract_mono_float(file_path, sample_rate, start_seconds=0.0, seconds=90.0):
    if sample_rate <= 0:
        raise RuntimeError("Invalid sample rate from ffprobe.")
    cmd = ["ffmpeg", "-v", "error"]
    if start_seconds > 0:
        cmd += ["-ss", f"{start_seconds:.3f}"]
    cmd += ["-i", file_path]
    if seconds > 0:
        cmd += ["-t", f"{seconds:.3f}"]
    cmd += ["-ac", "1", "-f", "f32le", "-"]
    rc, out, err = _run_cmd_bytes(cmd)
    if rc != 0:
        raise RuntimeError(f"ffmpeg decode failed: {err.strip()}")
    return np.frombuffer(out, dtype=np.float32)


def _parse_ebur128_log(text):
    def _last_float(pattern, haystack, flags=0):
        matches = re.findall(pattern, haystack, flags)
        return float(matches[-1]) if matches else None

    # Prefer summary block when present to avoid transient frame-level values.
    summary_match = re.search(r"summary:\s*(.+)$", text, re.IGNORECASE | re.DOTALL)
    summary = summary_match.group(1) if summary_match else text

    i_lufs = _last_float(rf"\bI:\s*({_RE_NUM})\s*LUFS\b", summary, re.IGNORECASE)
    lra_lu = _last_float(rf"\bLRA:\s*({_RE_NUM})\s*LU\b", summary, re.IGNORECASE)
    tp_db = _last_float(rf"\bPeak:\s*({_RE_NUM})\s*dB(?:FS|TP)?\b", summary, re.IGNORECASE)

    # Fallbacks for possible label/style variations in future ffmpeg output.
    if i_lufs is None:
        i_lufs = _last_float(rf"\bIntegrated loudness\b[^\r\n]*?({_RE_NUM})\s*LUFS\b", summary, re.IGNORECASE)
    if lra_lu is None:
        lra_lu = _last_float(rf"\bLoudness range\b[^\r\n]*?({_RE_NUM})\s*LU\b", summary, re.IGNORECASE)
    if tp_db is None:
        tp_db = _last_float(rf"\bTrue peak\b[^\r\n]*?({_RE_NUM})\s*dB(?:FS|TP)?\b", summary, re.IGNORECASE)

    if i_lufs is None or lra_lu is None:
        raise RuntimeError("Could not parse ebur128 integrated loudness/LRA.")
    return i_lufs, lra_lu, tp_db


def _run_ebur128_segment(file_path, start_seconds=None, duration_seconds=None):
    cmd = ["ffmpeg", "-hide_banner", "-nostats"]
    if start_seconds is not None and start_seconds > 0:
        cmd += ["-ss", f"{start_seconds:.3f}"]
    cmd += ["-i", file_path]
    if duration_seconds is not None and duration_seconds > 0:
        cmd += ["-t", f"{duration_seconds:.3f}"]
    cmd += ["-filter_complex", "ebur128=peak=true", "-f", "null", "-"]
    rc, _, stderr = _run_cmd(cmd)
    if rc != 0:
        if ("no such filter" in stderr.lower()) and ("ebur128" in stderr.lower()):
            raise RuntimeError("ffmpeg build is missing the ebur128 filter.")
        raise RuntimeError(f"ffmpeg ebur128 analysis failed: {stderr.strip()}")
    i_lufs, lra_lu, tp_dbfs = _parse_ebur128_log(stderr)
    return {
        "start_seconds": start_seconds,
        "duration_seconds": duration_seconds,
        "integrated_lufs": i_lufs,
        "lra_lu": lra_lu,
        "true_peak_dbfs": tp_dbfs,
    }


def _measure_loudness(file_path, duration_s, full_scan_max_seconds, window_seconds, window_count):
    segments = []
    if duration_s > 0 and duration_s <= full_scan_max_seconds:
        segments.append(_run_ebur128_segment(file_path))
        mode = "full_scan"
    else:
        starts = _window_starts(duration_s, window_seconds, window_count)
        for start in starts:
            segments.append(_run_ebur128_segment(file_path, start_seconds=start, duration_seconds=window_seconds))
        mode = "windowed"

    i_vals = [s["integrated_lufs"] for s in segments if s["integrated_lufs"] is not None]
    lra_vals = [s["lra_lu"] for s in segments if s["lra_lu"] is not None]
    tp_vals = [s["true_peak_dbfs"] for s in segments if s["true_peak_dbfs"] is not None]
    if not i_vals or not lra_vals:
        raise RuntimeError("Loudness analysis did not return valid I/LRA values.")

    integrated_lufs = float(np.median(np.array(i_vals, dtype=np.float64)))
    lra_lu = float(np.median(np.array(lra_vals, dtype=np.float64)))
    true_peak_dbfs = float(max(tp_vals)) if tp_vals else None
    return integrated_lufs, lra_lu, true_peak_dbfs, mode, segments


def _dynamic_range_bucket(lra_lu, genre_profile="standard"):
    """Map EBU R128 LRA to a mastering grade with genre-adaptive thresholds.

    Genre profiles reflect that intentional loudness (rock, metal, EDM) is a
    stylistic choice, not a defect, while audiophile genres (classical, jazz)
    warrant stricter dynamic-range expectations.

    The F grade is reserved for genuine technical defects (LRA < 3 LU),
    not genre-appropriate loudness.  Albums with LRA 3–5 receive grade C
    regardless of genre, preventing false "Trash" recommendations.
    """
    if genre_profile == "audiophile":
        # Classical, jazz, acoustic: high dynamic range expected.
        if lra_lu > 12:
            return "S", 10
        if lra_lu >= 9:
            return "A", 8
        if lra_lu >= 6:
            return "B", 6
        if lra_lu >= 3:
            return "C", 4
        return "F", 1
    if genre_profile == "high_energy":
        # Rock, metal, EDM: intentionally loud masters are normal.
        if lra_lu > 9:
            return "S", 10
        if lra_lu >= 6:
            return "A", 8
        if lra_lu >= 4:
            return "B", 6
        if lra_lu >= 2:
            return "C", 4
        return "F", 1
    # Standard (default): broadcast-adjacent genres, pop, etc.
    if lra_lu > 12:
        return "S", 10
    if lra_lu >= 8:
        return "A", 8
    if lra_lu >= 6:
        return "B", 6
    if lra_lu >= 3:
        return "C", 4
    return "F", 1


def _grade_from_score(score):
    if score >= 9:
        return "S"
    if score >= 7:
        return "A"
    if score >= 5:
        return "B"
    if score >= 3:
        return "C"
    return "F"


def _detect_fake_hires_192k(freqs, spec_db, nyq_hz, fmax_hz, noise_db):
    if nyq_hz < 90000:
        return False, {"reason": "not_192k_nyquist"}

    pre = (freqs >= 18000) & (freqs <= 22000)
    post = (freqs >= 24000) & (freqs <= 32000)
    if not pre.any() or not post.any():
        return False, {"reason": "insufficient_bins"}

    pre_db = float(np.median(spec_db[pre]))
    post_db = float(np.median(spec_db[post]))
    drop_db = pre_db - post_db
    post_near_noise = post_db <= (noise_db + 4.0)

    band = (freqs >= 18000) & (freqs <= 32000)
    x = freqs[band]
    y = spec_db[band]
    slope_db_per_khz = 0.0
    if x.size >= 10:
        A = np.vstack([x, np.ones_like(x)]).T
        slope, _ = np.linalg.lstsq(A, y, rcond=None)[0]
        slope_db_per_khz = float(slope * 1000.0)

    hf_extension_band = (freqs >= 40000) & (freqs <= min(80000, nyq_hz * 0.95))
    hf_extension_db = float(np.median(spec_db[hf_extension_band])) if hf_extension_band.any() else noise_db
    has_hf_extension = (hf_extension_db - noise_db) > 6.0

    cutoff_like = fmax_hz < 24000
    sharp_drop = (drop_db >= 14.0) and (slope_db_per_khz < -1.2) and post_near_noise and not has_hf_extension
    is_fake = cutoff_like or sharp_drop
    details = {
        "drop_db_18_22_vs_24_32": round(drop_db, 2),
        "slope_db_per_khz_18_32": round(slope_db_per_khz, 2),
        "post_near_noise": bool(post_near_noise),
        "has_hf_extension": bool(has_hf_extension),
        "fmax_khz": round(fmax_hz / 1000.0, 2),
    }
    return is_fake, details


def _score_audio(dynamic_grade, dynamic_range_score, fake_hires, likely_clipped, loudness_war):
    score = float(dynamic_range_score)
    deductions = []
    if fake_hires:
        score -= QUALITY_RULES["fake_hires_penalty"]
        deductions.append(("fake_hires_192k_24bit", -QUALITY_RULES["fake_hires_penalty"]))
    if likely_clipped:
        score -= QUALITY_RULES["clipped_penalty"]
        deductions.append(("likely_clipped_distorted", -QUALITY_RULES["clipped_penalty"]))
    if loudness_war:
        score -= QUALITY_RULES["loudness_war_penalty"]
        deductions.append(("loudness_war_victim", -QUALITY_RULES["loudness_war_penalty"]))

    score = round(max(1.0, min(10.0, score)), 1)
    grade_from_score = _grade_from_score(score)
    final_rank = min(GRADE_RANK[grade_from_score], GRADE_RANK[dynamic_grade])
    return score, INV_GRADE_RANK[final_rank], deductions


def _recommendation(fake_hires, likely_clipped, mastering_grade):
    if fake_hires:
        return "Replace with CD Rip"
    if likely_clipped or mastering_grade == "F":
        return "Trash"
    return "Keep"


def analyze_audio_quality(
    file_path,
    target_lufs=-14.0,
    debug=False,
    use_spectral=True,
    spectral_seconds=QUALITY_RULES["default_spectral_seconds"],
    loudness_full_scan_max_seconds=QUALITY_RULES["default_full_loudness_scan_max_seconds"],
    loudness_window_seconds=QUALITY_RULES["default_loudness_window_seconds"],
    loudness_window_count=QUALITY_RULES["default_loudness_window_count"],
    genre_profile="standard",
):
    """
    Analyze audio quality with FFT/spectrogram, dynamic range, and true peak checks.
    Uses bounded windows for large files to avoid scanning entire album-length sources.
    """
    sample_rate, bit_depth, duration_s = _probe_audio(file_path)
    nyq_hz = sample_rate / 2.0
    spectral_start_s = _clip_window_start(duration_s, spectral_seconds, 0.5) if use_spectral else 0.0
    fmax_hz = 0.0
    noise_db = float("nan")
    thr_db = float("nan")
    cutoff_hz = 0.0
    up_conf = "N/A"
    upsample_like = False

    fake_hires = False
    fake_hires_details = {"reason": "not_applicable"}

    if use_spectral:
        pcm = _extract_mono_float(
            file_path,
            sample_rate,
            start_seconds=spectral_start_s,
            seconds=spectral_seconds,
        )
        if pcm.size == 0:
            raise RuntimeError("Decoded PCM excerpt is empty.")

        x = pcm - np.mean(pcm)
        freqs, spec = aggregate_spectrum(x, sample_rate, nfft=16384, seg_dur=10.0, segs=4)
        fmax_hz, spec_db, noise_db = estimate_fmax(freqs, spec, nyq_hz)
        thr_db = noise_db + 8.0
        upsample_like, cutoff_hz, up_conf = detect_upsample(freqs, spec_db, nyq_hz, noise_db, thr_db, fmax_hz)

        if sample_rate >= 192000 and bit_depth >= 24:
            fake_hires, fake_hires_details = _detect_fake_hires_192k(freqs, spec_db, nyq_hz, fmax_hz, noise_db)
    else:
        fake_hires_details = {"reason": "spectral_analysis_disabled"}

    integrated_lufs, lra_lu, true_peak_dbfs, loudness_mode, loudness_segments = _measure_loudness(
        file_path,
        duration_s=duration_s,
        full_scan_max_seconds=loudness_full_scan_max_seconds,
        window_seconds=loudness_window_seconds,
        window_count=loudness_window_count,
    )

    dynamic_grade, dynamic_range_score = _dynamic_range_bucket(lra_lu, genre_profile=genre_profile)
    likely_clipped = (true_peak_dbfs is not None) and (true_peak_dbfs > -0.1) and (lra_lu < 6.0)
    loudness_war = (true_peak_dbfs is not None) and (abs(true_peak_dbfs) < 0.01)

    quality_score, mastering_grade, deductions = _score_audio(
        dynamic_grade=dynamic_grade,
        dynamic_range_score=dynamic_range_score,
        fake_hires=fake_hires,
        likely_clipped=likely_clipped,
        loudness_war=loudness_war,
    )

    required_gain_db = float(target_lufs - integrated_lufs)
    should_apply_loudnorm = abs(required_gain_db) > QUALITY_RULES["loudnorm_deadband_db"]

    recommendation = _recommendation(fake_hires=fake_hires, likely_clipped=likely_clipped, mastering_grade=mastering_grade)
    if use_spectral:
        spectrogram_summary = (
            f"fmax={fmax_hz/1000.0:.1f}kHz, nyquist={nyq_hz/1000.0:.1f}kHz, "
            f"upsample_like={int(upsample_like)} (conf={up_conf}, cutoff={cutoff_hz/1000.0:.1f}kHz)"
        )
    else:
        spectrogram_summary = "skipped (no-spectral mode)"

    result = {
        "score": quality_score,
        "grade": mastering_grade,
        "quality_score": quality_score,
        "mastering_grade": mastering_grade,
        "dynamic_range_grade": dynamic_grade,
        "dynamic_range_score": dynamic_range_score,
        "is_upscaled": bool(fake_hires or upsample_like),
        "fake_hires_192k_24bit": bool(fake_hires),
        "integrated_lufs": round(integrated_lufs, 2),
        "lra_lu": round(lra_lu, 2),
        "true_peak_dbfs": None if true_peak_dbfs is None else round(true_peak_dbfs, 2),
        "likely_clipped_distorted": bool(likely_clipped),
        "loudness_war_victim": bool(loudness_war),
        "required_gain_db": round(required_gain_db, 2),
        "should_apply_loudnorm": bool(should_apply_loudnorm),
        "recommendation": recommendation,
        "spectrogram_summary": spectrogram_summary,
        "recommendation_with_spectrogram": f"{recommendation} | {spectrogram_summary}",
        "fake_hires_details": fake_hires_details,
    }

    if debug:
        result["debug"] = {
            "rules": QUALITY_RULES,
            "audio_meta": {
                "sample_rate": sample_rate,
                "bit_depth": bit_depth,
                "duration_s": round(duration_s, 3),
            },
            "spectral_window": {
                "start_s": round(spectral_start_s, 3),
                "duration_s": spectral_seconds if use_spectral else 0.0,
                "noise_floor_db": round(float(noise_db), 2) if use_spectral else None,
                "threshold_db": round(float(thr_db), 2) if use_spectral else None,
                "fmax_hz": round(float(fmax_hz), 2),
                "cutoff_hz": round(float(cutoff_hz), 2),
                "upsample_confidence": up_conf,
                "enabled": bool(use_spectral),
            },
            "loudness_mode": loudness_mode,
            "loudness_segments": loudness_segments,
            "deductions": deductions,
        }
    return result

def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--quality":
        file_path = sys.argv[2]
        debug = False
        use_spectral = True
        genre_profile = "standard"
        for arg in sys.argv[3:]:
            if arg == "--debug":
                debug = True
            elif arg == "--no-spectral":
                use_spectral = False
            elif arg.startswith("--genre-profile="):
                genre_profile = arg.split("=", 1)[1].strip().lower()
        result = analyze_audio_quality(file_path, debug=debug, use_spectral=use_spectral, genre_profile=genre_profile)
        print(f"QUALITY_SCORE={result['quality_score']:.1f}")
        print(f"MASTERING_GRADE={result['mastering_grade']}")
        print(f"IS_UPSCALED={int(result['is_upscaled'])}")
        print(f"DYNAMIC_RANGE_SCORE={result['dynamic_range_score']}")
        print(f"LRA_LU={result['lra_lu']}")
        true_peak = "" if result["true_peak_dbfs"] is None else result["true_peak_dbfs"]
        print(f"TRUE_PEAK_DBFS={true_peak}")
        print(f"LIKELY_CLIPPED_DISTORTED={int(result['likely_clipped_distorted'])}")
        print(f"RECOMMENDATION={result['recommendation']}")
        print(f"SPECTROGRAM={result['spectrogram_summary']}")
        print(f"RECOMMEND_WITH_SPECTROGRAM={result['recommendation_with_spectrogram']}")
        if debug:
            print(f"DEBUG_JSON={json.dumps(result.get('debug', {}), separators=(',', ':'))}")
        return

    if len(sys.argv) < 2:
        sys.exit(2)
    wav_path = sys.argv[1]
    orig_sr = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 0
    dsd_hint = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 0

    sr, x = read_wav_mono(wav_path)
    x = x - np.mean(x)
    nyq_hz = sr / 2.0
    freqs, spec = aggregate_spectrum(x, sr, nfft=16384, seg_dur=10.0, segs=4)
    fmax, spec_db, noise_db = estimate_fmax(freqs, spec, nyq_hz)
    thr_db = noise_db + 8.0
    dsd_like, dsd_conf = detect_dsd_noise(freqs, spec_db, nyq_hz, noise_db)
    if dsd_hint == 1:
        dsd_like = True
        dsd_conf = "HIGH"
    upsample_like, cutoff_hz, up_conf = detect_upsample(freqs, spec_db, nyq_hz, noise_db, thr_db, fmax)

    fmax_khz = fmax/1000.0
    nyq_khz  = sr/2000.0
    
    # 1. FAMILY DETECTION (44.1k vs 48k family)
    # DSD is fundamentally in the 44.1k family
    if orig_sr <= 0:
        orig_sr = sr
    is_44k_family = (orig_sr % 44100 == 0)

    # 2. INTELLIGENT RECOMMENDATION
    # FIX: Rely solely on spectral DSD detection, not sample rate assumptions
    reason = ""
    confidence = "MED"
    if dsd_like:
        # DSD content detected - always recommend 88.2/24 for optimal integer downsampling
        rec = "DSD Source → RECODE TO 88.2/24 (Best integer match, filters noise)"
        reason = "DSD detected (noise-shaping tilt or DSD file hint)"
        confidence = dsd_conf
    else:
        rec = recommend_by_fmax(fmax_khz, is_44k_family)
        confidence = confidence_from_fmax(fmax_khz)

    # 3. TRANSCODE ERROR DETECTION
    # FIX: Warn about ANY 48k-family file with DSD characteristics
    if not is_44k_family and dsd_like:
        rec = f"WARNING: Non-integer DSD transcode detected ({orig_sr/1000:.1f}k). RECODE from original DSF to 88.2/24."
        reason = "DSD detected in 48k-family file (non-integer transcode)"
    elif upsample_like and not dsd_like:
        rec = f"Upsample detected → {recommend_by_fmax(cutoff_hz / 1000.0, is_44k_family)}"
        reason = f"Upsample pattern (cutoff≈{cutoff_hz/1000.0:.1f} kHz, HF near noise)"
        confidence = up_conf
    elif not reason:
        reason = f"Bandwidth fmax≈{fmax_khz:.1f} kHz vs nyquist≈{nyq_khz:.1f} kHz"

    print(f"SUMMARY=FMAX≈{fmax_khz:.1f}kHz, NYQ≈{nyq_khz:.1f}kHz, DSD={int(dsd_like)}, UPSAMPLE={int(upsample_like)}, CONF={confidence}")
    print(f"FMAX_KHZ={fmax_khz:.2f}")
    print(f"NYQUIST_KHZ={nyq_khz:.2f}")
    print(f"DSD_LIKE={'1' if dsd_like else '0'}")
    print(f"UPSAMPLE_LIKE={'1' if upsample_like else '0'}")
    print(f"CUTOFF_KHZ={cutoff_hz/1000.0:.2f}")
    print(f"RECOMMEND={rec}")
    print(f"REASON={reason}")
    print(f"CONFIDENCE={confidence}")

if __name__ == "__main__":
    main()
