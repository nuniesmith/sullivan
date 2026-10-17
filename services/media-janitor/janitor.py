#!/usr/bin/env python3
"""Sullivan's media janitor: keeps qBittorrent's completed area from filling the
system disk, and wires Radarr, Sonarr and Lidarr to Emby and Discord.

Runs once a day as the `media-janitor` compose service and posts what it did to
DISCORD_MEDIA_WEBHOOK_URL. Nothing is deleted unless MEDIA_JANITOR_EXECUTE=true:
until then every run is a report of what it WOULD delete.

1. Unpackerr duplicates. Until 2026-10-17 Unpackerr also watched all of
   /complete as a plain folder and extracted each category folder into a
   `<category>_unpackerred` copy that nothing read or deleted: 612 GB of
   Sullivan's 1.8 TB system disk, 560 GB of it in the *arr categories
   (`seed_unpackerred` is reported, never deleted). Radarr, Sonarr and Lidarr import from
   Unpackerr's OTHER, in-place extraction, which it deletes after import. An
   entry in an *arr category's `_unpackerred` folder untouched for
   MEDIA_JANITOR_DUPLICATE_DAYS (default 2) is deleted.
2. Orphans. A top-level entry in an *arr category folder that no qBittorrent
   torrent owns, untouched for MEDIA_JANITOR_ORPHAN_DAYS (default 30). This
   needs QBITTORRENT_USERNAME and QBITTORRENT_PASSWORD; without them, or when
   qBittorrent lists nothing, the step is skipped. "Could not list the
   torrents" must never read as "no torrent owns this".
3. The old download area. Before downloads moved to the system disk, they
   lived in /mnt/media/qbittorrent: 2.6 TB of it on 2026-10-17, untouched
   since January, owned by no torrent, and none of it hardlinked to the
   library. An entry there (in an *arr category, its `_unpackerred` twin, or
   `incomplete`) that no torrent owns and that is untouched for
   MEDIA_JANITOR_LEGACY_DAYS (default 90) is deleted; one holding a file
   hardlinked elsewhere is kept, since deleting it would free nothing. Same
   qBittorrent rule as orphans.
4. Connections. Each *arr gets an Emby connection (refresh the library on
   import, rename and delete) and a Discord one (grabbed, imported, upgraded,
   failed, health), created or updated by name. Each needs its key or URL set.
5. Seed goals. Prowlarr's seed ratio and time per indexer are reported, and
   set when MEDIA_SEED_RATIO and MEDIA_SEED_DAYS are both set. Prowlarr pushes
   them to the *arrs, which hand them to qBittorrent with every new torrent.
   qBittorrent stops a torrent at its goal, and the *arrs' "remove completed"
   setting then deletes it and its files. With qBittorrent credentials,
   finished *arr torrents already in the client get the same limits.

The `seed` category is never touched: its torrents are force-seeded on purpose.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

log = logging.getLogger("media-janitor")

DAY = 86400.0
# Categories whose downloads an *arr imports, so their leftovers are only ever
# copies. NOT "seed" and NOT "shelfmark-books" (freddy copies those and owns
# their lifecycle).
ARR_CATEGORIES = ("tv-sonarr", "radarr", "lidarr")
# (environment prefix, API version) for each *arr.
ARRS = (("RADARR", "v3"), ("SONARR", "v3"), ("LIDARR", "v1"))

DISCORD_TRIGGERS = (
    "onGrab", "onDownload", "onReleaseImport", "onUpgrade", "onHealthIssue",
    "onManualInteractionRequired", "onDownloadFailure", "onImportFailure",
)
EMBY_TRIGGERS = (
    "onDownload", "onReleaseImport", "onUpgrade", "onRename", "onMovieDelete",
    "onMovieFileDelete", "onMovieFileDeleteForUpgrade", "onSeriesDelete",
    "onEpisodeFileDelete", "onEpisodeFileDeleteForUpgrade", "onArtistDelete",
    "onAlbumDelete", "onTrackRetag",
)
CONNECTION_NAME = {"Discord": "Discord (media-janitor)", "MediaBrowser": "Emby (media-janitor)"}


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def human(num: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if abs(num) < 1000:
            return f"{num:.0f} {unit}" if unit == "B" else f"{num:.1f} {unit}"
        num /= 1000
    return f"{num:.2f} TB"


# ---------------------------------------------------------------- filesystem

def walk_stats(path: Path) -> tuple[int, float]:
    """(apparent bytes, newest mtime) of everything under `path`, symlinks not followed.

    The newest mtime, not the entry's own: a folder whose name has not changed
    for a year can still be receiving files, and only its newest file says so.
    """
    size, newest, _ = walk_stats_linked(path)
    return size, newest


def walk_stats_linked(path: Path) -> tuple[int, float, int]:
    """walk_stats plus the bytes in files with more than one hard link."""
    try:
        if path.is_symlink():
            return 0, path.lstat().st_mtime, 0
        st = path.stat()
    except OSError:
        return 0, time.time(), 0
    if not path.is_dir():
        return st.st_size, st.st_mtime, st.st_size if st.st_nlink > 1 else 0
    total, newest, linked = 0, st.st_mtime, 0
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            p = Path(root) / name
            try:
                s = p.lstat()
            except OSError:
                continue
            newest = max(newest, s.st_mtime)
            if name in files and not p.is_symlink():
                total += s.st_size
                if s.st_nlink > 1:
                    linked += s.st_size
    return total, newest, linked


@dataclass
class Candidate:
    path: Path
    size: int
    age_days: float
    reason: str


def owned_by(entry: Path, owned: list[Path]) -> bool:
    """True if `entry` is, or holds, a torrent's content: never delete it."""
    return any(p == entry or entry in p.parents for p in owned)


def unpackerr_duplicates(complete: Path, now: float, min_days: float,
                         owned: list[Path] | None = None) -> list[Candidate]:
    """Entries in the *arr categories' `_unpackerred` folders, untouched for `min_days`.

    These are extraction COPIES: torrents seed their original files, which
    Unpackerr leaves in place (DELETE_ORIG false). `owned` is a second guard
    on top of that layout: anything a torrent owns, wherever it sits, is
    never a candidate, so a seeding torrent's files cannot be touched.
    """
    owned = owned or []
    out = []
    for category in ARR_CATEGORIES:
        folder = complete / f"{category}_unpackerred"
        if folder.is_symlink() or not folder.is_dir():
            continue
        for entry in sorted(folder.iterdir()):
            if entry.is_symlink() or owned_by(entry, owned):
                continue
            size, newest = walk_stats(entry)
            age = (now - newest) / DAY
            if age >= min_days:
                out.append(Candidate(entry, size, age, f"Unpackerr duplicate ({category})"))
    return out


def torrent_roots(torrents: list[dict[str, Any]], complete: Path) -> set[Path]:
    """The top-level entry under complete/<category>/ that each torrent owns."""
    roots = set()
    for t in torrents:
        content = Path(str(t.get("content_path") or ""))
        try:
            rel = content.relative_to(complete)
        except ValueError:
            continue
        if len(rel.parts) >= 2:
            roots.add(complete / rel.parts[0] / rel.parts[1])
    return roots


def mapped_content_paths(torrents: list[dict[str, Any]], container_prefix: str, here: Path) -> list[Path]:
    """Each torrent's content path under `container_prefix`, as this container sees it.

    qBittorrent's container mounts /mnt/media at /media, so a torrent it
    stores under /media/qbittorrent/... lives in the old download area, which
    this container mounts at `here`.
    """
    out = []
    prefix = Path(container_prefix)
    for t in torrents:
        content = Path(str(t.get("content_path") or ""))
        try:
            out.append(here / content.relative_to(prefix))
        except ValueError:
            continue
    return out


def legacy_candidates(legacy: Path, owned: list[Path], now: float, min_days: float,
                      kept: list[str]) -> list[Candidate]:
    """Old download area entries no torrent owns, untouched for `min_days`.

    An entry holding a hardlinked file is kept and named in `kept`: its data
    is still referenced somewhere else, so deleting it would free nothing.
    """
    folders = [legacy / "incomplete"]
    for category in ARR_CATEGORIES:
        folders += [legacy / "complete" / category, legacy / "complete" / f"{category}_unpackerred"]
    out = []
    for folder in folders:
        if folder.is_symlink() or not folder.is_dir():
            continue
        for entry in sorted(folder.iterdir()):
            if entry.is_symlink() or owned_by(entry, owned):
                continue
            size, newest, linked = walk_stats_linked(entry)
            if linked:
                kept.append(f"{entry} ({human(linked)} hardlinked)")
                continue
            age = (now - newest) / DAY
            if age >= min_days:
                out.append(Candidate(entry, size, age, f"old download area ({folder.relative_to(legacy)})"))
    return out


def orphans(complete: Path, owned: set[Path], now: float, min_days: float) -> list[Candidate]:
    out = []
    for category in ARR_CATEGORIES:
        folder = complete / category
        if folder.is_symlink() or not folder.is_dir():
            continue
        for entry in sorted(folder.iterdir()):
            if entry.is_symlink() or entry in owned:
                continue
            size, newest = walk_stats(entry)
            age = (now - newest) / DAY
            if age >= min_days:
                out.append(Candidate(entry, size, age, f"no torrent owns it ({category})"))
    return out


def delete(candidate: Candidate, now: float, min_days: float) -> bool:
    """Delete one candidate, re-checking it first. True if it was removed."""
    path = candidate.path
    if path.is_symlink() or not path.exists():
        return False
    _, newest = walk_stats(path)
    if (now - newest) / DAY < min_days:
        log.warning("skipping %s: changed since the scan", path)
        return False
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()
    return True


# ---------------------------------------------------------------------- HTTP

def http(method: str, url: str, *, headers: dict[str, str] | None = None,
         body: Any = None, form: dict[str, str] | None = None, timeout: float = 30) -> Any:
    data = None
    hdrs = {"Accept": "application/json", **(headers or {})}
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    elif form is not None:
        data = urllib.parse.urlencode(form).encode()
        hdrs["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return raw.decode(errors="replace")


class Arr:
    def __init__(self, name: str, base: str, key: str, version: str):
        self.name, self.base, self.key, self.version = name, base.rstrip("/"), key, version

    def call(self, method: str, path: str, body: Any = None) -> Any:
        return http(method, f"{self.base}/api/{self.version}{path}",
                    headers={"X-Api-Key": self.key}, body=body)


def configured_arrs() -> list[Arr]:
    arrs = []
    for prefix, version in ARRS:
        base, key = env(f"{prefix}_URL"), env(f"{prefix}_API_KEY")
        if base and key:
            arrs.append(Arr(prefix.title(), base, key, version))
    return arrs


def build_connection(resource: dict[str, Any], name: str, fields: dict[str, Any],
                     triggers: tuple[str, ...]) -> dict[str, Any]:
    """Fill a notification resource (a schema entry or an existing one) in place."""
    resource = json.loads(json.dumps(resource))
    resource["name"] = name
    for f in resource.get("fields", []):
        if f.get("name") in fields:
            f["value"] = fields[f["name"]]
    for key in list(resource):
        if key.startswith("on") and isinstance(resource[key], bool):
            supported = resource.get("supports" + key[0].upper() + key[1:], True)
            resource[key] = key in triggers and bool(supported)
    return resource


def ensure_connection(arr: Arr, implementation: str, fields: dict[str, Any],
                      triggers: tuple[str, ...]) -> str:
    """Create or update this janitor's connection of `implementation`; say what happened."""
    name = CONNECTION_NAME[implementation]
    existing = [n for n in arr.call("GET", "/notification") or [] if n.get("name") == name]
    if existing:
        resource = build_connection(existing[0], name, fields, triggers)
        if resource == existing[0]:
            return "unchanged"
        arr.call("PUT", f"/notification/{existing[0]['id']}", resource)
        return "updated"
    schema = [s for s in arr.call("GET", "/notification/schema") or []
              if s.get("implementation") == implementation]
    if not schema:
        return f"{implementation} is not offered by this version"
    arr.call("POST", "/notification", build_connection(schema[0], name, fields, triggers))
    return "created"


# ------------------------------------------------------------------ prowlarr

SEED_RATIO_FIELD = "torrentBaseSettings.seedRatio"
SEED_TIME_FIELD = "torrentBaseSettings.seedTime"


def seed_goal_changes(indexer: dict[str, Any], ratio: float | None, minutes: int | None) -> dict[str, Any] | None:
    """The indexer with new seed goals, or None when nothing would change."""
    if ratio is None or minutes is None:
        return None
    changed = json.loads(json.dumps(indexer))
    dirty = False
    for f in changed.get("fields", []):
        if f.get("name") == SEED_RATIO_FIELD and f.get("value") != ratio:
            f["value"], dirty = ratio, True
        if f.get("name") == SEED_TIME_FIELD and f.get("value") != minutes:
            f["value"], dirty = minutes, True
    return changed if dirty else None


def field_value(resource: dict[str, Any], name: str) -> Any:
    return next((f.get("value") for f in resource.get("fields", []) if f.get("name") == name), None)


# ---------------------------------------------------------------- the run

@dataclass
class Report:
    execute: bool
    lines: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)

    def add(self, line: str) -> None:
        log.info(line)
        self.lines.append(line)

    def problem(self, line: str) -> None:
        log.warning(line)
        self.problems.append(line)


def clean(report: Report, label: str, candidates: list[Candidate], now: float, min_days: float) -> None:
    total = sum(c.size for c in candidates)
    if not candidates:
        report.add(f"{label}: nothing to remove.")
        return
    if not report.execute:
        report.add(f"{label}: {len(candidates)} entries, {human(total)}, would be deleted.")
        return
    freed, removed = 0, 0
    for c in candidates:
        try:
            if delete(c, now, min_days):
                freed += c.size
                removed += 1
        except OSError as exc:
            report.problem(f"could not delete {c.path}: {exc}")
    report.add(f"{label}: deleted {removed} of {len(candidates)} entries, {human(freed)} freed.")


def qbittorrent_torrents() -> list[dict[str, Any]] | None:
    base, user, password = env("QBITTORRENT_URL"), env("QBITTORRENT_USERNAME"), env("QBITTORRENT_PASSWORD")
    if not (base and user and password):
        return None
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
    login = urllib.request.Request(
        base.rstrip("/") + "/api/v2/auth/login",
        data=urllib.parse.urlencode({"username": user, "password": password}).encode(),
        headers={"Referer": base},
    )
    with opener.open(login, timeout=30) as resp:
        if resp.read().strip() != b"Ok.":
            raise RuntimeError("qBittorrent refused the login")
    with opener.open(base.rstrip("/") + "/api/v2/torrents/info", timeout=60) as resp:
        torrents = json.loads(resp.read())
    return torrents if isinstance(torrents, list) else []


def run(execute: bool, now: float | None = None) -> Report:
    now = now or time.time()
    report = Report(execute=execute)
    complete = Path(env("MEDIA_JANITOR_COMPLETE", "/complete"))
    dup_days = float(env("MEDIA_JANITOR_DUPLICATE_DAYS", "2"))
    orphan_days = float(env("MEDIA_JANITOR_ORPHAN_DAYS", "30"))

    try:
        torrents = qbittorrent_torrents()
    except (OSError, urllib.error.URLError, RuntimeError, ValueError) as exc:
        torrents = None
        report.problem(f"qBittorrent unreadable, orphans skipped: {exc}")
    # Every torrent's content as this container sees it, from either mount.
    seeding = []
    if torrents:
        seeding = mapped_content_paths(torrents, "/complete", complete) + mapped_content_paths(
            torrents, env("MEDIA_JANITOR_LEGACY_CONTAINER_PATH", "/media/qbittorrent"),
            Path(env("MEDIA_JANITOR_LEGACY", "/legacy")))

    clean(report, "Unpackerr duplicates", unpackerr_duplicates(complete, now, dup_days, seeding), now, dup_days)
    legacy = Path(env("MEDIA_JANITOR_LEGACY", "/legacy"))
    legacy_days = float(env("MEDIA_JANITOR_LEGACY_DAYS", "90"))
    if torrents is None:
        report.add("Orphans and the old download area: skipped, no qBittorrent login configured.")
    elif not torrents:
        report.add("Orphans and the old download area: skipped, qBittorrent listed no torrents.")
    else:
        owned = torrent_roots(torrents, complete)
        clean(report, "Orphans", orphans(complete, owned, now, orphan_days), now, orphan_days)
        if legacy.is_dir():
            kept: list[str] = []
            old_owned = mapped_content_paths(torrents, env("MEDIA_JANITOR_LEGACY_CONTAINER_PATH", "/media/qbittorrent"), legacy)
            clean(report, "Old download area (/mnt/media/qbittorrent)",
                  legacy_candidates(legacy, old_owned, now, legacy_days, kept), now, legacy_days)
            if kept:
                report.add(f"Old download area: kept {len(kept)} entries that share files with the library.")

    for root, label in ((complete, "complete"), (legacy / "complete", "/mnt/media/qbittorrent/complete")):
        for name in ("seed", "seed_unpackerred"):
            folder = root / name
            if folder.is_dir() and not folder.is_symlink():
                size, _ = walk_stats(folder)
                if size:
                    report.add(f"Left alone: {human(size)} in {label}/{name} (the seed category is yours to manage).")

    configure_connections(report)
    configure_seed_goals(report, torrents)
    # Downloads land on the NVMe system disk (fast, small), and the *arrs copy
    # finished media to the HDD pool Emby reads. Both filling up stops things:
    # a full NVMe stalls every download, a full pool stops every import.
    disk_report(report, "NVMe (downloads)", complete, float(env("MEDIA_JANITOR_NVME_WARN", "0.15")))
    disk_report(report, "HDD pool (library)", legacy, float(env("MEDIA_JANITOR_POOL_WARN", "0.10")))
    return report


def disk_report(report: Report, label: str, path: Path, warn_below: float) -> None:
    try:
        usage = shutil.disk_usage(path)
    except OSError:
        return
    free = usage.free / usage.total if usage.total else 1.0
    report.add(f"{label}: {human(usage.free)} free of {human(usage.total)} ({free:.0%}).")
    if free < warn_below:
        report.problem(f"{label} is low on space: {free:.0%} free.")


def configure_connections(report: Report) -> None:
    arrs = configured_arrs()
    emby_key = env("EMBY_API_KEY")
    webhook = env("DISCORD_MEDIA_WEBHOOK_URL")
    if not arrs:
        report.add("Connections: skipped, no *arr API keys.")
        return
    for arr in arrs:
        results = []
        try:
            if emby_key:
                emby_fields = {
                    "host": env("EMBY_HOST_FOR_ARRS", "100.87.125.19"),
                    "port": int(env("EMBY_PORT", "8096")),
                    "useSsl": False,
                    "apiKey": emby_key,
                    "notify": False,
                    "updateLibrary": True,
                }
                results.append("Emby " + ensure_connection(arr, "MediaBrowser", emby_fields, EMBY_TRIGGERS))
            if webhook:
                discord_fields = {"webHookUrl": webhook, "username": "Media"}
                results.append("Discord " + ensure_connection(arr, "Discord", discord_fields, DISCORD_TRIGGERS))
        except (OSError, urllib.error.URLError, ValueError) as exc:
            report.problem(f"{arr.name} connections failed: {exc}")
            continue
        if results:
            report.add(f"{arr.name} connections: " + ", ".join(results) + ".")
    if not emby_key:
        report.add("Emby refresh: not set up, EMBY_API_KEY is empty.")
    if not webhook:
        report.add("Discord notices: not set up, DISCORD_MEDIA_WEBHOOK_URL is empty.")


def configure_seed_goals(report: Report, torrents: list[dict[str, Any]] | None) -> None:
    base, key = env("PROWLARR_URL"), env("PROWLARR_API_KEY")
    ratio_text, days_text = env("MEDIA_SEED_RATIO"), env("MEDIA_SEED_DAYS")
    ratio = float(ratio_text) if ratio_text else None
    minutes = int(float(days_text) * 1440) if days_text else None
    if not (base and key):
        return
    prowlarr = Arr("Prowlarr", base, key, "v1")
    try:
        for indexer in prowlarr.call("GET", "/indexer") or []:
            current = (field_value(indexer, SEED_RATIO_FIELD), field_value(indexer, SEED_TIME_FIELD))
            changed = seed_goal_changes(indexer, ratio, minutes)
            if changed is not None:
                prowlarr.call("PUT", f"/indexer/{indexer['id']}?forceSave=true", changed)
                report.add(f"Seed goal for {indexer.get('name')}: was ratio {current[0]}, "
                           f"{current[1]} min; now ratio {ratio}, {minutes} min.")
            else:
                report.add(f"Seed goal for {indexer.get('name')}: ratio {current[0]}, "
                           f"time {current[1] or 'none'} min."
                           + ("" if ratio is not None else " Set MEDIA_SEED_RATIO and MEDIA_SEED_DAYS to change it."))
    except (OSError, urllib.error.URLError, ValueError) as exc:
        report.problem(f"Prowlarr seed goals unreadable: {exc}")
        return
    if ratio is None or minutes is None or not torrents:
        return
    def needs_goal(t: dict[str, Any]) -> bool:
        # -2 means "the global limit" (none is set here), -1 means "never stop".
        ratio_limit = t.get("ratio_limit")
        time_limit = t.get("seeding_time_limit")
        return ratio_limit != ratio or time_limit != minutes

    late = [t["hash"] for t in torrents
            if t.get("category") in ARR_CATEGORIES and (t.get("progress") or 0) >= 1 and needs_goal(t)]
    if late and report.execute:
        try:
            set_share_limits(late, ratio, minutes)
            report.add(f"Applied the seed goal to {len(late)} finished torrents already in qBittorrent.")
        except (OSError, urllib.error.URLError, RuntimeError) as exc:
            report.problem(f"qBittorrent share limits not set: {exc}")
    elif late:
        report.add(f"{len(late)} finished torrents would get the new seed goal.")


def set_share_limits(hashes: list[str], ratio: float, minutes: int) -> None:
    base = env("QBITTORRENT_URL").rstrip("/")
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
    login = urllib.request.Request(base + "/api/v2/auth/login", headers={"Referer": base}, data=urllib.parse.urlencode(
        {"username": env("QBITTORRENT_USERNAME"), "password": env("QBITTORRENT_PASSWORD")}).encode())
    opener.open(login, timeout=30).read()
    form = {"hashes": "|".join(hashes), "ratioLimit": str(ratio), "seedingTimeLimit": str(minutes),
            "inactiveSeedingTimeLimit": "-2"}
    opener.open(urllib.request.Request(base + "/api/v2/torrents/setShareLimits", headers={"Referer": base},
                                       data=urllib.parse.urlencode(form).encode()), timeout=60).read()


def post_report(report: Report) -> None:
    webhook = env("DISCORD_MEDIA_WEBHOOK_URL")
    if not webhook:
        return
    mode = "deleting" if report.execute else "report only, set MEDIA_JANITOR_EXECUTE=true to delete"
    text = "\n".join(f"- {line}" for line in report.lines + [f"Problem: {p}" for p in report.problems])
    embed = {
        "title": f"Sullivan media janitor ({mode})",
        "description": text[:4000],
        "color": 0xED4245 if report.problems else 0x5865F2,
    }
    try:
        http("POST", webhook, body={"embeds": [embed], "allowed_mentions": {"parse": []}}, timeout=20)
    except (OSError, urllib.error.URLError) as exc:
        log.warning("Discord report not sent: %s", exc)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--loop", action="store_true", help="run every MEDIA_JANITOR_INTERVAL_HOURS")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    execute = env("MEDIA_JANITOR_EXECUTE").lower() in {"1", "true", "yes", "on"}
    interval = float(env("MEDIA_JANITOR_INTERVAL_HOURS", "24")) * 3600
    if args.loop:
        # Not the moment a deploy starts everything else.
        time.sleep(float(env("MEDIA_JANITOR_START_DELAY_SECONDS", "600")))
    while True:
        report = run(execute)
        post_report(report)
        if not args.loop:
            return
        time.sleep(interval)


if __name__ == "__main__":
    main()
