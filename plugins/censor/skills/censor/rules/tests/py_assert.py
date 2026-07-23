# Test fixture for rule: py-assert-security  (NOT production code)

# ruleid: py-assert-security
assert user.is_authenticated

# ruleid: py-assert-security
assert token == expected_token, "invalid token"

# ok: py-assert-security
if not user.is_authenticated:
    raise PermissionError("not authenticated")
