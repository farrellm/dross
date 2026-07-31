# CLAUDE.md — proactive

Scheduled jobs. See the repo-root `CLAUDE.md` for the project overview.

- `proactive/` — stage-4 scheduled jobs: `run-job.sh` +
  `prompts/{digest,gardening,synthesis}.md`. Prompts are the job
  definitions; synthesis stages proposal branches via a temp git worktree
  (the live checkout never switches branches).

`proactive/README.md` is the fuller writeup: what each job does, the cron
wiring, and the Approve/Reject proposal flow.
