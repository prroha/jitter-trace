#!/usr/bin/env bash
# Unit tests for the parsing and classification functions. Fixture text only,
# so these run anywhere, in milliseconds, with no Mac and no sampling.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/parse.sh
. "$HERE/../lib/parse.sh"

pass=0
fail=0

expect() {
  name="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "  ok    %s\n" "$name"
    pass=$((pass + 1))
  else
    printf "  FAIL  %s\n        expected: %s\n        got:      %s\n" "$name" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

expect_contains() {
  name="$1"
  needle="$2"
  haystack="$3"
  case "$haystack" in
    *"$needle"*)
      printf "  ok    %s\n" "$name"
      pass=$((pass + 1))
      ;;
    *)
      printf "  FAIL  %s\n        expected to contain: %s\n        got: %s\n" "$name" "$needle" "$haystack"
      fail=$((fail + 1))
      ;;
  esac
}

echo "vm_stat"
expect "reads the macOS 14+ counter names" "1030423909 99589699 6315219" \
  "$(parse_vm_stat < "$HERE/fixtures/vm_stat.txt")"
expect "reads the macOS 13 and earlier names" "900000 5000000 20000" \
  "$(parse_vm_stat < "$HERE/fixtures/vm_stat-legacy.txt")"
expect "ignores tagged decompressions" "1030423909 99589699 6315219" \
  "$(parse_vm_stat < "$HERE/fixtures/vm_stat.txt")"
expect "reports zeros for unrecognised output" "0 0 0" "$(printf "nothing useful\n" | parse_vm_stat)"

echo "iostat"
expect "finds the cpu columns with one disk" "8" \
  "$(parse_iostat_busy < "$HERE/fixtures/iostat-one-disk.txt")"
expect "finds them again when two disks shift the columns" "12" \
  "$(parse_iostat_busy < "$HERE/fixtures/iostat-two-disks.txt")"
expect "returns empty when there is no header" "" "$(printf "garbage line\n" | parse_iostat_busy)"

echo "cputime"
expect "minutes and seconds, to the centisecond" "118906.81" "$(parse_cputime "1981:46.81")"
expect "hours, minutes and seconds" "8130.00" "$(parse_cputime "2:15:30.00")"
expect "unparseable input" "0.00" "$(parse_cputime "nonsense")"

echo "arithmetic"
expect "delta" "40" "$(delta 100 140)"
expect "a counter reset never reads as negative" "0" "$(delta 500 10)"
expect "pages to megabytes" "10.000" "$(megabytes 2560 4096)"
expect "sub-megabyte values are not rounded to zero" "0.500" "$(megabytes 128 4096)"
expect "per-second rate" "4.000" "$(per_second 8 2)"
expect "zero elapsed does not divide by zero" "0.000" "$(per_second 8 0)"

echo "classification"
expect_contains "flags a memory stall above the limit" "MEMORY-STALL" \
  "$(classify_sample 20 0 0 0 8 2 60)"
expect "stays quiet below every limit" "" "$(classify_sample 1 0.5 0 10 8 2 60)"
expect_contains "flags a disk fault" "DISK-FAULT" "$(classify_sample 0 9 0 0 8 2 60)"
expect_contains "flags any swap-in at all" "SWAP-IN" "$(classify_sample 0 0 0.1 0 8 2 60)"
expect_contains "flags a single 16KB page on Apple Silicon" "SWAP-IN" \
  "$(classify_sample 0 0 "$(per_second "$(megabytes 1 16384)" 1)" 0 8 2 60)"
expect "header-only iostat reports an unknown cpu, not an idle one" "" \
  "$(printf "disk0 cpu load average\n" | parse_iostat_busy)"
expect_contains "flags a busy compositor" "COMPOSITOR-BUSY" "$(classify_sample 0 0 0 94 8 2 60)"
expect_contains "respects a raised limit" "" "$(classify_sample 20 0 0 0 50 2 60)"

echo "verdict"
expect_contains "memory comes first" "Memory pressure" "$(summarize_verdict 2 1 0 1)"
expect_contains "swap counts as memory" "Memory pressure" "$(summarize_verdict 0 0 1 0)"
expect_contains "then disk" "Disk faults" "$(summarize_verdict 0 3 0 1)"
expect_contains "then the compositor" "Compositor" "$(summarize_verdict 0 0 0 2)"
expect_contains "nothing seen says so" "No stalls seen" "$(summarize_verdict 0 0 0 0)"

echo
printf "passed: %s   failed: %s\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
