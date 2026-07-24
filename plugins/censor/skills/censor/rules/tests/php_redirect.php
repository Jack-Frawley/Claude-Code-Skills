<?php
// Fixture for php-open-redirect (§8, CWE-601).

// ruleid: php-open-redirect
header("Location: " . $_GET['next']);

// ruleid: php-open-redirect
header("Location: " . $_POST['returnUrl']);

// ruleid: php-open-redirect
header("Location: {$_REQUEST['redirect']}");

// ruleid: php-open-redirect
header("Location: " . $_COOKIE['last_page']);

// ok: php-open-redirect
header("Location: /dashboard.php");

// ok: php-open-redirect
header("Location: https://intranet.example.com/home");

// ok: php-open-redirect -- allowlisted target chosen by key, not passed through
$targets = ['home' => '/home.php', 'reports' => '/reports.php'];
$key = $_GET['to'] ?? 'home';
$dest = $targets[$key] ?? '/home.php';
header("Location: " . $dest);

// ok: php-open-redirect
header("Content-Type: application/json");
