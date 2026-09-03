<?php
// Fixtures for the taint rules — INDIRECT flow (assign, then sink).
function cmd() {
  $host = $_GET['host'];
  // ruleid: php-taint-command-exec
  exec("ping " . $host);
  $safe = escapeshellarg($_GET['h2']);
  // ok: php-taint-command-exec
  exec("ping " . $safe);
  $n = (int) $_GET['count'];
  // ok: php-taint-command-exec
  system("ping -c " . $n);
}
function lfi() {
  $page = $_REQUEST['page'];
  // ruleid: php-taint-file-include
  include $page . ".php";
  $safe = basename($_GET['p2']);
  // ok: php-taint-file-include
  include "views/" . $safe;
}
function sqli($conn) {
  $id = $_GET['id'];
  $sql = "SELECT * FROM t WHERE id = " . $id;
  // ruleid: php-taint-sql-query
  sqlsrv_query($conn, $sql);
  // ok: php-taint-sql-query  (value bound in the params array, not the query)
  sqlsrv_query($conn, "SELECT * FROM t WHERE id = ?", array($_GET['id']));
}
