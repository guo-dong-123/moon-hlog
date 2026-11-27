#!/usr/bin/env python3
"""Run MoonHlog and retain JSON and a bounded CI job summary."""

import html
import json
import os
from pathlib import Path
import subprocess
import sys


def metric(histogram, name):
    if histogram is None or histogram[name] is None:
        return "-"
    return str(histogram[name])


def summary(report):
    rows = report.get("rows", [])
    if report["outcome"] == "incomparable":
        units = report["units"]
        return ("## MoonHlog performance gate\n\n"
                f'Outcome **incomparable** ({report["reason"]})\n\n'
                f'Baseline unit: {units["baseline"]} · Candidate unit: {units["candidate"]}\n')
    attention = [row for row in rows if row["outcome"] in ("regression", "insufficient_data")]
    preview = attention[:50] if attention else rows[:50]
    lines = [
        "## MoonHlog performance gate",
        "",
        f'Outcome **{report["outcome"]}** ({report["reason"]})',
        "",
        "| Tag | Relative window (s) | Baseline samples | Candidate samples | Baseline P99 | Candidate P99 | Reason |",
        "| --- | --- | ---: | ---: | ---: | ---: | --- |",
    ]
    for row in preview:
        tag = "(untagged)" if row["tag"] is None else row["tag"]
        tag = html.escape(tag[:120]).replace("|", "&#124;").replace("\t", " ")
        before = row["baseline"]
        after = row["candidate"]
        window = f'[{row["window_start"]}, {row["window_end"]})'
        lines.append(
            f'| <code>{tag}</code> | {window} | {metric(before, "samples")} | '
            f'{metric(after, "samples")} | {metric(before, "p99")} | '
            f'{metric(after, "p99")} | {row["reason"]} |'
        )
    lines.extend(["", f"Shown {len(preview)} of {len(rows)} windows. Download the JSON report for all results.", ""])
    return "\n".join(lines)


def main(args):
    if len(args) < 4:
        print("Usage: run-gate.py HLOG REPORT.json BASELINE.hlog CANDIDATE.hlog [report flags]", file=sys.stderr)
        return 2

    hlog, output, baseline, candidate, *options = args
    try:
        report_path = Path(output)
        if report_path.resolve() in (Path(baseline).resolve(), Path(candidate).resolve(), Path(hlog).resolve()):
            raise ValueError("Report output must be distinct from the inputs and executable")
        if report_path.exists() or report_path.is_symlink():
            raise ValueError("Report output path must be new")
        run = subprocess.run(
            [hlog, "report", baseline, candidate, *options, "--json"],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if run.stderr:
            sys.stderr.write(run.stderr)
        if run.returncode == 2:
            try:
                report = json.loads(run.stdout)
            except ValueError:
                sys.stderr.write(run.stdout)
                return 2
            if not isinstance(report, dict) or report.get("outcome") != "incomparable":
                sys.stderr.write(run.stdout)
                return 2
        elif run.returncode not in (0, 1):
            sys.stderr.write(run.stdout)
            return 2
        else:
            report = json.loads(run.stdout)
        if report["gate_failed"] is not (run.returncode != 0):
            raise ValueError("MoonHlog exit status does not match the report")
        rendered = summary(report)
        with report_path.open("x", encoding="utf-8") as stream:
            stream.write(run.stdout)
        step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if step_summary:
            with open(step_summary, "a", encoding="utf-8") as stream:
                stream.write(rendered)
        else:
            print(rendered)
        return run.returncode
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"MoonHlog example failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
