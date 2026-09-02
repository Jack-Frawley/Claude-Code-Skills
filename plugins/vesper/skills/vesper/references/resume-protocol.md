# Resume protocol

The coming-back leg. Runs against an existing `VESPER_HANDOFF.md`.

## The autonomy boundary does NOT bind this leg

`departure-protocol.md`'s forbidden list - deploy, prod writes, outward-facing
actions - is a rule about acting UNATTENDED. On this leg the user is present
and asking, so it does not apply here. Deploying in particular is not merely
allowed: a successful deploy run in this session is one of only two things that
can clear the deploy gate at step 2.

**A repo's `PostToolUse` deploy hook may be Vesper-aware and inject a deferral
message here.** Whenever an unresolved `VESPER_HANDOFF.md` exists such a hook
fires after any `git push` touching a deployable project and says: do NOT
deploy, record a deferred action carrying the exact command, then continue with
the next ledger item. **That message is written for the departure leg and does
not bind this one.** There is no ledger on this leg, and deferring the deploy is
the one move that guarantees the handoff can never be cleared - it would defer
the very action the clearing condition requires. Read it as a reminder that a
handoff is still open, then deploy anyway when the user has asked for it, and
let that deploy clear the gate.

## Sequence

1. **Re-probe for what has moved in the repo.** Run:

       pwsh "<skill dir>/scripts/Get-VesperState.ps1" -RepoRoot "<repo root>" -ConfigPath "<repo root>/.vesper/config.json" -Baseline <baseline from the handoff>

   `<skill dir>` is wherever Vesper is installed - resolve it rather than
   writing a repo-relative path here. This is the FIRST command of the leg, so
   a path that is right for only one installation fails before anything else
   has run. Use the directory this file was read from if that is visible;
   otherwise read `install.skillDir` from `<repo root>/.vesper/config.json`,
   written by `/vesper setup`; otherwise fall back to the conventional install
   location, `~/.claude/skills/vesper`.

   `-ConfigPath` is what points the probe at this repo's config; without it
   the probe still exits 0 but every config-driven answer falls back to
   built-in defaults, and the deploy gate you are about to present is then
   describing a repo other than this one.

   Check `baselineValid` first. If it is false, the sha was transcribed wrong
   out of the handoff - fix the transcription and re-run. Do NOT proceed on a
   failed-closed gate; it reports every project pending and tells you nothing.

   What the re-probe CAN verify: further commits since the baseline, new
   uncommitted paths, whether the branch is ahead or behind origin, graph and
   memory state. Report anything it contradicts before acting on it - the file
   is a record of what was true last night, not now.

   **What it CANNOT verify: whether a deploy happened.** `git diff
   baseline..HEAD` is invariant under deployment and the project's deploy
   script (`deploy.script` in the config) leaves no state marker on either
   side. A `deployPending: true` on re-probe
   is NOT evidence that a deploy failed or never ran. Never redeploy, and never
   refuse work, on that basis.

2. **Present the blocking gate FIRST.** For each `webProjects[]` entry with
   `deployPending: true`, name the project and give its `command` verbatim.
   List any `orphanFiles[]` separately: those are server paths left live by a
   delete or rename, and no deploy run clears them - they need manual cleanup
   on the server, so they are a task for the user, not a deploy command.

   Then read the handoff's own "Blocking on return" section and present every
   `UNPUSHED COMMITS` line it carries, naming the shas. The probe cannot
   produce that line - it is written by the departure leg when a push was
   rejected - so a resume driven only off `webProjects[]` never mentions it.

   **The gate clears on exactly two things, and neither is a probe result:**
   - a successful deploy run performed in THIS session (you saw it exit
     cleanly), or
   - the user's explicit waiver in this session.

   If the user says they deployed from another machine last night, that is a
   waiver - take it and move on. Do not start new work until every gate is
   cleared one of those two ways. This is the whole reason the drift exception
   is safe.

   **Orphans clear separately, and they also clear on exactly two things:**
   - the paths were removed from the server in THIS session (you saw it), or
   - the orphan was explicitly rehomed to a named tracker in this session -
     a line in the operations doc (`docs.operations`), an entry in this
     repo's configured memory doc (`docs.projectMemory` - a single repo-root
     file under `scope: "root"`, or the relevant project's own file under
     `scope: "project"`), or a ticket, whichever of those this repo
     configures - carrying the exact server paths.

   A deploy run does NOT clear an orphan and neither does a waiver of the
   deploy gate; the deploy script never touches them. Treat each
   `ORPHANED SERVER PATHS` line the way a deferred action is treated: it is
   done, or it has a new home. "Probably harmless" is not a third option - a
   deleted page left live on the server is still serving.

   **Stranded commits clear separately as well, on exactly two things:**
   - the commits were pushed in THIS session (you watched `git push` succeed,
     and the branch is no longer ahead), or
   - the situation was explicitly rehomed to a named tracker in this session -
     a line in the operations doc (`docs.operations`), an entry in this
     repo's configured memory doc (`docs.projectMemory` - a single repo-root
     file under `scope: "root"`, or the relevant project's own file under
     `scope: "project"`), or a ticket, whichever of those this repo
     configures - naming the exact shas and the machine they are stranded
     on.

   An `UNPUSHED COMMITS` line is cleared by neither a deploy, nor a deploy
   waiver, nor a resolved decision. Nor by the re-probe looking healthy:
   `repo.ahead` is measured against the LAST FETCH, so a small number there is
   not proof the commits reached origin. Until one of the two terminators above
   holds, N commits exist on exactly one machine, on no backup, and nowhere any
   other machine can see - which is the whole failure the banner was raised to
   report.

3. **Walk decisions one at a time**, in handoff order. For each: the question,
   the default taken, and what reversing costs. Wait for the user's call. Do not
   batch them into one wall of text - each is a decision they are making now.

4. **Apply reversals immediately** as they are called, committing each.

5. **Reconcile the file** as you go: mark decisions resolved with the outcome.

6. **Clear the handoff** once ALL FOUR hold - the deploy gate is clear, every
   decision is resolved, every `ORPHANED SERVER PATHS` line has been
   terminated the way step 2 requires (removed from the server in this
   session, or rehomed to a named tracker), and every `UNPUSHED COMMITS` line
   has been terminated the way step 2 requires (the commits pushed in this
   session, or rehomed to a named tracker naming the shas). Then replace
   `VESPER_HANDOFF.md` with the cleared block given verbatim at the end of
   `handoff-template.md`, and commit and push. History lives in
   `git log -p VESPER_HANDOFF.md`.

   An unterminated orphan blocks clearing exactly as an unresolved decision
   does. Clearing the file over one leaves the only record of a live-but-
   deleted server path in `git log -p`, where nobody looks.

   An unterminated `UNPUSHED COMMITS` line blocks clearing for the same reason
   and harder. Clearing over one silences the SessionStart hook about commits
   that exist on a single machine and have never reached origin: they are
   absent from every other machine, absent from every backup, and the only
   trace left is a superseded revision of this file. Never clear the handoff to
   tidy it up while a push is still owed.

   Copy that block exactly. The `SessionStart` hook decides a handoff is
   resolved by matching `status:\s*resolved` **on the title line only**
   (`(?m)^#.*status:\s*resolved`); any decoration around it (bold, different
   casing, a different word) leaves the hook nagging about a handoff that no
   longer exists, in every session, forever. The anchor is deliberate: the
   guard used to match anywhere in the raw file, so a decision annotated at
   step 5 with an outcome containing the words "status: resolved" muted the
   hook completely over a handoff that was still fully pending.

   A handoff still claiming "2 decisions pending" after they are resolved is
   exactly the stale-claim rot the memory-hygiene sweep exists to hunt. Do not
   leave one behind.

7. **Fold durable outcomes** into this repo's configured memory doc
   (`docs.projectMemory`, if configured - the single repo-root file under
   `scope: "root"`, or the relevant project's own file under
   `scope: "project"`) and into auto-memory, per the standing conventions.
   Deferred actions that are still deferred move into whichever tracker owns
   them - they must not survive only inside a cleared handoff.

## Follow-ups

Unstarted follow-up items are offered, not started. Items done in extended
mode are tagged UNREVIEWED: present each with its sha so the user can review or
`git revert` it individually.

## When there is no handoff

If a return cue fires and no `VESPER_HANDOFF.md` exists, or it is already
`resolved`, say so in one line and carry on with the normal session. Do not
manufacture a resume.
