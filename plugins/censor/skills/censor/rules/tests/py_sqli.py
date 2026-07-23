# Test fixture for rule: py-sqli-format  (NOT production code)

# ruleid: py-sqli-format
cursor.execute(f"SELECT * FROM users WHERE id = {user_id}")

# ruleid: py-sqli-format
cursor.execute("SELECT * FROM users WHERE name = '%s'" % name)

# ruleid: py-sqli-format
cursor.execute("SELECT * FROM t WHERE id = " + user_id)

# ruleid: py-sqli-format
cursor.execute("SELECT * FROM t WHERE id = {}".format(user_id))

# ruleid: py-sqli-format
query = "SELECT * FROM t WHERE name = '" + name + "'"

# ok: py-sqli-format
cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))

# ok: py-sqli-format
cursor.execute("SELECT * FROM users WHERE id = ?", [user_id])

# ok: py-sqli-format
cursor.execute("SELECT 1")
