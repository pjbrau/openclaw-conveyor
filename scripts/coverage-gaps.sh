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

# Optional ignore/ceiling file: one entry per line, "package[:max_pct]".
#   - "package"        → never select this package (treat as done)
#   - "package:73"     → treat package as done once coverage >= 73%
# Blank lines and #-comments are ignored. Lets us retire packages whose
# remaining gap is structurally untestable (e.g. main(), huge-arg wiring,
# browser-launching helpers) so the oracle stops re-dispatching them forever.
IGNORE_FILE="${CONVEYOR_COVERAGE_IGNORE:-$REPO_ROOT/.conveyor-coverage-ignore}"

python3 - "$cover_out" "$MODULE" "$IGNORE_FILE" <<'PY'
import sys, json, re, os

cover_file, module = sys.argv[1], sys.argv[2]
ignore_file = sys.argv[3] if len(sys.argv) > 3 else ''

# Parse ignore/ceiling file → {package: max_pct}; max_pct None means always skip.
ceilings = {}
if ignore_file and os.path.exists(ignore_file):
    with open(ignore_file) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if ':' in line:
                pkg, _, pct = line.partition(':')
                pkg = pkg.strip()
                try:
                    ceilings[pkg] = float(pct.strip())
                except ValueError:
                    ceilings[pkg] = None
            else:
                ceilings[line] = None

def is_done(pkg, cov):
    if pkg not in ceilings:
        return False
    cap = ceilings[pkg]
    return cap is None or cov >= cap

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
            if is_done(pkg, cov):
                continue
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
