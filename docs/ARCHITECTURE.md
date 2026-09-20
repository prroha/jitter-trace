# Architecture

How jitter-trace is put together, why it is shaped this way, and where to change things.

## The idea in one line

**Read three cumulative macOS counters twice, divide the difference by the measured
elapsed time, and say which of four stories the rates tell.**

No daemon, no sampling profiler, no kernel extension, no file written anywhere. One bash
script that calls `vm_stat`, `iostat`, `ps` and `sysctl`, and does its arithmetic in `awk`.

## Shape

```
  vm_stat        iostat -c        ps -o cputime=       perl Time::HiRes
     |               |                  |                     |
     v               v                  v                     v
parse_vm_stat  parse_iostat_busy   parse_cputime            now()
     |               |                  |                     |
 decomp/pagein/   cpu busy %      cumulative CPU-secs     wall clock
 swapin totals        |                  |                     |
     |                |                  |                     |
     v                |                  +----------+----------+
  delta (vs previous) |                             |
     |                |                      difference / elapsed
  megabytes           |                             |
     |                |                             v
  per_second          |                     windowserver_percent
     |                |                             |
     +----------------+------------+----------------+
                                   v
                          classify_sample  ──► tags ("MEMORY-STALL(...)", ...)
                                   |
              +--------------------+--------------------+
              v                    v                    v
         table row             csv row              json object
              |                    |                    |
              +--------------------+--------------------+
                                   |
                            event counters + worst-seen
                                   |
                                   v
                          summarize_verdict  ──► print_summary
```

Everything flows one way. The parsing and arithmetic functions are pure: text or numbers
in, text out, no globals read, no commands run. Only the loop inside `main` touches the
system, keeps state, or prints.

## The one file

`bin/jitter-trace` is 420 lines. It is not a set of modules and this document will not
pretend otherwise. It is two halves: a library of pure functions at the top, and the tool
that uses them below the `── the tool` comment at line 144.

### The pure half (lines 13–142)

| Function | Lines | Responsibility |
|---|---|---|
| `parse_vm_stat` | 21–29 | `vm_stat` text on stdin → `"decomp pagein swapin"` cumulative page counts |
| `parse_iostat_busy` | 33–54 | `iostat -c` text on stdin → integer busy percent (`us` + `sy`), or empty |
| `parse_cputime` | 57–65 | `"MM:SS.ss"` or `"HH:MM:SS.ss"` → seconds, to two decimals |
| `delta` | 68–70 | `after - before`, floored at 0 so a reboot is not a negative spike |
| `megabytes` | 72–74 | pages × page size → MB, three decimals |
| `per_second` | 76–78 | amount ÷ seconds, three decimals, 0 when seconds is not positive |
| `display_rate` | 82–89 | a rate → the shortest string that still shows it is non-zero |
| `above` | 91–93 | exit status: is value strictly greater than limit |
| `classify_sample` | 97–120 | four rates plus three limits → space-separated tags |
| `summarize_verdict` | 123–142 | four event counts → one sentence naming the cause |

### The tool half (lines 144–420)

| Section | Lines | Responsibility |
|---|---|---|
| Defaults and settings | 146–159 | `DEFAULT_*` constants and the variables the options write to |
| `usage` | 161–195 | The help text, including the column glossary and how to read it |
| `die` | 197–200 | Message to stderr, exit with a code (default 1) |
| `require_macos` | 202–207 | `uname -s` must be `Darwin` and `vm_stat` must exist, else exit 3 |
| `positive_number`, `positive_integer` | 209–215 | Validators as exit statuses |
| `require_number`, `require_integer` | 217–223 | The same, but they `die` with the option name |
| `main` | 225–415 | Everything stateful — see below |
| Source guard | 417–420 | `main "$@"` only when the file was executed, not sourced |

`main` itself is another seven parts:

| Part of `main` | Lines | Responsibility |
|---|---|---|
| Option parsing | 226–242 | A `while`/`case` loop; every value goes through a `require_*` first |
| Preflight | 244–246 | `require_macos`, then `sysctl -n hw.pagesize` with a 4096 fallback |
| `now` | 249–251 | Sub-second wall clock via `perl`, falling back to `date +%s` |
| WindowServer plumbing | 253–264 | `pgrep -x WindowServer` once; `windowserver_seconds` reads its cumulative CPU time |
| `cpu_busy_percent` | 266–272 | `iostat -c 2 -w 1` piped to `parse_iostat_busy`, or empty under `--no-cpu` |
| Accumulators and `track_worst` | 274–289 | Event counts and the highest rate seen for each counter |
| `print_summary`, traps | 291–327 | The closing summary, and the exit/interrupt handling that guarantees it |
| Header and sample loop | 329–414 | The output header, then the loop |

The functions inside `main` are nested definitions: they do not exist until `main` runs.
That is deliberate — see the source guard below.

## The data model

There is no structure richer than a handful of shell variables. The whole state carried
between iterations is:

```
previous_counters                "decomp pagein swapin"   (a single string, re-split)
previous_windowserver_seconds    cumulative CPU-seconds
previous_time                    wall clock, seconds with milliseconds
started_at                       wall clock at the first sample
sample_count
memory_events, disk_events, swap_events, compositor_events
worst_decomp, worst_pagein, worst_swapin, worst_windowserver
```

Everything else is derived inside one iteration and thrown away. That is the reason the
tool can be a shell script at all: nothing needs a record, only a previous reading.

`classify_sample` returns its result as a single string of space-separated tags rather
than an array, because bash 3.2 has no associative arrays and returning an indexed array
from a function means either `eval` or a global. A string that the caller matches with
`case "$tags" in *MEMORY-STALL*)` is simpler and survives being captured in `$(...)`.

## Three ideas that drive most of the code

### 1. Rates, not counts, decide everything

Every threshold — `--decomp-mb`, `--pagein-mb`, `--ws-percent` — is per second. The raw
page deltas are shown in the table because they are what the counters actually say, but
nothing is ever compared against them.

The consequence is that `--interval 2` and `--interval 0.5` flag the same stalls. If the
limits were per sample, doubling the interval would double every count and halve the
apparent sensitivity, and the defaults would only mean anything at exactly one second.

The divisor is the **measured** elapsed time, not `$interval`:

```bash
elapsed="$(awk -v a="$previous_time" -v b="$time_now" -v fallback="$interval" \
  'BEGIN { e = b - a; print (e > 0.05) ? e : fallback }')"
```

This matters because an iteration takes longer than it sleeps. `iostat -c 2 -w 1` blocks
for about a second, `vm_stat`, `ps` and `pgrep` each cost a few milliseconds, and the loop
only sleeps `interval - CPU_SAMPLE_SECONDS` (lines 409–413) to compensate. The result is
close to the requested interval but never exact, and using the nominal interval as the
divisor would bias every rate. The `0.05` floor exists so that a clock that went backwards,
or a `now()` that fell back to whole-second `date`, cannot produce a division by something
tiny and report an absurd rate.

### 2. Counters are cumulative and untrustworthy at the edges

`vm_stat` counts since boot. Two things follow.

**The first sample prints nothing.** A single reading of a cumulative counter says nothing
about the last second. The loop reads, stores into `previous_counters`, and only produces
a row once `previous_counters` is non-empty (line 355). So `--samples 2` performs three
`vm_stat` reads and prints two rows, and the `TIME` column is the time of the *end* of the
interval.

**A reset reads as zero, not as a negative.** `delta` floors at zero:

```bash
awk -v before="$1" -v after="$2" 'BEGIN { print (after >= before) ? after - before : 0 }'
```

Without that, a reboot mid-run (or `ps` reporting a different WindowServer) would show a
minus-billion-page spike, which would then set `worst_decomp` for the rest of the session.
Losing one sample is the cheaper error.

The same reasoning drives `WS%`. It is computed as the difference in cumulative CPU-seconds
divided by elapsed, not read from `ps -o pcpu`, because `pcpu` is an average over the
process's whole lifetime — for a WindowServer that has been up for a fortnight it is a
constant that says nothing about the last second.

### 3. Missing is not zero

Every counter has a "cannot tell" answer distinct from "nothing happened".

- `parse_iostat_busy` prints the **empty string** when it finds no header, or when the
  cells where `us` and `sy` should be do not look like numbers (lines 45 and 50). It never
  prints `0`, because reporting an idle CPU when `iostat` is missing or has changed its
  format would invent the very evidence the tool exists to supply. The empty value then
  renders as `-` in the table (`${cpu_percent:--}`), as an empty field in CSV, and as
  JSON `null` (`${cpu_percent:-null}`).
- `--no-cpu` produces the same empty value by the same path, so there is one code path,
  not two.
- No WindowServer process (headless, or over SSH) means `windowserver_seconds` returns a
  literal `0` and the tool says so **once**, on stderr, before the run starts (lines
  254–256). A warning per sample would drown the table.
- `parse_vm_stat` is the exception: unrecognised input yields `0 0 0`, via `print decomp +
  0` on unset awk variables. That is a genuine asymmetry — see the limitations below.

`require_macos` only guarantees `vm_stat`. Everything else degrades: no `iostat` gives a
`-` CPU column, no `perl` falls back to whole-second timing, no `sysctl` assumes a 4 KiB
page. The tool still answers the question it was opened for.

## Parsing, in detail

### `vm_stat`

```awk
/^Decompressions:/      { gsub(/\./, "", $2); decomp = $2 }
/^Pages decompressed:/  { gsub(/\./, "", $3); decomp = $3 }
```

Three things are going on.

- **The counter was renamed.** macOS 13 and earlier print `Pages decompressed:`, macOS 14
  and later print `Decompressions:`. Both patterns are present, and whichever the machine
  emits wins. A script that matches only the old name silently reports zero on modern
  macOS, which looks exactly like a healthy machine.
- **The field number differs** (`$2` versus `$3`) purely because the old label is two
  words.
- **`^` anchoring is load-bearing.** `vm_stat` also prints `Tagged decompressions:`, which
  counts something else entirely. Anchoring at the start of the line is what excludes it;
  a bare `/Decompressions:/` would match both and the last one read would win.

The trailing full stop on every `vm_stat` number is stripped with `gsub`. The `END` block
adds `+ 0` so an absent counter prints `0` rather than an empty field, which keeps the
output a stable three fields for `read -r` to consume.

### `iostat`

`iostat -c` puts the CPU columns after the per-disk columns, so their absolute position
depends on how many disks are attached. Hard-coding `$11` works on a laptop and silently
reads a load average on a machine with an external drive.

`parse_iostat_busy` finds `us` and `sy` **by name** in the header, remembers their field
indices, then re-splits the last data line. The re-split is where the awkward part lives:

```awk
split(last, fields, /[[:space:]]+/)
offset = (fields[1] == "") ? 1 : 0
```

Awk's default field splitting ignores leading whitespace, so the header's `us` might be
field 7. An explicit `split` on a whitespace regex does **not** ignore it, so an indented
data row puts an empty string in `fields[1]` and shifts everything by one. The offset
corrects for exactly that. (The explicit `split` is needed because `last` was stored as a
whole line, `$0`, not as fields.)

`seen_header && NF >= 3 { last = $0 }` keeps overwriting, so `last` ends up being the final
data row — which, for `iostat -c 2 -w 1`, is the one-second sample rather than the
since-boot average that `iostat` prints first.

### `ps` cputime

`parse_cputime` accepts both `MM:SS.ss` and `HH:MM:SS.ss` by switching on `NF` with `-F:`,
and returns `0.00` for anything else — including the empty string it gets when the process
has gone away. The input arrives via a here-string (`<<< "${1:-}"`) so the function reads
an argument rather than stdin, which is what the callers want.

The resolution ceiling comes from `ps`: it reports centiseconds. Over a one-second interval
that is 1% granularity on `WS%`, so a nearly idle compositor reads as a flat `0.0`.

## A worked trace: one sample becomes one row

Starting at line 344, with `previous_counters` already populated:

```
read -r decomp pagein swapin <<< "$(vm_stat | parse_vm_stat)"
  └─ "1030423909 99589699 6315219"

cpu_percent="$(cpu_busy_percent)"
  └─ iostat -c 2 -w 1            blocks ~1s
       └─ parse_iostat_busy      header names us/sy → "8"

windowserver_now="$(windowserver_seconds)"
  └─ ps -o cputime= -p 412  →  "1981:46.81"
       └─ parse_cputime         →  "118906.81"

time_now="$(now)"                →  "1758361355.402"

elapsed = time_now - previous_time                        →  1.043
ws%     = (118906.81 - 118906.55) * 100 / 1.043           →  "24.9"

decomp_pages = delta(previous_decomp, decomp)             →  4210
decomp_rate  = per_second(megabytes(4210, 16384), 1.043)  →  "63.069"
  (same for pagein and swapin)

tags = classify_sample(63.069, 0.812, 0, 24.9, 8, 2, 60)
  ├─ above 63.069 8   → "MEMORY-STALL(63.1MB/s-decompressed) "
  ├─ above 0.812  2   → no
  ├─ above 0      0   → no
  └─ above 24.9   60  → no

case "$tags" in *MEMORY-STALL*) memory_events++ ;;        (four such cases)
track_worst 63.069 0.812 0 24.9
sample_count++

printf ... "$(date +%H:%M:%S)" 4210 ...  MEMORY-STALL(63.1MB/s-decompressed)
```

Then `previous_counters="$decomp $pagein $swapin"`, the stop conditions are checked, and
the loop sleeps whatever is left of the interval.

Two details in that trace are easy to miss. `read -r ... <<< "$(...)"` uses a here-string
rather than a pipe deliberately: `vm_stat | parse_vm_stat | read a b c` would run `read` in
a subshell and the variables would not survive the pipeline. And `display_rate` is applied
only in the tag and the summary, never to the CSV or JSON rate columns — machine-readable
output keeps all three decimals, while human output prints `63.1`, `0.81` or `0.003`
depending on magnitude, so a real but small rate never renders as a bare `0`.

## Output formats

One loop, three `printf` calls selected by `case "$format"`, all fed from the same
variables. There is no formatter abstraction because three `printf` lines are shorter than
any indirection that would replace them.

| Format | Sample rows | Summary | Notes |
|---|---|---|---|
| `table` (default) | stdout, fixed-width columns | **stderr** | Unknown CPU renders `-` |
| `--csv` | stdout, 10 columns, header row | **stderr** | Tags joined with `;` via `tr -s ' ' ';' \| sed 's/;$//'` |
| `--json` | stdout, one object per line | **stdout**, `"type":"summary"` | Unknown CPU renders `null` |

The split matters. For `table` and `csv` the summary goes to stderr, so
`jitter-trace --csv > jitter.csv` writes a clean parseable file and the verdict still
appears on the terminal. For `--json` the summary goes to stdout instead, because it is
itself a JSON object and a consumer doing `jitter-trace --json | jq` wants it in the
stream. That is why `print_summary` branches on the format before anything else
(lines 293–298).

CSV and JSON carry both the raw page deltas and the computed MB/s rates. The table shows
pages only, and puts the rates inside the tag text where they are needed for judgement.

## Errors and interruption

| Where | What happens |
|---|---|
| Unknown option | `die "unknown option: ..."` → stderr, exit 1 |
| Bad option value | `require_number` / `require_integer` → exit 1, naming the option and the value |
| Not macOS, or no `vm_stat` | `require_macos` → exit 3 |
| No WindowServer | One line on stderr at startup, `WS%` stays `0` |
| `iostat` missing or unparseable | CPU column becomes `-` / empty / `null` |
| Counter reset | `delta` returns 0 for that sample |
| Ctrl-C or `SIGTERM` | `finish` → `exit 0` → the `EXIT` trap prints the summary |

The two traps at lines 326–327 are the whole story of "Ctrl-C still gives you an answer":

```bash
trap finish INT TERM
trap on_exit EXIT
```

`finish` does not print. It sets `stop_requested=1` and exits, and the `EXIT` trap does the
printing — so the summary is produced by exactly one path whether the run ended from
`--samples`, `--duration`, Ctrl-C or a `kill`. `on_exit` first does `trap - EXIT` to
disarm itself against re-entry, captures `$?` before anything else can clobber it, and
re-raises that status unless the stop was requested, in which case an interrupted run is
reported as a success. A monitoring tool you stopped on purpose did not fail.

Note that the traps are installed **after** argument parsing and `require_macos`, so a
usage error exits without printing an empty summary.

## Sourceability, and why the tests are fast

The last four lines:

```bash
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
```

When the script is executed, `BASH_SOURCE[0]` and `$0` are both the script's path and
`main` runs. When another script does `. bin/jitter-trace`, `BASH_SOURCE[0]` is this file
but `$0` is the *caller*, so the condition fails and nothing runs. Sourcing therefore
defines the ten pure functions, the option defaults and `usage`/`die`, and starts no
sampling.

That guard is what makes `test/parse.test.sh` possible. It sources the tool and calls
`parse_vm_stat`, `classify_sample` and the rest directly against recorded fixture text —
29 assertions in milliseconds, on any machine, with no Mac and no waiting for real
counters to move. Without it, testing the iostat column logic would mean owning a machine
with two disks attached.

It is also the reason `now`, `windowserver_seconds`, `cpu_busy_percent`, `track_worst`,
`print_summary`, `on_exit` and `finish` are defined **inside** `main` rather than at the
top level. They read and write the loop's state and would be meaningless to a test in
isolation, so nesting them keeps the sourced surface to exactly the part that is pure.

## Portability assumptions

- **macOS only, and checked.** `vm_stat`, `iostat -c`, `ps -o cputime=`, `sysctl -n
  hw.pagesize` and `pgrep -x` are the interface. `require_macos` refuses anything that is
  not Darwin with exit 3 rather than producing nonsense.
- **bash 3.2**, because that is what macOS ships and the script is meant to run from a
  fresh machine with no Homebrew. No associative arrays, no `${var^^}`, no `mapfile`,
  no `local -n`. The features it does use — `[[ ]]`-free `case`, here-strings, `$(...)`,
  `BASH_SOURCE` — are all 3.2. The shebang is `/usr/bin/env bash`, so a newer bash on
  `PATH` is used if present; nothing depends on it.
- **awk, not bash, does every calculation.** Bash 3.2 has integer arithmetic only, and
  every quantity here is fractional: MB/s, elapsed seconds, CPU percentages. Delegating to
  `awk` keeps one arithmetic model instead of a mix of `$(( ))` and scaled integers, and
  `awk` is in POSIX so there is nothing to install. The cost is a process per calculation,
  which is real but irrelevant next to the one-second `iostat` wait.
- **`perl` for sub-second time**, because macOS `date` has no `%N`. Perl ships with macOS;
  `date +%s` is the fallback if it ever does not.
- **Page size is asked for, not assumed.** `sysctl -n hw.pagesize` returns 4096 on Intel
  and 16384 on Apple Silicon. Hard-coding 4096 would under-report every rate on Apple
  Silicon by a factor of four. The 4096 default applies only when `sysctl` fails.

## Testing

| File | Covers | Needs a Mac |
|---|---|---|
| `test/parse.test.sh` | 29 assertions on the pure functions, against fixture text | No |
| `test/cli.test.sh` | 17 assertions: runs the real binary, checks every format and exit code | Yes, mostly |

```bash
bash test/parse.test.sh
bash test/cli.test.sh
```

`test/fixtures/` holds the awkward inputs: `vm_stat.txt` and `vm_stat-legacy.txt` for the
two spellings of the decompression counter, and `iostat-one-disk.txt` and
`iostat-two-disks.txt` for the column shift. Those four files are the reason the parsing
can be changed with any confidence.

`test/cli.test.sh` detects a non-Darwin host and, rather than skipping, asserts the
opposite: that the tool refuses to run and exits 3. So the guard itself is covered on
Linux. The end-to-end runs all pass `--no-cpu`, which removes the one-second `iostat` wait
and keeps the suite quick; the consequence is that the `iostat` path is exercised only by
the unit tests against fixtures, never against a live `iostat`.

Neither suite is a framework. `expect` and `expect_contains` are eight-line functions that
increment `pass` or `fail` and the script exits non-zero if `fail` is not 0 — which is all
a CI step needs.

CI (`.github/workflows/test.yml`) runs the unit tests on Ubuntu and macOS, the CLI tests on
macOS, the non-Darwin guard on Ubuntu, and `shellcheck -x` over all three scripts.

## Releasing

`scripts/release.sh` takes `patch`, `minor`, `major` or an explicit `1.2.3`, and
`--dry-run` to print what it would do. It refuses unless the tree is a clean `main` that
matches `origin/main`, the tag is free, and both suites pass. Only then does it rewrite the
`VERSION=` line in `bin/jitter-trace` with `awk`, commit, tag, push, create the GitHub
release, wait for the tag's tarball to appear (polling for up to 60 seconds, because it is
generated a moment after the push), checksum it, and rewrite `url` and `sha256` in the
Homebrew formula.

`VERSION` lives in the script rather than in a separate file because the script *is* the
distribution: the documented install is to copy one file onto your `PATH`, and a version
that can be separated from what it versions will be.

## Where to change things

| To change | Edit |
|---|---|
| A counter's name across macOS versions | `parse_vm_stat`, lines 21–29 — add a pattern, do not replace one |
| How the CPU percent is read | `parse_iostat_busy`, lines 33–54, and `cpu_busy_percent`, 266–272 |
| What counts as a stall | `DEFAULT_*` at lines 147–149, and the `above` calls in `classify_sample` |
| A new tag | `classify_sample`, then a `case` arm in the loop at 366–377, then `summarize_verdict` |
| The advice text | `summarize_verdict`, lines 123–142 |
| A column | The three `printf` calls at 382–396, plus the headers at 329–336, plus `usage` |
| A new option | The `case` in `main` at 227–240, plus `usage`, plus the README options table |
| Sampling cadence | Lines 408–413, and `CPU_SAMPLE_SECONDS` at 150 |

Anything added to the pure half should get a fixture-based assertion in
`test/parse.test.sh`; anything added to the loop is only reachable from
`test/cli.test.sh`.

## Deliberate omissions

Not oversights:

- **No history, no output file, no database.** It writes nothing. Persisting is the
  shell's job: `--csv > file`. A tool that manages its own storage acquires a retention
  policy, a schema and a migration.
- **No per-process attribution.** It says *what kind* of pressure the machine is under, not
  which application caused it. Naming the culprit means `footprint` or sampling every
  process every second, which costs more than the stall being measured. Activity Monitor
  already does that part; the gap this fills is that Activity Monitor cannot tell you the
  stall happened at all.
- **No thresholds tuned per machine.** 8 MB/s, 2 MB/s and 60% are defaults picked to be
  quiet on a healthy laptop, and all three are flags. Automatic calibration would need a
  baseline run and a notion of "healthy" that the tool has no way to establish.
- **No GPU, thermal or network counters.** The verdict text names those as places to look
  next rather than pretending to measure them. Three counters that genuinely explain the
  invisible case are more useful than twelve that need interpreting.
- **No colour, no curses, no live redraw.** Output is append-only lines, so it pipes, tees
  and pastes into a bug report unchanged.
- **No aggregate CPU% in the verdict logic.** `CPU%` is printed as context only. The whole
  premise is that it is the misleading number.
