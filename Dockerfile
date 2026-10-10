###############################################################################
# print-blockage-stopper
#
# All-in-one container that keeps any IPP-capable network printer's print head
# healthy by sending a small test print on a schedule. Supports multiple
# printers, custom test images, and a web dashboard.
###############################################################################

FROM debian:bookworm-slim

# The publish workflow adds org.opencontainers.image.* labels (source, revision, version).
LABEL description="Automated maintenance prints for any network printer (IPP Everywhere compatible)"

# ── Install packages ─────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        cups \
        cups-client \
        cups-filters \
        cups-ipp-utils \
        printer-driver-gutenprint \
        cron \
        curl \
        ca-certificates \
        python3 \
        python3-pip \
        fonts-dejavu-core \
    && pip3 install --break-system-packages --no-cache-dir Pillow \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── CUPS configuration ───────────────────────────────────────
COPY <<'CUPSD_CONF' /etc/cups/cupsd.conf
LogLevel warn
MaxLogSize 1m
Listen 0.0.0.0:631
ServerAlias *
DefaultEncryption Never
WebInterface Yes
# Queues point straight at network printers. Nothing is shared or advertised over DNS-SD.
Browsing No
# Abort a job that fails instead of stopping the queue. cups_admin.py also sets this per queue.
ErrorPolicy abort-job
# Save queue changes to /data/cups right away instead of up to 30s later.
DirtyCleanInterval 0

# Status pages — read-only, accessible from LAN
<Location />
  Order allow,deny
  Allow all
</Location>

# Job status — read-only from LAN
<Location /jobs>
  Order allow,deny
  Allow all
</Location>

# Printer status — read-only from LAN
<Location /printers>
  Order allow,deny
  Allow all
</Location>

# Admin — localhost only (container-internal)
<Location /admin>
  Order allow,deny
  Allow localhost
</Location>

# Admin config — localhost only
<Location /admin/conf>
  Order allow,deny
  Allow localhost
  AuthType Default
  Require user @SYSTEM
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Order deny,allow
    Allow localhost
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
    Allow localhost
  </Limit>

  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
CUPSD_CONF

# ── Create app directories ───────────────────────────────────
RUN mkdir -p /app /app/presets /data/logs /data/uploads

# ── Copy application files ───────────────────────────────────
COPY test-image/pro1100-test-print.png /app/test-print.png
COPY scripts/generate-presets.py /app/generate-presets.py
COPY scripts/entrypoint.sh /app/entrypoint.sh
COPY scripts/auto-print.sh /app/auto-print.sh
COPY scripts/webui.py /app/webui.py
COPY scripts/printer_probe.py /app/printer_probe.py
COPY scripts/stamp_image.py /app/stamp_image.py
COPY scripts/notify.py /app/notify.py
COPY scripts/cups_admin.py /app/cups_admin.py
COPY favicon.ico /app/favicon.ico

RUN chmod +x /app/entrypoint.sh /app/auto-print.sh

# ── Generate preset test images at build time ─────────────────
RUN python3 /app/generate-presets.py /app/presets

# ── Volumes ──────────────────────────────────────────────────
# /data persists logs, printer config, uploads, and CUPS state
VOLUME ["/data"]

# ── Environment variables (user-configurable) ────────────────
# PRINTER_IP:    (Optional) Auto-add this printer on first boot
# PRINTER_PORT:  Port for socket connection (default 9100)
# SCHEDULE:      Default cron expression for new printers
# PAPER_SIZE:    Default media size (A4, Letter, etc.)
# CONNECTION:    Default connection type: ipp or socket
# SKIP_HOURS:    Default skip-if-recently-printed window (hours)
# WEBHOOK_URL:   (Optional) URL for success/failure notifications
# TZ:            (Optional) IANA time zone, e.g. America/New_York. Cron schedules,
#                logs, and the dashboard use it. Defaults to UTC.
ENV PRINTER_IP="" \
    PRINTER_PORT="9100" \
    SCHEDULE="0 10 */3 * *" \
    PAPER_SIZE="A4" \
    CONNECTION="ipp" \
    SKIP_HOURS="72" \
    WEBHOOK_URL=""

# ── Expose ports ──────────────────────────────────────────────
EXPOSE 631
EXPOSE 8631

# ── Health check ─────────────────────────────────────────────
HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD curl -sf -o /dev/null http://localhost:8631/ \
        && lpstat -r | grep -qx 'scheduler is running' \
        && pgrep -x cron >/dev/null \
        || exit 1

# ── Version ──────────────────────────────────────────────────
# Shown in the dashboard footer and startup log. The publish workflow passes
# `git describe --tags --always --dirty`. Last, so a new version doesn't
# invalidate the cached layers above.
ARG VERSION=dev
ENV APP_VERSION=$VERSION

ENTRYPOINT ["/app/entrypoint.sh"]
