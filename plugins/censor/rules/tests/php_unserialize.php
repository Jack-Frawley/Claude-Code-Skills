<?php
// Test fixture for rule: php-unserialize-untrusted  (NOT production code)

// ruleid: php-unserialize-untrusted
$data = unserialize($_GET['payload']);

// ruleid: php-unserialize-untrusted
$obj = unserialize($_COOKIE['session']);

// ok: php-unserialize-untrusted
$data = json_decode($_GET['payload'], true);

// ok: php-unserialize-untrusted
$config = unserialize($trustedLocalString);
