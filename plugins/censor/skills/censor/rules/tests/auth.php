<?php
// Test fixture for rule: cookie-as-identity  (NOT production code)

// ruleid: cookie-as-identity
$user = $_COOKIE['username'];

// ruleid: cookie-as-identity
$userName = $_COOKIE['remembered_user'];

// ruleid: cookie-as-identity
$currentUser = trim($_COOKIE['who']);

// ok: cookie-as-identity
$theme = $_COOKIE['theme'];

// ok: cookie-as-identity
$user = $_SESSION['authenticated_user'];
