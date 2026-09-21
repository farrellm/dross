---
name: synthesis
description: Find a cluster of related notes that has no hub (map-of-content) note, draft the hub, and create it once I approve. Use this whenever I ask to synthesise, map, or structure a topic, build a hub or MOC or index note, see what themes are emerging, or pull scattered notes on a subject together — including when I name the topic myself. Manual counterpart of the scheduled synthesis job.
---

# Synthesis

Draft a hub note for a cluster of notes that share a topic but have nothing
structuring them. It follows the cron job in `proactive/prompts/synthesis.md`
(dross repo), with one difference: the job stages a git proposal branch
because nobody is there to approve it, but here I am. So show me the draft
and create it through the MCP tools once I say yes. No worktree, no
`proposal/` branch.

## Arguments

An optional topic or seed note, e.g. `/synthesis spaced repetition`. With
one, cluster around it (`semantic-search` + `search` for the topic, or start
from the named note). Without one, survey.

## Steps

1. **Find a cluster** — for a survey, take seed notes from `recent-notes`
   (days 30) and `stale-notes`, then expand the promising ones with
   `similar-notes` and `neighborhood`. You want three to six notes that
   clearly share a topic: fewer isn't worth a hub, and many more probably
   means two topics.
2. **Check for an existing hub** — run `backlinks` on the cluster's notes. If
   they are already linked from a common structuring note, that note is the
   hub; tell me, and pick another cluster, or suggest adding the missing
   members to that hub instead (a proposal, since it edits an existing note).
3. **Nothing worth it?** Say so in a line and stop. A forced hub is worse
   than none.
4. **Draft** — `read-note` every member so each role clause reflects what the
   note actually says. Show me:
   - title: the topic as a claim or question, not a bare topic ("Retrieval
     practice beats rereading because…", not "Memory")
   - filetags: `hub`
   - body: two or three sentences framing the topic and what ties these notes
     together, then one bullet per member:

     ```
     - [[id:<note-id>][<note title>]] — <one clause on its role in the topic>
     ```

   Say briefly why you chose this cluster.
5. **Create on approval** — apply my edits, then `create-note` with the
   title, `tags: ["hub"]`, and the body. Don't pass an ID; the tool mints one.
6. **Link back** — offer to add a pointer to the new hub in each member note
   (under a `Related` heading, or woven into the text where it fits). That
   edits existing notes, so show the change and wait for approval.
