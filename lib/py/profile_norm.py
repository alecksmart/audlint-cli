"""Profile normalization helpers.

Canonical internal format is ``SR_HZ/BITS`` (for example ``44100/16``).
"""

from __future__ import annotations

import re
from typing import Final, Optional, Tuple

_PROFILE_SPLIT_RE: Final[re.Pattern[str]] = re.compile(r"^([^/:-]+)[/:-]([^/:-]+)$")
_PROFILE_PACKED_RE: Final[re.Pattern[str]] = re.compile(r"^([0-9]+(?:\.[0-9]+)?(?:khz|k)?)([0-9]{2,3}f?)$")

SUPPORTED_TARGET_PROFILES: Final[tuple[str, ...]] = (
    "44100/16",
    "44100/24",
    "48000/24",
    "88200/24",
    "96000/24",
    "176400/24",
    "192000/24",
)


def _compact_lower(raw: str) -> str:
    return "".join(raw.strip().lower().split())


def normalize_bits(raw: str) -> Optional[str]:
    token = _compact_lower(raw)
    if not token:
        return None

    aliases = {
        "32f": "32f",
        "f32": "32f",
        "float32": "32f",
        "flt": "32f",
        "fltp": "32f",
        "64f": "64f",
        "f64": "64f",
        "float64": "64f",
        "double": "64f",
        "dbl": "64f",
        "dblp": "64f",
    }
    if token in aliases:
        return aliases[token]

    m = re.match(r"^([0-9]{1,3})(?:bits?|b)?$", token)
    if not m:
        return None
    bits = int(m.group(1))
    if bits <= 0:
        return None
    return str(bits)


def normalize_sr_hz(raw: str) -> Optional[int]:
    token = _compact_lower(raw)
    if not token:
        return None

    m = re.match(r"^([0-9]+(?:\.[0-9]+)?)(?:khz|k)$", token)
    if m:
        value = float(m.group(1)) * 1000.0
        hz = int(round(value))
        return hz if hz > 0 else None

    m = re.match(r"^([0-9]+(?:\.[0-9]+)?)hz$", token)
    if m:
        value = float(m.group(1))
        hz = int(round(value))
        return hz if hz > 0 else None

    if not re.match(r"^[0-9]+(?:\.[0-9]+)?$", token):
        return None

    value = float(token)
    if value <= 0:
        return None

    if "." in token:
        hz = int(round(value if value >= 1000.0 else value * 1000.0))
    else:
        hz = int(value if value >= 1000 else value * 1000)

    return hz if hz > 0 else None


def normalize_profile(raw: str) -> Optional[str]:
    token = _compact_lower(raw).replace("_", "/")
    if not token:
        return None

    m = _PROFILE_SPLIT_RE.match(token)
    if m:
        sr_token, bits_token = m.group(1), m.group(2)
    else:
        m = _PROFILE_PACKED_RE.match(token)
        if not m:
            return None
        sr_token, bits_token = m.group(1), m.group(2)

    sr_hz = normalize_sr_hz(sr_token)
    bits = normalize_bits(bits_token)
    if sr_hz is None or bits is None:
        return None
    return f"{sr_hz}/{bits}"


def split_canonical_profile(raw: str) -> Optional[Tuple[int, str]]:
    normalized = normalize_profile(raw)
    if normalized is None:
        return None
    sr, bits = normalized.split("/", 1)
    return int(sr), bits


def profile_help_text() -> str:
    return "\n".join(
        [
            "Accepted profile input forms (fuzzy):",
            "  44100/16",
            "  44.1/16",
            "  44.1-16",
            "  44k/16",
            "  44khz/16",
            "",
            "Canonical internal format:",
            "  SR_HZ/BITS  (example: 44100/16)",
        ]
    )
