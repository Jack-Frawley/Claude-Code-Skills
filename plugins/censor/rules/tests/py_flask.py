# Test fixture for rule: py-flask-debug  (NOT production code)

# ruleid: py-flask-debug
app.run(debug=True)

# ruleid: py-flask-debug
app.run(host="0.0.0.0", port=8080, debug=True)

# ok: py-flask-debug
app.run(host="0.0.0.0", port=8080)

# ok: py-flask-debug
app.run(debug=False)
