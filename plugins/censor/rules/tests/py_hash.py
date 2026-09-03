# Test fixture for rule: py-weak-hash-password  (NOT production code)

# ruleid: py-weak-hash-password
digest = hashlib.md5(password.encode()).hexdigest()

# ruleid: py-weak-hash-password
digest = hashlib.sha1(token.encode()).hexdigest()

# ruleid: py-weak-hash-password
h = hashlib.new("md5", data)

# ok: py-weak-hash-password
digest = hashlib.sha256(password.encode()).hexdigest()
