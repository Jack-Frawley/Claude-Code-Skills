import pyodbc, os

# ruleid: py-odbc-trust-server-cert
CONN = f"DRIVER={{ODBC Driver 17}};SERVER=x;DATABASE=d;UID=u;PWD=p;TrustServerCertificate=yes"

# ruleid: py-odbc-trust-server-cert
CONN2 = "DRIVER={ODBC Driver 18};SERVER=y;Encrypt=yes;trustservercertificate=YES"

# ok: py-odbc-trust-server-cert
GOOD = f"DRIVER={{ODBC Driver 18}};SERVER=x;Encrypt=yes;TrustServerCertificate=no"

# ok: py-odbc-trust-server-cert
GOOD2 = "DRIVER={ODBC Driver 18};SERVER=x;Encrypt=yes"
