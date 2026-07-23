<?php
// Test fixture for rule: error-detail-echoed  (NOT production code)

// ruleid: error-detail-echoed
die($e->getMessage());

// ruleid: error-detail-echoed
echo "Query failed: " . $e->getMessage();

// ruleid: error-detail-echoed
print_r(sqlsrv_errors());

// ok: error-detail-echoed
error_log($e->getMessage());

// ok: error-detail-echoed
die('An error occurred. Reference: ' . $correlationId);
