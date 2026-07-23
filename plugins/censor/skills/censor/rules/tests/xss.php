<?php
// Test fixture for rule: echo-request-unescaped  (NOT production code)

// ruleid: echo-request-unescaped
echo $_GET['q'];

// ruleid: echo-request-unescaped
echo "Hello " . $_POST['name'];

// ruleid: echo-request-unescaped
print $_REQUEST['msg'];

// ok: echo-request-unescaped
echo htmlspecialchars($_GET['q'], ENT_QUOTES);

// ok: echo-request-unescaped
echo h($_POST['name']);

// ok: echo-request-unescaped
echo e($_REQUEST['msg']);
