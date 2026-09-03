<?php
// Test fixture for rule: php-ldap-injection  (NOT production code)

// ruleid: php-ldap-injection
$result = ldap_search($conn, $baseDn, "(uid=" . $_GET['user'] . ")");

// ok: php-ldap-injection
$safe = ldap_search($conn, $baseDn, "(uid=" . ldap_escape($_GET['user'], '', LDAP_ESCAPE_FILTER) . ")");

// ok: php-ldap-injection
$all = ldap_search($conn, $baseDn, "(objectClass=*)");
