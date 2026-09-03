// FP-corpus: clean JS/TS. Nothing here should fire a rule.
const cp = require('child_process');
const jwt = require('jsonwebtoken');

// safe DOM sink — not innerhtml-string-build
el.textContent = userInput;
el.setAttribute('data-id', String(id));

// argv exec — not js-child-process-exec-concat
cp.execFile('ls', ['-la', dir]);

// parse, not eval — not js-eval-dynamic
const cfg = JSON.parse(raw);

// verified with pinned alg — not js-jwt-alg-none
const claims = jwt.verify(token, key, { algorithms: ['RS256'] });
