#!/usr/bin/env bash
# =============================================================================
# seed-users.sh — Tao user hang loat cho load test qua Admin REST API (curl)
# Khong can python/requests/jq — chi dung curl + grep + sed (core utils).
# Tu dong gia han admin token khi het han (401) va dinh ky.
# Xuat file users_dataset.csv (username,password) de nap vao JMeter CSV Data Set.
#
# Cach dung:
#   chmod +x seed-users.sh
#   ./seed-users.sh
# Sua cac bien ben duoi cho khop moi truong truoc khi chay.
# =============================================================================
set -u

# ── Cau hinh ─────────────────────────────────────────────────────────────────
KEYCLOAK_URL="http://172.16.227.134"     # IP:Port cua HAProxy/VIP hoac node
REALM="loadtest"                          # realm dich (phai ton tai san)
ADMIN_USER="admin"
ADMIN_PASS="admin"
TOTAL_USERS=1000                          # so user can tao
CSV="users_dataset.csv"
REFRESH_EVERY=500                         # lay lai token sau moi N user (phong 401)
# ─────────────────────────────────────────────────────────────────────────────

get_token() {
  curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" -d "client_id=admin-cli" \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"//; s/"$//'
}

TOKEN="$(get_token)"
if [ -z "$TOKEN" ]; then
  echo "[-] Khong lay duoc admin token — kiem tra KEYCLOAK_URL / ADMIN_PASS"
  exit 1
fi
echo "[+] Da lay admin token."

echo "username,password" > "$CSV"
echo "[*] Bat dau tao $TOTAL_USERS users vao realm '$REALM'..."
START=$(date +%s)

i=1
while [ "$i" -le "$TOTAL_USERS" ]; do
  USERNAME="user_loadtest_$i"
  PASSWORD="SecurePass_${i}"
  BODY="{\"username\":\"$USERNAME\",\"enabled\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"$PASSWORD\",\"temporary\":false}]}"

  # Gia han token dinh ky
  if [ "$i" -gt 1 ] && [ $((i % REFRESH_EVERY)) -eq 0 ]; then
    TOKEN="$(get_token)"
    echo "[*] ...$i/$TOTAL_USERS ($(($(date +%s)-START))s) — da gia han token"
  fi

  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$KEYCLOAK_URL/admin/realms/$REALM/users" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$BODY")

  # Token het han giua chung → cap lai + thu lai 1 lan
  if [ "$CODE" = "401" ]; then
    echo "[!] Token het han tai user $i — cap lai va thu lai..."
    TOKEN="$(get_token)"
    if [ -z "$TOKEN" ]; then
      echo "[-] Khong gia han duoc token. Dung tai user $USERNAME."
      break
    fi
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "$KEYCLOAK_URL/admin/realms/$REALM/users" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$BODY")
  fi

  case "$CODE" in
    201) echo "$USERNAME,$PASSWORD" >> "$CSV" ;;                 # tao thanh cong
    409) echo "$USERNAME,$PASSWORD" >> "$CSV" ;;                 # da ton tai — van ghi CSV
    *)   echo "[-] That bai $USERNAME: HTTP $CODE" ;;
  esac

  i=$((i+1))
done

TOTAL_OK=$(($(wc -l < "$CSV") - 1))
echo "[==>] HOAN THANH: $TOTAL_OK user trong CSV ($(($(date +%s)-START))s). File: $CSV"
