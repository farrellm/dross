---
name: digest
description: Weekly digest of the Zettelkasten — what changed recently, how much is waiting in the inbox, and which new notes have unlinked connections worth making. Use this whenever I ask what I've been working on, what changed this week (or in the last N days), for a weekly review or catch-up, "where was I", or how backed up the inbox is, even if I don't say "digest". Manual counterpart of the scheduled digest job.
---

# Digest

A short look back over recent activity in the archive, shown here in the
session. It is the interactive twin of the cron job in
`proactive/prompts/digest.md` (dross repo) — same steps, but the reply goes
to me rather than to Telegram, so use markdown and cite notes as org links.

This skill is read-only: gather and report, don't edit anything. Offers to act
come at the end, and each still needs my go-ahead.

## Arguments

An optional number of days (default 7), e.g. `/digest 14`.

## Steps

1. **What changed** — `recent-notes` with `days` set to the window. Skip the
   inbox file itself here; it is covered in step 2.
2. **Inbox status** — `search` for "inbox" (or find `inbox.org`'s file-level
   note) and `read-note` it. Count the captures still waiting (each is a
   timestamped headline) and note the oldest one's date — age matters more
   than count, since an old capture is the one losing context.
3. **Worth linking** — pick the two or three most substantial recent notes
   (real content, not stubs or trivial edits) and run `similar-notes` on each.
   Ignore results already `linked: true`. Keep a candidate only if you can say
   in one clause how the two notes relate — similarity score alone isn't a
   reason (see Link suggestion in CLAUDE.md). `read-note` both sides when the
   titles don't make the relationship clear.

## Report

Keep it scannable — roughly a screenful:

- one line summarising the period's activity
- the changed notes, one bullet each as `[[id:<uuid>][<title>]]`
- inbox: how many captures are waiting and how old the oldest is
- up to three "worth linking" nudges, each naming both notes and the
  relationship

If nothing changed in the window, say so in one line and stop.

Then offer the natural next moves, e.g. adding one of the nudged links
(a proposal: it edits an existing note) or running `/inbox` if captures are
piling up.
