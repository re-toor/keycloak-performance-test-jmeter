#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG: sua cho dung moi truong ---
KC_BASE_DIR="/u01"
KC_HOME="/u01/keycloak"          # thu muc keycloak dang chay, sua neu khac
REQUIRED_JAVA_MAJOR=25
SERVICE_NAME="keycloak"
SYSTEMD_DIR="/etc/systemd/system"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

opt1_check_java() {
  if command -v java >/dev/null 2>&1; then
    local ver_str major
    ver_str=$(java -version 2>&1 | head -n1)
    major=$(echo "$ver_str" | grep -oP '"\K[0-9]+' | head -1)
    if [ -n "$major" ] && [ "$major" -gt "$REQUIRED_JAVA_MAJOR" ]; then
      echo "Java hien tai: ${ver_str} -> OK (> ${REQUIRED_JAVA_MAJOR})"
      exit 0
    fi
    log "Java hien tai: ${ver_str} -> chua dat (can > ${REQUIRED_JAVA_MAJOR})"
  else
    log "Chua co java."
  fi

  local jdk_zip jdk_dir
  jdk_zip=$(find "$KC_BASE_DIR" -maxdepth 1 -iname "jdk*.zip" | head -1)
  [ -n "$jdk_zip" ] || die "Khong tim thay file jdk*.zip trong ${KC_BASE_DIR}"
  log "Tim thay: ${jdk_zip}"

  jdk_dir="${jdk_zip%.zip}"
  if [ -d "$jdk_dir" ]; then
    log "${jdk_dir} da ton tai — bo qua giai nen."
  else
    unzip -q "$jdk_zip" -d "$jdk_dir"
    log "Da giai nen: ${jdk_zip} -> ${jdk_dir}"
  fi
}

opt2_backup_conf() {
  local conf="${KC_HOME}/conf/keycloak.conf"
  [ -f "$conf" ] || die "Khong thay ${conf}"
  cp "$conf" "${conf}.bak"
  log "OK: ${conf} -> ${conf}.bak"
}

opt3_replace_conf() {
  local src="${KC_BASE_DIR}/keycloak.conf" dest="${KC_HOME}/conf/keycloak.conf"
  [ -f "$src" ] || die "Khong thay ${src}"
  cp "$src" "$dest"
  log "OK: ${src} -> ${dest}"
}

opt4_install_service() {
  local src="${KC_BASE_DIR}/keycloak.service" dest="${SYSTEMD_DIR}/${SERVICE_NAME}.service"
  [ -f "$src" ] || die "Khong thay ${src}"
  cp "$src" "$dest"
  systemctl daemon-reload
  log "OK: ${src} -> ${dest}, daemon-reload done."
}

opt5_stop_service() {
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Keycloak dang chay — stopping..."
    systemctl stop "$SERVICE_NAME"
    log "Da stop."
  else
    log "Keycloak khong chay."
  fi
}

opt6_start_service() {
  systemctl start "$SERVICE_NAME"
  sleep 3
  systemctl status "$SERVICE_NAME" --no-pager | sed -n '1,10p'
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "OK: keycloak dang chay."
  else
    die "Keycloak khong active. Kiem tra: journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
  fi
}

run() {
  case "$1" in
    1) opt1_check_java ;;
    2) opt2_backup_conf ;;
    3) opt3_replace_conf ;;
    4) opt4_install_service ;;
    5) opt5_stop_service ;;
    6) opt6_start_service ;;
    *) die "Option khong hop le: $1" ;;
  esac
}

if [ "${1:-}" != "" ]; then
  run "$1"
  exit 0
fi

cat <<EOF

=== Keycloak Upgrade ===
1) Check Java (> ${REQUIRED_JAVA_MAJOR}), neu chua co thi cai JDK tu ${KC_BASE_DIR}/jdk*.zip
2) Backup conf/keycloak.conf -> .bak
3) Thay keycloak.conf tu ${KC_BASE_DIR}
4) Cai keycloak.service tu ${KC_BASE_DIR}
5) Stop keycloak (neu dang chay)
6) Start keycloak va kiem tra
0) Thoat
EOF
read -rp "Chon (0-6): " CHOICE
[ "$CHOICE" = "0" ] && exit 0
run "$CHOICE"
