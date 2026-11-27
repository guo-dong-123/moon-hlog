# Streaming reader benchmark

Measured on 2026-11-27, macOS ARM64, using the pinned MoonBit 0.10.11 release build. The baseline is the published v0.2.0 macOS ARM64 executable. The optimized executable includes streaming aggregation. Each run compares the same generated log with itself. Each generated row reuses a valid V2 compressed histogram from the candidate fixture and has a distinct interval start.

The query selects one window with `report --window 1 --from 0 --until 1 --json`. Both modes produced identical values for all report fields shared with v0.2.0, including histogram summaries, P99 change, window status and the gate flag. The wall-clock time and peak RSS are the medians of three runs, collected with macOS `/usr/bin/time -l`.

| Rows per file | Before time (s) | Strict stream time (s) | Selected stream time (s) | Before peak RSS (MiB) | Strict peak RSS (MiB) | Selected peak RSS (MiB) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2,000 | 0.02 | 0.02 | 0.01 | 6.92 | 2.88 | 2.83 |
| 20,000 | 0.13 | 0.16 | 0.06 | 36.31 | 2.91 | 2.83 |
| 100,000 | 0.68 | 0.81 | 0.28 | 182.33 | 2.89 | 2.83 |

Strict streaming validates every compressed payload, including intervals outside the selection. With `--selected-only`, the 100,000-row query validates one payload per file and explicitly reports 99,999 skipped payloads per file. All line headers are still parsed. This measurement isolates a narrow query with simple, sparse histograms. For broader selections, memory also depends on the number of selected tag/window groups and their bucket counts. Strict validation has a small wall-clock overhead in this run.

## Rerun

Extract the [v0.2.0 macOS executable](https://github.com/guo-dong-123/moon-hlog/releases/tag/v0.2.0) and build the current executable with the pinned toolchain. Then run:

```sh
python3 scripts/benchmark-stream.py /path/to/old-hlog \
  _build/native/release/build/cmd/hlog/hlog.exe
```

The script compares fields shared by both versions and checks the selected-only validation counters. The query uses no gate policy.
