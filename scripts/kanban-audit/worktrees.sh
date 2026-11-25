#!/bin/zsh
# Purpose: for every git worktree of every KANBAN repo under ~/development, report whether its branch is merged
# into the trunk checkout (ahead = commits not in trunk, patch-not-in-trunk = ahead minus rebased/cherry-picked, dirty = uncommitted files).
# Read-only. Trunk = the repo's main checkout (a directory with .git/), whatever branch it is on.
for kb in $(find ~/development -maxdepth 4 -name KANBAN.md -not -path '*/node_modules/*' -not -path '*/.claude/*' -not -path '*/.squawk/*'); do
  r=${kb:h}; [ -d "$r/.git" ] || continue
  tb=$(git -C $r rev-parse --abbrev-ref HEAD)
  echo "## ${r#$HOME/development/} (trunk=$tb)"
  git -C $r worktree list --porcelain | awk '/^worktree /{p=$2} /^HEAD /{h=$2} /^branch /{b=$2} /^detached/{b="DETACHED"} /^$/{if(p)print p"|"h"|"b; p="";h="";b=""}' | while IFS='|' read p h b; do
    [ "$p" = "$r" ] && continue
    ahead=$(git -C $r rev-list --count $tb..$h 2>/dev/null)
    plus=$(git -C $r cherry $tb $h 2>/dev/null | grep -c '^+')
    dirty=$(git -C "$p" status --short 2>/dev/null | grep -v node_modules | wc -l | tr -d ' ')
    last=$(git -C $r log -1 --format=%ad --date=short $h 2>/dev/null)
    echo "${p#$HOME/development/} | ${b#refs/heads/} | ahead=$ahead patch-not-in-trunk=$plus dirty=$dirty last=$last"
  done
done
