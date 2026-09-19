# jitter-trace

**Why does my Mac stutter when the CPU meter says it's idle?** This samples the counters that answer that, and tells you which of three causes it is.

```
$ jitter-trace
TIME       DECOMP   PAGEIN   SWAPIN   CPU%    WS%  NOTE
11:22:35        4       15        0     2%   2.1%
11:22:36     4210       53        0     6%  26.1%  MEMORY-STALL(16.4MB/s-decompressed)
11:22:37       65      212        0     2%  71.4%  DISK-FAULT(3.0MB/s) COMPOSITOR-BUSY
^C
3 samples over 1s intervals
  memory stalls    1   (worst 16.4 MB/s decompressed)
  disk faults      1   (worst 3.0 MB/s paged in)
  swap-ins         0   (worst 0 MB/s)
  compositor busy  1   (WindowServer peaked at 71.4%)

Memory pressure. The working set does not fit, so touched pages come back from
the compressor or swap. Close apps, or add RAM.
```

## Why the CPU meter lies

A thread waiting on a page fault is **parked, not busy**. macOS compresses memory it thinks you aren't using; touching that memory again means decompressing it, and the thread waits. Activity Monitor shows the CPU *falling* at exactly the moment the frame is missed, because nothing is executing. The usual advice ("check what's using CPU") therefore leads nowhere.

These counters move instead:

| Column | What it counts | What it means |
|---|---|---|
| `DECOMP` | Pages faulted back out of the memory compressor | Your working set doesn't fit in RAM. The classic invisible stall |
| `PAGEIN` | Pages read from disk | Memory-mapped files or code being pulled in |
| `SWAPIN` | Pages pulled from the swap file | Real swapping: worse than compression |
| `CPU%` | Overall user + system CPU | Context, so you can see it *isn't* the cause |
| `WS%` | WindowServer CPU | The compositor. High here with flat counters means animations, windows or displays, not memory |

`WS%` is computed from the difference in cumulative CPU-seconds between samples. `ps -o pcpu` would be wrong: it reports a process's average over its whole lifetime, so for a WindowServer that has been up for two weeks it's a constant that ignores what just happened on screen.

## Install

One file, no dependencies. macOS only: it reads `vm_stat`, `iostat`, `ps` and `sysctl`, which all ship with the system.

```bash
curl -fsSL https://raw.githubusercontent.com/prroha/jitter-trace/main/bin/jitter-trace \
  -o /usr/local/bin/jitter-trace && chmod +x /usr/local/bin/jitter-trace
jitter-trace --help
```

No write access to `/usr/local/bin`? Put it anywhere on your `PATH`, for example `~/bin`. Or clone and run it in place:

```bash
git clone https://github.com/prroha/jitter-trace.git
./jitter-trace/bin/jitter-trace
```

## Use it

```bash
jitter-trace                         # watch live, Ctrl-C to stop and see the summary
jitter-trace --duration 30           # sample for 30 seconds
jitter-trace --samples 10            # ten samples, then stop
jitter-trace --interval 2            # every 2 seconds
jitter-trace --no-cpu --interval 0.5 # tighter sampling (skips the iostat wait)
jitter-trace --csv > jitter.csv      # for a spreadsheet or a graph
jitter-trace --json | jq             # one object per sample, then a summary
```

**The workflow:** start it, reproduce the stutter (switch spaces, scroll a background tab, wake a sleeping app), stop it, read the verdict.

## Reading the output

| What you see | Cause | What to do |
|---|---|---|
| `DECOMP` spikes while CPU is low | Memory pressure, pages coming back from the compressor | Close apps, especially browsers and Electron ones. Add RAM if it's constant |
| `SWAPIN` above zero at all | Real swapping | Same, more urgent. Check free disk space too |
| `PAGEIN` spikes | Reading from disk | Find what's reading (Activity Monitor → Disk), or check a nearly full disk |
| `WS%` high, counters flat | The compositor is doing real work | Reduce animations, close windows, check scaled resolutions and external displays. Try `System Settings → Accessibility → Display → Reduce motion` |
| Nothing moves | Not memory, disk or the compositor | Look at the app itself, the GPU, or thermal throttling (`pmset -g thermlog`) |

An idle machine reads near zero on every counter, so a baseline run is worth having for comparison.

## Options

| Option | Meaning |
|---|---|
| `-i`, `--interval <s>` | Seconds between samples (default 1) |
| `-d`, `--duration <s>` | Stop after this long |
| `-n`, `--samples <n>` | Stop after this many samples |
| `--csv` | Comma-separated, one row per sample, with rate columns |
| `--json` | One JSON object per sample, then a summary object |
| `--no-cpu` | Skip overall CPU%, which drops a ~1s `iostat` wait per sample |
| `--decomp-mb <n>` | MB/s decompressed that counts as a memory stall (default 8) |
| `--pagein-mb <n>` | MB/s paged in that counts as a disk fault (default 2) |
| `--ws-percent <n>` | WindowServer CPU% that counts as compositor busy (default 60) |
| `-v`, `--version` · `-h`, `--help` | Version, help |

Thresholds are **per second**, so changing `--interval` doesn't change what counts as a stall.

Exit codes: `0` finished · `1` bad usage · `3` not macOS, or a required tool is missing.

## Notes and limitations

- **macOS only**, by nature: these are macOS counters. On anything else it says so and exits 3.
- **The decompression counter was renamed.** macOS 13 and earlier print `Pages decompressed`; macOS 14+ print `Decompressions`. Both are read, so the column works across versions. (Scripts that only look for the old name silently report zero on modern macOS.)
- **`iostat` costs about a second** per sample for its CPU figure, so an interval below ~1s only takes effect with `--no-cpu`.
- **Over SSH or headless**, WindowServer isn't running, so `WS%` stays 0 and the tool says so once.
- **Counters are cumulative and reset on reboot.** A reset shows as zero rather than a negative spike.
- **`WS%` resolution is one centisecond of CPU time**, because that is what `ps` reports. Over a 1-second interval that is 1% granularity, so an almost idle compositor reads near zero.
- It observes only. Nothing is changed, nothing is written outside the files you redirect to.

## Tests

```bash
bash test/parse.test.sh   # 29 unit tests on fixture text, no Mac needed
bash test/cli.test.sh     # 17 end-to-end tests: runs the tool, checks every format
```

The tool is one self-contained file whose parsing, rate arithmetic, classification and verdict functions come first, so the unit tests source it and feed them recorded `vm_stat` and `iostat` output, including the two-disk layout that shifts iostat's columns and both spellings of the decompression counter. Sourcing it never starts a sampling run.

## License

MIT
