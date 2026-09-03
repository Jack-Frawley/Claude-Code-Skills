# Test fixture for rule: py-hardcoded-secret  (NOT production code)
# All literal values below are OBVIOUS FAKES — not real credentials.

# ruleid: py-hardcoded-secret
PASSWORD = "REDACTED_FAKE"

# ruleid: py-hardcoded-secret
api_key = "REDACTED_FAKE_KEY"

# ruleid: py-hardcoded-secret
AUTH_TOKEN = "REDACTED_FAKE"

# ok: py-hardcoded-secret
PASSWORD = os.getenv("APP_PASSWORD")

# ok: py-hardcoded-secret
api_key = os.environ["API_KEY"]

# ok: py-hardcoded-secret
api_key = ""

# ok: py-hardcoded-secret
secret = load_secret_from_vault()
