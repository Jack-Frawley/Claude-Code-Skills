<?php
// Test fixture for rules: php-display-errors-on, php-error-reporting-all,
// session-cookie-insecure  (NOT production code)

// ruleid: php-display-errors-on
ini_set('display_errors', 1);

// ruleid: php-display-errors-on
ini_set('display_errors', 'On');

// ok: php-display-errors-on
ini_set('display_errors', 0);

// ok: php-display-errors-on
ini_set('display_errors', 'Off');

// ruleid: php-error-reporting-all
error_reporting(E_ALL);

// ruleid: php-error-reporting-all
error_reporting(E_ALL | E_STRICT);

// ok: php-error-reporting-all
error_reporting(0);

// ruleid: session-cookie-insecure
session_set_cookie_params(['secure' => false, 'httponly' => true]);

// ruleid: session-cookie-insecure
ini_set('session.cookie_secure', 0);

// ok: session-cookie-insecure
session_set_cookie_params(['secure' => true, 'httponly' => true, 'samesite' => 'Lax']);

// ok: session-cookie-insecure
ini_set('session.cookie_secure', 1);
