# MoonHlog

MoonHlog is a MoonBit library and CLI for HdrHistogram interval logs. It merges recorded bucket counts before computing percentiles, so a comparison reflects the whole selected distribution.

The sample logs each have 1,100 `read` measurements. P50 stays at 10,007 ns while P99 rises from 10,007 ns to 180,095 ns.

## Run the example

Use MoonBit `0.10.11+6ff76a5f9`, the version used for verification. Clone this repository and run the following from its root.

```sh
moon update
moon build --target native --release
hlog=_build/native/release/build/cmd/hlog/hlog.exe

"$hlog" summary tests/fixtures/baseline.hlog --tag read --json
"$hlog" compare tests/fixtures/baseline.hlog tests/fixtures/candidate.hlog \
  --tag read --from 1 --until 2 --max-p99-increase-pct 5
"$hlog" rewrite tests/fixtures/candidate.hlog /tmp/moonhlog-candidate.hlog
```

The comparison returns 1 for this deliberately regressed fixture. Exit 0 means the command succeeded and any configured threshold passed. Exit 2 means the input or options prevented the command from completing.

- Add `--json` to `summary` or `compare` for structured output. `p999` denotes P99.9.
- Time windows select interval starts relative to each log's `StartTime`, with an inclusive `--from` and exclusive `--until`. Selected intervals contribute all their samples.
- Histogram values stay in the producer's units. Compare runs written with the same unit and a comparable workload. Relative P99 increase is undefined when the baseline P99 is zero. With a threshold set, any positive candidate P99 in that case returns 1.

## Use the library

The root package is `guo-dong-123/moon-hlog`. Add the local checkout as a path dependency in your consumer module and import it with alias `@hlog`. You can also pin this repository as a Git dependency on MoonBit toolchains that support Git resolution.

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

The interop check uses Java, Python 3 and the checksum-pinned HdrHistogram 2.2.2 JAR. It compares eight summaries against Java and verifies that Java reads every recorded bucket, tag and timestamp from the two rewritten logs. Run [the reviewer walkthrough](docs/REVIEWER_DEMO.md) for the offline demo.

[Implementation plan](docs/PLAN.md) · [项目申报书 PDF](docs/PROPOSAL.pdf) · [申报书 Markdown](docs/PROPOSAL.md)

## License

MoonHlog is MIT-licensed. The interchange format is based on [HdrHistogram](https://github.com/HdrHistogram/HdrHistogram), available under CC0-1.0 or BSD-2-Clause. The Java files under `scripts/` form an independent verification harness. MoonBit's `flate` and `x` dependencies use Apache-2.0.
