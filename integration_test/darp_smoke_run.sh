#!/usr/bin/env bash
# Runs the darp smoke test and keeps its RESULT lines for the job summary.
# Lives in a script because android-emulator-runner executes every line of its
# `script:` in a separate shell, which loses `$PIPESTATUS` and `set -o pipefail`.
#
# usage: integration_test/darp_smoke_run.sh <attempt>
set -uo pipefail

attempt="${1:-1}"
log="smoke-attempt-${attempt}.log"
results="smoke-results-${attempt}.txt"

flutter test integration_test/darp_smoke_test.dart \
  --flavor develop --dart-define=DARP_SMOKE=true --reporter expanded 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"

# The test prints `RESULT <key=value ...>`; the reporter may prefix the line.
grep -o 'RESULT .*' "$log" | sort -u > "$results" || true
exit "$status"
