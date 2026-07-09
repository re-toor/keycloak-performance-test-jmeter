# -*- coding: utf-8 -*-
from __future__ import print_function
import requests
import json
import codecs

# =================================================================
# I. CẤU HÌNH THÔNG TIN
# =================================================================
KEYCLOAK_URL = "http://172.16.227.134"   # Thay bằng IP và Port của HAProxy / VIP
REALM = "loadtest"
ADMIN_USER = "admin"
ADMIN_PASS = "admin"
TOTAL_USERS = 1000                        # Đặt số lượng user tùy ý (ví dụ: 1000, 2000)

# =================================================================
# II. HÀM LẤY ADMIN ACCESS TOKEN (Dùng để gọi lại nhiều lần)
# =================================================================
def get_admin_token():
    token_url = "{0}/realms/master/protocol/openid-connect/token".format(KEYCLOAK_URL)
    payload = "grant_type=password&client_id=admin-cli&username={0}&password={1}".format(ADMIN_USER, ADMIN_PASS)
    headers = {'Content-Type': 'application/x-www-form-urlencoded'}

    try:
        response = requests.post(token_url, data=payload, headers=headers)
        response.raise_for_status()
        return response.json()['access_token']
    except Exception as e:
        print("[-] Loi nghiem trong khi lay Admin Token: {0}".format(e))
        return None

# Khởi tạo token lần đầu tiên
access_token = get_admin_token()
if not access_token:
    print("[-] Khong the khoi tao Script do loi Token.")
    exit(1)

auth_headers = {
    'Authorization': "Bearer {0}".format(access_token),
    'Content-Type': 'application/json'
}

# =================================================================
# III. TIẾN HÀNH TẠO USER VÀ GHI FILE CSV (WITH FAIL-SAFE RETRY)
# =================================================================
csv_filename = 'users_dataset.csv'
print("[*] Bat dau tao {0} users...".format(TOTAL_USERS))

with codecs.open(csv_filename, 'w', encoding='utf-8') as f:
    f.write(u"username,password\n")  # Header cho JMeter

    for i in range(1, TOTAL_USERS + 1):
        username = "user_loadtest_{0}".format(i)
        password = "SecurePass_{0}!@#".format(i)

        user_data = {
            "username": username,
            "enabled": True,
            "credentials": [{"type": "password", "value": password, "temporary": False}]
        }

        create_url = "{0}/admin/realms/{1}/users".format(KEYCLOAK_URL, REALM)

        # Gửi request tạo user
        res = requests.post(create_url, data=json.dumps(user_data), headers=auth_headers)

        # --- CƠ CHẾ TỰ ĐỘNG GIA HẠN TOKEN KHI HẾT HẠN (HTTP 401) ---
        if res.status_code == 401:
            print("[!] Phat hien Token het han tai user so {0}. Dang cap lai Token moi...".format(i))

            # Lấy token mới
            new_token = get_admin_token()
            if new_token:
                access_token = new_token
                auth_headers['Authorization'] = "Bearer {0}".format(access_token)

                # Thử lại (Retry) gửi request tạo user một lần nữa bằng Token mới
                print("[*] Dang thu lai tac vu tao: {0}...".format(username))
                res = requests.post(create_url, data=json.dumps(user_data), headers=auth_headers)
            else:
                print("[-] Khong the gia han token. Script dung tai user {0}".format(username))
                break
        # -----------------------------------------------------------

        if res.status_code == 201:
            f.write(u"{0},{1}\n".format(username, password))
            print("[+] Da tao thanh cong: {0}".format(username))
        elif res.status_code == 409:
            print("[!] Bo qua {0}: User nay da ton tai tren Keycloak.".format(username))
        else:
            print("[-] That bai tai {0}: Ma loi {1} - {2}".format(username, res.status_code, res.text))

print("[==>] HOAN THANH! File '{0}' da san sang.".format(csv_filename))
