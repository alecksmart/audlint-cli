#!/usr/bin/env bash

LYRICS_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$LYRICS_SH_DIR/sqlite.sh"

lyrics_cache_duration_bounds() {
  local duration_int="${1:-0}"
  local low high
  [[ "$duration_int" =~ ^[0-9]+$ ]] || duration_int=0
  low=$((duration_int - 2))
  ((low < 0)) && low=0
  high=$((duration_int + 2))
  printf '%s\t%s\n' "$low" "$high"
}

lyrics_db_init() {
  local db="$1"
  local db_dir
  db_dir=$(dirname "$db")
  mkdir -p "$db_dir"
  sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS lyrics_cache (
  id INTEGER PRIMARY KEY,
  artist_lc TEXT NOT NULL,
  title_lc TEXT NOT NULL,
  album_lc TEXT NOT NULL,
  duration_int INTEGER NOT NULL,
  path TEXT,
  status TEXT NOT NULL,
  lyrics TEXT,
  source TEXT,
  attempted_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_lyrics_lookup
  ON lyrics_cache(artist_lc, title_lc, album_lc, duration_int);
CREATE INDEX IF NOT EXISTS idx_lyrics_lookup_recent
  ON lyrics_cache(artist_lc, title_lc, album_lc, duration_int, updated_at DESC);
SQL
}

lyrics_cache_lookup() {
  local db="$1"
  local artist_lc="$2"
  local title_lc="$3"
  local album_lc="$4"
  local duration_int="$5"
  local a_sql t_sql al_sql low high
  a_sql=$(sql_escape "$artist_lc")
  t_sql=$(sql_escape "$title_lc")
  al_sql=$(sql_escape "$album_lc")
  IFS=$'\t' read -r low high <<<"$(lyrics_cache_duration_bounds "$duration_int")"

  sqlite3 -separator "|" "$db" \
    "SELECT status, attempted_at
       FROM lyrics_cache
      WHERE artist_lc='${a_sql}'
        AND title_lc='${t_sql}'
        AND album_lc='${al_sql}'
        AND duration_int BETWEEN ${low} AND ${high}
      ORDER BY updated_at DESC
      LIMIT 1;"
}

lyrics_cache_delete_window() {
  local db="$1"
  local artist_lc="$2"
  local title_lc="$3"
  local album_lc="$4"
  local duration_int="$5"
  local a_sql t_sql al_sql low high
  a_sql=$(sql_escape "$artist_lc")
  t_sql=$(sql_escape "$title_lc")
  al_sql=$(sql_escape "$album_lc")
  IFS=$'\t' read -r low high <<<"$(lyrics_cache_duration_bounds "$duration_int")"

  sqlite3 "$db" \
    "DELETE FROM lyrics_cache
      WHERE artist_lc='${a_sql}'
        AND title_lc='${t_sql}'
        AND album_lc='${al_sql}'
        AND duration_int BETWEEN ${low} AND ${high};"
}

lyrics_cache_upsert() {
  local db="$1"
  local artist_lc="$2"
  local title_lc="$3"
  local album_lc="$4"
  local duration_int="$5"
  local path="$6"
  local status="$7"
  local lyrics="$8"
  local source="$9"
  local attempted_at="${10}"
  local updated_at="${11}"

  local a_sql t_sql al_sql p_sql s_sql l_sql src_sql low high
  a_sql=$(sql_escape "$artist_lc")
  t_sql=$(sql_escape "$title_lc")
  al_sql=$(sql_escape "$album_lc")
  p_sql=$(sql_escape "$path")
  s_sql=$(sql_escape "$status")
  l_sql=$(sql_escape "$lyrics")
  src_sql=$(sql_escape "$source")
  IFS=$'\t' read -r low high <<<"$(lyrics_cache_duration_bounds "$duration_int")"

  sqlite3 "$db" \
    "BEGIN IMMEDIATE;
     DELETE FROM lyrics_cache
      WHERE artist_lc='${a_sql}'
        AND title_lc='${t_sql}'
        AND album_lc='${al_sql}'
        AND duration_int BETWEEN ${low} AND ${high};
     INSERT INTO lyrics_cache (
       artist_lc, title_lc, album_lc, duration_int, path, status, lyrics, source, attempted_at, updated_at
     ) VALUES (
       '${a_sql}', '${t_sql}', '${al_sql}', ${duration_int}, '${p_sql}', '${s_sql}', '${l_sql}', '${src_sql}', ${attempted_at}, ${updated_at}
     );
     COMMIT;"
}
