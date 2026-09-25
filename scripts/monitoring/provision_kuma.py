#!/usr/bin/env python3
"""Idempotently provision Uptime-Kuma monitors from monitors.yml.

Uptime-Kuma has no REST API; it speaks Socket.IO. This uses the community
`uptime-kuma-api` client, which wraps that protocol.

    pip install uptime-kuma-api pyyaml

    export KUMA_URL=http://100.106.65.55:3001
    export KUMA_USERNAME=admin
    export KUMA_PASSWORD=...            # or KUMA_TOKEN for 2FA
    python3 provision_kuma.py --apply   # omit --apply for a dry run
    python3 provision_kuma.py --apply --test-notification

Idempotency: monitors are matched by NAME. An existing monitor with the same
name is updated in place rather than duplicated, so re-running is safe.

Alerts go to a Discord webhook read from $KUMA_DISCORD_WEBHOOK, or else from
~/.config/homelab/discord-webhook (one line, mode 600) -- the same file the
backup jobs on oryx alert through. Every monitor is attached to it on every
run, so a rebuilt Kuma gets its alerts back along with its monitors.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("missing dependency: pip install pyyaml")

INVENTORY = Path(__file__).with_name("monitors.yml")
WEBHOOK_FILE = Path(
    os.environ.get("KUMA_DISCORD_WEBHOOK_FILE", "~/.config/homelab/discord-webhook")
).expanduser()
NOTIFICATION_NAME = "Discord: servers"


def load_webhook() -> str | None:
    """The Discord webhook URL, or None when none is configured."""
    url = os.environ.get("KUMA_DISCORD_WEBHOOK", "").strip()
    if not url and WEBHOOK_FILE.is_file():
        url = WEBHOOK_FILE.read_text().strip()
    return url or None


def ensure_discord_notification(api, name: str, webhook_url: str) -> int:
    """Return the id of the Discord notification, creating or updating it.

    Kuma had ZERO notification channels while it held 31 monitors: a red
    monitor reached nobody unless someone happened to open the page, which is
    how freddy's backup failed two nights running without anyone knowing. A
    monitor wired to nobody is a dashboard, not an alert.

    Matched by name, so re-running updates the webhook rather than adding a
    second channel. `isDefault` puts it on monitors created in the UI later.
    """
    from uptime_kuma_api import NotificationType

    settings = dict(
        name=name,
        type=NotificationType.DISCORD,
        discordWebhookUrl=webhook_url,
        isDefault=True,
        applyExisting=True,
    )
    for n in api.get_notifications():
        if n.get("name") == name:
            api.edit_notification(n["id"], **settings)
            return n["id"]
    created = api.add_notification(**settings)
    return created.get("id") or next(
        n["id"] for n in api.get_notifications() if n.get("name") == name
    )



def ensure_docker_host(api, name: str, socket_path: str) -> int:
    """Return the id of a Docker Host in Kuma, creating it if absent.

    Kuma's `docker` monitor type does not talk to Docker directly -- it
    references a Docker Host entity configured separately, and the API
    rejects the monitor with "missing 1 required argument: 'docker_host'"
    if one does not exist yet. Provisioning the monitors therefore has to
    provision the host first.

    Matched by name so re-running updates nothing and creates no duplicates.
    """
    from uptime_kuma_api import DockerType

    for h in api.get_docker_hosts():
        if h.get("name") == name:
            return h["id"]
    created = api.add_docker_host(
        name=name, dockerType=DockerType.SOCKET, dockerDaemon=socket_path
    )
    # The API returns the created host under different keys by version.
    host = created.get("dockerHost") or created
    return host["id"] if isinstance(host, dict) and "id" in host else (
        next(h["id"] for h in api.get_docker_hosts() if h.get("name") == name)
    )


def build_payloads(doc: dict) -> list[dict]:
    """Translate the inventory into uptime-kuma-api monitor kwargs."""
    defaults = doc.get("defaults") or {}
    out: list[dict] = []

    for entry in doc.get("monitors") or []:
        spec = dict(entry)
        # 'weak' is documentation for humans, not part of the API payload.
        spec.pop("weak", None)
        mtype = spec.pop("type")

        payload: dict = {
            "name": spec.pop("name"),
            "interval": spec.pop("interval", defaults.get("interval", 60)),
            "retryInterval": spec.pop(
                "retryInterval", defaults.get("retryInterval", 60)
            ),
            "maxretries": spec.pop("maxretries", defaults.get("maxretries", 2)),
        }

        if mtype in ("http", "keyword"):
            payload["url"] = spec.pop("url")
            payload["accepted_statuscodes"] = spec.pop(
                "accepted_statuscodes", defaults.get("accepted_statuscodes")
            )
            if mtype == "keyword":
                payload["keyword"] = spec.pop("keyword")
        elif mtype == "port":
            payload["hostname"] = spec.pop("hostname")
            payload["port"] = spec.pop("port")
        elif mtype == "ping":
            payload["hostname"] = spec.pop("hostname")
        elif mtype == "docker":
            payload["docker_container"] = spec.pop("docker_container")
        else:
            raise ValueError(f"unsupported monitor type: {mtype}")

        payload["_type"] = mtype
        out.append(payload)

    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--apply",
        action="store_true",
        help="actually create/update monitors (default is a dry run)",
    )
    ap.add_argument(
        "--test-notification",
        action="store_true",
        help="with --apply, also send a test message through the Discord webhook",
    )
    args = ap.parse_args()
    webhook = load_webhook()
    if not webhook:
        print(
            f"WARNING: no Discord webhook ($KUMA_DISCORD_WEBHOOK or {WEBHOOK_FILE}) -- "
            "every monitor will alert NOBODY"
        )

    doc = yaml.safe_load(INVENTORY.read_text())
    payloads = build_payloads(doc)

    weak = [m["name"] for m in (doc.get("monitors") or []) if m.get("weak")]
    print(f"inventory: {len(payloads)} monitors defined in {INVENTORY.name}")
    if weak:
        print(f"  weak (port-only, cannot detect a hung app): {', '.join(weak)}")

    if not args.apply:
        for p in payloads:
            target = p.get("url") or p.get("docker_container") or p.get("hostname")
            print(f"  [dry-run] {p['_type']:8} {p['name']:32} {target}")
        if webhook:
            print(f"  [dry-run] notification {NOTIFICATION_NAME!r} on every monitor")
        print("\nDry run only. Re-run with --apply to write to Uptime-Kuma.")
        return 0

    try:
        from uptime_kuma_api import MonitorType, UptimeKumaApi
    except ImportError:
        return print("missing dependency: pip install uptime-kuma-api") or 1

    url = os.environ.get("KUMA_URL")
    user = os.environ.get("KUMA_USERNAME")
    password = os.environ.get("KUMA_PASSWORD")
    if not (url and user and password):
        return print("set KUMA_URL, KUMA_USERNAME and KUMA_PASSWORD") or 1

    type_map = {
        "http": MonitorType.HTTP,
        "keyword": MonitorType.KEYWORD,
        "port": MonitorType.PORT,
        "ping": MonitorType.PING,
        "docker": MonitorType.DOCKER,
    }

    api = UptimeKumaApi(url)
    created = updated = failed = 0
    try:
        api.login(user, password, os.environ.get("KUMA_TOKEN", ""))
        existing = {m["name"]: m["id"] for m in api.get_monitors()}
        print(f"connected to {url}; {len(existing)} monitor(s) already present")

        # Docker monitors reference a Docker Host entity, not the daemon
        # directly, so it has to exist before any of them can be created.
        docker_host_id = None
        if any(p["_type"] == "docker" for p in payloads):
            docker_host_id = ensure_docker_host(
                api,
                os.environ.get("KUMA_DOCKER_HOST_NAME", "freddy-socket"),
                os.environ.get("KUMA_DOCKER_SOCKET", "/var/run/docker.sock"),
            )
            print(f"  docker host id={docker_host_id}")

        notification_id = None
        if webhook:
            notification_id = ensure_discord_notification(api, NOTIFICATION_NAME, webhook)
            print(f"  notification {NOTIFICATION_NAME!r} id={notification_id}")
            if args.test_notification:
                from uptime_kuma_api import NotificationType

                result = api.test_notification(
                    name=NOTIFICATION_NAME,
                    type=NotificationType.DISCORD,
                    discordWebhookUrl=webhook,
                )
                print(f"  test message: {result.get('msg', result)}")

        for p in payloads:
            spec = {k: v for k, v in p.items() if k != "_type"}
            spec["type"] = type_map[p["_type"]]
            if p["_type"] == "docker":
                spec["docker_host"] = docker_host_id
            # Explicitly, every run: applyExisting only covers monitors that
            # existed when the notification was saved.
            if notification_id is not None:
                spec["notificationIDList"] = [notification_id]
            name = spec["name"]
            try:
                if name in existing:
                    api.edit_monitor(existing[name], **spec)
                    updated += 1
                    print(f"  updated {name}")
                else:
                    api.add_monitor(**spec)
                    created += 1
                    print(f"  created {name}")
            except Exception as exc:  # keep going; report at the end
                failed += 1
                print(f"  FAILED  {name}: {exc}")

        total = len(api.get_monitors())
        print(f"\ncreated={created} updated={updated} failed={failed} total={total}")
    finally:
        api.disconnect()

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
