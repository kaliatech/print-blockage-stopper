#!/usr/bin/env bash
###############################################################################
# auto-print.sh — Send a maintenance test print to one printer and wait for the
# printer to finish it. Called by cron and by the dashboard's Print Now button.
#
# Usage:
#   auto-print.sh --printer-id=printer-abc123           (cron)
#   auto-print.sh --printer-id=printer-abc123 --force   (Print Now)
#
# --force bypasses the pause and skip-if-recently-printed checks.
#
# Reads printer config from /data/printers.json. Writes the result to
# /data/status-<id>.json and appends it to /data/print-history.json.
###############################################################################
set -euo pipefail

# cron runs jobs with PATH=/usr/bin:/bin, which lacks lpadmin and cupsenable.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LOG_FILE="/data/logs/auto-print.log"
HISTORY_FILE="/data/print-history.json"
PRINTERS_FILE="/data/printers.json"
PRESETS_DIR="/app/presets"
UPLOADS_DIR="/data/uploads"
# How long to wait for the printer to finish the job. JOB_WAIT_SECONDS overrides it.
MAX_WAIT="${JOB_WAIT_SECONDS:-600}"
POLL_INTERVAL=5
# A scheduled run fires at the same minute as the previous one, so a skip window
# equal to the schedule interval would skip every other run. The window is
# shortened by this much.
SKIP_SLACK_SECONDS=3600

FORCE=false
PRINTER_ID=""

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --printer-id=*) PRINTER_ID="${arg#--printer-id=}" ;;
    esac
done

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Validate PRINTER_ID format (prevent path traversal)
if [ -z "$PRINTER_ID" ] || ! echo "$PRINTER_ID" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    echo "[$(timestamp)] ERROR: Invalid or missing PRINTER_ID: $PRINTER_ID" >> "$LOG_FILE"
    exit 1
fi

log() {
    local msg="[$(timestamp)] [$PRINTER_ID] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# ── Log rotation (keep last 1000 lines for multi-printer) ────────
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 1000 ]; then
    tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# One run per printer at a time, so Print Now can't cancel a scheduled job mid-print.
exec 9> "/tmp/auto-print-${PRINTER_ID}.lock"
if ! flock -n 9; then
    log "Another print run for this printer is in progress. Skipping."
    exit 0
fi

# The status and history files are written by Python so that quotes in CUPS
# messages can't break the JSON.
write_status() {
    local status="$1" message="$2"
    local status_file="/data/status-${PRINTER_ID}.json"
    PBS_STATUS="$status" PBS_MESSAGE="$message" PBS_TS="$(timestamp)" PBS_ID="$PRINTER_ID" python3 -c '
import json, os
e = os.environ
print(json.dumps({"status": e["PBS_STATUS"], "message": e["PBS_MESSAGE"], "timestamp": e["PBS_TS"],
                  "printer_id": e["PBS_ID"]}))
' > "${status_file}.tmp" && mv "${status_file}.tmp" "$status_file"
}

write_history() {
    local result="$1" message="$2"
    PBS_RESULT="$result" PBS_MESSAGE="$message" PBS_TS="$(timestamp)" PBS_EPOCH="$(date +%s)" \
    PBS_ID="$PRINTER_ID" python3 -c '
import json, os
e = os.environ
print(json.dumps({"timestamp": e["PBS_TS"], "epoch": int(e["PBS_EPOCH"]), "result": e["PBS_RESULT"],
                  "message": e["PBS_MESSAGE"], "printer_id": e["PBS_ID"]}))
' >> "$HISTORY_FILE"
    # Keep last 200 entries (more printers = more entries)
    if [ "$(wc -l < "$HISTORY_FILE")" -gt 200 ]; then
        tail -n 200 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    fi
}

# Send notifications (webhook, email, HA) if configured
notify() {
    local event="$1" message="$2"
    python3 /app/notify.py --event "$event" --printer "$PRINTER_NAME" --printer-id "$PRINTER_ID" \
        --message "$message" >> "$LOG_FILE" 2>&1 || true
}

# Record a failure, notify, and exit
fail() {
    local event="$1" message="$2"
    log "ERROR: $message"
    write_status "error" "$message"
    write_history "error" "$message"
    notify "$event" "$message"
    exit 1
}

if [ ! -f "$PRINTERS_FILE" ]; then
    log "ERROR: $PRINTERS_FILE not found"
    exit 1
fi

# ── Read printer config from JSON ────────────────────────────────
PRINTER_VARS=$(PBS_PRINTERS_FILE="$PRINTERS_FILE" PBS_PRINTER_ID="$PRINTER_ID" python3 -c "
import json, os, shlex, sys
e = os.environ
data = json.load(open(e['PBS_PRINTERS_FILE']))
p = next((p for p in data.get('printers', []) if p['id'] == e['PBS_PRINTER_ID']), None)
if p is None:
    sys.exit(1)
fields = {
    'CUPS_NAME': p.get('cups_name', ''),
    'PRINTER_NAME': p.get('name', 'Unknown'),
    'PRINTER_IP': p.get('ip', ''),
    'PRINTER_MODEL': p.get('model', ''),
    'PAPER_SIZE': p.get('paper_size', 'A4'),
    'SKIP_HOURS': p.get('skip_hours', 72),
    'IS_PAUSED': p.get('paused', False),
    'VARY_POSITION': p.get('vary_position', False),
    'TEST_IMAGE_ID': p.get('test_image', 'preset-4'),
}
for k, v in fields.items():
    print(f'{k}={shlex.quote(str(v))}')
") || {
    log "ERROR: Printer ID '$PRINTER_ID' not found in config"
    exit 1
}
eval "$PRINTER_VARS"
[[ "$SKIP_HOURS" =~ ^[0-9]+$ ]] || SKIP_HOURS=0

# ── Check if scheduling is paused ────────────────────────────────
if [ "$FORCE" = false ] && [ "$IS_PAUSED" = "True" ]; then
    log "Schedule is PAUSED. Skipping. Use dashboard to resume."
    exit 0
fi

# ── Skip if this service printed successfully within the window ──
# Only prints sent through this service are visible here. The printer's own
# job history isn't available over IPP.
if [ "$FORCE" = false ]; then
    LAST_OK_EPOCH=$(PBS_HISTORY_FILE="$HISTORY_FILE" PBS_PRINTER_ID="$PRINTER_ID" python3 -c "
import json, os
e = os.environ
last = 0
try:
    with open(e['PBS_HISTORY_FILE']) as f:
        for line in f:
            try:
                h = json.loads(line)
            except ValueError:
                continue
            if h.get('printer_id') == e['PBS_PRINTER_ID'] and h.get('result') == 'ok':
                last = max(last, int(h.get('epoch', 0)))
except FileNotFoundError:
    pass
print(last)
")
    if [ "$LAST_OK_EPOCH" -gt 0 ]; then
        AGE=$(( $(date +%s) - LAST_OK_EPOCH ))
        if [ "$AGE" -lt $(( SKIP_HOURS * 3600 - SKIP_SLACK_SECONDS )) ]; then
            HOURS_AGO=$((AGE / 3600))
            log "SKIPPED: last successful print ${HOURS_AGO}h ago (within ${SKIP_HOURS}h window)."
            write_status "ok" "Skipped. Printed ${HOURS_AGO}h ago"
            write_history "skipped" "Printed ${HOURS_AGO}h ago (threshold: ${SKIP_HOURS}h)"
            exit 0
        fi
    fi
fi

# ── Resolve the test image ───────────────────────────────────────
resolve_image() {
    local img_id="$1"
    if [[ "$img_id" == preset-* ]]; then
        local path="${PRESETS_DIR}/${img_id}.png"
        if [ -f "$path" ]; then echo "$path"; return; fi
    elif [[ "$img_id" == custom-* ]]; then
        local filename="${img_id#custom-}"
        local path="${UPLOADS_DIR}/${filename}"
        if [ -f "$path" ]; then echo "$path"; return; fi
    fi
    # Fallback
    if [ -f "/app/test-print.png" ]; then echo "/app/test-print.png"; return; fi
    echo "${PRESETS_DIR}/preset-4.png"
}

IMAGE_ORIG=$(resolve_image "$TEST_IMAGE_ID")

log "Printer: $PRINTER_NAME ($CUPS_NAME) | Image: $TEST_IMAGE_ID"

# ── Pre-flight ──────────────────────────────────────────────────
if [ ! -f "$IMAGE_ORIG" ]; then
    fail print_failed "Test image not found at $IMAGE_ORIG"
fi

# cupsd runs under the entrypoint, which restarts the container if it exits.
if ! lpstat -r 2>/dev/null | grep -qx 'scheduler is running'; then
    fail print_failed "CUPS is not running"
fi

# Saved queues normally survive restarts. ensure-queue re-registers one that's
# missing, or that was created while the printer was off (CUPS then has no PPD
# for it), and sets the queue to accept jobs and enabled.
ensure_queue() {
    local output
    if ! output=$(python3 /app/cups_admin.py ensure-queue "$PRINTER_ID" 2>&1); then
        fail print_failed "CUPS queue $CUPS_NAME can't print and couldn't be re-registered: $output"
    fi
    [ -z "$output" ] || log "$output"
}

log "Printer status: $(lpstat -p "$CUPS_NAME" 2>&1 | head -n 1)"
ensure_queue

# A job left queued by an earlier run (e.g. the printer was off) would print
# alongside this one, so cancel it.
STALE_JOBS=$({ lpstat -o "$CUPS_NAME" 2>/dev/null || true; } | wc -l)
if [ "$STALE_JOBS" -gt 0 ]; then
    log "Cancelling $STALE_JOBS unfinished job(s) from earlier runs."
    cancel -a "$CUPS_NAME" 2>/dev/null || true
fi

# ── Compose the page ─────────────────────────────────────────────
# Draws the image and a printer-info footer at the printer's resolution, sized to
# the printable area in the queue's PPD. Presets are drawn fresh at that size.
PAGE_IMAGE="/tmp/page-${PRINTER_ID}.png"
COMPOSE_ARGS=(--ppd "/etc/cups/ppd/${CUPS_NAME}.ppd" --media "$PAPER_SIZE"
              --name "$PRINTER_NAME" --ip "$PRINTER_IP" --model "$PRINTER_MODEL")
if [[ "$TEST_IMAGE_ID" =~ ^preset-([0-9]+)$ ]] && [ "$IMAGE_ORIG" = "${PRESETS_DIR}/${TEST_IMAGE_ID}.png" ]; then
    COMPOSE_ARGS+=(--preset "${BASH_REMATCH[1]}")
else
    COMPOSE_ARGS+=(--image "$IMAGE_ORIG")
fi
if [ "$VARY_POSITION" = "True" ]; then
    COMPOSE_ARGS+=(--vary-position)
fi
if COMPOSE_OUTPUT=$(python3 /app/compose_page.py "$PAGE_IMAGE" "${COMPOSE_ARGS[@]}" 2>&1); then
    IMAGE="$PAGE_IMAGE"
    log "$COMPOSE_OUTPUT"
else
    log "WARNING: Could not compose the page. Printing the image as is: $(echo "$COMPOSE_OUTPUT" | tail -n 1)"
    IMAGE="$IMAGE_ORIG"
fi

# ── Send print job (with retry) ──────────────────────────────────
submit() {
    lp -d "$CUPS_NAME" \
        -o media="$PAPER_SIZE" \
        -o fit-to-page \
        -o orientation-requested=3 \
        "$IMAGE" 2>&1
}

log "Sending maintenance print..."
if ! JOB_OUTPUT=$(submit); then
    log "WARNING: Submit failed: $JOB_OUTPUT. Retrying in 30 seconds..."
    sleep 30
    ensure_queue
    JOB_OUTPUT=$(submit) || fail print_failed "Could not submit job after 2 attempts: $JOB_OUTPUT"
fi

# lp prints e.g. "request id is PBS_legacy-12 (1 file(s))"
JOB_ID=$(echo "$JOB_OUTPUT" | sed -n 's/^request id is \([^ ]*\).*/\1/p')
JOB_NUM="${JOB_ID##*-}"
if ! [[ "$JOB_NUM" =~ ^[0-9]+$ ]]; then
    fail print_failed "Could not read the job ID from lp output: $JOB_OUTPUT"
fi
log "Job submitted: $JOB_ID"

# ── Wait for the printer to finish ───────────────────────────────
log "Waiting up to ${MAX_WAIT}s for job $JOB_ID to finish..."
ELAPSED=0
STATE="" REASONS="" MESSAGE=""
while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    IFS=$'\x1f' read -r STATE REASONS MESSAGE < <(python3 /app/cups_admin.py job-state "$JOB_NUM" 2>/dev/null) || true
    case "$STATE" in
        completed|aborted|canceled) break ;;
    esac
    # CUPS leaves a job whose filter crashed in processing-stopped, even with
    # ErrorPolicy abort-job. It can't print, so stop waiting. Other stopped
    # reasons, like media-empty, can clear on their own.
    case "$REASONS" in
        *cups-filter-crashed*|*document-format-error*|*document-unprintable-error*)
            cancel "$JOB_ID" 2>/dev/null || true
            STATE="failed"
            break
            ;;
    esac
done

log "Job $JOB_ID: state=${STATE:-unknown}, reasons=${REASONS:-none}, message=${MESSAGE:-none} (after ${ELAPSED}s)"
DETAIL="${MESSAGE:-$REASONS}"

case "$STATE" in
    completed)
        write_status "ok" "Print completed successfully"
        write_history "ok" "Print completed"
        notify print_completed "Print completed successfully"
        ;;
    aborted|canceled|failed)
        fail print_failed "Job ${STATE}: ${DETAIL:-no reason given}"
        ;;
    processing-stopped|pending-held)
        fail print_stopped "Printer stopped the job: ${DETAIL:-check paper, ink, and jams}. The job stays queued."
        ;;
    *)
        fail print_timeout "Not printed after ${MAX_WAIT}s (${STATE:-unknown}: ${DETAIL:-no reason given}). The job stays queued and prints when the printer is available."
        ;;
esac

exit 0
