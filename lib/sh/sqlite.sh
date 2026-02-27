#!/usr/bin/env bash

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

norm_lc() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "${raw,,}"
}

norm_lc_or_null_sql() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf 'NULL'
    return 0
  fi
  printf "'%s'" "$(sql_escape "$(norm_lc "$raw")")"
}

_sqlite_trim() {
  printf '%s' "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

_sqlite_ensure_profile_normalizer() {
  if declare -F profile_normalize >/dev/null 2>&1; then
    return 0
  fi
  local lib_dir profile_lib
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  profile_lib="$lib_dir/profile.sh"
  [[ -f "$profile_lib" ]] || return 1
  # shellcheck source=/dev/null
  source "$profile_lib"
  declare -F profile_normalize >/dev/null 2>&1
}

_sqlite_profile_canonical_into() {
  local raw out_var normalized
  raw="$(_sqlite_trim "${1:-}")"
  out_var="${2:-}"
  [[ -n "$out_var" ]] || return 1
  [[ -n "$raw" ]] || return 1
  _sqlite_ensure_profile_normalizer || return 1
  normalized="$(profile_normalize "$raw" 2>/dev/null || true)"
  [[ -n "$normalized" ]] || return 1
  printf -v "$out_var" '%s' "$normalized"
  return 0
}

norm_profile_or_null_sql() {
  local raw canonical
  raw="$(_sqlite_trim "${1:-}")"
  [[ -n "$raw" ]] || {
    printf 'NULL'
    return 0
  }
  canonical=""
  if _sqlite_profile_canonical_into "$raw" canonical; then
    printf "'%s'" "$(sql_escape "$canonical")"
  else
    printf "'%s'" "$(sql_escape "$(norm_lc "$raw")")"
  fi
}

sql_num_or_null() {
  local v="$1"
  if [[ "$v" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$v"
  else
    printf 'NULL'
  fi
}

_album_quality_has_column() {
  local db="$1"
  local col="$2"
  local rows
  rows="$(sqlite3 -noheader "$db" "PRAGMA table_info(album_quality);" 2>/dev/null || true)"
  printf '%s\n' "$rows" | awk -F'|' -v c="$col" '$2 == c { found = 1 } END { exit(found ? 0 : 1) }'
}

album_quality_db_init() {
  local db="$1"
  local db_dir
  db_dir="$(dirname "$db")"
  mkdir -p "$db_dir" 2>/dev/null || return 1
  sqlite3 "$db" <<'SQL' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS album_quality (
  id INTEGER PRIMARY KEY,
  artist TEXT NOT NULL,
  artist_lc TEXT NOT NULL,
  artist_norm TEXT,
  album TEXT NOT NULL,
  album_lc TEXT NOT NULL,
  album_norm TEXT,
  year_int INTEGER NOT NULL,
  quality_grade TEXT,
  grade_rank INTEGER,
  quality_score REAL,
  dynamic_range_score REAL,
  is_upscaled INTEGER,
  recommendation TEXT,
  current_quality TEXT,
  profile_norm TEXT,
  bitrate TEXT,
  codec TEXT,
  codec_norm TEXT,
  recode_recommendation TEXT,
  needs_recode INTEGER NOT NULL DEFAULT 0,
  has_lyrics INTEGER NOT NULL DEFAULT 0,
  last_recoded_at INTEGER,
  needs_replacement INTEGER NOT NULL DEFAULT 0,
  rarity INTEGER NOT NULL DEFAULT 0,
  last_checked_at INTEGER,
  checked_sort INTEGER,
  scan_failed INTEGER NOT NULL DEFAULT 0,
  source_path TEXT,
  notes TEXT,
  genre_profile TEXT,
  recode_source_profile TEXT
);
SQL
  local needs_refresh_derived=0

  if ! _album_quality_has_column "$db" "last_checked_at"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN last_checked_at INTEGER;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "scan_failed"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN scan_failed INTEGER NOT NULL DEFAULT 0;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "current_quality"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN current_quality TEXT;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "bitrate"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN bitrate TEXT;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "codec"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN codec TEXT;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "recode_recommendation"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN recode_recommendation TEXT;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "artist_norm"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN artist_norm TEXT;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "album_norm"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN album_norm TEXT;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "grade_rank"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN grade_rank INTEGER;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "checked_sort"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN checked_sort INTEGER;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "profile_norm"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN profile_norm TEXT;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "codec_norm"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN codec_norm TEXT;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "needs_recode"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN needs_recode INTEGER NOT NULL DEFAULT 0;" >/dev/null 2>&1 || true
    needs_refresh_derived=1
  fi
  if ! _album_quality_has_column "$db" "has_lyrics"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN has_lyrics INTEGER NOT NULL DEFAULT 0;" >/dev/null 2>&1 || true
  fi
  if ! _album_quality_has_column "$db" "last_recoded_at"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN last_recoded_at INTEGER;" >/dev/null 2>&1 || true
  fi
  if ! _album_quality_has_column "$db" "genre_profile"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN genre_profile TEXT;" >/dev/null 2>&1 || true
  fi
  if ! _album_quality_has_column "$db" "recode_source_profile"; then
    sqlite3 "$db" "ALTER TABLE album_quality ADD COLUMN recode_source_profile TEXT;" >/dev/null 2>&1 || true
  fi

  sqlite3 "$db" <<'SQL' >/dev/null 2>&1
CREATE UNIQUE INDEX IF NOT EXISTS idx_album_quality_key
  ON album_quality(artist_lc, album_lc, year_int);
CREATE INDEX IF NOT EXISTS idx_album_quality_flags
  ON album_quality(needs_replacement, rarity);
CREATE INDEX IF NOT EXISTS idx_album_quality_scan_failed
  ON album_quality(scan_failed);
CREATE INDEX IF NOT EXISTS idx_album_quality_source_path
  ON album_quality(source_path);
SQL

  # Remove pre-partial broad indexes superseded by hot-view partial indexes.
  sqlite3 "$db" <<'SQL' >/dev/null 2>&1 || true
DROP INDEX IF EXISTS idx_album_quality_browse_checked;
DROP INDEX IF EXISTS idx_album_quality_scanfail_checked;
DROP INDEX IF EXISTS idx_album_quality_sort_grade;
DROP INDEX IF EXISTS idx_album_quality_sort_codec;
DROP INDEX IF EXISTS idx_album_quality_filter_codec;
DROP INDEX IF EXISTS idx_album_quality_filter_profile;
SQL

  sqlite3 "$db" <<'SQL' >/dev/null 2>&1
-- Primary hot path: default browse (non-rarity) ordered by checked DESC.
CREATE INDEX IF NOT EXISTS idx_album_quality_hot_checked_r0
  ON album_quality(checked_sort DESC, artist_norm, album_norm, year_int, id)
  WHERE rarity=0;
-- Rarity-only view counterpart.
CREATE INDEX IF NOT EXISTS idx_album_quality_hot_checked_r1
  ON album_quality(checked_sort DESC, artist_norm, album_norm, year_int, id)
  WHERE rarity=1;
-- Hot path: scan-failed queue in non-rarity set.
CREATE INDEX IF NOT EXISTS idx_album_quality_hot_scan_failed_checked_r0
  ON album_quality(checked_sort DESC, artist_norm, album_norm, year_int, id)
  WHERE rarity=0 AND scan_failed=1;
-- Hot path: grade-priority view in non-rarity set.
CREATE INDEX IF NOT EXISTS idx_album_quality_hot_grade_r0
  ON album_quality(grade_rank, COALESCE(quality_score,9999), artist_norm, album_norm, year_int, id)
  WHERE rarity=0;
-- Hot path: codec/profile filter selectors in non-rarity set.
CREATE INDEX IF NOT EXISTS idx_album_quality_hot_codec_filter_r0
  ON album_quality(codec_norm, checked_sort DESC, artist_norm, album_norm, year_int, id)
  WHERE rarity=0;
CREATE INDEX IF NOT EXISTS idx_album_quality_hot_profile_filter_r0
  ON album_quality(profile_norm, checked_sort DESC, artist_norm, album_norm, year_int, id)
  WHERE rarity=0;
SQL

  # Expose schema-change flag so callers can force-refresh backups.
  ALBUM_QUALITY_DB_SCHEMA_CHANGED="${needs_refresh_derived}"

  if ((needs_refresh_derived == 1)); then
    sqlite3 "$db" <<'SQL' >/dev/null 2>&1 || true
UPDATE album_quality
SET
  artist_norm=COALESCE(NULLIF(TRIM(artist_lc),''), COALESCE(artist_norm,'')),
  album_norm=COALESCE(NULLIF(TRIM(album_lc),''), COALESCE(album_norm,'')),
  grade_rank=CASE quality_grade
    WHEN 'F' THEN 1
    WHEN 'C' THEN 2
    WHEN 'B' THEN 3
    WHEN 'A' THEN 4
    WHEN 'S' THEN 5
    ELSE 6
  END,
  checked_sort=COALESCE(last_checked_at,0),
  profile_norm=LOWER(TRIM(COALESCE(current_quality,''))),
  codec_norm=LOWER(TRIM(COALESCE(codec,'')))
WHERE
  artist_norm IS NULL OR artist_norm=''
  OR album_norm IS NULL OR album_norm=''
  OR grade_rank IS NULL
  OR checked_sort IS NULL
  OR profile_norm IS NULL
  OR codec_norm IS NULL;
SQL
  fi

  album_quality_normalize_profile_columns_once "$db" || true

  # Prefer WAL for concurrent read-heavy browsing with batch writes.
  sqlite3 "$db" "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;" >/dev/null 2>&1 || true

  # Optional fast text search index; skip silently if this sqlite build lacks FTS5.
  if sqlite3 "$db" <<'SQL' >/dev/null 2>&1; then
CREATE VIRTUAL TABLE IF NOT EXISTS album_quality_fts USING fts5(
  artist,
  album,
  content='album_quality',
  content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);
SQL
    sqlite3 "$db" <<'SQL' >/dev/null 2>&1 || true
CREATE TRIGGER IF NOT EXISTS trg_album_quality_fts_ai
AFTER INSERT ON album_quality
BEGIN
  INSERT INTO album_quality_fts(rowid, artist, album)
  VALUES (new.id, new.artist, new.album);
END;

CREATE TRIGGER IF NOT EXISTS trg_album_quality_fts_ad
AFTER DELETE ON album_quality
BEGIN
  INSERT INTO album_quality_fts(album_quality_fts, rowid, artist, album)
  VALUES ('delete', old.id, old.artist, old.album);
END;

CREATE TRIGGER IF NOT EXISTS trg_album_quality_fts_au
AFTER UPDATE OF artist, album ON album_quality
BEGIN
  INSERT INTO album_quality_fts(album_quality_fts, rowid, artist, album)
  VALUES ('delete', old.id, old.artist, old.album);
  INSERT INTO album_quality_fts(rowid, artist, album)
  VALUES (new.id, new.artist, new.album);
END;
SQL

    sqlite3 "$db" "CREATE TABLE IF NOT EXISTS app_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);" >/dev/null 2>&1 || true
    local fts_version
    fts_version="$(sqlite3 -noheader "$db" "SELECT value FROM app_meta WHERE key='album_quality_fts_index_version' LIMIT 1;" 2>/dev/null || true)"
    if [[ "$fts_version" != "1" ]]; then
      sqlite3 "$db" "INSERT INTO album_quality_fts(album_quality_fts) VALUES('rebuild');" >/dev/null 2>&1 || true
      sqlite3 "$db" "INSERT INTO app_meta(key,value) VALUES('album_quality_fts_index_version','1') ON CONFLICT(key) DO UPDATE SET value=excluded.value;" >/dev/null 2>&1 || true
    fi
  fi
}

album_quality_normalize_profile_columns() {
  local db="$1"
  local rows
  local row_sep=$'\x1f'
  _sqlite_ensure_profile_normalizer || true
  rows="$(sqlite3 -separator "$row_sep" -noheader "$db" \
    "SELECT id, COALESCE(current_quality,''), COALESCE(profile_norm,'')
       FROM album_quality
      WHERE NULLIF(TRIM(COALESCE(current_quality,'')),'') IS NOT NULL
         OR NULLIF(TRIM(COALESCE(profile_norm,'')),'') IS NOT NULL;" 2>/dev/null || true)"
  [[ -n "$rows" ]] || return 0

  local -a sql_updates=()
  local id curr_raw prof_raw curr_trim prof_trim canonical desired_norm
  local changed=0

  while IFS="$row_sep" read -r id curr_raw prof_raw; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    curr_trim="$(_sqlite_trim "$curr_raw")"
    prof_trim="$(_sqlite_trim "$prof_raw")"

    canonical=""
    if ! _sqlite_profile_canonical_into "$curr_trim" canonical; then
      _sqlite_profile_canonical_into "$prof_trim" canonical || true
    fi

    if [[ -n "$canonical" ]]; then
      desired_norm="$(norm_lc "$canonical")"
      if [[ "$curr_trim" != "$canonical" || "$prof_trim" != "$desired_norm" ]]; then
        sql_updates+=(
          "UPDATE album_quality
           SET current_quality='$(sql_escape "$canonical")',
               profile_norm='$(sql_escape "$desired_norm")'
           WHERE id=$id;"
        )
        changed=1
      fi
      continue
    fi

    # Non-profile text should remain untouched in current_quality; only keep
    # profile_norm synchronized for stable filtering.
    desired_norm=""
    if [[ -n "$curr_trim" ]]; then
      desired_norm="$(norm_lc "$curr_trim")"
    elif [[ -n "$prof_trim" ]]; then
      desired_norm="$(norm_lc "$prof_trim")"
    fi
    if [[ -n "$desired_norm" && "$prof_trim" != "$desired_norm" ]]; then
      sql_updates+=(
        "UPDATE album_quality
         SET profile_norm='$(sql_escape "$desired_norm")'
         WHERE id=$id;"
      )
      changed=1
    fi
  done <<<"$rows"

  ((changed == 1)) || return 0
  local apply_err=""
  if ! apply_err="$(
    {
      printf 'BEGIN;\n'
      printf '%s\n' "${sql_updates[@]}"
      printf 'COMMIT;\n'
    } | sqlite3 "$db" 2>&1 >/dev/null
  )"; then
    printf 'album_quality_normalize_profile_columns: sqlite apply failed: %s\n' "$apply_err" >&2
    return 1
  fi
}

album_quality_normalize_profile_columns_once() {
  local db="$1"
  local meta_key="album_quality_profile_norm_version"
  local meta_ver="1"

  sqlite3 "$db" "CREATE TABLE IF NOT EXISTS app_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);" >/dev/null 2>&1 || return 1

  local current_ver=""
  current_ver="$(sqlite3 -noheader "$db" "SELECT value FROM app_meta WHERE key='${meta_key}' LIMIT 1;" 2>/dev/null || true)"
  if [[ "$current_ver" == "$meta_ver" ]]; then
    return 0
  fi

  album_quality_normalize_profile_columns "$db" || return 1

  sqlite3 "$db" \
    "INSERT INTO app_meta(key,value) VALUES('${meta_key}','${meta_ver}')
     ON CONFLICT(key) DO UPDATE SET value=excluded.value;" >/dev/null 2>&1 || return 1
}

album_quality_sync_lc_columns() {
  local db="$1"
  local rows
  rows="$(sqlite3 -separator $'\x1f' -noheader "$db" "SELECT id, artist, album FROM album_quality;" 2>/dev/null || true)"
  [[ -n "$rows" ]] || return 0

  local sql_updates=()
  local id artist album artist_lc album_lc changed=0
  while IFS=$'\x1f' read -r id artist album; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    artist_lc="$(norm_lc "$artist")"
    album_lc="$(norm_lc "$album")"
    sql_updates+=(
      "UPDATE OR IGNORE album_quality
       SET artist_lc='$(sql_escape "$artist_lc")',
           album_lc='$(sql_escape "$album_lc")'
       WHERE id=$id
         AND (artist_lc!='$(sql_escape "$artist_lc")' OR album_lc!='$(sql_escape "$album_lc")');"
    )
    changed=1
  done <<<"$rows"

  ((changed == 1)) || return 0
  {
    printf 'BEGIN;\n'
    printf '%s\n' "${sql_updates[@]}"
    printf 'COMMIT;\n'
  } | sqlite3 "$db" >/dev/null 2>&1 || return 1
}

scan_roadmap_db_init() {
  local db="$1"
  local db_dir
  db_dir="$(dirname "$db")"
  mkdir -p "$db_dir" 2>/dev/null || return 1
  sqlite3 "$db" <<'SQL' >/dev/null 2>&1
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS scan_roadmap (
  id INTEGER PRIMARY KEY,
  artist TEXT NOT NULL,
  artist_lc TEXT NOT NULL,
  album TEXT NOT NULL,
  album_lc TEXT NOT NULL,
  year_int INTEGER NOT NULL,
  source_path TEXT NOT NULL,
  album_mtime INTEGER NOT NULL DEFAULT 0,
  scan_kind TEXT NOT NULL DEFAULT 'changed',
  enqueued_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_scan_roadmap_key
  ON scan_roadmap(artist_lc, album_lc, year_int);
CREATE INDEX IF NOT EXISTS idx_scan_roadmap_queue
  ON scan_roadmap(scan_kind, enqueued_at, id);
SQL
}

album_quality_is_replace() {
  local db="$1"
  local artist="$2"
  local year="$3"
  local album="$4"

  local artist_lc album_lc
  artist_lc="$(norm_lc "$artist")"
  album_lc="$(norm_lc "$album")"
  [[ "$year" =~ ^[0-9]{4}$ ]] || year=0

  local q
  q="$(sqlite3 -noheader "$db" \
    "SELECT needs_replacement FROM album_quality WHERE artist_lc='$(sql_escape "$artist_lc")' AND album_lc='$(sql_escape "$album_lc")' AND year_int=$year LIMIT 1;" 2>/dev/null || true)"
  [[ "$q" == "1" ]]
}

album_quality_upsert() {
  local db="$1"
  local artist="$2"
  local year="$3"
  local album="$4"
  local grade="$5"
  local score="$6"
  local dyn="$7"
  local ups="$8"
  local rec="$9"
  local needs_replacement="${10}"
  local source_path="${11}"
  local last_checked_at="${12:-}"
  local scan_failed="${13:-0}"
  local notes="${14:-}"
  local current_quality="${15:-}"
  local bitrate="${16:-}"
  local codec="${17:-}"
  local recode_recommendation="${18:-}"
  local needs_recode="${19:-0}"
  local genre_profile="${20:-}"
  local recode_source_profile="${21:-}"

  local now
  now="$(date +%s)"
  [[ -n "$last_checked_at" ]] || last_checked_at="$now"

  local artist_lc album_lc
  artist_lc="$(norm_lc "$artist")"
  album_lc="$(norm_lc "$album")"
  local artist_norm album_norm
  artist_norm="$artist_lc"
  album_norm="$album_lc"

  [[ "$year" =~ ^[0-9]{4}$ ]] || year=0
  [[ "$needs_replacement" =~ ^[01]$ ]] || needs_replacement=0
  [[ "$needs_recode" =~ ^[01]$ ]] || needs_recode=0
  [[ "$scan_failed" =~ ^[01]$ ]] || scan_failed=0

  local ups_i="NULL"
  if [[ "$ups" == "1" || "$ups" == "YES" ]]; then
    ups_i="1"
  elif [[ "$ups" == "0" || "$ups" == "NO" ]]; then
    ups_i="0"
  fi

  local grade_sql="NULL"
  local grade_rank_sql="NULL"
  if [[ "$grade" =~ ^[SABCF]$ ]]; then
    grade_sql="'$(sql_escape "$grade")'"
    case "$grade" in
    F) grade_rank_sql=1 ;;
    C) grade_rank_sql=2 ;;
    B) grade_rank_sql=3 ;;
    A) grade_rank_sql=4 ;;
    S) grade_rank_sql=5 ;;
    *) grade_rank_sql=6 ;;
    esac
  fi
  local rec_sql="NULL"
  if [[ -n "$rec" ]]; then
    rec_sql="'$(sql_escape "$rec")'"
  fi
  local current_quality_canonical=""
  if [[ -n "$current_quality" ]]; then
    if _sqlite_profile_canonical_into "$current_quality" current_quality_canonical; then
      current_quality="$current_quality_canonical"
    fi
  fi
  local current_quality_sql="NULL"
  if [[ -n "$current_quality" ]]; then
    current_quality_sql="'$(sql_escape "$current_quality")'"
  fi
  local codec_sql="NULL"
  if [[ -n "$codec" ]]; then
    codec_sql="'$(sql_escape "$codec")'"
  fi
  local bitrate_sql="NULL"
  if [[ -n "$bitrate" ]]; then
    bitrate_sql="'$(sql_escape "$bitrate")'"
  fi
  local recode_rec_sql="NULL"
  if [[ -n "$recode_recommendation" ]]; then
    recode_rec_sql="'$(sql_escape "$recode_recommendation")'"
  fi
  local codec_norm_sql profile_norm_sql
  codec_norm_sql="$(norm_lc_or_null_sql "$codec")"
  profile_norm_sql="$(norm_profile_or_null_sql "$current_quality")"
  local genre_profile_sql="NULL"
  if [[ -n "$genre_profile" ]]; then
    genre_profile_sql="'$(sql_escape "$genre_profile")'"
  fi
  local recode_source_profile_sql="NULL"
  if [[ -n "$recode_source_profile" ]]; then
    recode_source_profile_sql="'$(sql_escape "$recode_source_profile")'"
  fi

  local score_sql dyn_sql
  score_sql="$(sql_num_or_null "$score")"
  dyn_sql="$(sql_num_or_null "$dyn")"
  local checked_sql
  checked_sql="$(sql_num_or_null "$last_checked_at")"
  [[ "$checked_sql" == "NULL" ]] && checked_sql="$now"
  local checked_sort_sql
  checked_sort_sql="$checked_sql"
  local notes_sql="NULL"
  if [[ -n "$notes" ]]; then
    notes_sql="'$(sql_escape "$notes")'"
  elif [[ -z "$notes" ]]; then
    notes_sql="''"
  fi

  sqlite3 "$db" \
    "INSERT INTO album_quality (
     artist, artist_lc, artist_norm, album, album_lc, album_norm, year_int,
       quality_grade, grade_rank, quality_score, dynamic_range_score, is_upscaled, recommendation, current_quality, profile_norm, bitrate, codec, codec_norm, recode_recommendation,
       needs_recode, needs_replacement, rarity, last_checked_at, checked_sort, scan_failed, source_path, notes,
       genre_profile, recode_source_profile
     ) VALUES (
       '$(sql_escape "$artist")', '$(sql_escape "$artist_lc")', '$(sql_escape "$artist_norm")',
       '$(sql_escape "$album")', '$(sql_escape "$album_lc")', '$(sql_escape "$album_norm")', $year,
       $grade_sql, $grade_rank_sql, $score_sql, $dyn_sql, $ups_i, $rec_sql, $current_quality_sql, $profile_norm_sql, $bitrate_sql, $codec_sql, $codec_norm_sql, $recode_rec_sql,
       $needs_recode, $needs_replacement, 0, $checked_sql, $checked_sort_sql, $scan_failed, '$(sql_escape "$source_path")', $notes_sql,
       $genre_profile_sql, $recode_source_profile_sql
     )
     ON CONFLICT(artist_lc, album_lc, year_int) DO UPDATE SET
      artist=excluded.artist,
      artist_norm=excluded.artist_norm,
      album=excluded.album,
      album_norm=excluded.album_norm,
       quality_grade=COALESCE(excluded.quality_grade, album_quality.quality_grade),
       grade_rank=COALESCE(excluded.grade_rank, album_quality.grade_rank),
       quality_score=COALESCE(excluded.quality_score, album_quality.quality_score),
      dynamic_range_score=COALESCE(excluded.dynamic_range_score, album_quality.dynamic_range_score),
      is_upscaled=COALESCE(excluded.is_upscaled, album_quality.is_upscaled),
      recommendation=COALESCE(excluded.recommendation, album_quality.recommendation),
      current_quality=COALESCE(excluded.current_quality, album_quality.current_quality),
      profile_norm=COALESCE(excluded.profile_norm, album_quality.profile_norm),
      bitrate=COALESCE(excluded.bitrate, album_quality.bitrate),
      codec=COALESCE(excluded.codec, album_quality.codec),
      codec_norm=COALESCE(excluded.codec_norm, album_quality.codec_norm),
      recode_recommendation=COALESCE(excluded.recode_recommendation, album_quality.recode_recommendation),
      needs_recode=excluded.needs_recode,
      needs_replacement=excluded.needs_replacement,
      last_checked_at=excluded.last_checked_at,
      checked_sort=excluded.checked_sort,
      scan_failed=excluded.scan_failed,
       source_path=COALESCE(excluded.source_path, album_quality.source_path),
       notes=excluded.notes,
       genre_profile=COALESCE(excluded.genre_profile, album_quality.genre_profile),
       recode_source_profile=COALESCE(excluded.recode_source_profile, album_quality.recode_source_profile);" >/dev/null \
    || printf 'album_quality_upsert: sqlite3 error (artist=%s album=%s year=%s)\n' "$artist" "$album" "$year" >&2
}

album_quality_set_rarity() {
  local db="$1"
  local artist="$2"
  local year="$3"
  local album="$4"
  local rarity="$5"
  local source_path="$6"

  local now
  now="$(date +%s)"
  local artist_lc album_lc
  artist_lc="$(norm_lc "$artist")"
  album_lc="$(norm_lc "$album")"
  local artist_norm album_norm
  artist_norm="$artist_lc"
  album_norm="$album_lc"

  [[ "$year" =~ ^[0-9]{4}$ ]] || year=0
  [[ "$rarity" =~ ^[01]$ ]] || rarity=1

  sqlite3 "$db" \
    "INSERT INTO album_quality (
       artist, artist_lc, artist_norm, album, album_lc, album_norm, year_int,
       quality_grade, grade_rank, quality_score, dynamic_range_score, is_upscaled, recommendation, current_quality, profile_norm, codec, codec_norm, recode_recommendation, checked_sort,
       needs_replacement, rarity, last_checked_at, scan_failed, source_path, notes
     ) VALUES (
       '$(sql_escape "$artist")', '$(sql_escape "$artist_lc")', '$(sql_escape "$artist_norm")',
       '$(sql_escape "$album")', '$(sql_escape "$album_lc")', '$(sql_escape "$album_norm")', $year,
       NULL, 6, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0,
       0, $rarity, NULL, 0, '$(sql_escape "$source_path")', NULL
     )
     ON CONFLICT(artist_lc, album_lc, year_int) DO UPDATE SET
       artist=excluded.artist,
       artist_norm=excluded.artist_norm,
       album=excluded.album,
       album_norm=excluded.album_norm,
       rarity=$rarity,
       source_path=COALESCE(excluded.source_path, album_quality.source_path);" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# DB backup helpers
# ---------------------------------------------------------------------------

_db_backup_stat_epoch_mtime() {
  local path="$1"
  local out=""
  if out="$(stat -f '%m' "$path" 2>/dev/null)"; then
    printf '%s\n' "$out"
    return 0
  fi
  if out="$(stat -c '%Y' "$path" 2>/dev/null)"; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

_db_backup_bundle_is_valid() {
  local bundle="$1"
  local bak_entry="$2"
  local stamp_entry="$3"
  local names=""
  [[ -f "$bundle" ]] || return 1
  unzip -tqq "$bundle" >/dev/null 2>&1 || return 1
  names="$(unzip -Z1 "$bundle" 2>/dev/null || true)"
  [[ -n "$names" ]] || return 1
  printf '%s\n' "$names" | grep -Fx "$bak_entry" >/dev/null || return 1
  printf '%s\n' "$names" | grep -Fx "$stamp_entry" >/dev/null || return 1
  return 0
}

_db_backup_cleanup_existing() {
  local db="$1"
  local db_base period bundle_path bak_entry stamp_entry file
  local had_nullglob=0

  db_base="$(basename "$db")"

  # Remove legacy loose artifacts.
  rm -f \
    "${db}.hourly.bak" "${db}.hourly.bak.stamp" "${db}.hourly.bak.zip" \
    "${db}.daily.bak" "${db}.daily.bak.stamp" \
    "${db}.weekly.bak" "${db}.weekly.bak.stamp" \
    "${db}.monthly.bak" "${db}.monthly.bak.stamp"

  for period in daily weekly monthly; do
    bundle_path="${db}.${period}.bak.zip"
    [[ -f "$bundle_path" ]] || continue
    bak_entry="${db_base}.${period}.bak"
    stamp_entry="${db_base}.${period}.bak.stamp"
    if ! _db_backup_bundle_is_valid "$bundle_path" "$bak_entry" "$stamp_entry"; then
      rm -f "$bundle_path"
    fi
  done

  # Remove unknown period bundles.
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  for file in "${db}".*.bak.zip; do
    case "$file" in
    "${db}.daily.bak.zip" | "${db}.weekly.bak.zip" | "${db}.monthly.bak.zip") ;;
    *) rm -f "$file" ;;
    esac
  done
  ((had_nullglob == 1)) || shopt -u nullglob
}

_db_backup_period() {
  local db="$1"
  local period="$2"
  local interval="$3"
  local now="$4"
  local force="${5:-0}"
  local db_base bak_entry stamp_entry bundle_path
  local bundle_mtime=0
  local tmpdir="" tmp_bak="" tmp_stamp="" tmp_zip=""

  db_base="$(basename "$db")"
  bak_entry="${db_base}.${period}.bak"
  stamp_entry="${db_base}.${period}.bak.stamp"
  bundle_path="${db}.${period}.bak.zip"

  if [[ -f "$bundle_path" ]]; then
    if ! _db_backup_bundle_is_valid "$bundle_path" "$bak_entry" "$stamp_entry"; then
      rm -f "$bundle_path"
    else
      if ((force == 0)); then
        bundle_mtime="$(_db_backup_stat_epoch_mtime "$bundle_path" || echo 0)"
        [[ "$bundle_mtime" =~ ^[0-9]+$ ]] || bundle_mtime=0
        if ((now - bundle_mtime < interval)); then
          return 0
        fi
      fi
      rm -f "$bundle_path"
    fi
  fi

  tmpdir="$(mktemp -d 2>/dev/null || true)"
  [[ -n "$tmpdir" && -d "$tmpdir" ]] || return 1
  tmp_bak="$tmpdir/$bak_entry"
  tmp_stamp="$tmpdir/$stamp_entry"
  tmp_zip="$tmpdir/${db_base}.${period}.bak.zip"

  cp -p "$db" "$tmp_bak" 2>/dev/null || {
    rm -rf "$tmpdir"
    return 1
  }
  touch "$tmp_stamp"
  (
    cd "$tmpdir" || exit 1
    zip -q -X "$tmp_zip" "$bak_entry" "$stamp_entry"
  ) || {
    rm -rf "$tmpdir"
    return 1
  }

  if ! _db_backup_bundle_is_valid "$tmp_zip" "$bak_entry" "$stamp_entry"; then
    rm -rf "$tmpdir"
    return 1
  fi

  mv -f "$tmp_zip" "$bundle_path" 2>/dev/null || {
    rm -rf "$tmpdir"
    return 1
  }
  rm -rf "$tmpdir"
}

# album_quality_db_backup <db> [force]
#
# Checks DB integrity first; exits non-zero (with message to stderr) on
# failure — caller should abort rather than overwrite known-good backups.
# Then creates/updates daily, weekly, and monthly zip bundles as needed.
# Pass force=1 to recreate all bundles regardless of age (used after schema
# migrations).
album_quality_db_backup() {
  local db="$1"
  local force="${2:-0}"

  [[ -f "$db" ]] || return 0

  local integrity_result
  integrity_result="$(sqlite3 -noheader "$db" "PRAGMA integrity_check;" 2>&1 || true)"
  if [[ "$integrity_result" != "ok" ]]; then
    printf 'album_quality_db_backup: integrity_check FAILED for %s\n%s\n' "$db" "$integrity_result" >&2
    return 1
  fi

  local now
  now="$(date +%s)"

  _db_backup_cleanup_existing "$db"

  _db_backup_period "$db" "daily"   86400   "$now" "$force" || return 1
  _db_backup_period "$db" "weekly"  604800  "$now" "$force" || return 1
  _db_backup_period "$db" "monthly" 2592000 "$now" "$force" || return 1
}
