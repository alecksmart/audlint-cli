import errno
import os
import pty
import select
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MAINTAIN = REPO_ROOT / "bin" / "audlint-maintain.sh"


def write_exec(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class PlayerContentCreatorTests(unittest.TestCase):
    def setUp(self) -> None:
        if shutil.which("sqlite3") is None:
            self.skipTest("sqlite3 is required")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.library = self.root / "library"
        self.library.mkdir()
        self.player = self.root / "player"
        self.player.mkdir()
        self.db = self.root / "library.sqlite"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self._init_db()

    def _init_db(self) -> None:
        proc = subprocess.run(
            ["bash", "-lc", f'source "{REPO_ROOT / "lib" / "sh" / "sqlite.sh"}"; album_quality_db_init "{self.db}"; printf "%s" "$ALBUM_QUALITY_DB_SCHEMA_CHANGED"'],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def _add_album(self, ident: int, artist: str, album: str, year: int, payload: bytes = b"audio") -> Path:
        folder = self.library / artist / f"{year} - {album}"
        folder.mkdir(parents=True)
        (folder / "01 track.flac").write_bytes(payload)
        (folder / "cover.jpg").write_bytes(b"cover")
        (folder / "front.jpg").write_bytes(b"not copied")
        con = sqlite3.connect(self.db)
        try:
            con.execute(
                "INSERT INTO album_quality(id,artist,artist_lc,artist_norm,album,album_lc,album_norm,year_int,source_path) VALUES(?,?,?,?,?,?,?,?,?)",
                (ident, artist, artist.lower(), artist.lower(), album, album.lower(), album.lower(), year, str(folder)),
            )
            con.commit()
        finally:
            con.close()
        return folder

    def _pty(self, keys: bytes, env_more: dict[str, str] | None = None, timeout_s: float = 8, followup: tuple[bytes, bytes] | None = None, followups: list[tuple[bytes, bytes]] | None = None) -> tuple[int, str]:
        env = os.environ.copy()
        env.update({
            "TERM": "xterm", "NO_COLOR": "1", "AUDLINT_LIBRARY_ROOT": str(self.library),
            "AUDL_DB_PATH": str(self.db), "AUDL_MEDIA_PLAYER_PATH": str(self.player),
            "PATH": f"{self.bin}{os.pathsep}{env.get('PATH', '')}",
        })
        if env_more:
            for name, value in env_more.items():
                if value is None:
                    env.pop(name, None)
                else:
                    env[name] = value
        master, slave = pty.openpty()
        proc = subprocess.Popen([str(MAINTAIN)], cwd=REPO_ROOT, env=env, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
        os.close(slave)
        pending = list(followups or ([] if followup is None else [followup]))
        output = bytearray(); sent = False; deadline = time.monotonic() + timeout_s
        try:
            while time.monotonic() < deadline:
                if not sent and b"choice >" in output:
                    os.write(master, keys); sent = True
                if sent and pending and pending[0][0] in output:
                    _, followup_keys = pending.pop(0)
                    os.write(master, followup_keys)
                ready, _, _ = select.select([master], [], [], .1)
                if ready:
                    try: chunk = os.read(master, 8192)
                    except OSError as exc: chunk = b"" if exc.errno == errno.EIO else (_ for _ in ()).throw(exc)
                    if chunk:
                        output.extend(chunk)
                    elif proc.poll() is not None:
                        break
                if proc.poll() is not None and not ready: break
            if proc.poll() is None: proc.kill()
            return proc.wait(timeout=1), output.decode("utf-8", errors="replace")
        finally:
            os.close(master)

    def test_schema_creation_and_selection_persist_through_selector(self) -> None:
        self._add_album(1, "Artist", "Album", 2001, b"x" * 20)
        # c opens creator, Space checks its first album, q returns to menu, q exits.
        rc, output = self._pty(b"c", followup=(b"1 of 1", b" q q"))
        self.assertEqual(rc, 0, output)
        self.assertIn("Player Content Creator", output)
        con = sqlite3.connect(self.db)
        try:
            self.assertEqual(con.execute("SELECT artist_lc,album_lc,year_int FROM player_content_selection").fetchall(), [("artist", "album", 2001)])
            self.assertEqual(con.execute("SELECT sql FROM sqlite_master WHERE name='player_content_selection'").fetchone() is not None, True)
        finally:
            con.close()

    def test_selection_schema_requests_backup_refresh_only_on_first_creation(self) -> None:
        fresh = self.root / "fresh.sqlite"
        lib = REPO_ROOT / "lib" / "sh" / "sqlite.sh"
        command = f'source "{lib}"; album_quality_db_init "{fresh}"; printf "%s" "$ALBUM_QUALITY_DB_SCHEMA_CHANGED"'
        first = subprocess.run(["bash", "-lc", command], text=True, capture_output=True, check=False)
        second = subprocess.run(["bash", "-lc", command], text=True, capture_output=True, check=False)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout, "1")
        self.assertEqual(second.stdout, "0")

    def test_deselecting_unsized_persisted_album_keeps_zero_total(self) -> None:
        self._add_album(1, "Artist", "Album", 2001, b"x" * 20)
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO player_content_selection VALUES('artist','album',2001)")
        con.commit(); con.close()
        rc, output = self._pty(
            b"c",
            followups=[
                (b"1 of 1", b" "),
                (b"Selected: 0 | Total: 0b", b"qq"),
            ],
        )
        self.assertEqual(rc, 0, output)
        self.assertIn("Selected: 0 | Total: 0b", output)

    def test_cancelled_and_accepted_manifest_mirror(self) -> None:
        source = self._add_album(1, "Artist", "Selected", 2001, b"selected")
        unchecked = self._add_album(2, "Artist", "Unchecked", 2002, b"unchecked")
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO player_content_selection VALUES('artist','selected',2001)")
        con.commit(); con.close()
        stale = self.player / "Artist" / "2002 - Unchecked"
        stale.mkdir(parents=True); (stale / "old.flac").write_bytes(b"old")
        (self.player / "extra.txt").write_text("extra", encoding="utf-8")
        calls = self.root / "rsync-calls"
        write_exec(self.bin / "rsync", "#!/usr/bin/env bash\nset -eu\n[[ ${1:-} == --help ]] && exit 0\nprintf x >>\"${RSYNC_CALLS:?}\"\nexit 0\n")
        write_exec(self.bin / "sync", "#!/usr/bin/env bash\nexit 0\n")
        # First confirmation is cancelled, so rsync is not invoked and stale data survives.
        rc, output = self._pty(b"cw nq q", {"RSYNC_CALLS": str(calls)})
        self.assertEqual(rc, 0, output)
        self.assertFalse(calls.exists(), output)
        self.assertTrue((stale / "old.flac").exists())
        # The accepted path invokes exactly one root mirror.  The stub records its one call.
        rc, output = self._pty(b"cwyqqq", {"RSYNC_CALLS": str(calls)})
        self.assertEqual(rc, 0, output)
        self.assertEqual(calls.read_text(encoding="utf-8"), "x", output)
        self.assertIn("Synchronization completed", output)
        self.assertTrue((source / "01 track.flac").exists())
        self.assertTrue((unchecked / "01 track.flac").exists())

    def test_unsafe_sync_never_calls_rsync(self) -> None:
        source = self._add_album(1, "Artist", "Album", 2001)
        con = sqlite3.connect(self.db); con.execute("INSERT INTO player_content_selection VALUES('artist','album',2001)"); con.commit(); con.close()
        calls = self.root / "rsync-calls"
        write_exec(self.bin / "rsync", "#!/usr/bin/env bash\nprintf x >>\"${RSYNC_CALLS:?}\"\n")

        def attempt(name: str, env_more: dict[str, str] | None = None) -> str:
            calls.unlink(missing_ok=True)
            rc, output = self._pty(b"cwyqqq", {"RSYNC_CALLS": str(calls), **(env_more or {})})
            self.assertEqual(rc, 0, f"{name}: {output}")
            self.assertFalse(calls.exists(), f"{name}: {output}")
            return output

        self.assertIn("unsafe player destination", attempt("overlapping", {"AUDL_MEDIA_PLAYER_PATH": str(self.library)}))
        self.assertIn("unsafe player destination", attempt("broad", {"AUDL_MEDIA_PLAYER_PATH": "/tmp"}))
        self.assertIn("not a writable mounted directory", attempt("missing destination", {"AUDL_MEDIA_PLAYER_PATH": str(self.root / "missing-player")}))
        self.assertIn("rsync not found", attempt("missing rsync", {"RSYNC_BIN": "audlint-no-rsync"}))

        outside = self.root / "outside"; outside.mkdir(); (outside / "track.flac").write_bytes(b"x")
        con = sqlite3.connect(self.db); con.execute("UPDATE album_quality SET source_path=?", (str(outside),)); con.commit(); con.close()
        self.assertIn("escapes library root", attempt("escaping source"))
        con = sqlite3.connect(self.db); con.execute("UPDATE album_quality SET source_path=?", (str(self.library / "missing-source"),)); con.commit(); con.close()
        self.assertIn("selected source is unreadable", attempt("missing source"))

        con = sqlite3.connect(self.db)
        con.execute("UPDATE album_quality SET source_path=?", (str(source),))
        con.execute("DROP INDEX idx_album_quality_key")
        con.execute("INSERT INTO album_quality(id,artist,artist_lc,artist_norm,album,album_lc,album_norm,year_int,source_path) VALUES(2,'Artist','artist','artist','Album','album','album',2001,?)", (str(source),))
        con.commit(); con.close()
        self.assertIn("resolves exactly once", attempt("duplicate identity"))

    def test_real_rsync_mirror_copies_only_checked_payload_and_deletes_extra(self) -> None:
        if shutil.which("rsync") is None:
            self.skipTest("rsync is required for the real mirror test")
        selected = self._add_album(1, "Artist", "Selected", 2001, b"selected-audio")
        (selected / ".audlint_inspect_cache.json").write_bytes(b"cache")
        unchecked = self._add_album(2, "Artist", "Unchecked", 2002, b"unchecked-audio")
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO player_content_selection VALUES('artist','selected',2001)")
        con.commit(); con.close()
        stale = self.player / "Artist" / "2002 - Unchecked"
        stale.mkdir(parents=True)
        (stale / "old.flac").write_bytes(b"old")
        (self.player / "extra.txt").write_text("extra", encoding="utf-8")

        # c, w, y, dismiss result, q selector, q Maintenance.
        rc, output = self._pty(b"cwyqqq", {"RSYNC_BIN": shutil.which("rsync") or "rsync", "SYNC_BIN": "sync"})
        self.assertEqual(rc, 0, output)
        target = self.player / "Artist" / "2001 - Selected"
        self.assertEqual((target / "01 track.flac").read_bytes(), b"selected-audio")
        self.assertTrue((target / "cover.jpg").exists())
        self.assertFalse((target / "front.jpg").exists())
        self.assertFalse((target / ".audlint_inspect_cache.json").exists())
        self.assertFalse(stale.exists())
        self.assertFalse((self.player / "extra.txt").exists())
        self.assertEqual((selected / "01 track.flac").read_bytes(), b"selected-audio")
        self.assertTrue((unchecked / "01 track.flac").exists())

    def test_status_and_live_total_work_without_a_player(self) -> None:
        self._add_album(1, "Artist", "Album", 2001, b"x" * 10)
        # The initial title is unselected/zero; Space immediately updates it.
        rc, output = self._pty(b"c", {"AUDL_MEDIA_PLAYER_PATH": ""}, followup=(b"1 of 1", b" q q"))
        self.assertEqual(rc, 0, output)
        self.assertIn("Total: sizing… (0/1 albums)", output)
        self.assertIn("SD: not mounted | Selected: 1 | Total: 15b", output)
        missing = self.root / "missing-player"
        rc, output = self._pty(b"cqq", {"AUDL_MEDIA_PLAYER_PATH": str(missing)})
        self.assertEqual(rc, 0, output)
        self.assertIn("SD: not mounted", output)
        file_player = self.root / "player-file"
        file_player.write_text("not a directory", encoding="utf-8")
        rc, output = self._pty(b"cqq", {"AUDL_MEDIA_PLAYER_PATH": str(file_player)})
        self.assertEqual(rc, 0, output)
        self.assertIn("SD: not mounted", output)
        rc, output = self._pty(b"cqq")
        self.assertEqual(rc, 0, output)
        self.assertIn("SD: mounted", output)

    def test_large_selector_is_ordered_bounded_and_reaches_both_boundaries(self) -> None:
        rows = []
        for ident in range(1600):
            artist_index, album_index = divmod(ident, 20)
            artist = f"Artist {artist_index:03d}"
            album = f"Album {album_index:02d}"
            rows.append((ident + 1, artist, artist.lower(), artist.lower(), album, album.lower(), album.lower(), 2000 + album_index, str(self.library / "missing" / str(ident))))
        con = sqlite3.connect(self.db)
        con.executemany("INSERT INTO album_quality(id,artist,artist_lc,artist_norm,album,album_lc,album_norm,year_int,source_path) VALUES(?,?,?,?,?,?,?,?,?)", rows)
        con.commit(); con.close()
        # No per-album directories are needed: unavailable rows stay visible but cannot be toggled.
        # Up at the first row is a no-op; enough Down actions cross an artist
        # boundary and force viewport scrolling without turning this into a
        # slow 1,600-key PTY test.
        keys = b"c\x1b[A" + (b"\x1b[B" * 20) + b"qq"
        rc, output = self._pty(keys, {"LINES": "12", "COLUMNS": "100", "AUDL_MEDIA_PLAYER_PATH": ""})
        self.assertEqual(rc, 0, output[-4000:])
        self.assertIn("Artist 000", output)
        self.assertIn("Artist 001", output)
        self.assertIn("21 of 1600", output)
        # With a 12-line terminal each render is bounded; this catches a single
        # attempt to print the 1,600-row inventory as one terminal page.
        self.assertNotIn("Artist 000\n  [ ] 2000 - Album 00\n  [ ] 2001 - Album 01\n  [ ] 2002 - Album 02\n  [ ] 2003 - Album 03\n  [ ] 2004 - Album 04\n  [ ] 2005 - Album 05\n  [ ] 2006 - Album 06\n  [ ] 2007 - Album 07\n  [ ] 2008 - Album 08\n  [ ] 2009 - Album 09\n  [ ] 2010 - Album 10\n  [ ] 2011 - Album 11", output)

    def test_checked_unavailable_row_can_be_recovered_and_stale_rows_are_cleaned(self) -> None:
        source = self._add_album(1, "Artist", "Gone", 2001)
        con = sqlite3.connect(self.db)
        con.executemany("INSERT INTO player_content_selection VALUES(?,?,?)", [("artist", "gone", 2001), ("missing", "identity", 1999)])
        con.commit(); con.close()
        shutil.rmtree(source)
        rc, output = self._pty(b"c q q")
        self.assertEqual(rc, 0, output)
        self.assertIn("[x] 2001 - Gone [unavailable]", output)
        con = sqlite3.connect(self.db)
        self.assertEqual(con.execute("SELECT * FROM player_content_selection ORDER BY artist_lc").fetchall(), [])
        con.close()

    def test_empty_selection_cancel_then_accept_empty_player(self) -> None:
        if shutil.which("rsync") is None:
            self.skipTest("rsync is required for the real mirror test")
        (self.player / "existing.txt").write_text("keep", encoding="utf-8")
        rc, output = self._pty(b"cw nqq", {"RSYNC_BIN": shutil.which("rsync") or "rsync", "SYNC_BIN": "sync"})
        self.assertEqual(rc, 0, output)
        self.assertTrue((self.player / "existing.txt").exists())
        rc, output = self._pty(b"cwyqqq", {"RSYNC_BIN": shutil.which("rsync") or "rsync", "SYNC_BIN": "sync"})
        self.assertEqual(rc, 0, output)
        self.assertEqual(list(self.player.iterdir()), [])

    def test_rsync_and_sync_failures_preserve_selection_then_retry(self) -> None:
        self._add_album(1, "Artist", "Album", 2001)
        con = sqlite3.connect(self.db); con.execute("INSERT INTO player_content_selection VALUES('artist','album',2001)"); con.commit(); con.close()
        write_exec(self.bin / "rsync", "#!/usr/bin/env bash\n[[ ${1:-} == --help ]] && exit 0\n[[ ${FAIL_RSYNC:-0} == 1 ]] && exit 7\nexit 0\n")
        write_exec(self.bin / "sync", "#!/usr/bin/env bash\n[[ ${FAIL_SYNC:-0} == 1 ]] && exit 9\nexit 0\n")
        for failure_env in ({"FAIL_RSYNC": "1"}, {"FAIL_SYNC": "1"}):
            rc, output = self._pty(b"cwyqqq", failure_env)
            self.assertEqual(rc, 0, output)
            self.assertIn("Synchronization failed", output)
            self.assertNotIn("Synchronization completed", output)
            con = sqlite3.connect(self.db)
            self.assertEqual(con.execute("SELECT * FROM player_content_selection").fetchall(), [("artist", "album", 2001)])
            con.close()
        rc, output = self._pty(b"cwyqqq")
        self.assertEqual(rc, 0, output)
        self.assertIn("Synchronization completed", output)

    def test_literal_metacharacter_relative_path_and_db_path_fallback(self) -> None:
        if shutil.which("rsync") is None:
            self.skipTest("rsync is required for the real mirror test")
        artist, album = "Artist *?[", "Album *?[\\"
        source = self._add_album(1, artist, album, 2001, b"literal")
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO player_content_selection VALUES(?,?,?)", (artist.lower(), album.lower(), 2001))
        con.commit(); con.close()
        rc, output = self._pty(b"cwyqqq", {"RSYNC_BIN": shutil.which("rsync") or "rsync", "SYNC_BIN": "sync"})
        self.assertEqual(rc, 0, output)
        self.assertEqual((self.player / artist / f"2001 - {album}" / "01 track.flac").read_bytes(), b"literal")
        # Direct Maintenance still resolves the conventional database path.
        rc, output = self._pty(b"cqq", {"AUDL_DB_PATH": None, "AUDL_PATH": str(self.root)})
        self.assertEqual(rc, 0, output)
        self.assertIn("Player Content Creator", output)

    def test_small_inventory_final_down_is_a_noop(self) -> None:
        for ident in range(3):
            self._add_album(ident + 1, "Artist", f"Album {ident}", 2000 + ident)
        rc, output = self._pty(b"c\x1b[B\x1b[B\x1b[Bqq")
        self.assertEqual(rc, 0, output)
        self.assertIn("3 of 3", output)
