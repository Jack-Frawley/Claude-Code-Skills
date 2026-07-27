<?php
phpinfo();                                  // phpinfo-call
$user = $_COOKIE['user'];                   // cookie-as-identity
echo $_GET['q'];                            // echo-request-unescaped
$host = $_GET['h']; exec("ping " . $host);  // php-taint-command-exec
$id = $_GET['id']; $db->query("SELECT * FROM t WHERE id=" . $id);  // sqli
