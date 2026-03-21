#!/usr/bin/env bash
set -euo pipefail

# verify-pins.sh — Check all reusable workflow files for unpinned action tags.
# Actions should be SHA-pinned (e.g., @abc123def), not tag-pinned (e.g., @v4).

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WORKFLOWS_DIR="$SCRIPT_DIR/../.github/workflows"
ERRORS=0

for f in "$WORKFLOWS_DIR"/reusable-*.yml; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
        if echo "$line" | grep -qE 'uses:.*@v[0-9]'; then
            echo "UNPINNED: $(basename "$f"): ${line#"${line%%[![:space:]]*}"}"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(grep 'uses:' "$f" 2>/dev/null || true)
done

if [[ "$ERRORS" -gt 0 ]]; then
    echo "Found $ERRORS unpinned actions"
    exit 1
fi
echo "All actions SHA-pinned"
