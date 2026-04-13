# Cloudflare DDNS

A lightweight dynamic DNS updater for Cloudflare using a Bash script and systemd timer.

This tool keeps a Cloudflare DNS A record synchronized with the host’s current public IP address. It is designed for homelab and self-hosted environments where IP addresses are dynamic.

---

## Features

- Detects current public IP automatically
- Compares against Cloudflare DNS record
- Updates record only when a change is detected
- Runs via `systemd` service + timer (fully automated)
- Environment-based configuration (no hardcoding secrets)

---

## Requirements

- Linux system with `systemd`
- `bash`
- `curl`
- `jq` (if used in script; remove if not required)
- Cloudflare API token with DNS edit permissions

---

## Repository Contents

- cloudflare-ddns.sh → main update script
- cloudflare-ddns.service → systemd service unit
- cloudflare-ddns.timer → systemd timer for scheduling
- cloudflare-ddns.env.example → environment variable template

---

## Configuration

Create your environment file:

    cp cloudflare-ddns.env.example cloudflare-ddns.env

Edit it with your Cloudflare details:

- API_TOKEN
- ZONE_ID
- RECORD_ID
- RECORD_NAME

---

## Install systemd units

Copy service files:

    sudo cp cloudflare-ddns.service /etc/systemd/system/
    sudo cp cloudflare-ddns.timer /etc/systemd/system/
    sudo systemctl daemon-reload

Enable and start the timer:

    sudo systemctl enable --now cloudflare-ddns.timer

---

## Logs / Debugging

View service logs:

    journalctl -u cloudflare-ddns.service -f

Check timer status:

    systemctl list-timers | grep cloudflare

---

## Behavior

- Script runs on a schedule defined by the systemd timer
- Fetches current public IP
- Queries Cloudflare DNS record
- Updates record only if IP has changed
- Exits cleanly when no update is needed

---

## Security Notes

- API token should be restricted to DNS edit permissions only
- Do not commit cloudflare-ddns.env to version control
- Prefer storing secrets outside the repository in production setups

---

## License

MIT

