<?php
// FP-corpus: clean PHP using common SAFE idioms that sit next to the rules'
// triggers. NOTHING here should produce a finding. A hit = a probable over-match.

// §2 parameterized — not sqli-string-interpolation
$stmt = $pdo->prepare("SELECT * FROM users WHERE id = ? AND org = ?");
$stmt->execute([$_GET['id'], $orgId]);

// §3 escaped output — not echo-request-unescaped
echo htmlspecialchars($_GET['q'] ?? '', ENT_QUOTES, 'UTF-8');
echo e($name);

// §1 secret from env — not hardcoded-secret-define
define('API_KEY', getenv('API_KEY'));
$dbPassword = getenv('DB_PASSWORD');

// php-debug-constant-true must NOT match ordinary boolean assignments
const DEBUG = false;
define('FEATURE_FLAG', true);
$response['ok'] = true;
$active = true;
$user['is_admin'] = true;

// §5 a cookie read into a NON-identity var — not cookie-as-identity
$theme = $_COOKIE['theme'] ?? 'light';
$lastPage = $_COOKIE['last_page'] ?? '/';

// §15 strong crypto — not php-weak-hash / php-weak-random-token
$hash = password_hash($pw, PASSWORD_ARGON2ID);
$token = bin2hex(random_bytes(32));
$id = random_int(1, 1000);

// §3 json, not unserialize; ldap escaped
$data = json_decode($_POST['payload'] ?? '{}', true);
$filter = "(uid=" . ldap_escape($_GET['u'] ?? '', '', LDAP_ESCAPE_FILTER) . ")";

// §8 same-origin redirect (fixed path) — not php-open-redirect
header('Location: /dashboard.php');

// §12 error logged, not echoed
try { risky(); } catch (Exception $ex) { error_log($ex->getMessage()); http_response_code(500); }
