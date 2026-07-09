import requests
import json
import time

# =================================================================
# I. CẤU HÌNH THÔNG TIN
# =================================================================
KEYCLOAK_URL = "http://172.16.227.134"  # Thay bằng IP và Port của HAProxy
REALM = "loadtest"
ADMIN_USER = "admin"
ADMIN_PASS = "admin"
TOTAL_USERS = 1000                           # Đặt số lượng user tùy ý (ví dụ: 1000, 2000)

# =================================================================
# II. HÀM LẤY ADMIN ACCESS TOKEN (Dùng để gọi lại nhiều lần)
# =================================================================
def get_admin_token():
    token_url = f"{KEYCLOAK_URL}/realms/master/protocol/openid-connect/token"
    payload = f"grant_type=password&client_id=admin-cli&username={ADMIN_USER}&password={ADMIN_PASS}"
    headers = {'Content-Type': 'application/x-www-form-urlencoded'}
    
    try:
        response = requests.post(token_url, data=payload, headers=headers)
        response.raise_for_status()
        return response.json()['access_token']
    except Exception as e:
        print(f"[-] Lỗi nghiêm trọng khi lấy Admin Token: {e}")
        return None

# Khởi tạo token lần đầu tiên
access_token = get_admin_token()
if not access_token:
    print("[-] Không thể khởi tạo Script do lỗi Token.")
    exit(1)

auth_headers = {
    'Authorization': f'Bearer {access_token}',
    'Content-Type': 'application/json'
}

# =================================================================
# III. TIẾN HÀNH TẠO USER VÀ GHI FILE CSV (WITH FAIL-SAFE RETRY)
# =================================================================
csv_filename = 'users_dataset.csv'
print(f"[*] Bắt đầu tạo {TOTAL_USERS} users...")

with open(csv_filename, 'w', encoding='utf-8') as f:
    f.write("username,password\n") # Header cho JMeter
    
    for i in range(1, TOTAL_USERS + 1):
        username = f"user_loadtest_{i}"
        password = f"SecurePass_{i}!@#"
        
        user_data = {
            "username": username,
            "enabled": True,
            "credentials": [{"type": "password", "value": password, "temporary": False}]
        }
        
        create_url = f"{KEYCLOAK_URL}/admin/realms/{REALM}/users"
        
        # Gửi request tạo user
        res = requests.post(create_url, data=json.dumps(user_data), headers=auth_headers)
        
        # --- CƠ CHẾ TỰ ĐỘNG GIA HẠN TOKEN KHI HẾT HẠN (HTTP 401) ---
        if res.status_code == 401:
            print(f"[!] Phát hiện Token hết hạn tại user số {i}. Đang tiến hành cấp lại Token mới...")
            
            # Lấy token mới
            new_token = get_admin_token()
            if new_token:
                access_token = new_token
                auth_headers['Authorization'] = f'Bearer {access_token}'
                
                # Thử lại (Retry) gửi request tạo user một lần nữa bằng Token mới
                print(f"[*] Đang thử lại tác vụ tạo: {username}...")
                res = requests.post(create_url, data=json.dumps(user_data), headers=auth_headers)
            else:
                print(f"[-] Không thể gia hạn token. Script dừng tại user {username}")
                break
        # -----------------------------------------------------------

        if res.status_code == 201:
            f.write(f"{username},{password}\n")
            print(f"[+] Đã tạo thành công: {username}")
        elif res.status_code == 409:
            print(f"[!] Bỏ qua {username}: User này đã tồn tại trên Keycloak.")
        else:
            print(f"[-] Thất bại tại {username}: Mã lỗi {res.status_code} - {res.text}")

print(f"[==>] HOÀN THÀNH! Đã vượt qua giới hạn timeout. File '{csv_filename}' đã sẵn sàng.")
