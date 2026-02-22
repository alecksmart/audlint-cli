#!/usr/bin/env python3
"""
genre_lookup.py — Fetch genre profile for an artist+album from MusicBrainz
(with optional Last.fm fallback) and map to one of three quality profiles:

  audiophile   — classical, jazz, blues, folk, acoustic, ambient
  high_energy  — rock, metal, punk, electronic, edm, hip-hop, rap, techno
  standard     — everything else / no tag found

Usage (CLI):
    genre_lookup.py <artist> <album>
    → prints one of: audiophile | high_energy | standard

Usage (module):
    from genre_lookup import get_genre_profile
    profile = get_genre_profile("Miles Davis", "Kind of Blue")
"""

import os
import sys
import time

# ---------------------------------------------------------------------------
# Tag → profile mapping
# ---------------------------------------------------------------------------

_AUDIOPHILE_KEYWORDS = {
    "classical", "classic", "orchestra", "symphony", "chamber",
    "opera", "baroque", "romantic", "choral", "choir",
    "jazz", "bebop", "swing", "bossa nova", "cool jazz", "modal jazz",
    "blues", "delta blues", "country blues",
    "folk", "acoustic", "singer-songwriter",
    "ambient", "new age", "meditation",
}

_HIGH_ENERGY_KEYWORDS = {
    "rock", "hard rock", "classic rock", "alternative rock", "indie rock",
    "metal", "heavy metal", "death metal", "black metal", "thrash", "doom",
    "punk", "hardcore", "post-punk",
    "electronic", "electro", "synth", "synthpop",
    "edm", "house", "techno", "trance", "drum and bass", "dnb",
    "dubstep", "breakbeat", "industrial",
    "hip hop", "hip-hop", "rap", "trap", "grime",
    "grunge", "noise", "experimental",
}


def _classify_tags(tags: list[str]) -> str:
    """Map a list of lowercased tag strings to a genre profile."""
    audiophile_score = 0
    high_energy_score = 0

    for tag in tags:
        tag = tag.lower().strip()
        for kw in _AUDIOPHILE_KEYWORDS:
            if kw in tag:
                audiophile_score += 1
                break
        for kw in _HIGH_ENERGY_KEYWORDS:
            if kw in tag:
                high_energy_score += 1
                break

    if audiophile_score == 0 and high_energy_score == 0:
        return "standard"
    if audiophile_score >= high_energy_score:
        return "audiophile"
    return "high_energy"


# ---------------------------------------------------------------------------
# MusicBrainz lookup (primary, free, no API key)
# ---------------------------------------------------------------------------

_MB_LAST_REQUEST = 0.0
_MB_MIN_INTERVAL = 1.05  # 1 req/s hard limit per MusicBrainz ToS


def _mb_fetch(artist: str, album: str) -> list[str]:
    """Query MusicBrainz for release tags.  Returns list of tag name strings."""
    global _MB_LAST_REQUEST
    try:
        import musicbrainzngs as mb
    except ImportError:
        return []

    mb.set_useragent(
        "audlint-genre-lookup",
        "1.0",
        "https://github.com/audlint/audlint-cli",
    )

    # Rate-limit: honour 1 req/s
    elapsed = time.monotonic() - _MB_LAST_REQUEST
    if elapsed < _MB_MIN_INTERVAL:
        time.sleep(_MB_MIN_INTERVAL - elapsed)
    _MB_LAST_REQUEST = time.monotonic()

    try:
        res = mb.search_releases(artist=artist, release=album, limit=5)
        releases = res.get("release-list", [])
        for release in releases:
            tag_list = release.get("tag-list", [])
            if tag_list:
                return [t["name"] for t in tag_list]

        # If first-page results had no tags, try a direct lookup on the best match.
        if releases:
            mbid = releases[0].get("id", "")
            if mbid:
                elapsed = time.monotonic() - _MB_LAST_REQUEST
                if elapsed < _MB_MIN_INTERVAL:
                    time.sleep(_MB_MIN_INTERVAL - elapsed)
                _MB_LAST_REQUEST = time.monotonic()
                detail = mb.get_release_by_id(mbid, includes=["tags"])
                tag_list = detail.get("release", {}).get("tag-list", [])
                return [t["name"] for t in tag_list]
    except Exception:
        pass
    return []


# ---------------------------------------------------------------------------
# Discogs fallback (free, no API key required for search)
# ---------------------------------------------------------------------------

def _discogs_fetch(artist: str, album: str) -> list[str]:
    """Query Discogs database search for genres and styles.
    No API key required.  Returns genres + styles as a flat list."""
    import urllib.request
    import urllib.parse
    import json as _json

    params = urllib.parse.urlencode({
        "q": f"{artist} {album}",
        "type": "release",
        "per_page": "3",
        "page": "1",
    })
    url = f"https://api.discogs.com/database/search?{params}"
    headers = {
        "User-Agent": "audlint-genre-lookup/1.0",
    }
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = _json.loads(resp.read().decode())
        results = data.get("results", [])
        tags: list[str] = []
        for result in results:
            tags.extend(result.get("genre", []))
            tags.extend(result.get("style", []))
            if tags:
                break  # first result with genre/style data is sufficient
        return tags
    except Exception:
        return []


# ---------------------------------------------------------------------------
# Last.fm fallback (requires LASTFM_API_KEY env var)
# ---------------------------------------------------------------------------

def _lastfm_fetch(artist: str, album: str) -> list[str]:
    """Query Last.fm album.getInfo for top tags.  Requires LASTFM_API_KEY env var."""
    api_key = os.environ.get("LASTFM_API_KEY", "")
    if not api_key:
        return []
    try:
        import urllib.request
        import urllib.parse
        import json as _json
        params = urllib.parse.urlencode({
            "method": "album.getinfo",
            "api_key": api_key,
            "artist": artist,
            "album": album,
            "format": "json",
        })
        url = f"http://ws.audioscrobbler.com/2.0/?{params}"
        with urllib.request.urlopen(url, timeout=8) as resp:
            data = _json.loads(resp.read().decode())
        tags = data.get("album", {}).get("tags", {}).get("tag", [])
        return [t["name"] for t in tags]
    except Exception:
        return []


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def get_genre_result(artist: str, album: str) -> tuple[str, str]:
    """Return (profile, best_raw_tag) for the given artist+album.

    profile      — one of 'audiophile', 'high_energy', 'standard'
    best_raw_tag — the highest-priority raw tag string (title-cased), or ''
                   if no tags were found.  Suitable for embedding as GENRE.

    Tries MusicBrainz first, then Last.fm if LASTFM_API_KEY is set.
    """
    tags = _mb_fetch(artist, album)
    if not tags:
        tags = _discogs_fetch(artist, album)
    if not tags:
        tags = _lastfm_fetch(artist, album)
    profile = _classify_tags(tags)
    best_raw = tags[0].title() if tags else ""
    return profile, best_raw


def get_genre_profile(artist: str, album: str) -> str:
    """Return a genre profile string for the given artist+album (profile only)."""
    profile, _ = get_genre_result(artist, album)
    return profile


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: genre_lookup.py <artist> <album>", file=sys.stderr)
        sys.exit(2)
    artist = sys.argv[1]
    album = sys.argv[2]
    profile, best_raw = get_genre_result(artist, album)
    # Line 1: profile (always present)
    # Line 2: best raw tag for embedding (empty string if none found)
    print(profile)
    print(best_raw)


if __name__ == "__main__":
    main()
