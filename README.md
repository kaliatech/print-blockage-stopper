# Print Blockage Stopper

Automated maintenance prints for **any network printer** (IPP Everywhere compatible). Keeps pigment inkjet print heads healthy by sending small test prints on a schedule.

Forked from [ahmedbadr3/print-blockage-stopper](https://github.com/ahmedbadr3/print-blockage-stopper).

## Why?

Pigment-based inkjet printers — especially large-format models like Canon imagePROGRAF, Epson SureColor, and HP DesignJet — clog when they sit idle. The pigment settles in the nozzles, leading to expensive cleaning cycles, wasted ink, and sometimes permanent damage. This container prevents that by automatically printing a tiny test image every few days.

## Quick Start

Build and run from the repo root:

```bash
cd print-blockage-stopper
VERSION=$(git describe --tags --always --dirty) docker compose up -d --build
docker compose logs -f
```

Open **http://localhost:8631** and add printers from the dashboard. The dashboard footer shows `VERSION`, which defaults to `dev`.

- Rerun the `up` command after changing code. The scripts are copied into the image, so nothing reloads on its own. Rebuilds take seconds because the package layer is cached.
- Data goes in `./data`, which is gitignored and owned by root. To start fresh, run `docker compose down`, then `sudo rm -rf data`.

To run the published image instead, use this compose file:

```yaml
services:
  print-blockage-stopper:
    image: ghcr.io/kaliatech/print-blockage-stopper:latest
    init: true
    environment:
      TZ: America/New_York
    ports:
      - "8631:8631"
    volumes:
      - ./data:/data
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID]
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
```

Then open **http://YOUR_HOST:8631**.

## Features

- **Multi-printer support** — manage multiple printers from one container
- **Smart scheduling** — skip a scheduled print if this service printed successfully within N hours
- **Print confirmation** — waits for the printer to finish each job, and reports failed, stopped, and unconfirmed jobs as failures
- **Preset test images** — optimised for 4, 6, 8, 11, and 12-colour printers, drawn at the printer's resolution
- **Vary vertical position** — optionally prints the pattern at a random height each time
- **Custom image upload** — use your own test pattern (up to 5 MB)
- **Web dashboard** — status, schedule controls, print history chart
- **Connection status** — real-time green/red indicators
- **Ink levels** — live ink level bars via IPP attributes
- **Auto-retry** — retries a failed job submission once after 30 seconds
- **Notifications** — webhook (Slack/Discord/ntfy), email (SMTP), and Home Assistant
- **CSV export** — download print history
- **Mobile-friendly** — responsive layout

## Configuration

All settings are optional. Printers can be added entirely from the dashboard.

| Variable | Default | Description |
|---|---|---|
| `TZ` | `UTC` | IANA time zone, e.g. `America/New_York`. Schedules, logs, and the dashboard use it. The container exits at startup if the name isn't valid. |
| `PRINTER_IP` | *(empty)* | Auto-add this printer on first boot |
| `SCHEDULE` | `0 10 */3 * *` | Default cron schedule |
| `PAPER_SIZE` | `A4` | Default paper size (A4, Letter, A3, etc.) |
| `SKIP_HOURS` | `72` | Default skip window in hours |
| `CONNECTION` | `ipp` | Connection type: `ipp` or `socket` |
| `PRINTER_PORT` | `9100` | Socket port (only with `CONNECTION=socket`) |
| `WEBHOOK_URL` | *(empty)* | Webhook URL for notifications |

### Schedule Examples

Times are in the `TZ` zone.

| Expression | Meaning |
|---|---|
| `0 10 */3 * *` | Every 3 days at 10 AM |
| `0 10 */5 * *` | Every 5 days at 10 AM |
| `0 8 * * 1,4` | Monday and Thursday at 8 AM |
| `0 9 * * *` | Daily at 9 AM |

`*/3` in the day-of-month field restarts each month, so the run on the 31st is followed by one on the 1st.

### Test image

Pick the preset that matches the printer's inks. A 4-ink CMYK printer only needs `4-colour`. On it, the extra channels in larger presets are just CMYK mixes.

Each print is composed at the resolution in the queue's PPD (300 dpi for most IPP Everywhere printers), on a page the size of the printable area. Presets are drawn directly at that resolution, so lines and text stay sharp. Uploaded images are scaled to the printable width. A footer with the printer's name, IP, and the time goes under the image.

With **Vary vertical position** on, the image goes at a random height on the page instead of the middle. A thin horizontal line is printed only by the nozzles that line up with it, so moving the pattern between prints spreads the work across all of them. It uses no extra ink.

### Skip window

A scheduled print is skipped if this service printed successfully on that printer less than `skip_hours − 1` hours ago. The hour of slack keeps a window equal to the schedule interval from skipping every other run. Only prints sent through this service count. The printer doesn't report jobs from other computers over IPP.

## Notifications

Configure notifications from the dashboard under the **Notifications** card. Three independent channels:

**Webhook** — Any URL that accepts JSON POST. Compatible with Slack, Discord, ntfy.

**Email** — SMTP configuration (server, port, from/to, optional auth). Works with Gmail, Outlook, Mailgun, or any SMTP provider.

**Home Assistant** — Creates persistent notifications via the HA REST API. Requires a long-lived access token (HA profile > Long-Lived Access Tokens > Create Token). Supports self-signed certificates.

Each channel has a **Test** button to verify your setup.

## Ports

| Port | Purpose |
|---|---|
| `8631` | Dashboard |

CUPS listens on 631 inside the container. Nothing outside the container needs it, so it isn't published.

## Volumes

| Path | Purpose |
|---|---|
| `/data` | Printer config, logs, uploads, CUPS queues |

## How It Works

1. On startup, the container restores the saved CUPS queues, re-registers each printer from `printers.json`, and installs one cron line per printer.
2. cupsd, cron, and the web UI run under the entrypoint. If any of them exits, the container exits so Docker's restart policy restarts it.
3. Cron runs `auto-print.sh` on each printer's schedule. It applies the skip window, re-creates the CUPS queue if it's missing, and cancels jobs left queued by earlier runs. `compose_page.py` then draws the page, and it's submitted with `lp -o fit-to-page`.
4. It then polls CUPS for the job's state for up to 10 minutes. `completed` is recorded as OK. `aborted`, `canceled`, stopped, held, or still unfinished is recorded as a failure with the printer's message.
5. Results are logged and notifications sent to enabled channels.

## Requirements

- Any network printer with IPP Everywhere support
- Printer powered on with paper loaded
- Network access from Docker host to printer

## Testing locally

### Trigger a run

The dashboard's **Print Now** button runs a forced print. To run the script cron runs:

```bash
curl -s localhost:8631/api/printers    # get the printer id
docker compose exec print-blockage-stopper /app/auto-print.sh --printer-id=<id>          # like a scheduled run (applies skip and pause)
docker compose exec print-blockage-stopper /app/auto-print.sh --printer-id=<id> --force  # like Print Now
```

Results go to `/data/logs/auto-print.log`, `docker compose logs`, and the dashboard. `docker compose exec -e JOB_WAIT_SECONDS=30 …` shortens the 10-minute wait for the printer to finish.

### With a real printer

Each forced run prints a page. The schedule also runs locally, by default every 3 days at 10 AM, so a printer that's configured in another deployment too prints twice. Pause the printer in the local dashboard, or run `docker compose down` when you're done.

### With a simulated printer

`ippeveprinter`, from the `cups-ipp-utils` package already in the image, acts as an IPP Everywhere printer and pretends to print each job. It needs avahi and dbus, so build it on top of the app image after the first `docker compose up --build`:

```bash
docker build -t pbs-fakeprinter - <<'EOF'
FROM print-blockage-stopper-print-blockage-stopper
RUN apt-get update && apt-get install -y --no-install-recommends avahi-daemon dbus && rm -rf /var/lib/apt/lists/*
HEALTHCHECK NONE
ENTRYPOINT ["/bin/sh", "-c", "mkdir -p /run/dbus && dbus-daemon --system && avahi-daemon -D --no-rlimits && sleep 1 && exec ippeveprinter -p 631 -f application/pdf,image/pwg-raster,image/urf \"$@\" FakePrinter", "--"]
EOF
docker run -d --name pbs-fakeprinter --network print-blockage-stopper_default pbs-fakeprinter
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pbs-fakeprinter
```

Add the IP from the last command as a printer in the dashboard. Compose names the image and network after the directory, so these commands assume a checkout named `print-blockage-stopper`.

- **A printer that fails every job:** `docker run -d --name pbs-fakeprinter-bad --network print-blockage-stopper_default pbs-fakeprinter -c /bin/false`
- **The printer going offline:** `docker stop pbs-fakeprinter`. To bring it back, run `docker rm -f pbs-fakeprinter` and the `docker run` command again. `docker start` fails because dbus leaves a stale pid file.
- **Clean up:** `docker rm -f pbs-fakeprinter pbs-fakeprinter-bad`

## Published image

`.github/workflows/docker-publish.yml` builds and pushes `ghcr.io/kaliatech/print-blockage-stopper` when a `v*` tag is pushed. The dashboard footer shows `git describe --tags --always --dirty` for the build, passed in as the `VERSION` build argument.

| Trigger | Image tags | Version shown |
|---|---|---|
| Push tag `v1.2.3` | `1.2.3`, `latest` | `v1.2.3` |
| Push tag `v1.3.0-rc.1` | `1.3.0-rc.1` | `v1.3.0-rc.1` |
| Manual run on a tag | same as pushing that tag | the tag |
| Manual run on a branch | builds, pushes nothing | e.g. `v1.2.3-4-g975bd6a` |

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

Local builds pass `VERSION` as shown in [Quick Start](#quick-start).

## License

MIT
