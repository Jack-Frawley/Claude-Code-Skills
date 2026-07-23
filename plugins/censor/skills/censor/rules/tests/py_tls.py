# Test fixture for rule: py-tls-verify-disabled  (NOT production code)

# ruleid: py-tls-verify-disabled
r = requests.get("https://api.example.com/data", verify=False)

# ruleid: py-tls-verify-disabled
r = requests.post(url, json=payload, verify=False)

# ruleid: py-tls-verify-disabled
r = session.get(url, verify=False)

# ok: py-tls-verify-disabled
r = requests.get("https://api.example.com/data", verify=True)

# ok: py-tls-verify-disabled
r = requests.get("https://api.example.com/data")

# ok: py-tls-verify-disabled
r = requests.get(url, verify="/etc/ssl/certs/internal-ca.pem")
