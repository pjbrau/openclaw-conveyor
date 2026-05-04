#!/usr/bin/env bash
# coverage-gaps.sh — report per-package test coverage, sorted ascending.
# Output: JSON array [{"package":"cmd/proxy","coverage":45.4,"full_package":"github.com/..."}, ...]
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# Detect module name from go.mod (works for any Go repo)
MODULE=$(awk '/^module /{print $2; exit}' go.mod)

cover_out="$(mktemp)"
go test -cover ./... >"$cover_out" 2>/dev/null || true

python3 - "$cover_out" "$MODULE" <<'PY'
import sys, json, re

cover_file, module = sys.argv[1], sys.argv[2]
packages = []

with open(cover_file) as f:
    for line in f:
        line = line.strip()
        # "ok  github.com/.../pkg  (cached)  coverage: 45.4% of statements"
        m = re.match(r'ok\s+(\S+)\s+\S+\s+coverage:\s+([\d.]+)%', line)
        if m:
            full = m.group(1)
            cov  = float(m.group(2))
            pkg  = full[len(module) + 1:] if full.startswith(module + '/') else full
            packages.append({"package": pkg, "coverage": cov, "full_package": full})
            continue
        # "?   github.com/.../pkg  [no test files]"
        m2 = re.match(r'\?\s+(\S+)\s+\[no test files\]', line)
        if m2:
            full = m2.group(1)
            pkg  = full[len(module) + 1:] if full.startswith(module + '/') else full
            packages.append({"package": pkg, "coverage": 0.0, "full_package": full})

packages.sort(key=lambda p: p['coverage'])
print(json.dumps(packages, indent=2))
PY

rm -f "$cover_out"
