#!/usr/bin/env python3
"""Re-apply Millie's rebrand string edits from a .rej file as literal
old->new line replacements against the current (drifted) tree.

Faithful: only changes lines Millie actually changed (each rejected hunk's
paired `-old`/`+new`). Robust to upstream line drift because it matches on
content, not line numbers. Skips pairs whose only delta is domain
substitution (already applied to the tree). Reports any `old` not found so
it can be hand-checked (upstream reworded that string).
"""
import re
import sys
from pathlib import Path

SRC = Path("/Users/dannybaute/mori-browser-build/build/src")

# strip ungoogled domain-substitution artifacts so a pair that differs ONLY
# by the .qjz9zk suffix (already in the tree) is treated as a no-op.
def norm_domain(s: str) -> str:
    return s.replace(".qjz9zk", "")

def parse_pairs(rej_path: Path):
    """Yield (old, new) for each -line immediately followed by a +line."""
    lines = rej_path.read_text().splitlines()
    i = 0
    pairs = []
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("-") and not ln.startswith("---"):
            # collect the run of - lines then the run of + lines
            minus = []
            while i < len(lines) and lines[i].startswith("-") and not lines[i].startswith("---"):
                minus.append(lines[i][1:])
                i += 1
            plus = []
            while i < len(lines) and lines[i].startswith("+") and not lines[i].startswith("+++"):
                plus.append(lines[i][1:])
                i += 1
            # only handle clean 1:1 line rewrites (the rebrand shape)
            if len(minus) == len(plus):
                for o, n in zip(minus, plus):
                    pairs.append((o, n))
            else:
                # unequal block — report for manual review
                for o in minus:
                    pairs.append((o, None))
        else:
            i += 1
    return pairs

def main():
    total_applied = total_skip = total_missing = 0
    for rej_arg in sys.argv[1:]:
        target = SRC / rej_arg
        rej = SRC / (rej_arg + ".rej")
        text = target.read_text()
        applied = skipped = missing = 0
        missing_lines = []
        for old, new in parse_pairs(rej):
            if new is None:
                missing += 1; missing_lines.append(old.strip()[:80]); continue
            if norm_domain(old) == norm_domain(new):
                skipped += 1; continue          # domain-only, already applied
            if old in text:
                text = text.replace(old, new, 1)
                applied += 1
            elif new in text:
                skipped += 1                     # already rebranded
            else:
                # domain-offset fallback: the tree line matches `old` except
                # for .qjz9zk domain suffixes already applied. Find that exact
                # tree line by domain-normalized equality and rebrand only it.
                def canon(s):  # domain- and whitespace-insensitive
                    return " ".join(norm_domain(s).split())
                lines = text.split("\n")
                hit = False
                target_canon = canon(old)
                for idx, L in enumerate(lines):
                    if "Chromium" not in L and "Google Chrome" not in L:
                        continue
                    if canon(L) == target_canon:
                        newL = L.replace("Google Chrome", "Millie").replace("Chromium", "Millie")
                        if newL != L:
                            lines[idx] = newL
                            text = "\n".join(lines)
                            applied += 1; hit = True
                        break
                if not hit:
                    missing += 1; missing_lines.append(old.strip()[:80])
        target.write_text(text)
        print(f"  {rej_arg}: applied={applied} skipped={skipped} missing={missing}")
        for m in missing_lines[:8]:
            print(f"      MISSING: {m}")
        total_applied += applied; total_skip += skipped; total_missing += missing
    print(f"TOTAL applied={total_applied} skipped={total_skip} missing={total_missing}")

if __name__ == "__main__":
    main()
