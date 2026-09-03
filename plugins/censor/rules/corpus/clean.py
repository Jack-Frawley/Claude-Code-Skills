# FP-corpus: clean Python. Nothing here should fire a rule.
import os, subprocess, secrets, json, hashlib
import yaml, requests, pyodbc

# parameterized — not py-sqli-format
cur.execute("SELECT * FROM t WHERE id = ? AND org = ?", (user_id, org))

# argv, no shell — not py-command-injection
subprocess.run(["ping", "-n", "1", host], check=True)

# env secret — not py-hardcoded-secret
CLIENT_SECRET = os.getenv("CLIENT_SECRET")
password = os.environ["DB_PASSWORD"]

# safe deserialization — not py-unsafe-deserialization
cfg = yaml.safe_load(open("config.yml"))
doc = json.loads(payload)

# TLS on, cert validated — not py-tls-verify-disabled / py-odbc-trust-server-cert
r = requests.get(url, timeout=(5, 30))
CONN = f"DRIVER={{ODBC Driver 18}};SERVER={s};Encrypt=yes;TrustServerCertificate=no"

# CSPRNG token; sha256 for a non-security checksum (md5/sha1 flag by design, so
# they are not used here — the corpus asserts a clean zero)
tok = secrets.token_hex(32)
etag = hashlib.sha256(open(path, "rb").read()).hexdigest()  # file etag

# no eval, no debug server
value = json.loads(external_input)
