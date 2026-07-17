#!/usr/bin/env bash
# =============================================================================
# upgrade-keycloak-26.6.4.sh
# In-place upgrade to Keycloak 26.6.4, run as root (no sudo). Edit CONFIG
# below to match your real environment before running.
#
# Lines marked [ADDED] are extra safety steps not in the original spec —
# skipping them causes silent failures or data loss, kept brief below.
# =============================================================================
set -euo pipefail

# --- CONFIG — edit to match your environment ---
KC_VERSION="26.6.4"
KC_BASE_DIR="/u01"
KC_ZIP="${KC_BASE_DIR}/keycloak-${KC_VERSION}.zip"
KC_NEW_HOME="${KC_BASE_DIR}/keycloak-${KC_VERSION}"
KC_NEW_CONF_SRC="${KC_BASE_DIR}/keycloak.conf"
KC_NEW_SERVICE_SRC="${KC_BASE_DIR}/keycloak.service"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="keycloak"
KC_RUNTIME_USER="keycloakadmin"
REQUIRED_JAVA_MAJOR="25"   # your env's policy — KC 26.6.4 itself supports Java 17+/21/25
STOP_TIMEOUT=60             # seconds to wait for old service to fully stop
START_TIMEOUT=180           # seconds to wait for new service to come up

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# =============================================================================
# Step 1 — Check Java major version
# =============================================================================
log "Step 1: checking Java..."
command -v java >/dev/null 2>&1 || die "Java not found. Install Java ${REQUIRED_JAVA_MAJOR} (tarball under /u01/java/..., not apt/yum — avoids package manager touching update-alternatives) and rerun."

JAVA_VER_STRING=$(java -version 2>&1 | head -n1)
JAVA_MAJOR=$(echo "$JAVA_VER_STRING" | grep -oP '"\K[0-9]+' | head -1)

if [ -z "$JAVA_MAJOR" ] || [ "$JAVA_MAJOR" != "$REQUIRED_JAVA_MAJOR" ]; then
  die "Current Java: ${JAVA_VER_STRING} — need Java ${REQUIRED_JAVA_MAJOR}. Install it and rerun. Note: this only checks 'java' on the shell's PATH — also verify JAVA_HOME in ${KC_NEW_SERVICE_SRC} points to the same Java, since systemd doesn't read the shell's PATH."
fi
log "OK — Java: ${JAVA_VER_STRING}"

# =============================================================================
# Step 2 — Ensure /u01 exists, cd into it
# =============================================================================
log "Step 2: checking ${KC_BASE_DIR}..."
if [ ! -d "$KC_BASE_DIR" ]; then
  mkdir -p "$KC_BASE_DIR"
  log "Created ${KC_BASE_DIR}."
fi
cd "$KC_BASE_DIR" || die "Cannot cd into ${KC_BASE_DIR}."

# =============================================================================
# Step 3 — Check install archive exists
# =============================================================================
log "Step 3: checking install archive ${KC_ZIP}..."
[ -f "$KC_ZIP" ] || die "Not found: ${KC_ZIP}. Download Keycloak ${KC_VERSION} (zip) into ${KC_BASE_DIR} and rerun."
log "OK — found ${KC_ZIP}."

# =============================================================================
# Step 4 — Unzip
# [ADDED] Verify the extracted folder actually matches KC_NEW_HOME instead of
# assuming it — protects against a re-packaged zip with a different top-level
# folder name.
# =============================================================================
log "Step 4: extracting ${KC_ZIP}..."
if [ -d "$KC_NEW_HOME" ]; then
  log "${KC_NEW_HOME} already exists — skipping extraction (won't overwrite silently on rerun). Remove it manually to re-extract."
else
  unzip -q "$KC_ZIP" -d "$KC_BASE_DIR"
  if [ ! -d "$KC_NEW_HOME" ]; then
    die "Extracted but ${KC_NEW_HOME} not found. Actual top-level folder in zip: $(unzip -l "$KC_ZIP" | awk 'NR==4{print $4}') — fix KC_NEW_HOME or rename it."
  fi
fi
cd "$KC_NEW_HOME" || die "Cannot cd into ${KC_NEW_HOME}."
log "OK — now in ${KC_NEW_HOME}."

# =============================================================================
# Step 5 — Check new config files (keycloak.conf, keycloak.service) exist in /u01
# =============================================================================
log "Step 5: checking new config files in ${KC_BASE_DIR}..."
[ -f "$KC_NEW_CONF_SRC" ]    || die "Missing new config: ${KC_NEW_CONF_SRC}. Prepare it and rerun."
[ -f "$KC_NEW_SERVICE_SRC" ] || die "Missing new config: ${KC_NEW_SERVICE_SRC}. Prepare it and rerun."
log "OK — both new config files present."

# =============================================================================
# [ADDED] Hard gate: confirm DB backup before proceeding.
# Jumping 21.0.1 -> 26.6.4 triggers a one-way Liquibase migration on next
# start. Reverting the binary won't undo it — only pg_restore from a backup
# will. This is the biggest risk in the whole run, so it's gated explicitly.
# =============================================================================
echo ""
echo "==== DB BACKUP CHECK ===="
echo "Next steps stop the service; starting Keycloak ${KC_VERSION} triggers an"
echo "automatic, one-way Liquibase schema migration — no binary-revert rollback."
echo 'Reference: pg_dump -h <db-host> -U <admin-user> -F c -f keycloak_backup_$(date +%Y%m%d_%H%M).dump keycloak'
echo "=========================="
read -rp "DB already backed up? (type 'yes' to continue): " DB_BACKUP_CONFIRM
[ "$DB_BACKUP_CONFIRM" = "yes" ] || die "Cancelled — back up the DB first, then rerun."

# =============================================================================
# Step 6 — Backup (rename) old config at the DESTINATION before overwrite:
#   - the default keycloak.conf shipped inside the extracted archive
#   - the current keycloak.service in /etc/systemd/system (old version's)
# =============================================================================
log "Step 6: backing up old destination configs to .bak..."
DEST_CONF="${KC_NEW_HOME}/conf/keycloak.conf"
if [ -f "$DEST_CONF" ]; then
  mv "$DEST_CONF" "${DEST_CONF}.bak"
  log "Backed up: ${DEST_CONF} -> ${DEST_CONF}.bak"
else
  log "No ${DEST_CONF} to back up — skipping."
fi

DEST_SERVICE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"
if [ -f "$DEST_SERVICE" ]; then
  mv "$DEST_SERVICE" "${DEST_SERVICE}.bak"
  log "Backed up: ${DEST_SERVICE} -> ${DEST_SERVICE}.bak"
else
  log "No ${DEST_SERVICE} to back up — skipping."
fi

# =============================================================================
# Step 7 — Copy new keycloak.conf into conf/
# =============================================================================
log "Step 7: copying new keycloak.conf..."
cp "$KC_NEW_CONF_SRC" "$DEST_CONF"
log "OK — ${KC_NEW_CONF_SRC} -> ${DEST_CONF}"

# =============================================================================
# Step 8 — Copy new keycloak.service into systemd
# [ADDED] daemon-reload right after — otherwise systemd keeps using the OLD
# cached unit definition, so 'start' in step 11 would silently run the old
# version despite the file on disk being replaced.
# =============================================================================
log "Step 8: copying new keycloak.service..."
cp "$KC_NEW_SERVICE_SRC" "$DEST_SERVICE"
log "OK — ${KC_NEW_SERVICE_SRC} -> ${DEST_SERVICE}"
systemctl daemon-reload
log "daemon-reload done."

# =============================================================================
# Step 9 — chown to keycloakadmin
# [ADDED] Verify the user exists first — chown to a nonexistent user still
# "succeeds" but leaves a raw UID, a silent footgun for later permission bugs.
# =============================================================================
log "Step 9: setting ownership of ${KC_NEW_HOME} to ${KC_RUNTIME_USER}..."
id "$KC_RUNTIME_USER" >/dev/null 2>&1 || die "User '${KC_RUNTIME_USER}' does not exist. Create it (useradd) and rerun."
chown -R "${KC_RUNTIME_USER}:${KC_RUNTIME_USER}" "$KC_NEW_HOME"
log "OK — ownership set."

# =============================================================================
# Step 10 — Stop old service if running, confirm it's fully stopped
# =============================================================================
log "Step 10: checking current ${SERVICE_NAME} service..."
if systemctl is-active --quiet "$SERVICE_NAME"; then
  log "Service is running (old version) — stopping..."
  systemctl stop "$SERVICE_NAME"

  waited=0
  while systemctl is-active --quiet "$SERVICE_NAME"; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$STOP_TIMEOUT" ]; then
      die "Service didn't stop within ${STOP_TIMEOUT}s. Check: journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
    fi
  done
  log "Confirmed: old service fully stopped."
else
  log "Service not running — skipping stop."
fi

# =============================================================================
# Step 11 — Start new service, wait until it's genuinely up
# Checks two layers: (a) process not crash-looping (is-active), (b) log
# actually shows Keycloak's startup success line — is-active alone can be
# true while Quarkus crashes and Restart=on-failure keeps retrying.
# =============================================================================
log "Step 11: starting ${SERVICE_NAME} (version ${KC_VERSION})..."
systemctl start "$SERVICE_NAME"

waited=0
STARTED_OK=0
while [ "$waited" -lt "$START_TIMEOUT" ]; do
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    die "Service not active while waiting to start — possible crash-loop. Check: journalctl -u ${SERVICE_NAME} -n 150 --no-pager"
  fi
  if journalctl -u "$SERVICE_NAME" --since "10 minutes ago" --no-pager 2>/dev/null | grep -qE "Keycloak.*started"; then
    STARTED_OK=1
    break
  fi
  sleep 3
  waited=$((waited + 3))
done

if [ "$STARTED_OK" -ne 1 ]; then
  die "Timed out after ${START_TIMEOUT}s waiting for startup confirmation. Follow manually: journalctl -u ${SERVICE_NAME} -f"
fi

echo ""
echo "=============================================="
echo " KEYCLOAK ${KC_VERSION} STARTED SUCCESSFULLY"
echo "=============================================="
systemctl status "$SERVICE_NAME" --no-pager | sed -n '1,10p'
