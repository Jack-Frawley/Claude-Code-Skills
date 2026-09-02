# Handoff template

Write this to `VESPER_HANDOFF.md` at the repo root. ASCII only. Section order
is fixed - decisions come before work, so the returning reader sees what needs
deciding first. Omit a section only when it is genuinely empty, except
"Blocking on return" and "Run log", which always appear.

Replace every `<n>` with a real count. Follow-ups are capped at ten: generate
at most ten items, derived from what was actually built. **Zero is a legitimate
count.** An evening that genuinely leaves no next step writes the Follow-ups
header with a count of 0 and nothing under it; never invent a follow-up to
avoid an empty section, because an invented one is indistinguishable from a
real one in the morning.

---

# Vesper Handoff - YYYY-MM-DD  .  status: in-progress | complete | resolved
baseline: <sha> . mode: standard | extended

## Blocking on return
DEPLOY PENDING - <Project Name>, <n> commits since baseline
  -> pwsh "<Project Name>/<deploy.script>" -Ref <baseline sha>
ORPHANED SERVER PATHS - <Project Name>: <path>, <path>
  -> deleted/renamed in the repo; the deploy script cannot remove them. Needs
     manual cleanup on the server.
UNPUSHED COMMITS - push rejected (branch diverged from origin), <n> commits
  stranded on this machine: <sha>, <sha>

(If nothing blocks: the single line "Nothing blocking.")

## Decisions needed (<n>)
### D1 - <the question, one line>
Default taken: <what I did>
Why: <the reasoning, one or two lines>
To reverse: <exact file:line or command, and what it costs>

## Deferred actions (<n>)
### A1 - <the action>
Why deferred: <policy boundary, or needs the user present>
Command: <exact, runnable>

## Work completed
- <sha> - <what shipped> - verified: <how, or "not verified: why">

## Not verifiable
- <what could not be checked, and what it would take>
- Pre-existing uncommitted at start (left untouched): <path>, <path>

## Follow-ups (<n>)
- F1 - <next logical step from the work just done> (unstarted | done UNREVIEWED @ <sha>)

## Run log
started <HH:MM> . ended <HH:MM> . mode <standard|extended> . stop reason: <ledger exhausted | all work blocked | window closing | permission prompt - halted at <item>>

---

## Rules

- Every decision entry carries all four fields. "To reverse" is the one that
  makes morning review fast - the user is pricing a reversal, not re-deciding.
- The `DEPLOY PENDING` arrow line is copied VERBATIM from the probe's
  `webProjects[].command`. Never hand-write it, edit it, or "complete" it - the
  emitted command carries the `-Ref <baseline>` pin, and a hand-written one
  silently falls back to the deploy script's own default of `HEAD~1`, which
  under-deploys after a multi-commit evening. The placeholder in the block
  above shows the SHAPE; the probe supplies the value.
- Never claim verification that did not happen. "verified: not verified -
  needs the site reachable" is a good entry.
- Extended-mode follow-up work is tagged UNREVIEWED and lands in its own
  commit, so it can be reverted individually.
- The "Pre-existing uncommitted" line lists what was already dirty when Vesper
  started. Those paths are the user's; they are recorded and left alone, never
  committed by Vesper.

## The cleared file

When the resume leg has closed every decision and the gate is clear, replace
the ENTIRE file with this block, verbatim, changing only the date:

```
# Vesper Handoff - none active  .  status: resolved

No active handoff. The last one was resolved on YYYY-MM-DD.
History: git log -p VESPER_HANDOFF.md
```

Do not decorate it. The `SessionStart` hook in `.claude/settings.json` decides
a handoff is resolved by matching `status:\s*resolved` **on the title line
only** (`(?m)^#.*status:\s*resolved`); writing `**status:** resolved`,
`Status: Resolved`, or "closed" instead leaves the hook announcing a pending
handoff in every future session, forever.

The anchor matters in the other direction too, and is why the guard is not a
whole-file match: a resolved decision whose outcome happens to read
`status: resolved` must NOT mute the hook while the handoff is still pending.
Never put the words `status: resolved` in the title line of a handoff that is
not resolved.
