<?php
// Test fixture for rules: php-weak-hash, php-weak-random-token  (NOT production code)

// ruleid: php-weak-hash
$h = md5($password);

// ruleid: php-weak-hash
$s = sha1($token);

// ok: php-weak-hash
$good = password_hash($password, PASSWORD_ARGON2ID);

// ruleid: php-weak-random-token
$t = mt_rand();

// ruleid: php-weak-random-token
$id = uniqid();

// ok: php-weak-random-token
$csprng = bin2hex(random_bytes(32));
