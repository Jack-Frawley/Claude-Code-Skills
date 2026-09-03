<?php
// Test fixture for rule: upload-trusts-client-name  (NOT production code)

// ruleid: upload-trusts-client-name
move_uploaded_file($_FILES['doc']['tmp_name'], $uploadDir . '/' . $_FILES['doc']['name']);

// ok: upload-trusts-client-name
move_uploaded_file($_FILES['doc']['tmp_name'], $uploadDir . '/' . $randomName . '.jpg');
