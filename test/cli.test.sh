#!/usr/bin/env bash
# End-to-end tests: run the real tool against the real machine for a few
# samples and check its output shapes, flags and exit codes. macOS only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE="$(dirname "$HERE")/bin/jitter-trace"

pass=0
fail=0

check() {
  name="$1"
  needle="$2"
  actual="$3"
  case "$actual" in
    *"$needle"*)
      printf "  ok    %s\n" "$name"
      pass=$((pass + 1))
      ;;
    *)
      printf "  FAIL  %s\n        expected to contain: %s\n        got: %s\n" "$name" "$needle" "$actual"
      fail=$((fail + 1))
      ;;
  esac
}

check_code() {
  name="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "  ok    %s\n" "$name"
    pass=$((pass + 1))
  else
    printf "  FAIL  %s (expected exit %s, got %s)\n" "$name" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

if [ "$(uname -s)" != "Darwin" ]; then
  echo "cli tests need macOS counters; skipping on $(uname -s)"
  check "refuses to run off macOS" "only runs on macOS" "$("$TRACE" --samples 1 2>&1)"
  "$TRACE" --samples 1 >/dev/null 2>&1
  check_code "and exits 3" 3 "$?"
  printf "\npassed: %s   failed: %s\n" "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi

echo "help and version"
check "help lists the columns" "DECOMP" "$("$TRACE" --help)"
check "version prints a number" "1." "$("$TRACE" --version)"
check "an unknown option is refused" "unknown option" "$("$TRACE" --nope 2>&1)"
"$TRACE" --nope >/dev/null 2>&1
check_code "and exits 1" 1 "$?"
check "a bad interval is refused" "expects a positive number" "$("$TRACE" --interval abc 2>&1)"

echo "table output"
table="$("$TRACE" --samples 2 --interval 1 --no-cpu 2>&1)"
check "prints a header" "TIME" "$table"
check "prints the decompression column" "DECOMP" "$table"
check "ends with a sample count" "2 samples" "$table"
case "$table" in
  *"Memory pressure"*|*"Disk faults"*|*Compositor*|*"No stalls seen"*)
    printf "  ok    ends with one of the four verdicts\n"
    pass=$((pass + 1))
    ;;
  *)
    printf "  FAIL  no verdict in the summary\n        got: %s\n" "$table"
    fail=$((fail + 1))
    ;;
esac

echo "csv output"
csv="$("$TRACE" --samples 2 --interval 1 --no-cpu --csv 2>/dev/null)"
check "has a csv header" "time,decomp_pages" "$csv"
check "rows carry the rate columns" "," "$(printf "%s\n" "$csv" | tail -1)"
columns="$(printf "%s\n" "$csv" | tail -1 | awk -F, '{print NF}')"
check_code "ten columns per row" 10 "$columns"
rows="$(printf "%s\n" "$csv" | grep -vc "^time,")"
check_code "two data rows" 2 "$rows"

echo "json output"
json="$("$TRACE" --samples 2 --interval 1 --no-cpu --json 2>/dev/null)"
check "emits sample objects" '"type":"sample"' "$json"
check "emits a summary object" '"type":"summary"' "$json"
if command -v python3 >/dev/null 2>&1; then
  parsed="$(printf "%s\n" "$json" | python3 -c '
import json, sys
kinds = [json.loads(line)["type"] for line in sys.stdin if line.strip()]
print(",".join(kinds))
' 2>&1)"
  check "every line is valid json" "sample,sample,summary" "$parsed"
fi

echo "stopping"
start="$(date +%s)"
"$TRACE" --duration 3 --interval 1 --no-cpu >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 8 ]; then
  printf "  ok    --duration stops on its own (%ss)\n" "$elapsed"
  pass=$((pass + 1))
else
  printf "  FAIL  --duration took %ss\n" "$elapsed"
  fail=$((fail + 1))
fi

# The clock has to start at the first reading, not a whole iteration earlier:
# with iostat in the loop that difference costs a third of the requested run.
duration_rows="$("$TRACE" --duration 3 --interval 1 --csv 2>/dev/null | grep -vc "^time,")"
if [ "$duration_rows" -ge 3 ]; then
  printf "  ok    --duration 3 --interval 1 samples for the full duration (%s rows)\n" "$duration_rows"
  pass=$((pass + 1))
else
  printf "  FAIL  --duration 3 --interval 1 gave %s rows, expected at least 3\n" "$duration_rows"
  fail=$((fail + 1))
fi

echo "warnings"
check "warns that iostat cannot honour a sub-second interval" "cannot be honoured" \
  "$("$TRACE" --interval 0.5 --samples 1 2>&1 >/dev/null)"
quiet_interval="$("$TRACE" --interval 0.5 --samples 1 --no-cpu 2>&1 >/dev/null | grep -c "cannot be honoured")"
check_code "stays quiet about the interval when the cpu sampler is off" 0 "$quiet_interval"

echo "unreadable counters"
fake_tools="$(mktemp -d)"
printf '#!/bin/sh\nprintf "nothing useful\\n"\n' > "$fake_tools/vm_stat"
chmod +x "$fake_tools/vm_stat"
unreadable="$(PATH="$fake_tools:$PATH" "$TRACE" --samples 1 --interval 1 --no-cpu 2>&1)"
rm -rf "$fake_tools"
check "says so when vm_stat stops printing the counters" "did not print the counters" "$unreadable"
check "and does not report a calm machine" "Nothing was measured" "$unreadable"

echo
printf "passed: %s   failed: %s\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
