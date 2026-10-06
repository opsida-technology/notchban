---
name: kanban
description: Maintain the repository's root KANBAN.md as the single source of truth for work tracking between humans and agents. Use when starting, claiming, updating, blocking, reviewing, verifying or completing repository work, when planning what to do next, or when the user asks for a board, backlog, status or task tracking. Never keep a second task list, roadmap or status file when KANBAN.md exists.
---

# Repository Kanban

`<repo>/KANBAN.md` is the only work board. Do not mirror a card's title, status, checklist, owner or
blocker in another planning file (no STATUS.md, TODO.md, roadmap or next-steps section: point to the card id).

## Open or initialize

1. Look for the exact root path `KANBAN.md` and read it before planning repository work.
2. If it is missing, do not create it just because you scanned. Ask the user once ("no KANBAN.md here, create
   it?"); on yes, create it from the template below. Scanning alone never modifies a repo.
3. The status order is fixed: `Backlog`, `Ready`, `In Progress`, `Human Review`, `Verified`, `Blocked`, `Done`.

```markdown
# Kanban
<!-- squawk-kanban:v1 -->

## Backlog

## Ready

## In Progress

## Human Review

## Verified

## Blocked

## Done
```

## Cards

```markdown
### KB-12 — Short imperative title
<!-- squawk:{"owner":"agent:task-x","task":"task-x","lease":{"acquiredAt":"2026-10-06T08:00:00Z","expiresAt":"2026-10-06T10:00:00Z","holder":"agent:task-x"},"after":["KB-09"],"before":["KB-15"]} -->

- [ ] Acceptance item one
- [ ] Acceptance item two

Why it matters, the known limit.
Proof: test name, log id or PR link
```

- The id is stable: never reuse or renumber. Prefix per repo (`KB-`, `API-`, …); take the repo's own.
- The containing `##` section is the status; never duplicate it in metadata.
- Metadata is one valid JSON line. No token, credential, transcript or large output in the board.
- Optional metadata a repo may add (keep what it uses): `after` (predecessor ids that must be Done first),
  `before` (successor ids), `track`, `phase`, `size`, `risk`, `gate`, `proofs`. Keep `after` and `before` mirrored:
  if A is after B, B lists A in `before`. No cycles.
- Non-checklist, non-metadata lines are notes: short and factual; wrapped lines join, a blank line starts a paragraph.
- A claim carries a two-hour ISO-8601 lease; renew it in long work. An active lease owned by another task is a hard
  conflict: do not move or overwrite that card. An expired lease means the card is free to claim.

## Work protocol

- Pick from `Ready`, and only a card whose `after` ids are all `Done`. Claim it: move it to `In Progress`, set
  `owner`, `task` and a lease, before any work.
- Keep the checklist current as you go. Scope discovered mid-task goes on the same card only when its acceptance
  needs it; otherwise create a new card (next free id) with its own `after`/`before`.
- External dependency or a decision only a human can make: move to `Blocked`, write the concrete blocker and the
  human action expected, and release the lease.
- Claim before you start work, and make the claim visible at once (commit it where others read the board). A board
  that is updated only when a PR merges is not live.
- When the work is finished and its Proof is on the card, move it to `Done` yourself. A
  card that still needs the human's hands or a decision goes to `Human Review` and the human moves it.
- Before every write, re-read `KANBAN.md`; if it changed since you read the card, merge deliberately and never
  overwrite another person's or agent's update.
- A new task found while working goes onto the board the moment you see it, not into your head or a side file.

## Large boards

Do not load the whole file. Find the card and its neighbours with `grep -n '^### ID'` and read a range; for
dependencies read only the cards named in its `after` and `before`. The Mac app `notchban` shows every board
under the projects folder you give it, read-only, with predecessors and successors.
