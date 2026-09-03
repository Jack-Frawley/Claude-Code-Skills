# Test fixture for rule: py-eval-exec  (NOT production code)

# ruleid: py-eval-exec
eval(user_input)

# ruleid: py-eval-exec
exec(request.form["code"])

# ruleid: py-eval-exec
eval("__import__('os')." + attr)

# ok: py-eval-exec
eval("2 + 2")

# ok: py-eval-exec
value = ast.literal_eval(raw)
