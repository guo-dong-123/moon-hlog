#!/usr/bin/env python3
"""Compare full and selective readers on the same deterministic valid HdrHistogram input."""

import argparse
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile


def measure(executable, args):
    result = subprocess.run(
        ["/usr/bin/time", "-l", str(executable), *args],
        check=True, capture_output=True, text=True,
    )
    seconds = float(re.search(r"([0-9.]+) real", result.stderr).group(1))
    rss = int(re.search(r"([0-9]+)  maximum resident set size", result.stderr).group(1))
    return json.loads(result.stdout), seconds, rss / 1048576


def comparable_fields(report):
    fields = ("tag", "window_start", "window_end", "baseline", "candidate",
              "p99_increase_pct", "status")
    return {
        "window_seconds": report["window_seconds"],
        "gate_failed": report["gate_failed"],
        "rows": [{field: row[field] for field in fields} for row in report["rows"]],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--rows", type=int, nargs="+", default=[2000, 20000, 100000])
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("this benchmark uses macOS /usr/bin/time -l")
    if min(args.rows + [args.repeats]) < 1:
        parser.error("row counts and repeats must be positive")
    before = args.before.resolve()
    after = args.after.resolve()
    fixture = Path(__file__).resolve().parents[1] / "tests/fixtures/candidate.hlog"
    payload = next(row.rsplit(",", 1)[1] for row in fixture.read_text().splitlines()
                   if row.startswith("Tag=read,"))
    architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
    print(f"macOS {platform.mac_ver()[0]} / {architecture}")
    with tempfile.TemporaryDirectory(prefix="moonhlog-stream-") as folder:
        for count in args.rows:
            logfile = Path(folder) / f"{count}.hlog"
            with logfile.open("w") as stream:
                for index in range(count):
                    stream.write(f"Tag=read,{index}.25,1.0,0.012,{payload}\n")
            command = ["report", str(logfile), str(logfile), "--window", "1",
                       "--from", "0", "--until", "1", "--json"]
            expected = None
            print(f"{count} rows, {logfile.stat().st_size} bytes per file", flush=True)
            for name, binary, extra in (
                ("before", before, []),
                ("stream-strict", after, []),
                ("stream-selected", after, ["--selected-only"]),
            ):
                durations, memory = [], []
                for _ in range(args.repeats):
                    report, seconds, rss = measure(binary, command + extra)
                    if extra:
                        stats = report.pop("validation")
                        if stats["baseline"] != {
                            "checked_payloads": 1, "skipped_payloads": count - 1
                        } or stats["candidate"] != stats["baseline"]:
                            raise AssertionError(stats)
                    comparable = comparable_fields(report)
                    if expected is None:
                        expected = comparable
                    if comparable != expected:
                        raise AssertionError(f"{name} changed the statistical result")
                    durations.append(seconds)
                    memory.append(rss)
                print(f"{name}: {statistics.median(durations):.2f} s, "
                      f"{statistics.median(memory):.2f} MiB median peak RSS", flush=True)


if __name__ == "__main__":
    main()
