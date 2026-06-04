#!/usr/bin/env bash
set -euo pipefail

FILE="${1:-alert-rules.yml}"

if [[ ! -f "$FILE" ]]; then
  echo "ERROR: file not found: $FILE"
  exit 1
fi

# Detect lines like:
#   - name:
#   name:
#   - name: ""
#   name: ''
awk '
  /^[[:space:]]*-?[[:space:]]*name:[[:space:]]*$/ {
    print "ERROR: empty rule group name at line " NR ": " $0
    found=1
  }

  /^[[:space:]]*-?[[:space:]]*name:[[:space:]]*["'\'']["'\''][[:space:]]*$/ {
    print "ERROR: empty quoted rule group name at line " NR ": " $0
    found=1
  }

  END {
    if (found) exit 1
  }
' "$FILE"

echo "OK: no empty group names found"
