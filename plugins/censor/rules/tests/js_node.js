const cp = require('child_process');
const jwt = require('jsonwebtoken');

function run(userInput) {
  // ruleid: js-child-process-exec-concat
  cp.exec('ls ' + userInput);
  // ok: js-child-process-exec-concat
  cp.execFile('ls', [userInput]);
}

function dyn(userInput) {
  // ruleid: js-eval-dynamic
  eval(userInput);
  // ok: js-eval-dynamic
  eval("1 + 1");
}

function verify(token, key) {
  // ruleid: js-jwt-alg-none
  return jwt.verify(token, key, { algorithms: ['none'] });
}
function verifyOk(token, key) {
  // ok: js-jwt-alg-none
  return jwt.verify(token, key, { algorithms: ['RS256'] });
}
