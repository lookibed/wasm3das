#!/usr/bin/env python3
"""Assigns every .wast of the test-suite checkout to a feature group.

Usage: corpus_index.py <testsuite dir> <groups.json> <index.json out>

The groups are tried in order (docs/wasm-features/groups.json); the first
whose fnmatch patterns match the path (relative, without .wast) owns the
file. Writes {"files": [{"path", "group"}...], "counts": {group: n}}.
Exit 1 when a file is claimed by no group.
"""
import fnmatch
import json
import os
import sys


def main():
    root, groups_path, out_path = sys.argv[1:4]
    groups = json.load(open(groups_path))["groups"]
    files = []
    unclaimed = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for fn in sorted(filenames):
            if not fn.endswith(".wast"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, fn), root)[:-len(".wast")].replace(os.sep, "/")
            owner = None
            for g in groups:
                if any(fnmatch.fnmatchcase(rel, p) for p in g["patterns"]):
                    owner = g["name"]
                    break
            if owner is None:
                unclaimed.append(rel)
            else:
                files.append({"path": rel, "group": owner})
    counts = {}
    for f in files:
        counts[f["group"]] = counts.get(f["group"], 0) + 1
    json.dump({"files": files, "counts": counts}, open(out_path, "w"), indent=1)
    for rel in unclaimed:
        print(f"corpus: no group claims {rel}", file=sys.stderr)
    print("corpus: " + ", ".join(f"{g['name']} {counts.get(g['name'], 0)}" for g in groups))
    sys.exit(1 if unclaimed else 0)


if __name__ == "__main__":
    main()
