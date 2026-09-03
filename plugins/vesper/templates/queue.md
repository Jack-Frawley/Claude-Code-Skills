# Maintenance queue

Items Vesper may work through once the ledger is exhausted. The rules governing
these items - ordering, priority, permission discipline - are in the skill's
`maintenance-rules.md`. This file is yours: edit it freely, it carries no
protocol logic.

Order matters. Put anything that might halt the turn last.

## 1. Test-suite green check

Run the project's test suites and record real counts, passed and failed.

**Only run suites whose exact command form is allowlisted** - check the probe's
`permissions.allow[]`. For any suite not covered, record a follow-up naming the
project and the exact command a human would run.

    <your test command here>

## 2. Documentation drift

Where a project's documentation disagrees with what the code now does, correct
the documentation. Never invent history: if a change is not in `git log`, do
not claim it happened.

## 3. Memory hygiene

For each file the probe reports in `memory[]`: open it, check whether the stale
marker is still true, and correct it. A memory saying "pending" for something
that shipped weeks ago is worse than no memory.

**Working-directory check (required).** `memoryPath` resolves outside the repo
and normally outside the session's working directories. A read against a path no
working directory covers will prompt, and a prompt ends the evening. Confirm
`memoryPath` is inside a working directory first; if it is not, record a
follow-up naming the files the probe flagged and move on.

---

<!-- Add your own items below. Anything environment-specific - a graph refresh,
     an archive sweep, an operations doc to re-verify - belongs here rather than
     in the skill, so it survives an upgrade. -->
