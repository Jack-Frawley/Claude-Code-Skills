<?php
// ruleid: php-debug-constant-true
define('DEBUG', true);

// ok: php-debug-constant-true
define('OTHER_FLAG', true);

// ok: php-debug-constant-true  (regression: a bare $var = true must NOT match)
$response['ok'] = true;
// ok: php-debug-constant-true
$active = true;
