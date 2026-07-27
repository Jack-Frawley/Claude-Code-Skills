import os, pyodbc
password = "SuperSecretLiteralValue123"                    # py-hardcoded-secret
cur.execute("SELECT * FROM t WHERE id = %s" % uid)         # py-sqli-format
CONN = "DRIVER=x;Encrypt=yes;TrustServerCertificate=yes"   # py-odbc-trust-server-cert
