# MoonHlog

MoonHlog is a MoonBit library and CLI for HdrHistogram interval logs. It merges recorded bucket counts before computing percentiles, so a comparison reflects the whole selected distribution.

The sample logs each have 1,100 `read` measurements. P50 stays at 10,007 ns while P99 rises from 10,007 ns to 180,095 ns.

## Install the CLI

Download the archive for Linux x86-64 or macOS Apple Silicon from [Release v0.3.0](https://github.com/guo-dong-123/moon-hlog/releases/tag/v0.3.0). Extract it and run `./hlog --help`. The release includes sample logs and checksums. On a machine with the supported MoonBit toolchain, install the published CLI with `moon install guo-dong-123/moon-hlog/cmd/hlog@0.3.0`, or build it from a checkout with `moon install ./cmd/hlog`.

## Run the example

Use MoonBit `0.10.11+6ff76a5f9`, the version used for verification. Clone this repository and run the following from its root.

```sh
moon update
moon build --target native --release
hlog=_build/native/release/build/cmd/hlog/hlog.exe

"$hlog" summary tests/fixtures/baseline.hlog --tag read --json
"$hlog" compare tests/fixtures/baseline.hlog tests/fixtures/candidate.hlog \
  --tag read --from 1 --until 2 --max-p99-increase-pct 5
"$hlog" report tests/fixtures/baseline.hlog tests/fixtures/candidate.hlog \
  --window 1 --max-p99-increase-pct 5 --json
"$hlog" rewrite tests/fixtures/candidate.hlog /tmp/moonhlog-candidate.hlog
```

The comparison and window report return 1 for this deliberately regressed fixture. Run commands separately when using a shell that stops on nonzero exit. Exit 0 means the command succeeded and any configured threshold passed. Exit 2 means the input or options prevented the command from completing.

- Add `--json` to `summary`, `compare` or `report` for structured output. `p999` denotes P99.9.
- `report` joins both logs by tag and relative-time window. With a threshold, the gate fails if any paired window exceeds it or if one or both sides lack samples. A missing histogram is `null` in the report.
- Time windows select interval starts relative to each log's `StartTime`, with an inclusive `--from` and exclusive `--until`. Selected intervals contribute all their samples.
- Histogram values stay in the producer's units. Compare runs written with the same unit and a comparable workload. Relative P99 increase is undefined when the baseline P99 is zero. With a threshold set, any positive candidate P99 in that case returns 1.

## Sample-count gating

Pass `--min-samples COUNT` to `compare` or `report`. The count is a positive integer and applies to both sides. `compare` checks the selected aggregate, and `report` checks each selected tag and time window.

```sh
"$hlog" report tests/fixtures/baseline.hlog tests/fixtures/candidate.hlog \
  --window 1 --tag write --min-samples 100 --max-p99-increase-pct 5 --json
```

The example returns 1. The report row has `outcome: "insufficient_data"`, `reason: "below_min_samples"`, and 30 samples on each side. Percentiles and the relative change remain visible as descriptive values. The P99 threshold is evaluated only when both sides meet the sample minimum.

- JSON includes the configured `min_samples`, the `gate_failed` flag, and the machine-readable `outcome` and `reason`. Reports also include an outcome and reason for each row. If a report has both a confirmed regression and insufficient data, its overall outcome is `regression`.
- `pass` means all configured conditions were met. With no gate configured, a comparable result is `not_evaluated`. A reported P99 threshold breach is `regression`.
- With `--min-samples` enabled, missing samples and empty selections block the gate with exit 1. Invalid arguments or malformed inputs still return 2. The minimum is a policy setting for sample coverage.

See [external log and GitHub Actions integration](docs/INTEGRATION.md) for a recorded jHiccup log, the real capture command, and a CI example that retains the full JSON report.

## Unit declarations and streaming reads

For comparisons of logs with known latency units, declare both `--baseline-unit UNIT` and `--candidate-unit UNIT`. Accepted values are `ns`, `us`, `ms` and `s`. Conflicting declarations return exit 2 and JSON `outcome: "incomparable"`, `reason: "unit_mismatch"`, before comparing any numerical values. Omit both flags for the original producer-unit behavior.

```sh
"$hlog" report tests/fixtures/baseline.hlog tests/fixtures/candidate.hlog \
  --window 1 --from 1 --until 2 --baseline-unit ns --candidate-unit ns \
  --selected-only --max-p99-increase-pct 5 --json
```

`summary`, `compare` and `report` read the logs one line at a time and accumulate selected histograms. By default all payloads are validated. `--selected-only` still parses every line header and explicitly skips compressed payloads outside the selection. The JSON validation object records checked and skipped payload counts, and text output reports these counts too.

The library exposes `LogParser` for incremental input and `WindowAccumulator` for per-tag/window aggregation. See [the benchmark](docs/STREAMING_BENCHMARK.md) for the measured performance of the streaming reader.

## Use the library

The root package is [`guo-dong-123/moon-hlog`](https://mooncakes.io/docs/guo-dong-123/moon-hlog@0.3.0). In an existing MoonBit module, run `moon add guo-dong-123/moon-hlog@0.3.0` and import it in `moon.pkg` with the alias `@hlog`. The repository includes an independent [consumer module](examples/consumer). Run it against this checkout with a temporary workspace:

```sh
moon package
scripts/verify-consumer.sh _build/publish/guo-dong-123-moon-hlog-0.3.0.zip
```

The verifier imports the public API from the unpacked archive on all four targets, then installs and runs the native CLI. The library exposes `Log::windows` for one log and `Log::compare_windows` for paired results.

```moonbit
fn read_p99(text : StringView) -> Int64? raise @hlog.HlogError {
  let log = @hlog.parse_log(text)
  let selection : @hlog.Selection = {
    tag: Some("read"),
    from: Some(0.0),
    until: Some(2.0),
  }
  match log.aggregate(selection) {
    Some(histogram) => histogram.percentile(9900)
    None => None
  }
}
```

Percentile arguments are basis points of the sample count, so 9,900 selects P99. Empty selections return `None`; empty histograms have no percentile.

The format scope is zlib-compressed HdrHistogram V2 integer payloads with unit scale and zero normalization offset, in logs with one time origin. Aggregation requires identical bucket precision and unit magnitude. `rewrite` preserves interval fields, tags and counts, and normalizes the file header. The decoder permits up to 8 MiB of inflated data per frame. The library is tested on Native, JavaScript, Wasm and Wasm GC. The file-based CLI uses Native.

## Verification

```sh
moon check --target all --deny-warn
moon test --target all --deny-warn
moon fmt --check
moon build --target native --release --deny-warn
scripts/verify-interop.sh _build/native/release/build/cmd/hlog/hlog.exe
```

The interop check uses Java, Python 3 and the checksum-pinned HdrHistogram 2.2.2 JAR. It compares eight summaries and the two sides of each of three report rows against Java, then verifies that Java reads every recorded bucket, tag and timestamp from the two rewritten logs. It also verifies a jHiccup capture and the CI summary example. Run [the reviewer walkthrough](docs/REVIEWER_DEMO.md) for the offline demo.

[Implementation plan](docs/PLAN.md) · [November follow-up](docs/MVP_FOLLOWUP.md) · [项目申报书 PDF](docs/PROPOSAL.pdf) · [申报书 Markdown](docs/PROPOSAL.md)

## License

MoonHlog is MIT-licensed. The interchange format is based on [HdrHistogram](https://github.com/HdrHistogram/HdrHistogram), available under CC0-1.0 or BSD-2-Clause. The Java files under `scripts/` form an independent verification harness. MoonBit's `flate`, `x` and `async` dependencies use Apache-2.0.
