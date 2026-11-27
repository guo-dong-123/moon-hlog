# Changelog

## 0.3.0 (2026-11-27)

- Add optional sample-count gates to `compare` and `report`, with machine-readable causes for regressions and insufficient evidence.
- Verify a real jHiccup capture against the Java reference and provide a GitHub Actions example with JSON artifacts and a job summary.
- Accept explicit producer units and report incompatible declarations before evaluation.
- Read and aggregate interval logs incrementally, with opt-in selective payload validation and a reproducible memory benchmark.

## 0.2.0 (2026-11-27)

- Add tag and time-window comparison to the public API and CLI, with explicit missing-data and P99 gate outcomes.
- Align equivalent millisecond timestamps across explicit and implicit log time bases.
- Check window results with Java and exercise the packaged API from a separate module on four backends.
- Verify Native CLI installation and provide a Linux release bundle from CI.

## 0.1.0 (2026-11-21)

- Read and write HdrHistogram interval logs with V2 compressed integer frames.
- Aggregate selected intervals and compare latency percentiles from the CLI.
- Verify the library across four MoonBit targets and check interoperability with the Java reference implementation.
