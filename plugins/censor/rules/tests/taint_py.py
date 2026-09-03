import os, subprocess, shlex
from flask import request
def cmd():
    host = request.args.get('host')
    # ruleid: py-taint-command-exec
    # ruleid: py-command-injection
    os.system("ping " + host)
    safe = shlex.quote(request.args.get('h2'))
    # ok: py-taint-command-exec
    # ruleid: py-command-injection
    os.system("ping " + safe)
    # ok: py-taint-command-exec
    subprocess.run(["ping", request.args.get('h3')])
def sql(cur):
    uid = request.args.get('id')
    q = "SELECT * FROM t WHERE id = " + uid
    # ruleid: py-taint-sql-query
    cur.execute(q)
    # ok: py-taint-sql-query
    cur.execute("SELECT * FROM t WHERE id = ?", (request.args.get('id'),))
