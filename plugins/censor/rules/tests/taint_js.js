const cp = require('child_process');
function h(req) {
  const host = req.query.host;
  // ruleid: js-taint-command-exec
  // ruleid: js-child-process-exec-concat
  cp.exec('ping ' + host);
  // ok: js-taint-command-exec
  cp.execFile('ping', [req.query.host]);
}
