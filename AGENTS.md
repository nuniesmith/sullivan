# AGENTS.md — sullivan

Deployment repo for **sullivan**, the media stack host (Tailscale 100.87.125.19): Prowlarr, qBittorrent, Radarr, Sonarr, Lidarr, Plex, Emby, Dispatcharr. Application code lives elsewhere; this repo is the compose + services layout for the box. Deploys auto-run on merge to main from the checkout at `/home/actions/sullivan`.

## Shared context

Read the shared agent context first: `soul.md` and `memory.md` (especially §1 and §3) in the [agents repo](https://github.com/nuniesmith/agents).

## Rules

- Markdown and `docs/**` are `paths-ignore`d in `ci-cd.yml`; any other merge to main redeploys the stack. Verify the **service** on the box afterwards, not the workflow checkmark.
- **Network exposure is deliberate:** Prowlarr (9696) and the qBittorrent WebUI (8080) bind to the tailnet only; BitTorrent (60000) stays public. Don't "fix" a bind to 0.0.0.0.
- Docker here uses the **containerd image store** and **sudo-rs** — commands that assume classic Docker storage or GNU sudo will mislead you.
- qBittorrent download directories must be owned by the `actions` user (qbt runs as `actions`); a root-owned download dir silently stalls torrents (paid for once, 2026-11-20).
- The `~/github/sullivan` clone on oryx is **stale** — don't treat it as the state of this repo; check origin or the deploy checkout.
- After adding or removing a stateful service here, update sullivan's backup script (in `nuniesmith/scripts`) in the same change.
- Daily host updates run from the `actions` repo composite (10:23 UTC).
