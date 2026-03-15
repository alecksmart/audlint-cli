#!/usr/bin/env python3
"""Analyze a spectrogram image for OCR stats and high-frequency cutoff."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import statistics
import tempfile
from typing import Any, Dict, List, Optional, Tuple

try:
    import cv2
    import numpy as np
except Exception as exc:  # pragma: no cover
    IMPORT_ERROR = exc
else:
    IMPORT_ERROR = None

try:
    import pytesseract
except Exception:  # pragma: no cover
    pytesseract = None


# Nyquist-like cutoff tiers in kHz, mapped to canonical audlint profile strings.
PROFILE_TIERS: List[Tuple[float, str, str]] = [
    (22.05, "44100/16", "CD-Quality"),
    (24.00, "48000/24", "Studio 48k"),
    (44.10, "88200/24", "Hi-Res 88.2k"),
    (48.00, "96000/24", "Hi-Res 96k"),
    (88.20, "176400/24", "Hi-Res 176.4k"),
    (96.00, "192000/24", "Hi-Res 192k"),
]


def ocr_image_to_string(image: Any, config: str = "") -> str:
    if pytesseract is not None:
        return pytesseract.image_to_string(image, config=config)

    tesseract_bin = shutil.which("tesseract")
    if not tesseract_bin:
        raise RuntimeError("tesseract binary not found on PATH")

    tmp_path = ""
    try:
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as handle:
            tmp_path = handle.name
        if not cv2.imwrite(tmp_path, image):
            raise RuntimeError("failed to write OCR temp image")
        cmd = [tesseract_bin, tmp_path, "stdout"]
        if config:
            cmd.extend(config.split())
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            return ""
        return proc.stdout
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except FileNotFoundError:
                pass


def parse_roi(value: str) -> Tuple[int, int, int, int]:
    match = re.fullmatch(r"(\d+):(\d+),(\d+):(\d+)", value.strip())
    if not match:
        raise argparse.ArgumentTypeError("ROI format must be Y0:Y1,X0:X1")
    y0, y1, x0, x1 = (int(group) for group in match.groups())
    if y1 <= y0 or x1 <= x0:
        raise argparse.ArgumentTypeError("ROI end coordinates must be greater than start coordinates")
    return y0, y1, x0, x1


def parse_labeled_number(text: str, labels: List[str]) -> Optional[float]:
    for label in labels:
        pattern = rf"{re.escape(label)}\s*[:=]?\s*([-+]?\d+(?:\.\d+)?)\s*(?:dB)?"
        match = re.search(pattern, text, re.IGNORECASE)
        if match is None:
            continue
        try:
            return float(match.group(1))
        except ValueError:
            continue
    return None


def parse_dynamic_range_number(text: str) -> Optional[float]:
    value = parse_labeled_number(text, ["Dynamic Range", "DR"])
    if value is not None:
        return value

    # OCR sometimes collapses separators, e.g. "DynamicRange: 53940351938"
    # for values like 53.94 and 51.93. Recover a plausible first-channel value.
    match = re.search(r"dynamic\s*range[^\d]*([0-9]{5,})", text, re.IGNORECASE)
    if match is None:
        return None

    raw = match.group(1)
    for split in (2, 3):
        if len(raw) < split + 2:
            continue
        candidate = f"{raw[:split]}.{raw[split:split + 2]}"
        try:
            parsed = float(candidate)
        except ValueError:
            continue
        if 1.0 <= parsed <= 60.0:
            return parsed
    return None


def _extract_axis_candidates_khz(text: str) -> List[float]:
    candidates: List[float] = []
    for match in re.finditer(r"(?i)(\d+(?:\.\d+)?)\s*(khz|k|hz)?", text):
        raw = match.group(1)
        unit = (match.group(2) or "").lower()
        try:
            value = float(raw)
        except ValueError:
            continue

        khz: Optional[float] = None
        if unit in ("k", "khz"):
            khz = value
        elif unit == "hz":
            khz = value / 1000.0
        elif value >= 1000.0:
            khz = value / 1000.0

        if khz is None:
            continue
        if 8.0 <= khz <= 384.0:
            candidates.append(khz)
    return candidates


def _nearest_axis_tier(value_khz: float) -> float:
    # Axis top-of-image tiers we support for profile inference.
    tiers = [22.05, 24.0, 48.0, 96.0]
    return min(tiers, key=lambda tier: abs(tier - value_khz))


def _infer_axis_from_dense_ladder(candidates: List[float]) -> Optional[float]:
    values = sorted({round(value, 3) for value in candidates if 8.0 <= value <= 120.0}, reverse=True)
    if len(values) < 5:
        return None

    best_run: List[float] = []
    current_run: List[float] = [values[0]]
    for value in values[1:]:
        diff = current_run[-1] - value
        if 0.8 <= diff <= 6.0:
            current_run.append(value)
            continue
        if len(current_run) > len(best_run):
            best_run = current_run[:]
        current_run = [value]
    if len(current_run) > len(best_run):
        best_run = current_run[:]

    if len(best_run) < 5:
        return None

    diffs = [best_run[idx] - best_run[idx + 1] for idx in range(len(best_run) - 1)]
    step = statistics.median(diffs)
    stable = [diff for diff in diffs if abs(diff - step) <= max(0.6, step * 0.35)]
    if len(stable) < max(3, len(diffs) // 2):
        return None
    return _nearest_axis_tier(max(best_run))


def _infer_axis_from_candidates(candidates: List[float]) -> Optional[float]:
    if not candidates:
        return None

    ladder_axis = _infer_axis_from_dense_ladder(candidates)
    if ladder_axis is not None:
        return ladder_axis

    # Keep only values that are plausibly close to known sampling/axis labels.
    known = [10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.05, 24.0, 30.0, 40.0, 44.1, 48.0, 50.0, 60.0, 88.2, 96.0, 176.4, 192.0, 352.8, 384.0]
    filtered: List[float] = []
    for value in candidates:
        nearest_ref: Optional[float] = None
        nearest_dist: Optional[float] = None
        for ref in known:
            tolerance = max(0.8, ref * 0.08)
            if abs(value - ref) <= tolerance:
                dist = abs(value - ref)
                if nearest_dist is None or dist < nearest_dist:
                    nearest_ref = ref
                    nearest_dist = dist
        if nearest_ref is not None:
            filtered.append(nearest_ref)
    if not filtered:
        return None

    strong_high = [v for v in filtered if v >= 160.0]
    if strong_high:
        # 176.4/192 labels are usually sample-rate indicators; axis top is Nyquist.
        return _nearest_axis_tier(max(strong_high) / 2.0)

    low_band = sorted({v for v in candidates if 8.0 <= v <= 24.0}, reverse=True)
    if len(low_band) >= 4:
        diffs = [low_band[idx] - low_band[idx + 1] for idx in range(len(low_band) - 1)]
        positive = [d for d in diffs if d > 0]
        step = statistics.median(positive) if positive else 2.0
        step = max(1.0, min(step, 6.0))
        top_estimate = max(low_band) + step
        return _nearest_axis_tier(top_estimate)

    high_band = [v for v in filtered if 40.0 <= v < 160.0]
    if high_band:
        # High values are often sample-rate labels (44.1/48/96/192 kHz).
        top_estimate = max(high_band) / 2.0
        return _nearest_axis_tier(top_estimate)

    return _nearest_axis_tier(max(filtered))


def _band_class(cutoff_khz: float, max_khz: float) -> str:
    if max_khz <= 24.5:
        ratio = cutoff_khz / max(1e-6, max_khz)
        if ratio < 0.55:
            return "low-bandwidth"
        return "cd-or-48k"

    if max_khz <= 50.0:
        if cutoff_khz < 16.0:
            return "low-bandwidth"
        if cutoff_khz < 30.0:
            return "cd-or-48k"
        return "hires-96-class"

    if cutoff_khz < 18.0:
        return "low-bandwidth"
    if cutoff_khz < 26.0:
        return "cd-or-48k"
    if cutoff_khz < 52.0:
        return "hires-96-class"
    return "hires-192-class"


def _row_to_khz(row: int, scan_limit: int, max_khz: float) -> float:
    if scan_limit <= 1 or max_khz <= 0:
        return 0.0
    return max_khz * (1.0 - (row / float(scan_limit - 1)))


def _khz_to_row(khz: float, scan_limit: int, max_khz: float) -> int:
    if scan_limit <= 1 or max_khz <= 0:
        return 0
    bounded = max(0.0, min(khz, max_khz))
    ratio = 1.0 - (bounded / max_khz)
    return int(ratio * (scan_limit - 1))


def detect_spectrogram_regions(image: Any) -> List[Tuple[int, int, int, int]]:
    height, width = image.shape[:2]
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    value = hsv[:, :, 2]
    # Dark-pane mask: spectrogram panes are dark backgrounds with colored texture.
    mask = (value < 70).astype("uint8")
    num_labels, _, stats, _ = cv2.connectedComponentsWithStats(mask, 8)

    regions: List[Tuple[int, int, int, int]] = []
    min_w = int(width * 0.45)
    min_h = int(height * 0.12)
    min_area = int(width * height * 0.015)
    for idx in range(1, num_labels):
        x = int(stats[idx, cv2.CC_STAT_LEFT])
        y = int(stats[idx, cv2.CC_STAT_TOP])
        w = int(stats[idx, cv2.CC_STAT_WIDTH])
        h = int(stats[idx, cv2.CC_STAT_HEIGHT])
        area = int(stats[idx, cv2.CC_STAT_AREA])
        if w < min_w or h < min_h or area < min_area:
            continue
        regions.append((x, y, w, h))

    # Largest panes first, then top-most.
    regions.sort(key=lambda item: (-item[2] * item[3], item[1]))
    return regions


def infer_axis_scale_khz(image: Any, region: Tuple[int, int, int, int]) -> Optional[float]:
    height, width = image.shape[:2]
    x, y, w, h = region
    x1 = min(width, max(0, x))
    x0 = max(0, x1 - 120)
    y0 = max(0, y)
    y1 = min(height, y + h)
    if x1 <= x0 or y1 <= y0:
        return None

    strip = image[y0:y1, x0:x1]
    gray = cv2.cvtColor(strip, cv2.COLOR_BGR2GRAY)
    gray = cv2.resize(gray, None, fx=3.0, fy=3.0, interpolation=cv2.INTER_CUBIC)
    thresh = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1]
    text = ocr_image_to_string(
        thresh, config="--psm 6 -c tessedit_char_whitelist=0123456789.kKhHzZ"
    )
    candidates = _extract_axis_candidates_khz(text)
    return _infer_axis_from_candidates(candidates)


def infer_axis_scale_khz_global(image: Any) -> Optional[float]:
    _, width = image.shape[:2]
    left_widths = [min(width, 140), min(width, 220), min(width, max(140, int(width * 0.18)))]
    crops = [(image[:, :crop_width], 3.0, "--psm 6") for crop_width in left_widths if crop_width > 0]
    crops.append((image, 1.8, "--psm 11"))
    for crop, scale, psm in crops:
        if crop.size == 0:
            continue
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
        gray = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
        thresh = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1]
        text = ocr_image_to_string(
            thresh, config=f"{psm} -c tessedit_char_whitelist=0123456789.kKhHzZ"
        )
        candidates = _extract_axis_candidates_khz(text)
        inferred = _infer_axis_from_candidates(candidates)
        if inferred is not None:
            return inferred
    return None


def _region_is_full_frame(region: Tuple[int, int, int, int], image_shape: Tuple[int, int, int]) -> bool:
    x, y, w, h = region
    height, width = image_shape[:2]
    x_margin = max(2, int(width * 0.03))
    y_margin = max(2, int(height * 0.05))
    return (
        x <= x_margin
        and y <= y_margin
        and (x + w) >= (width - x_margin)
        and (y + h) >= (height - y_margin)
    )


def _ocr_has_mastering_stats(text: str) -> bool:
    return bool(re.search(r"(peak(?:\s+amplitude)?|dynamic\s*range|\bdr\b)", text, re.IGNORECASE))


def analyze_spectral_signature(
    gray: Any,
    scan_limit: int,
    max_khz: float,
    brightness_threshold: float,
    energy_mode: str = "texture",
) -> Dict[str, Any]:
    width = gray.shape[1]
    x0 = max(0, int(width * 0.25))
    roi = gray[:scan_limit, x0:]
    if roi.size == 0:
        return {
            "cutoff_row": scan_limit - 1,
            "detected_khz": 0.0,
            "transition_found": False,
            "noise_floor": 0.0,
            "threshold": 0.0,
            "dynamic_span": 0.0,
            "wall_strength": 0.0,
            "high_band_ratio": 0.0,
            "brickwall_hint": False,
            "brickwall_khz": 0.0,
        }

    if energy_mode == "intensity":
        row_energy = np.percentile(roi, 75, axis=1).astype(np.float32)
    else:
        # Use row texture (std across time axis) instead of raw brightness so
        # color-map background gradients do not look like musical energy.
        row_energy = np.std(roi, axis=1).astype(np.float32)
    kernel = max(3, int(scan_limit * 0.01))
    if kernel % 2 == 0:
        kernel += 1
    smooth = np.convolve(row_energy, np.ones(kernel, dtype=np.float32) / float(kernel), mode="same")

    noise_rows = max(5, scan_limit // 8)
    noise_floor = float(np.median(smooth[:noise_rows]))
    p90 = float(np.percentile(smooth, 90))
    dynamic_span = max(0.0, p90 - noise_floor)
    threshold = noise_floor + max(2.0, dynamic_span * 0.25)
    if energy_mode == "intensity":
        threshold = max(float(brightness_threshold), threshold)

    sustain = max(8, scan_limit // 18)
    start_row = max(5, int(scan_limit * 0.08))
    cutoff_row = scan_limit - 1
    transition_found = False
    for y in range(start_row, max(start_row + 1, scan_limit - sustain)):
        if float(np.mean(smooth[y : y + sustain])) >= threshold:
            cutoff_row = y
            transition_found = True
            break

    detected_khz = _row_to_khz(cutoff_row, scan_limit, max_khz)
    grad = np.diff(smooth)
    g0 = max(0, cutoff_row - 4)
    g1 = min(len(grad), cutoff_row + 10)
    wall_strength = float(np.max(grad[g0:g1])) if g1 > g0 else 0.0

    row_24 = max(1, _khz_to_row(24.0, scan_limit, max_khz))
    row_20 = _khz_to_row(20.0, scan_limit, max_khz)
    row_8 = _khz_to_row(8.0, scan_limit, max_khz)
    lo = min(row_20, row_8)
    hi = max(row_20, row_8)
    high_energy = float(np.mean(smooth[:row_24]))
    mid_energy = float(np.mean(smooth[lo : max(lo + 1, hi)]))
    high_band_ratio = high_energy / max(1e-6, mid_energy)

    brickwall_hint = bool(
        transition_found
        and detected_khz <= 24.5
        and (max_khz > 24.5 or detected_khz <= (max_khz * 0.88))
        and wall_strength >= max(2.0, dynamic_span * 0.12)
        and (
            (max_khz <= 24.5 and high_band_ratio <= 0.78)
            or high_band_ratio <= 0.45
        )
    )

    return {
        "cutoff_row": cutoff_row,
        "detected_khz": detected_khz,
        "transition_found": transition_found,
        "noise_floor": noise_floor,
        "threshold": threshold,
        "dynamic_span": dynamic_span,
        "wall_strength": wall_strength,
        "high_band_ratio": high_band_ratio,
        "brickwall_hint": brickwall_hint,
        "brickwall_khz": round(detected_khz, 2),
    }


def infer_profile_from_cutoff(
    cutoff_khz: float,
    max_khz: float,
    transition_found: bool,
    stats_detected: bool,
    dynamic_span: Optional[float] = None,
    high_band_ratio: Optional[float] = None,
    brickwall_hint: bool = False,
) -> Dict[str, Any]:
    bounded = max(0.0, min(cutoff_khz, max_khz))
    tier = min(PROFILE_TIERS, key=lambda item: abs(item[0] - bounded))
    tier_khz, profile, profile_name = tier
    distance = abs(tier_khz - bounded)
    axis_aligned_profile = bool(
        transition_found
        and max_khz > 0.0
        and bounded >= (max_khz * 0.88)
    )

    # Confidence is mostly transition quality + closeness to known tier.
    if not transition_found:
        score = 0
    elif distance <= 1.5:
        score = 2
    elif distance <= 4.0:
        score = 1
    else:
        score = 0

    if not stats_detected and score > 0:
        score -= 1

    texture_promoted = bool(
        not brickwall_hint
        and transition_found
        and 44.0 <= max_khz <= 52.0
        and 21.0 <= bounded <= 26.0
        and dynamic_span is not None
        and dynamic_span >= 28.0
        and high_band_ratio is not None
        and high_band_ratio >= 0.55
    )
    if texture_promoted:
        tier_khz = 48.0
        profile = "96000/24"
        profile_name = "Hi-Res 96k"
        distance = abs(tier_khz - bounded)
        score = max(score, 1)

    if axis_aligned_profile:
        if max_khz >= 90.0:
            tier_khz = 96.0
            profile = "192000/24"
            profile_name = "Hi-Res 192k"
        elif max_khz >= 44.0:
            tier_khz = 48.0
            profile = "96000/24"
            profile_name = "Hi-Res 96k"
        elif max_khz > 22.5:
            tier_khz = 24.0
            profile = "48000/24"
            profile_name = "Studio 48k"
        else:
            tier_khz = 22.05
            profile = "44100/16"
            profile_name = "CD-Quality"
        distance = abs(tier_khz - bounded)
        score = max(score, 1)

    cd_authentic_confident = bool(
        not brickwall_hint
        and transition_found
        and max_khz <= 24.5
        and axis_aligned_profile
    )
    if cd_authentic_confident:
        score = max(score, 1)

    confidence = {0: "LOW", 1: "MEDIUM", 2: "HIGH"}[score]
    band_class = "hires-96-class" if texture_promoted else _band_class(bounded, max_khz)
    return {
        "likely_profile": profile,
        "profile_name": profile_name,
        "confidence": confidence,
        "tier_cutoff_khz": tier_khz,
        "distance_to_tier_khz": round(distance, 2),
        "band_class": band_class,
        "texture_promoted": texture_promoted,
    }


def build_quality_insights(
    cutoff_khz: float,
    peak_db: Optional[float],
    dynamic_range_db: Optional[float],
    max_khz: float = 96.0,
    brickwall_hint: bool = False,
    brickwall_khz: Optional[float] = None,
    cd_authentic_hint: bool = False,
) -> List[str]:
    notes: List[str] = []

    if cutoff_khz < 18.0:
        notes.append("Strong low-pass signature; likely lossy or low-rate source.")
    elif cutoff_khz < 26.0:
        notes.append("Bandwidth is near CD/48k ceiling.")
    elif cutoff_khz >= 44.0:
        notes.append("Bandwidth supports a high-resolution source class.")

    if brickwall_hint:
        cutoff_text = f"{brickwall_khz:.1f}" if isinstance(brickwall_khz, (int, float)) else f"{cutoff_khz:.1f}"
        if max_khz > 24.5:
            notes.append(
                f"Brickwall-like cutoff around {cutoff_text} kHz with weak ultrasonic content; likely upsampled/fake hi-res."
            )
        else:
            notes.append(
                f"Brickwall-like cutoff around {cutoff_text} kHz with weak upper-band content; likely strong lossy/band-limited source."
            )
    elif cd_authentic_hint:
        notes.append("Cutoff is near Nyquist for this scale; consistent with authentic Redbook/CD bandwidth.")

    if peak_db is not None:
        if peak_db > 0.2:
            notes.append("Peak above 0 dB detected by OCR; possible clipping or OCR misread.")
        elif peak_db >= -0.2:
            notes.append("Peak is near 0 dB; mastering likely loud/hot.")
        elif peak_db <= -2.0:
            notes.append("Peak headroom is preserved; less aggressive limiting.")
    else:
        notes.append("Peak metric unavailable from OCR; quality class is downgraded conservatively.")

    if dynamic_range_db is not None:
        if dynamic_range_db >= 14.0:
            notes.append("Dynamic range appears wide.")
        elif dynamic_range_db >= 10.0:
            notes.append("Dynamic range appears healthy.")
        elif dynamic_range_db >= 7.0:
            notes.append("Dynamic range appears moderately compressed.")
        else:
            notes.append("Dynamic range appears heavily compressed.")
    else:
        notes.append("Dynamic-range metric unavailable from OCR; quality class is downgraded conservatively.")

    return notes


def predict_quality_class(
    band_class: str,
    transition_found: bool,
    stats_detected: bool,
    peak_db: Optional[float],
    dynamic_range_db: Optional[float],
    cutoff_khz: Optional[float] = None,
    max_khz: Optional[float] = None,
    dynamic_span: Optional[float] = None,
    high_band_ratio: Optional[float] = None,
    brickwall_hint: bool = False,
    brickwall_khz: Optional[float] = None,
    cd_authentic_hint: bool = False,
) -> Dict[str, Any]:
    base_score = 62
    score = base_score
    components: List[Dict[str, Any]] = []

    if band_class == "low-bandwidth":
        score -= 20
        components.append(
            {
                "factor": "band_class",
                "value": band_class,
                "delta": -20,
                "reason": "Bandwidth suggests low-rate/lossy ceiling.",
            }
        )
    elif band_class == "hires-96-class":
        score += 8
        components.append(
            {
                "factor": "band_class",
                "value": band_class,
                "delta": 8,
                "reason": "Bandwidth supports hi-res 96k class.",
            }
        )
    elif band_class == "hires-192-class":
        score += 10
        components.append(
            {
                "factor": "band_class",
                "value": band_class,
                "delta": 10,
                "reason": "Bandwidth supports top hi-res class.",
            }
        )
    else:
        components.append(
            {
                "factor": "band_class",
                "value": band_class,
                "delta": 0,
                "reason": "Bandwidth is neutral for quality score.",
            }
        )

    if transition_found:
        score += 6
        components.append(
            {
                "factor": "transition_found",
                "value": True,
                "delta": 6,
                "reason": "Stable transition detected in spectral energy profile.",
            }
        )
    else:
        score -= 4
        components.append(
            {
                "factor": "transition_found",
                "value": False,
                "delta": -4,
                "reason": "No stable transition detected in spectral energy profile.",
            }
        )

    if stats_detected:
        score += 3
        components.append(
            {
                "factor": "stats_window",
                "value": "detected",
                "delta": 3,
                "reason": "Stats panel detected; OCR context is more reliable.",
            }
        )
    else:
        score -= 2
        components.append(
            {
                "factor": "stats_window",
                "value": "missing",
                "delta": -2,
                "reason": "Stats panel missing; reduce confidence slightly.",
            }
        )

    if peak_db is not None:
        if peak_db > 0.2:
            score -= 25
            components.append(
                {
                    "factor": "peak_amplitude_db",
                    "value": peak_db,
                    "delta": -25,
                    "reason": "OCR suggests overs/clipping risk.",
                }
            )
        elif peak_db >= -0.2:
            score -= 10
            components.append(
                {
                    "factor": "peak_amplitude_db",
                    "value": peak_db,
                    "delta": -10,
                    "reason": "Peak near 0 dB implies hot limiting.",
                }
            )
        elif peak_db <= -2.0:
            score += 10
            components.append(
                {
                    "factor": "peak_amplitude_db",
                    "value": peak_db,
                    "delta": 10,
                    "reason": "Healthy headroom preserved.",
                }
            )
        else:
            score += 3
            components.append(
                {
                    "factor": "peak_amplitude_db",
                    "value": peak_db,
                    "delta": 3,
                    "reason": "Slight headroom benefit.",
                }
            )
    else:
        score -= 2
        components.append(
            {
                "factor": "peak_amplitude_db",
                "value": None,
                "delta": -2,
                "reason": "No OCR peak value detected.",
            }
        )

    if dynamic_range_db is not None:
        if dynamic_range_db >= 14.0:
            score += 20
            components.append(
                {
                    "factor": "dynamic_range_db",
                    "value": dynamic_range_db,
                    "delta": 20,
                    "reason": "Very wide dynamics.",
                }
            )
        elif dynamic_range_db >= 10.0:
            score += 10
            components.append(
                {
                    "factor": "dynamic_range_db",
                    "value": dynamic_range_db,
                    "delta": 10,
                    "reason": "Healthy dynamics.",
                }
            )
        elif dynamic_range_db >= 7.0:
            score -= 5
            components.append(
                {
                    "factor": "dynamic_range_db",
                    "value": dynamic_range_db,
                    "delta": -5,
                    "reason": "Moderate compression.",
                }
            )
        else:
            score -= 20
            components.append(
                {
                    "factor": "dynamic_range_db",
                    "value": dynamic_range_db,
                    "delta": -20,
                    "reason": "Heavy compression.",
                }
            )
    else:
        score -= 5
        components.append(
            {
                "factor": "dynamic_range_db",
                "value": None,
                "delta": -5,
                "reason": "No OCR dynamic-range value detected.",
            }
        )

    if peak_db is None and dynamic_range_db is None:
        score -= 2
        components.append(
            {
                "factor": "ocr_mastering_stats",
                "value": "missing_peak_and_dr",
                "delta": -2,
                "reason": "Both mastering metrics missing; apply conservative downgrade.",
            }
        )

    if cd_authentic_hint:
        score += 35
        components.append(
            {
                "factor": "cd_authenticity",
                "value": "nyquist_aligned",
                "delta": 35,
                "reason": "Cutoff aligns with Redbook Nyquist ceiling and no fake-hires signature.",
            }
        )

    if brickwall_hint:
        score -= 35
        components.append(
            {
                "factor": "brickwall_signature",
                "value": f"{brickwall_khz:.2f}kHz" if isinstance(brickwall_khz, (int, float)) else "detected",
                "delta": -35,
                "reason": "Hard cutoff near CD band with weak ultrasonic energy (upsample risk).",
            }
        )
    elif band_class.startswith("hires") and cutoff_khz is not None and max_khz is not None:
        if max_khz >= 90.0 and cutoff_khz >= 50.0:
            score += 10
            components.append(
                {
                    "factor": "ultrasonic_extent",
                    "value": round(cutoff_khz, 2),
                    "delta": 10,
                    "reason": "High-frequency energy reaches deep into ultrasonic band.",
                }
            )
        elif max_khz >= 44.0 and cutoff_khz >= (max_khz * 0.88):
            score += 8
            components.append(
                {
                    "factor": "axis_aligned_hires",
                    "value": round(cutoff_khz, 2),
                    "delta": 8,
                    "reason": "Cutoff remains close to the detected hi-res Nyquist ceiling.",
                }
            )
        if dynamic_span is not None and dynamic_span >= 30.0:
            score += 8
            components.append(
                {
                    "factor": "spectral_dynamic_span",
                    "value": round(dynamic_span, 2),
                    "delta": 8,
                    "reason": "Wide spectral contrast suggests non-trivial high-band structure.",
                }
            )
        if high_band_ratio is not None and 0.25 <= high_band_ratio <= 1.4:
            score += 4
            components.append(
                {
                    "factor": "high_band_ratio",
                    "value": round(high_band_ratio, 3),
                    "delta": 4,
                    "reason": "High-band energy ratio is plausible for native hi-res texture.",
                }
            )
    elif (
        band_class == "cd-or-48k"
        and not brickwall_hint
        and cutoff_khz is not None
        and max_khz is not None
        and max_khz >= 90.0
        and cutoff_khz >= 18.0
    ):
        score += 14
        components.append(
            {
                "factor": "cd_band_in_hires_frame",
                "value": round(cutoff_khz, 2),
                "delta": 14,
                "reason": "CD-band ceiling presented on hi-res axis without hard fake-hires signature.",
            }
        )

    if peak_db is None and dynamic_range_db is None:
        if band_class == "cd-or-48k":
            score = min(score, 69)
        elif band_class.startswith("hires"):
            score = min(score, 85)

    raw_score = score
    score = max(0, min(100, raw_score))
    s_candidate = False
    if score >= 95 and band_class.startswith("hires") and not brickwall_hint:
        s_candidate = True
    elif (
        score >= 93
        and band_class.startswith("hires")
        and not brickwall_hint
        and cutoff_khz is not None
        and cutoff_khz >= 50.0
        and dynamic_span is not None
        and dynamic_span >= 30.0
        and high_band_ratio is not None
        and high_band_ratio <= 0.6
    ):
        s_candidate = True
    elif (
        score >= 90
        and band_class.startswith("hires")
        and not brickwall_hint
        and dynamic_range_db is not None
        and dynamic_range_db >= 20.0
    ):
        s_candidate = True

    if s_candidate:
        quality_class = "S"
        quality_label = "Reference"
    elif score >= 86:
        quality_class = "A"
        quality_label = "Excellent"
    elif score >= 70:
        quality_class = "B"
        quality_label = "Good"
    elif score >= 54:
        quality_class = "C"
        quality_label = "Fair"
    elif score >= 38:
        quality_class = "D"
        quality_label = "Limited"
    else:
        quality_class = "F"
        quality_label = "Poor"

    signal_points = 0
    if transition_found:
        signal_points += 1
    if stats_detected:
        signal_points += 1
    if peak_db is not None:
        signal_points += 1
    if dynamic_range_db is not None:
        signal_points += 2

    if signal_points >= 4:
        confidence = "HIGH"
    elif signal_points >= 2:
        confidence = "MEDIUM"
    else:
        confidence = "LOW"

    breakdown = {
        "base_score": base_score,
        "components": components,
        "raw_score": raw_score,
        "final_score": score,
        "signal_points": signal_points,
        "class_thresholds": {
            "S": ">=95 (hires, non-brickwall)",
            "A": ">=86",
            "B": ">=70",
            "C": ">=54",
            "D": ">=38",
            "F": "<38",
        },
        "notes": [
            "Bandwidth alone cannot prove mastering quality.",
            "Missing OCR mastering metrics trigger conservative penalties.",
        ],
    }

    return {
        "quality_class": quality_class,
        "quality_label": quality_label,
        "quality_score": score,
        "quality_confidence": confidence,
        "quality_breakdown": breakdown,
    }


def build_verdict(
    cutoff_khz: float,
    max_khz: float,
    transition_found: bool,
    stats_detected: bool,
    peak_db: Optional[float],
    dynamic_range_db: Optional[float],
    dynamic_span: Optional[float] = None,
    high_band_ratio: Optional[float] = None,
    brickwall_hint: bool = False,
    brickwall_khz: Optional[float] = None,
) -> Dict[str, Any]:
    profile_guess = infer_profile_from_cutoff(
        cutoff_khz=cutoff_khz,
        max_khz=max_khz,
        transition_found=transition_found,
        stats_detected=stats_detected,
        dynamic_span=dynamic_span,
        high_band_ratio=high_band_ratio,
        brickwall_hint=brickwall_hint,
    )
    band_class = profile_guess["band_class"]
    cd_authentic_hint = bool(
        (not brickwall_hint)
        and band_class == "cd-or-48k"
        and max_khz > 0
        and cutoff_khz >= (max_khz * 0.75)
    )
    insights = build_quality_insights(
        cutoff_khz=cutoff_khz,
        peak_db=peak_db,
        dynamic_range_db=dynamic_range_db,
        max_khz=max_khz,
        brickwall_hint=brickwall_hint,
        brickwall_khz=brickwall_khz,
        cd_authentic_hint=cd_authentic_hint,
    )
    if profile_guess.get("texture_promoted"):
        insights.append("Hi-res frame retains plausible ultrasonic texture beyond a simple CD-width ceiling.")

    if brickwall_hint:
        if max_khz > 24.5:
            summary = "Likely upsampled/fake hi-res source (brickwall near CD bandwidth)."
        else:
            summary = "Likely low-bitrate lossy or strongly band-limited source (brickwall near Nyquist)."
    elif cd_authentic_hint:
        summary = "Likely authentic Redbook/CD-quality bandwidth (Nyquist-aligned)."
    elif band_class == "low-bandwidth":
        summary = "Most likely low-bandwidth or lossy-sourced master."
    elif band_class == "cd-or-48k":
        summary = "Most likely CD/48k-class source."
    elif band_class == "hires-96-class":
        summary = "Most likely 88.2/96k high-resolution source."
    else:
        summary = "Most likely 176.4/192k high-resolution source."

    quality = predict_quality_class(
        band_class=band_class,
        transition_found=transition_found,
        stats_detected=stats_detected,
        peak_db=peak_db,
        dynamic_range_db=dynamic_range_db,
        cutoff_khz=cutoff_khz,
        max_khz=max_khz,
        dynamic_span=dynamic_span,
        high_band_ratio=high_band_ratio,
        brickwall_hint=brickwall_hint,
        brickwall_khz=brickwall_khz,
        cd_authentic_hint=cd_authentic_hint,
    )

    lossy_signature_strong = bool(
        (not brickwall_hint)
        and max_khz >= 90.0
        and cutoff_khz <= 50.0
        and high_band_ratio is not None
        and high_band_ratio <= 0.25
    )
    lossy_signature_moderate = bool(
        (not brickwall_hint)
        and max_khz >= 90.0
        and cutoff_khz <= 45.0
        and high_band_ratio is not None
        and high_band_ratio <= 0.70
        and dynamic_span is not None
        and dynamic_span <= 20.0
    )
    lossy_signature = lossy_signature_strong or lossy_signature_moderate

    if not brickwall_hint and lossy_signature:
        summary = "Likely lossy-compressed or strongly band-limited source."

    quality_class = quality["quality_class"]
    quality_label = quality["quality_label"]
    quality_score = quality["quality_score"]

    if lossy_signature_moderate and quality_class in {"S", "A", "B"}:
        quality_score = max(0, int(quality_score) - 12)
        if quality_score >= 95 and band_class.startswith("hires"):
            quality_class = "S"
            quality_label = "Reference"
        elif quality_score >= 86:
            quality_class = "A"
            quality_label = "Excellent"
        elif quality_score >= 70:
            quality_class = "B"
            quality_label = "Good"
        elif quality_score >= 54:
            quality_class = "C"
            quality_label = "Fair"
        elif quality_score >= 38:
            quality_class = "D"
            quality_label = "Limited"
        else:
            quality_class = "F"
            quality_label = "Poor"

    return {
        "summary": summary,
        "likely_profile": (
            "lossy-upsampled"
            if (brickwall_hint and max_khz > 24.5)
            else ("lossy-compressed" if (brickwall_hint or lossy_signature) else profile_guess["likely_profile"])
        ),
        "profile_name": (
            "Lossy Upsampled"
            if (brickwall_hint and max_khz > 24.5)
            else ("Lossy Compressed" if (brickwall_hint or lossy_signature) else profile_guess["profile_name"])
        ),
        "canonical_profile": profile_guess["likely_profile"],
        "confidence": profile_guess["confidence"],
        "quality_class": quality_class,
        "quality_label": quality_label,
        "quality_score": quality_score,
        "quality_confidence": quality["quality_confidence"],
        "quality_breakdown": quality["quality_breakdown"],
        "insights": insights,
        "band_class": band_class,
        "texture_promoted": bool(profile_guess.get("texture_promoted")),
    }


def analyze_image(
    image_path: str,
    stats_roi: Tuple[int, int, int, int],
    top_scan_fraction: float,
    brightness_threshold: float,
    max_khz: float,
) -> Dict[str, Any]:
    image = cv2.imread(image_path)
    if image is None:
        raise ValueError(f"could not read image: {image_path}")

    regions = detect_spectrogram_regions(image)
    pane_mode = len(regions) >= 2 and not _region_is_full_frame(regions[0], image.shape)
    region = regions[0] if pane_mode else (0, 0, image.shape[1], image.shape[0])
    rx, ry, rw, rh = region

    # Auto-detect axis scale from the right-side ruler when available.
    auto_max_khz = infer_axis_scale_khz(image, region) if pane_mode else None
    if auto_max_khz is None:
        auto_max_khz = infer_axis_scale_khz_global(image)
    effective_max_khz = auto_max_khz if auto_max_khz is not None else max_khz

    analysis_image = image[ry : ry + rh, rx : rx + rw]
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    gray_analysis = cv2.cvtColor(analysis_image, cv2.COLOR_BGR2GRAY)
    height, width = gray.shape

    y0, y1, x0, x1 = stats_roi
    y0 = max(0, min(y0, height - 1))
    y1 = max(y0 + 1, min(y1, height))
    x0 = max(0, min(x0, width - 1))
    x1 = max(x0 + 1, min(x1, width))

    stats_crop = image[y0:y1, x0:x1]
    ocr_text = ocr_image_to_string(stats_crop, config="--psm 6")
    ocr_text = ocr_text.strip()

    # If pane detected, analyze the full pane height (already single channel).
    if pane_mode:
        scan_limit = max(1, gray_analysis.shape[0])
    else:
        scan_limit = max(1, min(height, int(height * top_scan_fraction)))
        gray_analysis = gray_analysis[:scan_limit, :]

    signature = analyze_spectral_signature(
        gray=gray_analysis,
        scan_limit=scan_limit,
        max_khz=effective_max_khz,
        brightness_threshold=brightness_threshold,
        energy_mode="intensity" if pane_mode else "texture",
    )

    # Tiny screenshots (common for compressed web spectrogram snippets) often
    # lose readable axis labels; remap scale heuristically when the current
    # estimate implies an implausibly high ceiling for the frame geometry.
    tiny_frame = image.shape[0] <= 260 and image.shape[1] <= 420
    if auto_max_khz is None and tiny_frame:
        detected_guess = float(signature["detected_khz"])
        ratio_guess = float(signature["high_band_ratio"])
        span_guess = float(signature["dynamic_span"])
        likely_low_ceiling = (
            detected_guess >= 70.0
            or (30.0 <= detected_guess <= 50.0 and ratio_guess < 0.35 and span_guess < 22.0)
        )
        if likely_low_ceiling:
            effective_max_khz = 22.05
            signature = analyze_spectral_signature(
                gray=gray_analysis,
                scan_limit=scan_limit,
                max_khz=effective_max_khz,
                brightness_threshold=brightness_threshold,
                energy_mode="intensity" if pane_mode else "texture",
            )
    cutoff_row = int(signature["cutoff_row"])
    transition_found = bool(signature["transition_found"])
    detected_khz = float(signature["detected_khz"])

    peak_db = parse_labeled_number(ocr_text, ["Peak Amplitude", "Peak"])
    dynamic_range_db = parse_dynamic_range_number(ocr_text)
    stats_detected = bool(
        peak_db is not None
        or dynamic_range_db is not None
        or _ocr_has_mastering_stats(ocr_text)
    )

    verdict = build_verdict(
        cutoff_khz=detected_khz,
        max_khz=effective_max_khz,
        transition_found=transition_found,
        stats_detected=stats_detected,
        peak_db=peak_db,
        dynamic_range_db=dynamic_range_db,
        dynamic_span=float(signature["dynamic_span"]),
        high_band_ratio=float(signature["high_band_ratio"]),
        brickwall_hint=bool(signature["brickwall_hint"]),
        brickwall_khz=float(signature["brickwall_khz"]),
    )

    return {
        "image_path": image_path,
        "detected_cutoff_khz": round(detected_khz, 2),
        "cutoff_row": cutoff_row,
        "scan_limit": scan_limit,
        "transition_found": transition_found,
        "scan_params": {
            "top_scan_fraction": top_scan_fraction,
            "brightness_threshold": brightness_threshold,
            "max_khz": effective_max_khz,
            "max_khz_source": "auto_axis_ocr" if auto_max_khz is not None else ("heuristic_tiny_fallback" if tiny_frame and effective_max_khz == 22.05 else "cli_default"),
        },
        "pane_mode": pane_mode,
        "analysis_region": {"x": rx, "y": ry, "w": rw, "h": rh},
        "stats_roi_used": {"y0": y0, "y1": y1, "x0": x0, "x1": x1},
        "stats_detected": stats_detected,
        "peak_amplitude_db": peak_db,
        "dynamic_range_db": dynamic_range_db,
        "spectral_signature": signature,
        "ocr_text": ocr_text,
        "verdict": verdict,
    }


def print_report(result: Dict[str, Any], show_metrics: bool, show_ocr: bool, show_explain: bool) -> None:
    verdict = result["verdict"]
    insights = verdict.get("insights", [])

    print("-" * 30)
    print("--- AUDIO QUALITY VERDICT ---")
    print(f"Image: {result['image_path']}")
    print(f"Likely Profile: {verdict['profile_name']} ({verdict['likely_profile']})")
    print(f"Confidence: {verdict['confidence']}")
    print(
        "Quality Class: "
        f"{verdict['quality_class']} ({verdict['quality_label']}, "
        f"confidence={verdict['quality_confidence']})"
    )
    print(f"Summary: {verdict['summary']}")
    for note in insights:
        print(f"Insight: {note}")

    if show_explain:
        breakdown = verdict.get("quality_breakdown", {})
        components = breakdown.get("components", [])
        print("")
        print("--- QUALITY SCORING BREAKDOWN ---")
        print(f"Base score: {breakdown.get('base_score', 0)}")
        for item in components:
            factor = item.get("factor")
            value = item.get("value")
            delta = int(item.get("delta", 0))
            reason = item.get("reason", "")
            sign = "+" if delta >= 0 else ""
            print(f"{factor} ({value}): {sign}{delta}  {reason}")
        print(
            f"Raw score: {breakdown.get('raw_score', verdict.get('quality_score'))} "
            f"-> Final: {breakdown.get('final_score', verdict.get('quality_score'))}"
        )

    if show_metrics:
        print("")
        print("--- DETECTION METRICS ---")
        print(f"Detected Cutoff: ~{result['detected_cutoff_khz']:.2f} kHz")
        print(f"Stats Window Detected: {'yes' if result['stats_detected'] else 'no'}")
        peak_db = result["peak_amplitude_db"]
        dynamic_range_db = result["dynamic_range_db"]
        if peak_db is not None:
            print(f"Peak Amplitude: {peak_db:.2f} dB")
        if dynamic_range_db is not None:
            print(f"Dynamic Range: {dynamic_range_db:.2f} dB")

    if show_ocr:
        print("")
        print("--- OCR TEXT (RAW) ---")
        raw = result.get("ocr_text") or ""
        if raw:
            print(raw)
        else:
            print("<empty>")

    print("-" * 30)


def build_compact_output(result: Dict[str, Any]) -> Dict[str, Any]:
    verdict = result.get("verdict", {})
    profile_name = verdict.get("profile_name")
    profile_code = verdict.get("likely_profile")
    if profile_name and profile_code:
        likely_profile = f"{profile_name} ({profile_code})"
    else:
        likely_profile = profile_name or profile_code

    return {
        "image": result.get("image_path"),
        "likely_profile": likely_profile,
        "confidence": verdict.get("confidence"),
        "quality_class": verdict.get("quality_class"),
    }


def positive_float_in_0_1(value: str) -> float:
    parsed = float(value)
    if not (0.0 < parsed <= 1.0):
        raise argparse.ArgumentTypeError("value must be > 0 and <= 1")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Read a spectrogram image, infer the most likely source profile,"
            " and emit quality insights from OCR stats."
        )
    )
    parser.add_argument("image_path", help="Path to the spectrogram image file")
    parser.add_argument(
        "--stats-roi",
        type=parse_roi,
        default=parse_roi("0:500,0:400"),
        help="ROI used for OCR as Y0:Y1,X0:X1 (default: 0:500,0:400)",
    )
    parser.add_argument(
        "--top-scan-fraction",
        type=positive_float_in_0_1,
        default=0.5,
        help="Fraction of image height to scan from top (default: 0.5)",
    )
    parser.add_argument(
        "--brightness-threshold",
        type=float,
        default=35.0,
        help="Mean grayscale threshold used to mark cutoff transition (default: 35)",
    )
    parser.add_argument(
        "--max-khz",
        type=float,
        default=96.0,
        help="Frequency represented by top edge of the scan area (default: 96)",
    )
    parser.add_argument(
        "--show-metrics",
        action="store_true",
        help="Legacy option (ignored in JSON output mode).",
    )
    parser.add_argument(
        "--show-ocr",
        action="store_true",
        help="Legacy option (ignored unless --full is used).",
    )
    explain_group = parser.add_mutually_exclusive_group()
    explain_group.add_argument(
        "--explain",
        dest="show_explain",
        action="store_true",
        help="Legacy option (ignored in JSON output mode).",
    )
    explain_group.add_argument(
        "--no-explain",
        dest="show_explain",
        action="store_false",
        help="Legacy option (ignored in JSON output mode).",
    )
    parser.set_defaults(show_explain=True)
    parser.add_argument(
        "--full",
        action="store_true",
        help="Emit full JSON payload (default output is compact JSON summary).",
    )
    # Backward-compatible alias. Compact JSON is now default.
    parser.add_argument("--json", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    if IMPORT_ERROR is not None:
        print(f"Error: missing Python dependency: {IMPORT_ERROR}", file=sys.stderr)
        return 1

    try:
        result = analyze_image(
            image_path=args.image_path,
            stats_roi=args.stats_roi,
            top_scan_fraction=args.top_scan_fraction,
            brightness_threshold=args.brightness_threshold,
            max_khz=args.max_khz,
        )
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    if args.full or args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print(json.dumps(build_compact_output(result), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
