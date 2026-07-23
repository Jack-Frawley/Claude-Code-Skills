<?php
// Test fixture for rule: sqli-string-interpolation  (NOT production code)

// ruleid: sqli-string-interpolation
$conn->query("SELECT * FROM users WHERE name = '" . $_POST['name'] . "'");

// ruleid: sqli-string-interpolation
mysqli_query($link, "SELECT * FROM t WHERE id = " . $_GET['id']);

// ruleid: sqli-string-interpolation
$sql = "SELECT * FROM t WHERE id = {$_REQUEST['id']}";

// ruleid: sqli-string-interpolation
$query = "SELECT * FROM sessions WHERE tok = '" . $_COOKIE['tok'] . "'";

// ok: sqli-string-interpolation
$stmt = $pdo->prepare("SELECT * FROM users WHERE id = ?");

// ok: sqli-string-interpolation
$stmt->execute([$_GET['id']]);

// ok: sqli-string-interpolation
$rows = $db->query("SELECT * FROM settings WHERE active = 1");
