# Maintenance rules

Idle work Vesper may do unattended, once the ledger is exhausted. **This file
holds the RULES. The ITEMS live in the repo's own queue file**, named by
`maintenance.queue` in `.vesper/config.json`. Read that file for what to do;
read this one for how.

## Ordering and priority

**Maintenance is step 6.** It runs only once the handed-off work is exhausted.
It **never displaces ledger work** - if the evening's assigned work consumes the
run, or the context window closes first, the queue is never reached and nothing
here happens. That is a correct outcome.

**Say which one happened in the handoff.** "The clock beat it" and "a rule
forbade it" are indistinguishable in the morning otherwise, and telling them
apart is the difference between a run that was working and a run that was stuck.

**Order the item most likely to halt the turn LAST within the queue.** Anything
that shells out to an external tool, or whose command form cannot be
allowlisted, belongs at the end - so that a halt costs one item rather than an
evening. Ordering is the mitigation; skipping is not.

**Work the user explicitly handed off is LEDGER work, not maintenance**, even
when the same action appears as an item here. No rule in this file governs it,
including any budget rule. They asked; their asking is the approval. Reaching
into the maintenance queue for a reason to decline assigned work is a real
failure mode, not a hypothetical one.

## Permission discipline

A permission prompt during an unattended run halts the evening with nobody there
to answer, mid-item and unrecorded. So before running any command:

**Check its exact form against `permissions.allow[]` in the probe's output.** The
probe reads and merges all three live settings files - user-level
`~/.claude/settings.json`, the repo's `.claude/settings.json`, and the
git-ignored `.claude/settings.local.json` beside it - and reports what is
actually allowlisted, naming the files it read in `permissions.source[]`. Reason
against that, never against a remembered answer - an allowlist changes, and a
conclusion written down here would be stale the next time it did.

Where an item's command form is not covered, the item is **not** pre-approved.
Record a follow-up naming the exact command a human would run. Do not improvise
a near-miss variant, and do not add an allowlist rule - granting permission is
the user's decision, never Vesper's.

**An item that produces only follow-ups has not failed.** If the allowlist
covers nothing an item needs - including the case where `permissions.status` is
`absent` and nothing at all is allowlisted - that item correctly produces
follow-ups and no other work. That is the designed outcome, not a gap to route
around. Do not substitute a different tool, widen the command form, or find
some other way to make the item "work": the follow-up IS the item's output when
its commands are uncovered, and a run that records one has done its job.

**The probe's `permissions.status` is one of three states, and each means
something different:**

- **`ok`** - at least one settings file was read successfully.
  `permissions.allow[]` is real as far as `permissions.source[]` goes; reason
  against it as described above. If a file that exists is missing from
  `source[]`, read that file yourself before concluding anything.
- **`absent`** - none of the three settings files exists, so nothing is
  allowlisted. Every command form is uncovered, by fact rather than by failure.
  This is the ONLY status under which an empty `allow[]` means what it looks
  like.
- **`unknown`** - a settings file that exists could not be read or parsed. The
  merged allowlist is short by an unknown amount. Treat every command form as
  potentially prompting - the same caution as `absent` in practice, but for the
  opposite reason: this is a failure to determine, not a determination of empty.
  Do not read `unknown` as `ok` with a short list, and do not treat it as
  license to guess.

## Scope

An item may only do what its own entry states. Anything not in the queue file at
all is not pre-approved.

Where an item's stated condition does not hold, record it as a follow-up rather
than asking - there is nobody to ask.

## Reporting

For any item that runs, record real counts and real outcomes. A red test suite
is a finding for the handoff, not something to quietly fix - unless the fix is
obvious and small, in which case fix it, commit it separately, and say so.
