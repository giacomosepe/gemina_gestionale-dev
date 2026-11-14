#!/usr/bin/env bash
# Runs every file in supabase/tests/ against one database and fails if any test reports failures.
# Usage: PGURL=postgresql://user@host:5432/postgres PGPASSWORD=... supabase/scripts/run_tests.sh [pattern]
# Each test is a DO block that rolls back and ends in a "TEST REPORT" exception; two report formats exist:
#   "... FAILURES: N"   and   "... N failure(s)".
set -u
: "${PGURL:?set PGURL}"
dir="$(cd "$(dirname "$0")/../tests" && pwd)"
pattern="${1:-0*.sql}"
failed=0; total=0
for f in "$dir"/$pattern; do
  total=$((total + 1))
  out="$(psql "$PGURL" -v ON_ERROR_STOP=0 -X -q -f "$f" 2>&1)"
  if grep -q "TEST REPORT" <<<"$out"; then
    n="$(grep -oE 'FAILURES: [0-9]+' <<<"$out" | tail -1 | grep -oE '[0-9]+')"
    [ -z "$n" ] && n="$(grep -oE '[0-9]+ failure\(s\)' <<<"$out" | head -1 | grep -oE '^[0-9]+')"
  else
    n=""
  fi
  if [ "${n:-x}" = "0" ]; then
    echo "PASS  $(basename "$f")"
  else
    failed=$((failed + 1))
    echo "FAIL  $(basename "$f")  (failures: ${n:-no report})"
    echo "$out" | grep -E "FAIL|ERROR" | head -15 | sed 's/^/      /'
  fi
done
echo "$((total - failed)) of $total test files passed"
[ "$failed" -eq 0 ]
