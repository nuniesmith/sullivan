"""Tests for the media janitor. Run: python3 -m unittest discover -s services/media-janitor"""

from __future__ import annotations

import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import janitor

DAY = 86400.0


class Tree(unittest.TestCase):
    """A fake /complete, with ages set through mtimes."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="janitor-test-")
        self.addCleanup(self.tmp.cleanup)
        self.complete = Path(self.tmp.name) / "complete"
        self.now = time.time()

    def make(self, rel: str, days_old: float, size: int = 10) -> Path:
        path = self.complete / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * size)
        stamp = self.now - days_old * DAY
        os.utime(path, (stamp, stamp))
        for parent in [path.parent, *path.parent.parents]:
            if parent == self.complete.parent:
                break
            os.utime(parent, (stamp, stamp))
        return path


class UnpackerrDuplicateTests(Tree):
    def test_only_old_entries_in_arr_categories_qualify(self) -> None:
        self.make("tv-sonarr_unpackerred/Old.Show.S01/e1.mkv", 10)
        self.make("tv-sonarr_unpackerred/New.Show.S01/e1.mkv", 0.5)
        self.make("seed_unpackerred/Mine/file.mkv", 400)
        found = janitor.unpackerr_duplicates(self.complete, self.now, 2)
        self.assertEqual([c.path.name for c in found], ["Old.Show.S01"])
        self.assertEqual(found[0].size, 10)

    def test_a_new_file_inside_an_old_folder_keeps_it(self) -> None:
        self.make("radarr_unpackerred/Film/part1.mkv", 30)
        new = self.make("radarr_unpackerred/Film/part2.mkv", 0.1)
        stamp = self.now - 30 * DAY
        os.utime(new.parent, (stamp, stamp))
        self.assertEqual(janitor.unpackerr_duplicates(self.complete, self.now, 2), [])

    def test_a_torrent_seeding_from_an_unpackerred_folder_is_never_touched(self) -> None:
        """Seeding needs the original files untouched. The layout already
        keeps torrents out of `_unpackerred`; this pins that ownership wins
        even if one is ever seeded from there."""
        self.make("tv-sonarr_unpackerred/Seeded.Here/e1.mkv", 30)
        self.make("tv-sonarr_unpackerred/Copy.Only/e1.mkv", 30)
        owned = [self.complete / "tv-sonarr_unpackerred/Seeded.Here/e1.mkv"]
        found = janitor.unpackerr_duplicates(self.complete, self.now, 2, owned)
        self.assertEqual([c.path.name for c in found], ["Copy.Only"])

    def test_symlinks_are_never_candidates(self) -> None:
        target = self.make("elsewhere/real.mkv", 30)
        link_dir = self.complete / "tv-sonarr_unpackerred"
        link_dir.mkdir(parents=True)
        (link_dir / "link").symlink_to(target)
        self.assertEqual(janitor.unpackerr_duplicates(self.complete, self.now, 2), [])


class OrphanTests(Tree):
    def test_entries_no_torrent_owns_qualify_once_old(self) -> None:
        self.make("tv-sonarr/Owned.S01/e1.mkv", 90)
        self.make("tv-sonarr/Orphan.Old/e1.mkv", 90)
        self.make("tv-sonarr/Orphan.New/e1.mkv", 3)
        self.make("seed/Mine/e1.mkv", 900)
        torrents = [{"content_path": str(self.complete / "tv-sonarr/Owned.S01/e1.mkv")}]
        owned = janitor.torrent_roots(torrents, self.complete)
        found = janitor.orphans(self.complete, owned, self.now, 30)
        self.assertEqual([c.path.name for c in found], ["Orphan.Old"])

    def test_a_single_file_torrent_owns_its_file(self) -> None:
        self.make("radarr/Film.2020.mkv", 90)
        torrents = [{"content_path": str(self.complete / "radarr/Film.2020.mkv")}]
        owned = janitor.torrent_roots(torrents, self.complete)
        self.assertEqual(janitor.orphans(self.complete, owned, self.now, 30), [])


class LegacyAreaTests(Tree):
    """The old download folder on the HDD pool: 2.6 TB on 2026-10-17, no torrent
    owning any of it, nothing changed since January."""

    def setUp(self) -> None:
        super().setUp()
        self.complete = Path(self.tmp.name) / "legacy"

    def test_old_unowned_entries_qualify_and_owned_or_recent_ones_do_not(self) -> None:
        self.make("complete/radarr/Old.Film/f.mkv", 200)
        self.make("complete/tv-sonarr_unpackerred/Old.Show/e.mkv", 200)
        self.make("incomplete/Partial.Download/p.mkv.!qB", 300)
        self.make("complete/radarr/Recent.Film/f.mkv", 10)
        self.make("complete/radarr/Owned.Film/f.mkv", 200)
        self.make("complete/seed/Mine/f.mkv", 400)
        torrents = [{"content_path": "/media/qbittorrent/complete/radarr/Owned.Film"}]
        owned = janitor.mapped_content_paths(torrents, "/media/qbittorrent", self.complete)
        kept: list[str] = []
        found = janitor.legacy_candidates(self.complete, owned, self.now, 90, kept)
        self.assertEqual(sorted(c.path.name for c in found), ["Old.Film", "Old.Show", "Partial.Download"])
        self.assertEqual(kept, [])

    def test_an_entry_sharing_a_file_with_the_library_is_kept(self) -> None:
        film = self.make("complete/radarr/Linked.Film/f.mkv", 200)
        library = Path(self.tmp.name) / "library-copy.mkv"
        os.link(film, library)
        kept: list[str] = []
        self.assertEqual(janitor.legacy_candidates(self.complete, [], self.now, 90, kept), [])
        self.assertEqual(len(kept), 1)
        self.assertIn("hardlinked", kept[0])


class DiskTests(unittest.TestCase):
    def test_a_disk_below_its_threshold_is_a_problem(self) -> None:
        report = janitor.Report(execute=False)
        usage = mock.Mock(total=1000, free=90, used=910)
        with mock.patch.object(janitor.shutil, "disk_usage", return_value=usage):
            janitor.disk_report(report, "HDD pool (library)", Path("/x"), 0.10)
        self.assertIn("HDD pool (library): 90 B free of 1.0 KB (9%).", report.lines)
        self.assertEqual(report.problems, ["HDD pool (library) is low on space: 9% free."])


class RunTests(Tree):
    def run_janitor(self, execute: bool, extra: dict[str, str] | None = None) -> janitor.Report:
        environ = {"MEDIA_JANITOR_COMPLETE": str(self.complete), **(extra or {})}
        with mock.patch.dict(os.environ, environ, clear=True):
            return janitor.run(execute, now=self.now)

    def test_report_only_deletes_nothing(self) -> None:
        dup = self.make("tv-sonarr_unpackerred/Old/e1.mkv", 10, size=2_000_000)
        report = self.run_janitor(execute=False)
        self.assertTrue(dup.exists())
        self.assertIn("Unpackerr duplicates: 1 entries, 2.0 MB, would be deleted.", report.lines)
        self.assertIn("Orphans and the old download area: skipped, no qBittorrent login configured.", report.lines)

    def test_execute_deletes_duplicates_and_keeps_the_seed_category(self) -> None:
        dup = self.make("tv-sonarr_unpackerred/Old/e1.mkv", 10)
        seed = self.make("seed_unpackerred/Mine/e1.mkv", 400)
        report = self.run_janitor(execute=True)
        self.assertFalse(dup.parent.exists())
        self.assertTrue(seed.exists())
        self.assertTrue(any(line.startswith("Left alone:") and "seed_unpackerred" in line for line in report.lines))

    def test_orphans_are_skipped_when_qbittorrent_lists_nothing(self) -> None:
        """An empty list may be a bad login or a fresh client; never "all orphans"."""
        orphan = self.make("radarr/Film/f.mkv", 90)
        with mock.patch.object(janitor, "qbittorrent_torrents", return_value=[]):
            report = self.run_janitor(execute=True)
        self.assertTrue(orphan.exists())
        self.assertIn("Orphans and the old download area: skipped, qBittorrent listed no torrents.", report.lines)

    def test_a_file_that_changed_since_the_scan_is_kept(self) -> None:
        path = self.make("radarr_unpackerred/Film/f.mkv", 10)
        candidate = janitor.Candidate(path.parent, 10, 10, "test")
        os.utime(path, (self.now, self.now))
        self.assertFalse(janitor.delete(candidate, self.now, 2))
        self.assertTrue(path.exists())


class ConnectionTests(unittest.TestCase):
    SCHEMA = {
        "implementation": "MediaBrowser",
        "name": "",
        "fields": [{"name": "host", "value": None}, {"name": "apiKey", "value": None}, {"name": "updateLibrary", "value": False}],
        "onGrab": False, "supportsOnGrab": False,
        "onDownload": False, "supportsOnDownload": True,
        "onRename": False, "supportsOnRename": True,
        "onHealthIssue": False, "supportsOnHealthIssue": True,
    }

    def test_fields_and_supported_triggers_are_set(self) -> None:
        built = janitor.build_connection(
            self.SCHEMA, "Emby (media-janitor)", {"host": "h", "apiKey": "k", "updateLibrary": True},
            ("onGrab", "onDownload", "onRename"),
        )
        self.assertEqual(built["name"], "Emby (media-janitor)")
        self.assertEqual({f["name"]: f["value"] for f in built["fields"]}, {"host": "h", "apiKey": "k", "updateLibrary": True})
        self.assertFalse(built["onGrab"], "Emby cannot do grabs; asking would be refused")
        self.assertTrue(built["onDownload"])
        self.assertFalse(built["onHealthIssue"], "not asked for")
        self.assertIsNone(self.SCHEMA["fields"][0]["value"], "the schema itself is untouched")

    def test_an_unchanged_connection_is_not_saved_again(self) -> None:
        existing = janitor.build_connection(self.SCHEMA, "Emby (media-janitor)", {"host": "h"}, ("onDownload",))
        existing["id"] = 7
        arr = mock.Mock()
        arr.call.side_effect = lambda method, path, body=None: [existing] if path == "/notification" else None
        self.assertEqual(janitor.ensure_connection(arr, "MediaBrowser", {"host": "h"}, ("onDownload",)), "unchanged")
        self.assertEqual([c.args[0] for c in arr.call.call_args_list], ["GET"])


class SeedGoalTests(unittest.TestCase):
    INDEXER = {"id": 1, "fields": [
        {"name": "torrentBaseSettings.seedRatio", "value": 3},
        {"name": "torrentBaseSettings.seedTime", "value": None},
    ]}

    def test_no_goal_configured_changes_nothing(self) -> None:
        self.assertIsNone(janitor.seed_goal_changes(self.INDEXER, None, None))

    def test_a_new_goal_rewrites_ratio_and_time(self) -> None:
        changed = janitor.seed_goal_changes(self.INDEXER, 1.0, 20160)
        self.assertEqual(janitor.field_value(changed, "torrentBaseSettings.seedRatio"), 1.0)
        self.assertEqual(janitor.field_value(changed, "torrentBaseSettings.seedTime"), 20160)
        self.assertEqual(janitor.field_value(self.INDEXER, "torrentBaseSettings.seedRatio"), 3)

    def test_the_same_goal_is_not_saved_again(self) -> None:
        already = janitor.seed_goal_changes(self.INDEXER, 1.0, 20160)
        self.assertIsNone(janitor.seed_goal_changes(already, 1.0, 20160))


if __name__ == "__main__":
    unittest.main()
