#!/usr/bin/env python3
"""Idempotently provision Uptime-Kuma monitors from monitors.yml.

Uptime-Kuma has no REST API; it speaks Socket.IO. This uses the community
`uptime-kuma-api` client, which wraps that protocol.

    pip install uptime-kuma-api pyyaml

    export KUMA_URL=http://100.106.65.55:3001
    export KUMA_USERNAME=admin
    export KUMA_PASSWORD=...            # or KUMA_TOKEN for 2FA
    python3 provision_kuma.py --apply   # omit --apply for a dry run

Idempotency: monitors are matched by NAME. An existing monitor with the same
name is updated in place rather than duplicated, so re-running is safe.
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
    args = ap.parse_args()

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

        for p in payloads:
            spec = {k: v for k, v in p.items() if k != "_type"}
            spec["type"] = type_map[p["_type"]]
            if p["_type"] == "docker":
                spec["docker_host"] = docker_host_id
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
