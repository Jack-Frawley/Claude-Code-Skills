<?php
// Test fixture for rules: phpinfo-call, var-dump-getenv  (NOT production code)

// ruleid: phpinfo-call
phpinfo();

// ok: phpinfo-call
$label = "phpinfo is dangerous";

// ruleid: var-dump-getenv
var_dump(getenv('DB_PASSWORD'));

// ruleid: var-dump-getenv
echo getenv('APP_KEY');

// ruleid: var-dump-getenv
print_r($_ENV);

// ok: var-dump-getenv
$dbHost = getenv('DB_HOST');
