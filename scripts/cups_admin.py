#!/usr/bin/env python3
"""
Keeps CUPS queues and the crontab in step with /data/printers.json, and reports
job states. Used by entrypoint.sh, auto-print.sh, and the web UI.

Usage:
  cups_admin.py sync              Make every printer's queue ready and install the crontab
  cups_admin.py ensure-queue ID   Make one printer's queue ready
  cups_admin.py job-state JOB     Print the job's state, state reasons, and printer
                                  message, separated by \\x1f
"""

import json
import os
import re
import time
import subprocess
import sys

PRINTERS_FILE = "/data/printers.json"
DEFAULT_SCHEDULE = "0 10 */3 * *"
CRON_FIELD = r"[0-9*/,-]+"
CRON_SCHEDULE = re.compile(rf"^{CRON_FIELD}( {CRON_FIELD}){{4}}$")
FIELD_SEP = "\x1f"
PPD_WAIT_SECONDS = 30


def read_printers():
    with open(PRINTERS_FILE) as f:
        return json.load(f)


def printer_uri(printer):
    if printer.get("connection", "ipp") == "socket":
        return f"socket://{printer['ip']}:{printer.get('port', 9100)}"
    return f"ipp://{printer['ip']}/ipp/print"


def ppd_path(name):
    return f"/etc/cups/ppd/{name}.ppd"


def register_queue(printer):
    """Create or update the printer's CUPS queue.

    -m everywhere builds the queue's PPD from the printer's capabilities. If the
    printer doesn't answer, CUPS still creates the queue, but disabled and
    without a PPD, so it can't print. That case raises RuntimeError. lpadmin
    failures raise CalledProcessError or TimeoutExpired."""
    name = printer["cups_name"]
    subprocess.run(
        ["lpadmin", "-p", name, "-v", printer_uri(printer), "-m", "everywhere",
         "-L", "Network", "-D", printer.get("name", name),
         "-o", f"media={printer.get('paper_size', 'Letter')}",
         # Abort a failed job instead of stopping the queue, so it can't block later prints.
         "-o", "printer-error-policy=abort-job"],
        check=True, capture_output=True, text=True, timeout=30)
    # CUPS builds the PPD after lpadmin returns. A sleeping printer can take a while to answer.
    for _ in range(PPD_WAIT_SECONDS):
        if os.path.exists(ppd_path(name)):
            break
        time.sleep(1)
    else:
        raise RuntimeError(f"{printer_uri(printer)} didn't answer, so CUPS has no PPD for {name}")
    enable_queue(name)


def enable_queue(name):
    # CUPS disables a queue, and may stop it accepting jobs, after some errors.
    subprocess.run(["cupsaccept", name], capture_output=True, timeout=5)
    subprocess.run(["cupsenable", name], capture_output=True, timeout=5)


def queue_ready(name):
    """True if CUPS has the queue and its PPD."""
    if subprocess.run(["lpstat", "-p", name], capture_output=True, timeout=10).returncode != 0:
        return False
    return os.path.exists(ppd_path(name))


def ensure_queue(printer):
    """Make sure the printer's queue can print, and return True if it had to be registered.

    A ready queue isn't re-registered, so a printer that's off when the container
    starts keeps its saved queue. It's still set to accept jobs and enabled, since
    the saved state can be disabled."""
    name = printer["cups_name"]
    if queue_ready(name):
        subprocess.run(["lpadmin", "-p", name, "-o", "printer-error-policy=abort-job"],
                       capture_output=True, timeout=10)
        enable_queue(name)
        return False
    register_queue(printer)
    return True


def install_cron(data):
    """Replace root's crontab with one line per active printer and return the line count.

    crontab rejects the whole file if one line is invalid, so invalid schedules are
    left out and reported instead."""
    default = data.get("global", {}).get("schedule", DEFAULT_SCHEDULE)
    lines = []
    for p in data.get("printers", []):
        if p.get("paused", False):
            continue
        schedule = " ".join(str(p.get("schedule", default)).split())
        if not CRON_SCHEDULE.match(schedule):
            print(f"  Skipping {p['id']}: invalid schedule {schedule!r}", file=sys.stderr)
            continue
        lines.append(f"{schedule} /app/auto-print.sh --printer-id={p['id']} >> /data/logs/cron.log 2>&1")
    content = "\n".join(lines) + "\n" if lines else ""
    subprocess.run(["crontab", "-"], input=content, text=True, check=True, capture_output=True, timeout=5)
    return len(lines)


def job_state(job_id):
    """Return (state, state reasons, printer message) for a job on the local CUPS server.

    The state is an IPP keyword: pending, pending-held, processing,
    processing-stopped, canceled, aborted, or completed. All three are empty if
    CUPS doesn't answer."""
    request = """{
  OPERATION Get-Job-Attributes
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR naturalLanguage attributes-natural-language en
  ATTR uri job-uri $uri
  ATTR keyword requested-attributes job-state,job-state-reasons,job-printer-state-message
}
"""
    proc = subprocess.run(["ipptool", "-tv", f"ipp://localhost/jobs/{job_id}", "/dev/stdin"],
                          input=request, capture_output=True, text=True, timeout=15)
    attrs = {}
    for line in proc.stdout.splitlines():
        m = re.match(r"\s*(job-state|job-state-reasons|job-printer-state-message) \(.*?\) = (.*)", line)
        if m:
            attrs[m.group(1)] = m.group(2).strip()
    return (attrs.get("job-state", ""), attrs.get("job-state-reasons", ""),
            attrs.get("job-printer-state-message", ""))


QUEUE_ERRORS = (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError)


def error_text(e):
    if isinstance(e, subprocess.CalledProcessError):
        return (e.stderr or "").strip() or str(e)
    return str(e)


def main():
    args = sys.argv[1:]
    if args == ["sync"]:
        data = read_printers()
        for p in data.get("printers", []):
            try:
                action = "Registered" if ensure_queue(p) else "Ready"
                print(f"  {action}: {p['cups_name']} -> {printer_uri(p)}")
            except QUEUE_ERRORS as e:
                print(f"  Could not register {p['cups_name']}: {error_text(e)}. auto-print.sh retries at print time.")
        print(f"  {install_cron(data)} cron job(s) installed")
    elif len(args) == 2 and args[0] == "ensure-queue":
        printer = next((p for p in read_printers().get("printers", []) if p["id"] == args[1]), None)
        if printer is None:
            sys.exit(f"Printer {args[1]} not found")
        try:
            if ensure_queue(printer):
                print(f"Queue {printer['cups_name']} wasn't ready. Registered it -> {printer_uri(printer)}")
        except QUEUE_ERRORS as e:
            sys.exit(f"Could not register {printer['cups_name']}: {error_text(e)}")
    elif len(args) == 2 and args[0] == "job-state":
        print(FIELD_SEP.join(job_state(args[1])))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
