<?php
// Test fixture for rules: eval-or-dynamic-exec, extract-request  (NOT production code)

// ruleid: eval-or-dynamic-exec
eval($_GET['code']);

// ruleid: eval-or-dynamic-exec
$fn = create_function('$a', 'return $a;');

// ruleid: eval-or-dynamic-exec
call_user_func($_POST['callback'], $data);

// ok: eval-or-dynamic-exec
$result = array_map('strtoupper', $items);

// ok: eval-or-dynamic-exec
call_user_func('trim', $value);

// ruleid: extract-request
extract($_POST);

// ruleid: extract-request
extract($_GET, EXTR_OVERWRITE);

// ok: extract-request
extract($validated_data);
