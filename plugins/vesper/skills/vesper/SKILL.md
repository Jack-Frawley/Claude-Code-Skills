---
name: vesper
description: Use when the user hands off work while leaving for the day - a departure cue ("heading home", "leaving for the day", "logging off", "before I go") combined in the same message with a continue-working instruction ("do as much as you can", "keep going", "finish X while I'm gone"). Also use on return ("I'm back", "morning", "picking this up") when an unresolved VESPER_HANDOFF.md exists. A departure cue alone must NOT fire this skill - there is nothing being handed off. Invoked explicitly as /vesper, /vesper full, /vesper resume, or /vesper setup.
---

# Vesper

Governs unattended end-of-day work: maximize what gets done, never block on a
question, defer only what genuinely must wait, and leave one clean resume point.

## Routing

Decide which leg is running, then read ONLY that leg's reference file.

| Signal | Leg | Read |
|---|---|---|
| `/vesper` or auto-fire on departure + continue cues | Departure, standard mode | `references/departure-protocol.md` |
| `/vesper full`, or "use the rest of the session" | Departure, extended mode | `references/departure-protocol.md` |
| `/vesper resume`, or a return cue with an unresolved `VESPER_HANDOFF.md` | Resume | `references/resume-protocol.md` |
| `/vesper setup` | Setup (attended) | `scripts/Invoke-VesperSetup.ps1` |

The table above resolves WHICH LEG runs once the skill has legitimately fired.
If the leg is still unclear at that point, check for `VESPER_HANDOFF.md` at the
repo root: an unresolved handoff means resume; no handoff means departure.

That fallback settles the leg only. It never settles whether to fire at all -
see the trigger contract below, which governs.

## Trigger contract

Auto-fire on departure requires BOTH signals in the same message:

1. A departure cue: heading home, leaving for the day, logging off, before I
   go, I'm out, heading out, done for the day.
2. A continue-working instruction: keep going, do as much as you can, finish X,
   work on Y while I'm gone, save the questions for the end.

A departure cue alone does NOT fire this skill. Neither does a question about
leaving ("I'm leaving soon, what's left?").

**When in doubt, do not fire.** This is the governing rule and it outranks the
routing fallback above. Doubt about whether a handoff was made is never
resolved by starting a departure run - a multi-hour autonomous session off a
plain goodbye is a far worse failure than a missed trigger. Say goodbye and
stop; the user can always type `/vesper`.

## Precondition: edits must not prompt

Both legs assume the session runs with **edits non-prompting** - `acceptEdits`
or bypass permissions. The user has confirmed they run that way. This is a
stated precondition, not a preference: every step writes files, starting with
`VESPER_HANDOFF.md` itself, so under a default `ask` permission mode the run
raises a prompt with nobody there before any record of the evening exists. The
protocol is void without it. The departure announce names the assumption out
loud so a morning reader can falsify it.

## Execution model

The departure leg is ONE continuous working session, not a setup step. Once
engaged, do not end the turn to report progress - keep working until the
ledger is exhausted or the work is genuinely blocked. There is no scheduler
behind this skill: if the turn ends, the evening ends.

## The autonomy boundary

Permitted unattended: editing files, running tests, committing, pushing to
origin, read-only prod probes.

Forbidden unattended: deploying to any server, prod writes (Graph, DB, AD,
scheduled tasks), sending email, and any outward-facing or irreversible
action. Hitting one of these does not stop the work - it becomes a deferred
action in the handoff, carrying the exact command to run.

**The word "unattended" is the whole scope of the rule, so the boundary binds
the departure leg only.** On the resume leg the user is present and asking, and
it relaxes: deploying there is correct, and a deploy run in that session is one
of only two things that can clear the handoff's deploy gate. Deferring it
instead would defer the one action the gate needs. See
`references/resume-protocol.md`.

## Reaching a human at both ends

A handoff that only exists as a file reaches nobody. Both ends of the cycle
put it in the chat:

- **Departure** ends with the closing report - see the section of that name in
  `references/departure-protocol.md`.
- **Return** is carried by the `SessionStart` hook in the repo's
  `.claude/settings.json`, NOT by this skill. That is deliberate and it is the
  only thing that works: this skill loads only when it fires, so a session that
  opens on unrelated work never sees a word of it. The hook runs every session
  regardless of topic, so it is the one channel that can reach a morning where
  Vesper is not the subject. It emits the open handoff's counts and banner
  lines as an instruction to surface them in the first reply.

Anyone editing that hook is editing this skill's return path. Keep it
emitting an instruction rather than a bare fact: the fact alone was already
absorbed silently once (2026-08-10) while a deploy gate sat open for three
days.

## State probe

Both legs run:

    pwsh "<skill dir>/scripts/Get-VesperState.ps1" -RepoRoot "<repo root>" -ConfigPath "<repo root>/.vesper/config.json" [-Baseline <sha>]

`<skill dir>` is wherever Vesper is installed - resolve it, never write a
repo-relative path here, because the path that is right for one installation is
wrong for every other one. This is the FIRST command of both legs, so getting
it wrong fails before any record of the evening exists - do not skip straight
to a guess. Resolve it in this order:

1. The directory containing the SKILL.md you are reading right now - whatever
   surfaced this skill made that path visible, and it is authoritative when
   available.
2. `install.skillDir` in `<repo root>/.vesper/config.json`, if the config
   exists - `/vesper setup` records the directory it ran from there for
   exactly this purpose. It is stored as a PORTABLE LABEL, not a raw path,
   because the probe echoes the whole config and handoff files get committed:
   a value starting `~/` resolves against the home directory, anything else
   relative resolves against the repo root, and only a path that is under
   neither is stored absolute.
3. The conventional install location, `~/.claude/skills/vesper`, if neither of
   the above is available.

**`-ConfigPath` is not optional in practice.** It is what points the probe at
THIS repo's config; without it the probe still runs and still exits 0, but every
config-driven answer - which directories are projects, where a deploy script
lives, whether there is a graph at all - silently falls back to built-in
defaults. Check the probe's `config` key: null there means no config took
effect, and any deploy or maintenance claim built on that run is describing a
different repo than the one you are in.

It is read-only and always exits 0. Trust its facts over recollection; report
anything in its `errors[]` array honestly in the handoff.
