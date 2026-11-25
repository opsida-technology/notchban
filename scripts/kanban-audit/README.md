# kanban-audit

Read-only checks that found the stale cards and unmerged worktrees of 2026-11-24/25. Run from anywhere; both scan
every trunk checkout that has a `KANBAN.md` under `~/development`.

- `worktrees.sh` — per worktree: ahead of trunk, patches not in trunk (rebased commits do not count), uncommitted files.
  A worktree that is merged (`patch-not-in-trunk=0`) and clean can go with `git worktree remove`; one with dirty or
  untracked files goes to the Trash, never `--force`.
- `done_proofs.py` — per Done card: do the cited commits/files exist in trunk. `problem` is a lead, not a verdict
  (rebased history, paths relative to a sub-folder, hashes from another repo): triage by hand or with a cheap agent.
  Known blind spots: evidence kept outside git (data folders, other machines), and a local `main` behind its upstream
  (check `git rev-list --count HEAD..@{u}` first).

`ok-by-card-id` only proves a trunk commit NAMES the card; a docs-only "done" commit also counts (for example when the closing
commits are on main but the code lives on a release branch). Look at what the commit touched before trusting it.

Output goes to `out/` (git-ignored).
