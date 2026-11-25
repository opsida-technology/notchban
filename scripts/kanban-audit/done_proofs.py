#!/usr/bin/env python3
"""Purpose: machine-check the Proof of every Done card on every KANBAN.md under ~/development.
For each Done card: do the commit hashes it cites exist and reach the trunk HEAD, do the file paths it cites exist,
and (fallback for rebased history) is there a trunk commit whose message names the card id.
Statuses: ok | ok-by-card-id (cited hash is gone but a trunk commit names the card: heuristic) | problem | no-proof.
Read-only. Writes out/done_proofs.json next to this file (out/ is git-ignored). Triage the `problem` cards by hand."""
import re, subprocess, json, os, collections
from pathlib import Path
DEV = Path.home() / "development"
OUT = Path(__file__).parent / "out"; OUT.mkdir(exist_ok=True)
HASH = re.compile(r'(?<![0-9A-Za-z_/.-])([0-9a-f]{7,40})(?![0-9A-Za-z_-])')
PATH = re.compile(r'(?<![\w/.-])((?:[\w@.\[\]()+-]+/)+[\w@.\[\]()+-]+\.(?:tsx?|jsx?|mjs|py|rs|swift|sql|css|html|sh|toml|ya?ml|json|md|kt|go|plist|strings))(?![\w-])')
def git(repo, *a): return subprocess.run(["git", "-C", str(repo), *a], capture_output=True, text=True)
def clean(p):  # "(src/x.ts" / "src/x.ts)" : drop an unbalanced paren the prose put around the path
    while p.startswith("(") and p.count("(") > p.count(")"): p = p[1:]
    while p.endswith(")") and p.count(")") > p.count("("): p = p[:-1]
    return p
out = {}
for kb in sorted(DEV.glob("**/KANBAN.md")):
    repo = kb.parent
    if any(s in kb.parts for s in ("node_modules", ".claude", ".squawk")) or not (repo / ".git").is_dir(): continue
    name = str(repo.relative_to(DEV)); files = set(git(repo, "ls-files").stdout.split("\n"))
    cards, cur, in_done = [], None, False
    for ln in kb.read_text(encoding="utf-8").split("\n"):
        if ln.startswith("## "): in_done = ln.strip() == "## Done"; cur = None; continue
        if not in_done: continue
        if ln.startswith("### "): cur = {"head": ln[4:].strip(), "body": []}; cards.append(cur)
        elif cur is not None: cur["body"].append(ln)
    res, stats = [], collections.Counter()
    for c in cards:
        body = "\n".join(c["body"]); cid = c["head"].split(" ")[0]
        hs = [h for h in set(HASH.findall(body)) if re.search(r'[a-f]', h) and re.search(r'\d', h)]
        ps = {clean(p) for p in PATH.findall(body)}
        hv, pv = [], []
        for h in hs:
            if git(repo, "cat-file", "-e", h + "^{commit}").returncode != 0: hv.append((h, "missing")); continue
            hv.append((h, "in-trunk" if git(repo, "merge-base", "--is-ancestor", h, "HEAD").returncode == 0 else "not-in-trunk"))
        for p in ps:
            if p in files or any(f.endswith("/" + p) for f in files): pv.append((p, "exists"))
            elif git(repo, "log", "--all", "--oneline", "-1", "--", p).stdout.strip(): pv.append((p, "gone-in-history"))
            else: pv.append((p, "never"))
        bad = any(s in ("missing", "not-in-trunk") for _, s in hv) or any(s != "exists" for _, s in pv)
        if not hs and not ps: status = "no-proof"
        elif not bad: status = "ok"
        else:
            rx = "(^|[^A-Za-z0-9-])" + re.escape(cid) + "($|[^0-9A-Za-z])"
            status = "ok-by-card-id" if git(repo, "log", "HEAD", "-E", "--grep=" + rx, "--oneline", "-1").stdout.strip() else "problem"
        stats[status] += 1; res.append({"id": cid, "title": c["head"], "status": status, "hashes": hv, "paths": pv})
    out[name] = {"stats": dict(stats), "cards": res}
(OUT / "done_proofs.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
for r, v in out.items(): print(f"{r:28} total={sum(v['stats'].values()):5} {v['stats']}")
