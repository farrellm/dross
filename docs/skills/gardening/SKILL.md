---
name: gardening
description: Garden the Zettelkasten — resurface old notes worth revisiting and flag near-duplicates, contradictions, and missing links among recent notes. Use this whenever I ask to tend, prune, tidy, or review the notes, find duplicates or conflicting notes, see what's gone stale or forgotten, or ask "what should I revisit?", even if I don't say "gardening". Manual counterpart of the scheduled gardening job.
---

# Gardening

Resurface old notes and flag problems, shown here in the session. It is the
interactive twin of the cron job in `proactive/prompts/gardening.md` (dross
repo) — same checks, but the report comes to me, so use markdown and cite
notes as org links.

The survey is read-only. Fixes come after the report, one at a time, and
every one of them touches an existing note — so each is a proposal I approve
before you make it.

## Steps

1. **Resurface** — `stale-notes` (limit 10). Pick the two or three most worth
   revisiting; skip the inbox and hub/structural notes, which are stale by
   nature. `read-note` each pick and give one sentence on why revisiting could
   pay off now: a fresh unlinked connection (`similar-notes`), an open
   question in the text, or plain age on a topic that keeps recurring.
2. **Near-duplicates and contradictions** — take the five most recently
   changed notes (`recent-notes`, days 30) and run `similar-notes` on each.
   For every pair scoring above 0.75 that isn't linked, `read-note` both and
   classify it:
   - **duplicate** — the same idea twice; a merge candidate
   - **contradiction** — the notes make incompatible claims; worth resolving
     or at least linking with the tension stated
   - **should-be-linked** — distinct ideas with a relationship you can name

   One line each on why. Report each pair once even if it turns up from both
   sides.

## Report

- **Revisit**: each pick as `[[id:<uuid>][<title>]]` plus its one sentence
- **Flags**: each pair, both notes linked, its class, and the reason

If the garden is clean, say so in one line and stop.

## Follow-ups

Offer to act on the flags, then do only what I approve:

- **should-be-linked / contradiction** — draft the link with its relationship
  phrase woven into the text (or under a `Related` heading) and show it
  before `update-note`/`append-note`.
- **duplicate** — propose which note survives and what text moves over. If
  the note being folded away has attachments (`ATTACH` filetag), its attach
  dir must move to the survivor's ID — see the inbox-processing section of
  CLAUDE.md for why and how. Merging deletes a permanent note, so get explicit
  approval for the whole plan first.
