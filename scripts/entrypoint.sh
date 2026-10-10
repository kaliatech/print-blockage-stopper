#!/usr/bin/env bash
###############################################################################
# entrypoint.sh — Configure the container, then run cupsd, cron, and the web UI
#
# PRINTER_IP is optional. If set, that printer is added on first run. Otherwise
# printers are added from the dashboard.
#
# cupsd, cron, and the web UI run as children of this script. If any of them
# exits, this script exits too, so Docker's restart policy restarts the
# container instead of leaving it running without a scheduler.
###############################################################################
set -euo pipefail

LOG_DIR="/data/logs"
mkdir -p "$LOG_DIR" /data/uploads

# ── Time zone ───────────────────────────────────────────────────
# Cron schedules, log timestamps, and the dashboard all use this zone.
if [ -n "${TZ:-}" ]; then
    zone_file="/usr/share/zoneinfo/$TZ"
    if [ ! -f "$zone_file" ] || [ "$(head -c 4 "$zone_file")" != "TZif" ]; then
        echo "ENTRYPOINT: ERROR: TZ='$TZ' is not a time zone. Use an IANA name such as America/New_York." >&2
        exit 1
    fi
    ln -sf "$zone_file" /etc/localtime
    echo "$TZ" > /etc/timezone
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ENTRYPOINT: $*"; }

# ── Input validation (all optional) ────────────────────────────

PRINTER_IP="${PRINTER_IP:-}"
PRINTER_PORT="${PRINTER_PORT:-9100}"
CONNECTION="${CONNECTION:-ipp}"
PAPER_SIZE="${PAPER_SIZE:-Letter}"
SCHEDULE="${SCHEDULE:-0 10 */3 * *}"
SKIP_HOURS="${SKIP_HOURS:-72}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

# Validate PRINTER_PORT if set
if [ -n "$PRINTER_PORT" ]; then
    if ! echo "$PRINTER_PORT" | grep -qE '^[0-9]{1,5}$' || [ "$PRINTER_PORT" -lt 1 ] || [ "$PRINTER_PORT" -gt 65535 ]; then
        log "ERROR: PRINTER_PORT must be 1-65535. Got: $PRINTER_PORT"
        exit 1
    fi
fi

# Validate CONNECTION
if [ "$CONNECTION" != "ipp" ] && [ "$CONNECTION" != "socket" ]; then
    log "ERROR: CONNECTION must be 'ipp' or 'socket'. Got: $CONNECTION"
    exit 1
fi

# Validate PAPER_SIZE
if ! echo "$PAPER_SIZE" | grep -qE '^[a-zA-Z0-9]{1,20}$'; then
    log "ERROR: PAPER_SIZE contains invalid characters: $PAPER_SIZE"
    exit 1
fi

# Validate SCHEDULE
if ! echo "$SCHEDULE" | grep -qE '^[0-9\*\/,\-]+[[:space:]]+[0-9\*\/,\-]+[[:space:]]+[0-9\*\/,\-]+[[:space:]]+[0-9\*\/,\-]+[[:space:]]+[0-9\*\/,\-]+$'; then
    log "ERROR: SCHEDULE is not a valid 5-field cron expression: $SCHEDULE"
    exit 1
fi

# Validate SKIP_HOURS
if ! echo "$SKIP_HOURS" | grep -qE '^[0-9]{1,3}$' || [ "$SKIP_HOURS" -lt 1 ] || [ "$SKIP_HOURS" -gt 720 ]; then
    log "ERROR: SKIP_HOURS must be 1-720. Got: $SKIP_HOURS"
    exit 1
fi

log "Time zone:        $(cat /etc/timezone 2>/dev/null || echo UTC)"
log "Default schedule: $SCHEDULE"
log "Default skip hrs: $SKIP_HOURS"
log "Paper size:       $PAPER_SIZE"

# ── Initialise printers.json if not present ───────────────────
PRINTERS_FILE="/data/printers.json"
if [ ! -f "$PRINTERS_FILE" ]; then
    log "Creating printers.json..."
    PBS_PRINTERS_FILE="$PRINTERS_FILE" PBS_SCHEDULE="$SCHEDULE" PBS_SKIP_HOURS="$SKIP_HOURS" \
    PBS_WEBHOOK_URL="$WEBHOOK_URL" python3 -c "
import json, os
e = os.environ
data = {'printers': [], 'global': {'schedule': e['PBS_SCHEDULE'], 'skip_hours': int(e['PBS_SKIP_HOURS']),
                                   'webhook_url': e['PBS_WEBHOOK_URL']}}
json.dump(data, open(e['PBS_PRINTERS_FILE'], 'w'), indent=2)
"
fi

# ── CUPS state in /data ─────────────────────────────────────────
# /etc/cups points at /data/cups, so queues (printers.conf and the PPDs generated
# from each printer) survive container re-creation, even if a printer is off when
# the container starts. cupsd.conf always comes from the image. This runs before
# cupsd starts so cupsd loads the saved queues.
if [ ! -L /etc/cups ]; then
    [ -d /data/cups ] || cp -a /etc/cups /data/cups
    cp /etc/cups/cupsd.conf /data/cups/cupsd.conf
    rm -rf /etc/cups
    ln -s /data/cups /etc/cups
fi

# ── Services ────────────────────────────────────────────────────
declare -A SERVICES
start_service() {
    local name="$1"
    shift
    "$@" &
    SERVICES[$!]="$name"
}

log "Starting CUPS daemon..."
start_service cupsd cupsd -f
# Wait for CUPS to be ready (up to 15 seconds)
for i in $(seq 1 15); do
    if lpstat -r 2>/dev/null | grep -qx 'scheduler is running'; then
        log "CUPS ready after ${i}s"
        break
    fi
    sleep 1
    if [ "$i" -eq 15 ]; then
        log "WARNING: CUPS not responding after 15s, continuing anyway"
    fi
done

# ── Legacy: add PRINTER_IP to printers.json if set and not already added ──
if [ -n "$PRINTER_IP" ]; then
    if echo "$PRINTER_IP" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.\-]{0,253}[a-zA-Z0-9]$'; then
        PBS_PRINTERS_FILE="$PRINTERS_FILE" \
        PBS_PRINTER_IP="$PRINTER_IP" \
        PBS_CONNECTION="$CONNECTION" \
        PBS_PRINTER_PORT="$PRINTER_PORT" \
        PBS_PAPER_SIZE="$PAPER_SIZE" \
        PBS_SCHEDULE="$SCHEDULE" \
        PBS_SKIP_HOURS="$SKIP_HOURS" \
        python3 -c "
import json, os
e = os.environ
data = json.load(open(e['PBS_PRINTERS_FILE']))
if any(p['ip'] == e['PBS_PRINTER_IP'] for p in data.get('printers', [])):
    print('Printer at ' + e['PBS_PRINTER_IP'] + ' already configured. Skipping auto-add.')
else:
    data['printers'].append({
        'id': 'printer-legacy',
        'name': 'Printer at ' + e['PBS_PRINTER_IP'],
        'ip': e['PBS_PRINTER_IP'],
        'connection': e['PBS_CONNECTION'],
        'port': int(e['PBS_PRINTER_PORT']),
        'paper_size': e['PBS_PAPER_SIZE'],
        'schedule': e['PBS_SCHEDULE'],
        'skip_hours': int(e['PBS_SKIP_HOURS']),
        'paused': False,
        'test_image': 'preset-4',
        'cups_name': 'PBS_legacy'
    })
    json.dump(data, open(e['PBS_PRINTERS_FILE'], 'w'), indent=2)
    print('Printer added: ' + e['PBS_PRINTER_IP'] + ' (PBS_legacy)')
" | while read -r line; do log "$line"; done
    else
        log "WARNING: PRINTER_IP has invalid format: $PRINTER_IP. Skipping auto-add."
    fi
fi

# ── Register printers in CUPS and install cron schedules ──────
log "Registering printers and installing cron schedules..."
python3 /app/cups_admin.py sync || log "WARNING: sync failed (see above)"

log "Starting cron daemon..."
start_service cron cron -f

log "Starting web UI on port 8631..."
start_service webui python3 /app/webui.py

# Copy the print log and CUPS errors to the container log.
touch /data/logs/auto-print.log
start_service log-tail tail -n 0 -F /data/logs/auto-print.log /var/log/cups/error_log 2>/dev/null

NUM_PRINTERS=$(PBS_PRINTERS_FILE="$PRINTERS_FILE" python3 -c "import json, os; print(len(json.load(open(os.environ['PBS_PRINTERS_FILE'])).get('printers',[])))" 2>/dev/null) || NUM_PRINTERS=0

log "============================================================"
log " print-blockage-stopper ${APP_VERSION:-unknown} is running"
log " Dashboard:  http://localhost:8631"
log " Printers:   $NUM_PRINTERS configured"
log " Logs:       /data/logs/"
log "============================================================"

# ── Run until a service exits ───────────────────────────────────
# The container ends as soon as this script exits, so wait for the services to
# stop. That gives cupsd time to save queue state.
stop_services() {
    kill "${!SERVICES[@]}" 2>/dev/null
    wait
}
trap 'log "Stopping"; stop_services; exit 0' TERM INT
set +e
wait -n -p EXITED_PID
status=$?
log "ERROR: ${SERVICES[$EXITED_PID]:-a service} exited with status $status. Exiting so Docker restarts the container."
stop_services
exit 1
