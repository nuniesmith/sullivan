"""Tests for the media janitor. Run: python3 -m unittest discover -s services/media-janitor"""

from __future__ import annotations

import os
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
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
        self.assertIn("Orphans, old seed folders and the old download area: skipped, no qBittorrent login configured.",
                      report.lines)

    def test_execute_deletes_duplicates_and_keeps_the_seed_category(self) -> None:
        dup = self.make("tv-sonarr_unpackerred/Old/e1.mkv", 10)
        seed = self.make("seed_unpackerred/Mine/e1.mkv", 400)
        report = self.run_janitor(execute=True)
        self.assertFalse(dup.parent.exists())
        self.assertTrue(seed.exists(), "without a torrent list nothing proves it unowned")
        self.assertIn("Orphans, old seed folders and the old download area: skipped, no qBittorrent login configured.",
                      report.lines)

    def test_orphans_are_skipped_when_qbittorrent_lists_nothing(self) -> None:
        """An empty list may be a bad login or a fresh client; never "all orphans"."""
        orphan = self.make("radarr/Film/f.mkv", 90)
        with mock.patch.object(janitor, "qbittorrent_torrents", return_value=[]):
            report = self.run_janitor(execute=True)
        self.assertTrue(orphan.exists())
        self.assertIn("Orphans, old seed folders and the old download area: skipped, qBittorrent listed no torrents.",
                      report.lines)

    def test_a_file_that_changed_since_the_scan_is_kept(self) -> None:
        path = self.make("radarr_unpackerred/Film/f.mkv", 10)
        candidate = janitor.Candidate(path.parent, 10, 10, "test")
        os.utime(path, (self.now, self.now))
        self.assertFalse(janitor.delete(candidate, self.now, 2))
        self.assertTrue(path.exists())


class QbittorrentLoginTests(unittest.TestCase):
    """qBittorrent 5.x answers a good login with 204 and no body; 4.x with "Ok."."""

    def opener(self, login_body: bytes) -> mock.Mock:
        def respond(request, timeout=0):
            response = mock.MagicMock()
            url = request if isinstance(request, str) else request.full_url
            body = login_body if url.endswith("/auth/login") else b"[]"
            response.__enter__.return_value.read.return_value = body
            return response

        opener = mock.Mock()
        opener.open.side_effect = respond
        return opener

    def call(self, login_body: bytes):
        environ = {"QBITTORRENT_URL": "http://qbittorrent:8080", "QBITTORRENT_USERNAME": "u",
                   "QBITTORRENT_PASSWORD": "p"}
        with mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(janitor.urllib.request, "build_opener", return_value=self.opener(login_body)):
            return janitor.qbittorrent_torrents()

    def test_an_empty_204_login_is_success(self) -> None:
        self.assertEqual(self.call(b""), [])

    def test_the_old_ok_reply_is_success(self) -> None:
        self.assertEqual(self.call(b"Ok."), [])

    def test_fails_is_a_refusal(self) -> None:
        with self.assertRaises(RuntimeError):
            self.call(b"Fails.")


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

    def test_a_secret_the_arr_masks_does_not_count_as_a_change(self) -> None:
        existing = janitor.build_connection(self.SCHEMA, "Emby (media-janitor)", {"host": "h", "apiKey": "********"},
                                            ("onDownload",))
        existing["id"] = 7
        arr = mock.Mock()
        arr.call.side_effect = lambda method, path, body=None: [existing] if path == "/notification" else None
        fields = {"host": "h", "apiKey": "real-key"}
        self.assertEqual(janitor.ensure_connection(arr, "MediaBrowser", fields, ("onDownload",)), "unchanged")
        self.assertEqual(janitor.ensure_connection(arr, "MediaBrowser", {**fields, "host": "new"}, ("onDownload",)),
                         "updated")
        sent = arr.call.call_args_list[-1].args[2]
        self.assertEqual({f["name"]: f["value"] for f in sent["fields"]}["apiKey"], "real-key")


class SeedGoalTests(unittest.TestCase):
    INDEXER = {"id": 1, "fields": [
        {"name": "torrentBaseSettings.seedRatio", "value": 3},
        {"name": "torrentBaseSettings.seedTime", "value": None},
    ]}

    def test_a_missing_prowlarr_key_is_reported_not_skipped_silently(self) -> None:
        report = janitor.Report(execute=False)
        with mock.patch.dict(os.environ, {"PROWLARR_URL": "http://prowlarr:9696"}, clear=True):
            janitor.configure_seed_goals(report, None)
        self.assertEqual(report.lines, ["Seed goals: skipped, PROWLARR_API_KEY is empty."])

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


class OldSeedFolderTests(Tree):
    """The `seed` folders of both download areas, unused since the category moved to /seed."""

    def setUp(self) -> None:
        super().setUp()
        self.complete = Path(self.tmp.name) / "areas"

    def test_old_entries_no_torrent_owns_qualify_in_both_areas(self) -> None:
        self.make("complete/seed/Left.Behind/e.mkv", 60)
        self.make("complete/seed_unpackerred/Extracted.Copy/e.mkv", 60)
        self.make("legacy/complete/seed/Older/e.mkv", 200)
        self.make("complete/seed/Recent/e.mkv", 5)
        self.make("complete/seed/Still.Seeding/e.mkv", 60)
        owned = [self.complete / "complete/seed/Still.Seeding/e.mkv"]
        found = janitor.old_seed_folders(self.complete / "complete", self.complete / "legacy", owned, self.now, 30)
        self.assertEqual(sorted(c.path.name for c in found), ["Extracted.Copy", "Left.Behind", "Older"])


def seed_torrent(h: str, *, ratio: float = 0.2, days: float = 5.0, state: str = "forcedUP",
                 category: str = "seed", active: float = 0) -> dict:
    return {"hash": h, "category": category, "progress": 1, "ratio": ratio, "seeding_time": days * DAY,
            "state": state, "last_activity": active, "size": 1_000_000_000}


class SeedRetirementTests(unittest.TestCase):
    """IPTorrents counts a hit-and-run unless a torrent seeds 1:1 or 336 hours;
    the goal here is ratio 3 or 15 days, whichever comes first."""

    def plan(self, torrents: list[dict], imported: set[str], keep_min: int = 0) -> janitor.SeedPlan:
        return janitor.plan_seed_retirement(torrents, "seed", 3.0, 15 * DAY, imported, keep_min)

    def test_a_torrent_goes_once_it_met_the_goal_and_an_arr_imported_it(self) -> None:
        torrents = [seed_torrent("ratio", ratio=3.1), seed_torrent("time", days=15.5),
                    seed_torrent("owed", ratio=0.9, days=13.9), seed_torrent("manual", days=20),
                    seed_torrent("arr", days=40, category="tv-sonarr")]
        plan = self.plan(torrents, imported={"ratio", "time", "owed", "arr"})
        self.assertEqual(sorted(t["hash"] for t in plan.remove), ["ratio", "time"])
        self.assertEqual([t["hash"] for t in plan.waiting], ["owed"])
        self.assertEqual([t["hash"] for t in plan.not_imported], ["manual"])

    def test_enough_torrents_stay_seeding_and_the_quietest_go_first(self) -> None:
        torrents = [seed_torrent(f"t{i}", days=20, active=i) for i in range(5)]
        plan = self.plan(torrents, imported={t["hash"] for t in torrents}, keep_min=3)
        self.assertEqual([t["hash"] for t in plan.remove], ["t0", "t1"])
        self.assertEqual(len(plan.kept_seeding), 3)

    def test_a_stopped_torrent_does_not_count_toward_the_floor(self) -> None:
        torrents = [seed_torrent("seeding", days=20), seed_torrent("stopped", days=20, state="stoppedUP")]
        plan = self.plan(torrents, imported={"seeding", "stopped"}, keep_min=1)
        self.assertEqual([t["hash"] for t in plan.remove], ["stopped"])
        self.assertEqual([t["hash"] for t in plan.kept_seeding], ["seeding"])


class ImportEvidenceTests(unittest.TestCase):
    def arr(self, records_by_id: dict[str, list[dict]]) -> mock.Mock:
        arr = mock.Mock()

        def call(method: str, path: str, body=None):
            asked = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)["downloadId"][0]
            return {"records": records_by_id.get(asked, [])}

        arr.call.side_effect = call
        return arr

    def test_only_an_import_of_that_very_download_counts(self) -> None:
        sonarr = self.arr({"AAA": [{"downloadId": "AAA", "eventType": "downloadFolderImported"}],
                           "BBB": [{"downloadId": "BBB", "eventType": "grabbed"}]})
        radarr = self.arr({"CCC": [{"downloadId": "CCC", "eventType": "downloadFolderImported"}]})
        self.assertEqual(janitor.imported_by_an_arr([sonarr, radarr], ["aaa", "bbb", "ccc"]), {"aaa", "ccc"})

    def test_an_arr_that_ignores_the_filter_proves_nothing(self) -> None:
        """An *arr answering with its newest history, whatever was asked, must
        not read as an import of this download."""
        lidarr = mock.Mock()
        lidarr.call.return_value = {"records": [{"downloadId": "ZZZ", "eventType": "trackFileImported"}]}
        self.assertEqual(janitor.imported_by_an_arr([lidarr], ["aaa"]), set())


class RetireSeedCategoryTests(unittest.TestCase):
    def run_rule(self, cleanup: bool, torrents: list[dict], imported=None, execute: bool = True):
        environ = {"MEDIA_SEED_RATIO": "3", "MEDIA_SEED_DAYS": "15", "MEDIA_SEED_KEEP_MIN": "0"}
        if cleanup:
            environ["MEDIA_JANITOR_SEED_CLEANUP"] = "true"
        report = janitor.Report(execute=execute)
        evidence = {"side_effect": imported} if isinstance(imported, Exception) else {"return_value": imported}
        with mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(janitor, "imported_by_an_arr", **evidence), \
                mock.patch.object(janitor, "qbittorrent_post") as post:
            janitor.retire_seed_category(report, torrents)
        return report, post

    def test_nothing_is_removed_until_seed_cleanup_is_on(self) -> None:
        report, post = self.run_rule(False, [seed_torrent("done", days=20)], {"done"})
        post.assert_not_called()
        self.assertIn("Seed category: 1 torrents, 1.0 GB, met the goal and were imported; "
                      "would be removed with their files once MEDIA_JANITOR_SEED_CLEANUP=true.", report.lines)

    def test_report_only_mode_still_wins_over_seed_cleanup(self) -> None:
        _, post = self.run_rule(True, [seed_torrent("done", days=20)], {"done"}, execute=False)
        post.assert_not_called()

    def test_with_both_flags_finished_imported_torrents_go_with_their_files(self) -> None:
        torrents = [seed_torrent("done", days=20), seed_torrent("owed", days=3)]
        report, post = self.run_rule(True, torrents, {"done", "owed"})
        post.assert_called_once_with("/api/v2/torrents/delete", {"hashes": "done", "deleteFiles": "true"}, timeout=300)
        self.assertIn("Seed category: removed 1 torrents and their files, 1.0 GB freed.", report.lines)

    def test_unreadable_history_removes_nothing(self) -> None:
        report, post = self.run_rule(True, [seed_torrent("done", days=20)], urllib.error.URLError("down"))
        post.assert_not_called()
        self.assertTrue(report.problems[0].startswith("Seed category: *arr history unreadable, nothing removed"))


class OutgoingRequestTests(unittest.TestCase):
    def test_requests_carry_a_named_user_agent(self) -> None:
        """Discord's Cloudflare answers Python's default agent with a 403
        (error 1010): the first live report never arrived (2026-10-17)."""
        sent = []

        def fake_urlopen(request, timeout=0):
            sent.append(request)
            response = mock.MagicMock()
            response.__enter__.return_value.read.return_value = b""
            return response

        with mock.patch.object(janitor.urllib.request, "urlopen", side_effect=fake_urlopen):
            janitor.http("POST", "https://discord.com/api/webhooks/1/x", body={"content": "hi"})
        self.assertEqual(sent[0].get_header("User-agent"), janitor.USER_AGENT)

    def test_share_limits_name_the_action_qbittorrent_5_2_requires(self) -> None:
        sent = []

        def respond(request, timeout=0):
            sent.append(request)
            response = mock.MagicMock()
            response.__enter__.return_value.read.return_value = b""
            return response

        opener = mock.Mock()
        opener.open.side_effect = respond
        environ = {"QBITTORRENT_URL": "http://qbittorrent:8080", "QBITTORRENT_USERNAME": "u",
                   "QBITTORRENT_PASSWORD": "p"}
        with mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(janitor.urllib.request, "build_opener", return_value=opener):
            janitor.set_share_limits(["abc", "def"], 3.0, 21600)
        form = urllib.parse.parse_qs(sent[-1].data.decode())
        self.assertEqual(sent[-1].full_url, "http://qbittorrent:8080/api/v2/torrents/setShareLimits")
        self.assertEqual(form["hashes"], ["abc|def"])
        self.assertEqual(form["shareLimitAction"], ["Default"])
        self.assertEqual((form["ratioLimit"], form["seedingTimeLimit"]), (["3.0"], ["21600"]))


if __name__ == "__main__":
    unittest.main()
