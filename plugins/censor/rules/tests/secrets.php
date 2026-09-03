<?php
// Test fixture for rule: hardcoded-secret-define  (NOT production code)
// All literal values below are OBVIOUS FAKES — not real credentials.

// ruleid: hardcoded-secret-define
define('API_SECRET', 'REDACTED_FAKE_SECRET');

// ruleid: hardcoded-secret-define
define('APP_KEY', 'REDACTED_FAKE_KEY');

// ruleid: hardcoded-secret-define
$db_password = 'REDACTED_FAKE_SECRET';

// ok: hardcoded-secret-define
define('API_SECRET', getenv('API_SECRET'));

// ok: hardcoded-secret-define
$db_password = getenv('DB_PW');

// ok: hardcoded-secret-define
define('MAX_UPLOAD_SIZE', 5000000);
