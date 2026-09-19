# shellcheck shell=bash
# Pure parsing and classification for jitter-trace. Sourced by the CLI and by
# the tests, which feed it fixture text instead of live commands.
# Bash 3.2 compatible: macOS ships that version.

# Cumulative page counters from `vm_stat` output on stdin: "decomp pagein swapin".
# The decompression counter was renamed: macOS 13 and earlier print
# "Pages decompressed", macOS 14+ print "Decompressions". Read whichever exists,
# and never match "Tagged decompressions", which counts something else.
parse_vm_stat() {
  awk '
    /^Decompressions:/      { gsub(/\./, "", $2); decomp = $2 }
    /^Pages decompressed:/  { gsub(/\./, "", $3); decomp = $3 }
    /^Pageins:/             { gsub(/\./, "", $2); pagein = $2 }
    /^Swapins:/             { gsub(/\./, "", $2); swapin = $2 }
    END { print decomp + 0, pagein + 0, swapin + 0 }
  '
}

# CPU busy percent from `iostat -c` output on stdin. The columns move with the
# number of disks, so the user and system columns are found by header name.
parse_iostat_busy() {
  awk '
    /[[:space:]]us[[:space:]]+sy[[:space:]]+id/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "us") { user_column = i }
        if ($i == "sy") { system_column = i }
      }
      seen_header = 1
      next
    }
    seen_header && NF >= 3 { last = $0 }
    END {
      if (user_column == 0 || last == "") { print ""; exit }
      split(last, fields, /[[:space:]]+/)
      offset = (fields[1] == "") ? 1 : 0
      user = fields[user_column + offset]
      system_time = fields[system_column + offset]
      if (user !~ /^[0-9.]+$/ || system_time !~ /^[0-9.]+$/) { print ""; exit }
      printf "%.0f", user + system_time
    }
  '
}

# "MM:SS.ss" or "HH:MM:SS.ss" (the `ps cputime` format) to seconds.
parse_cputime() {
  awk -F: '
    {
      if (NF == 3) { printf "%.2f", $1 * 3600 + $2 * 60 + $3 }
      else if (NF == 2) { printf "%.2f", $1 * 60 + $2 }
      else { printf "%.2f", 0 }
    }
  ' <<< "${1:-}"
}

# Counters reset on reboot, and a reset would otherwise read as a huge negative.
delta() {
  awk -v before="${1:-0}" -v after="${2:-0}" 'BEGIN { print (after >= before) ? after - before : 0 }'
}

megabytes() {
  awk -v pages="${1:-0}" -v page_size="${2:-4096}" 'BEGIN { printf "%.3f", pages * page_size / 1048576 }'
}

per_second() {
  awk -v amount="${1:-0}" -v seconds="${2:-1}" 'BEGIN { printf "%.3f", (seconds > 0) ? amount / seconds : 0 }'
}

# Rates carry three decimals so a single page still registers. Displays show
# just enough of them that a small but real rate does not read as zero.
display_rate() {
  awk -v value="${1:-0}" 'BEGIN {
    if (value == 0) { printf "0" }
    else if (value >= 1) { printf "%.1f", value }
    else if (value >= 0.01) { printf "%.2f", value }
    else { printf "%.3f", value }
  }'
}

above() {
  awk -v value="${1:-0}" -v limit="${2:-0}" 'BEGIN { exit !(value > limit) }'
}

# What this sample means, as space-separated tags. Rates are per second, so
# changing the sampling interval does not change what counts as a stall.
classify_sample() {
  decomp_mb_rate="$1"
  pagein_mb_rate="$2"
  swapin_mb_rate="$3"
  windowserver_percent="$4"
  decomp_limit="$5"
  pagein_limit="$6"
  windowserver_limit="$7"

  tags=""
  if above "$decomp_mb_rate" "$decomp_limit"; then
    tags="${tags}MEMORY-STALL($(display_rate "$decomp_mb_rate")MB/s-decompressed) "
  fi
  if above "$pagein_mb_rate" "$pagein_limit"; then
    tags="${tags}DISK-FAULT($(display_rate "$pagein_mb_rate")MB/s) "
  fi
  if above "$swapin_mb_rate" 0; then
    tags="${tags}SWAP-IN($(display_rate "$swapin_mb_rate")MB/s) "
  fi
  if above "$windowserver_percent" "$windowserver_limit"; then
    tags="${tags}COMPOSITOR-BUSY "
  fi
  printf "%s" "$tags"
}

# The verdict: which cause the numbers point at.
summarize_verdict() {
  memory_events="$1"
  disk_events="$2"
  swap_events="$3"
  compositor_events="$4"

  if [ "$memory_events" -gt 0 ] || [ "$swap_events" -gt 0 ]; then
    printf "%s" "Memory pressure. The working set does not fit, so touched pages come back from the compressor or swap. Close apps, or add RAM."
    return
  fi
  if [ "$disk_events" -gt 0 ]; then
    printf "%s" "Disk faults. Pages are being read from disk. Check what is reading heavily, or whether the disk is nearly full."
    return
  fi
  if [ "$compositor_events" -gt 0 ]; then
    printf "%s" "Compositor. WindowServer is doing real work: animations, many windows, displays or scaled resolutions. Not a memory problem."
    return
  fi
  printf "%s" "No stalls seen. Nothing here explains the jitter: look at the app itself, the GPU, or thermal throttling."
}
