#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -x "$1" ]]; then
    echo "Usage: $0 PATH_TO_HLOG_EXECUTABLE [EXTERNAL_LOG.hlog]" >&2
    exit 2
fi
hlog=$1
project_root=$(cd "$(dirname "$0")/.." && pwd)
external_log="$project_root/tests/fixtures/jhiccup-2.0.10.hlog"
if [[ $# -eq 2 ]]; then
    external_log=$2
fi
if [[ ! -f "$external_log" ]]; then
    echo "External log not found: $external_log" >&2
    exit 2
fi
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

jar_sha256=22d1d4316c4ec13a68b559e98c8256d69071593731da96136640f864fa14fad8
jar=${HDRHISTOGRAM_JAR:-"$test_dir/HdrHistogram-2.2.2.jar"}
if [[ -z "${HDRHISTOGRAM_JAR:-}" ]]; then
    curl -fsSL --retry 2 --max-time 60 \
        https://repo.maven.apache.org/maven2/org/hdrhistogram/HdrHistogram/2.2.2/HdrHistogram-2.2.2.jar \
        -o "$jar"
fi
if command -v sha256sum >/dev/null; then
    jar_digest=$(sha256sum < "$jar")
else
    jar_digest=$(shasum -a 256 < "$jar")
fi
if [[ ${jar_digest%% *} != "$jar_sha256" ]]; then
    echo "HdrHistogram 2.2.2 reference JAR checksum mismatch" >&2
    exit 2
fi

javac -cp "$jar" -d "$test_dir" "$project_root/scripts/Oracle.java"
oracle() {
    java -cp "$jar:$test_dir" Oracle "$@"
}

assert_summary() {
    local expected=$1
    shift
    "$hlog" summary "$@" --json > "$test_dir/summary.json"
    python3 - "$expected" "$test_dir/summary.json" <<'PY'
import json
import sys

expected = json.loads(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as result:
    actual = json.load(result)
for key, value in expected.items():
    if type(actual.get(key)) is not int or actual[key] != value:
        raise SystemExit(f"{key}: expected {value}, got {actual.get(key)!r}")
PY
}

expect_exit() {
    local expected=$1
    shift
    local actual=0
    "$@" > "$test_dir/stdout" 2> "$test_dir/stderr" || actual=$?
    if [[ $actual -ne $expected ]]; then
        echo "Expected exit $expected, got $actual for $*" >&2
        cat "$test_dir/stdout" "$test_dir/stderr" >&2
        exit 1
    fi
}

baseline=$project_root/tests/fixtures/baseline.hlog
candidate=$project_root/tests/fixtures/candidate.hlog
oracle generate "$test_dir/fixtures"
for file in "$baseline" "$candidate"; do
    name=${file##*/}
    oracle intervals "$file" > "$test_dir/original-intervals"
    oracle intervals "$test_dir/fixtures/$name" > "$test_dir/generated-intervals"
    diff -u "$test_dir/generated-intervals" "$test_dir/original-intervals"
    assert_summary "$(oracle summary "$file")" "$file"
    assert_summary "$(oracle summary "$file" read)" "$file" --tag read
    assert_summary "$(oracle summary "$file" read 0.25 1.25)" "$file" --tag read --from 0.25 --until 1.25
    assert_summary "$(oracle summary "$file" read 1.25 2.25)" "$file" --tag read --from 1.25 --until 2.25

    rewritten="$test_dir/rewritten-$name"
    "$hlog" rewrite "$file" "$rewritten"
    oracle intervals "$rewritten" > "$test_dir/rewritten-intervals"
    diff -u "$test_dir/original-intervals" "$test_dir/rewritten-intervals"
done

assert_summary "$(oracle summary "$external_log")" "$external_log"
"$hlog" rewrite "$external_log" "$test_dir/rewritten-external.hlog"
oracle intervals "$external_log" > "$test_dir/external-intervals"
oracle intervals "$test_dir/rewritten-external.hlog" > "$test_dir/rewritten-external-intervals"
diff -u "$test_dir/external-intervals" "$test_dir/rewritten-external-intervals"
echo "External log matched Java for the summary and every rewritten interval."

expect_exit 0 "$hlog" compare "$baseline" "$baseline" --tag read --max-p99-increase-pct 0
expect_exit 1 "$hlog" compare "$baseline" "$candidate" --tag read --max-p99-increase-pct 5
printf '0.25,1.000,0.012,not-base64!\n' > "$test_dir/invalid.hlog"
expect_exit 2 "$hlog" summary "$test_dir/invalid.hlog" --json

expect_exit 1 "$hlog" report "$baseline" "$candidate" --window 1 --max-p99-increase-pct 5 --json
cp "$test_dir/stdout" "$test_dir/report.json"
python3 - "$test_dir/report.json" "$jar:$test_dir" "$baseline" "$candidate" <<'REPORT_PY'
import json
import subprocess
import sys
from pathlib import Path

report_path, classpath, baseline, candidate = sys.argv[1:]
report = json.loads(Path(report_path).read_text())
assert report["window_seconds"] == 1 and report["gate_failed"] is True
expected_keys = [("read", 0), ("read", 1), ("write", 2)]
assert [(row["tag"], row["window_start"]) for row in report["rows"]] == expected_keys
for row in report["rows"]:
    assert row["window_end"] == row["window_start"] + 1
    for key, path in (("baseline", baseline), ("candidate", candidate)):
        expected = json.loads(subprocess.check_output(
            ["java", "-cp", classpath, "Oracle", "summary", path, row["tag"],
             str(row["window_start"]), str(row["window_end"])],
            text=True,
        ))
        assert row[key] == expected, (row["tag"], row["window_start"], key, row[key], expected)
assert [row["status"] for row in report["rows"]] == ["regression", "regression", "compared"]
REPORT_PY
expect_exit 0 "$hlog" report "$baseline" "$baseline" --window 1 --max-p99-increase-pct 0 --json

# Omit the candidate write interval to verify that the gate fails on missing samples.
awk '!/^Tag=write,/' "$candidate" > "$test_dir/missing.hlog"
expect_exit 1 "$hlog" report "$baseline" "$test_dir/missing.hlog" --window 1 --max-p99-increase-pct 5 --json
python3 - "$test_dir/stdout" <<'MISSING_PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
assert report["rows"][-1]["status"] == "missing_candidate_samples"
assert report["rows"][-1]["candidate"] is None
MISSING_PY
expect_exit 2 "$hlog" report "$baseline" "$candidate" --window 0
expect_exit 2 "$hlog" report "$baseline" "$candidate" --window 1 --tag absent
expect_exit 2 "$hlog" report "$baseline" "$candidate"

# Represent the same 0.300 s interval on either side of a decimal window boundary.
awk '/^#|^"StartTimestamp"/ { print } /^Tag=read,10\.250,/ { sub(/10\.250,/, "10.300,"); print }' \
    "$baseline" > "$test_dir/anchored.hlog"
sed '/^#\[BaseTime:/d; s/Tag=read,10\.300,/Tag=read,0.300,/' \
    "$test_dir/anchored.hlog" > "$test_dir/relative.hlog"
expect_exit 0 "$hlog" report "$test_dir/relative.hlog" "$test_dir/anchored.hlog" \
    --window 0.1 --max-p99-increase-pct 0 --json
python3 - "$test_dir/stdout" <<'TIME_PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
row, = report["rows"]
assert (row["window_start"], row["window_end"]) == (0.3, 0.4)
assert row["status"] == "compared" and report["gate_failed"] is False
TIME_PY

python3 - "$hlog" "$baseline" "$candidate" "$test_dir" "$project_root" <<'GATE_PY'
import json
import os
import subprocess
import sys
from pathlib import Path

hlog, baseline, candidate, test_dir, project_root = sys.argv[1:]
test_dir = Path(test_dir)


def check(code, command, options, *, before=baseline, after=candidate):
    result = subprocess.run(
        [hlog, command, str(before), str(after), *options, "--json"],
        capture_output=True, text=True,
    )
    assert result.returncode == code, (result.args, result.returncode, result.stdout, result.stderr)
    if code != 2:
        data = json.loads(result.stdout)
        assert data["gate_failed"] is (code == 1), data
        return data


minimum = ["--min-samples", "100"]
p99_limit = ["--max-p99-increase-pct", "5"]
write_tag = ["--tag", "write"]
window = ["--window", "1"]

for command, extra in (("compare", []), ("report", window)):
    opts = extra + write_tag
    existing = check(0, command, opts + p99_limit)
    assert existing["outcome"] == "pass" and existing["min_samples"] is None
    result = check(1, command, opts + minimum + p99_limit)
    row = result["rows"][0] if command == "report" else result
    assert result["outcome"] == row["outcome"] == "insufficient_data"
    assert row["reason"] == "below_min_samples" and result["min_samples"] == 100
    assert row["baseline"]["samples"] == row["candidate"]["samples"] == 30
    assert row["p99_increase_pct"] == 0
    if command == "compare":
        assert row["threshold_exceeded"] is False

    exact = check(0, command, opts + ["--min-samples", "30"])
    assert exact["outcome"] == "pass"
    descriptive = check(0, command, opts)
    assert descriptive["outcome"] == "not_evaluated"

    missing = check(1, command, opts + minimum, after=test_dir / "missing.hlog")
    missing_row = missing["rows"][0] if command == "report" else missing
    assert missing_row["reason"] == "missing_candidate_samples" and missing_row["candidate"] is None

    empty = check(1, command, extra + ["--tag", "absent"] + minimum)
    assert empty["outcome"] == "insufficient_data"
    if command == "report":
        assert empty["reason"] == "no_matching_intervals" and empty["rows"] == []
    else:
        assert empty["reason"] == "no_samples" and empty["baseline"] is empty["candidate"] is None

    for value in ("0", "-1", "1.5", "9223372036854775808"):
        check(2, command, extra + ["--min-samples", value])
    check(2, command, extra + minimum, after=test_dir / "invalid.hlog")

regression = check(1, "compare", ["--tag", "read"] + minimum + p99_limit)
assert regression["outcome"] == "regression" and regression["reason"] == "p99_threshold_exceeded"
assert regression["threshold_exceeded"] is True

below_minimum = check(1, "compare", ["--tag", "read", "--min-samples", "1101"] + p99_limit)
assert below_minimum["reason"] == "below_min_samples" and below_minimum["threshold_exceeded"] is False
assert below_minimum["p99_increase_pct"] > 5

mixed = check(1, "report", window + minimum + p99_limit)
assert mixed["outcome"] == "regression" and mixed["reason"] == "window_regression"
assert [row["outcome"] for row in mixed["rows"]] == ["regression", "regression", "insufficient_data"]

zero = check(
    1, "compare", ["--tag", "read", "--until", "1"] + minimum + p99_limit,
    before=test_dir / "fixtures" / "zero.hlog",
)
assert zero["outcome"] == "regression" and zero["baseline"]["p99"] == 0
assert zero["p99_increase_pct"] is None

check(2, "compare", write_tag, after=test_dir / "missing.hlog")
rejected = subprocess.run(
    [hlog, "summary", baseline, "--min-samples", "30"],
    capture_output=True, text=True,
)
assert rejected.returncode == 2

example = Path(project_root) / "examples" / "github-actions" / "run-gate.py"
for code, outcome, compared, tag, reason in (
    (0, "pass", baseline, "read", "thresholds_met"),
    (1, "regression", candidate, "read", "p99_threshold_exceeded"),
    (1, "insufficient_data", candidate, "write", "below_min_samples"),
):
    result_json = test_dir / f"ci-{outcome}.json"
    result_summary = test_dir / f"ci-{outcome}.md"
    cmd = [sys.executable, str(example), hlog, str(result_json), baseline, compared,
           *window, "--tag", tag, *minimum, *p99_limit]
    run = subprocess.run(cmd, env={**os.environ, "GITHUB_STEP_SUMMARY": str(result_summary)},
                         capture_output=True, text=True)
    assert run.returncode == code, (cmd, run.returncode, run.stdout, run.stderr)
    assert json.loads(result_json.read_text())["outcome"] == outcome
    markdown = result_summary.read_text()
    assert f"Outcome **{outcome}**" in markdown and reason in markdown

invalid_report = test_dir / "ci-invalid.json"
invalid = subprocess.run(
    [sys.executable, str(example), hlog, str(invalid_report), baseline,
     str(test_dir / "invalid.hlog"), *window],
    capture_output=True, text=True,
)
assert invalid.returncode == 2 and not invalid_report.exists()

unit_report = test_dir / "ci-unit-mismatch.json"
unit_summary = test_dir / "ci-unit-mismatch.md"
unit = subprocess.run(
    [sys.executable, str(example), hlog, str(unit_report), baseline, candidate, *window,
     "--baseline-unit", "ns", "--candidate-unit", "ms"],
    env={**os.environ, "GITHUB_STEP_SUMMARY": str(unit_summary)}, capture_output=True, text=True,
)
assert unit.returncode == 2
assert json.loads(unit_report.read_text())["reason"] == "unit_mismatch"
assert "unit_mismatch" in unit_summary.read_text()
GATE_PY

python3 - "$hlog" "$baseline" "$candidate" "$test_dir" <<'STREAM_PY'
import json
import subprocess
import sys
from pathlib import Path

hlog, baseline, candidate, directory = sys.argv[1:]
directory = Path(directory)

def invoke(code, *args):
    run = subprocess.run([hlog, *map(str, args), "--json"], capture_output=True, text=True)
    assert run.returncode == code, (run.args, run.returncode, run.stdout, run.stderr)
    return run.stdout if code == 2 and not run.stdout.startswith("{") else json.loads(run.stdout)

for command, extra in (("compare", []), ("report", ["--window", "1"])):
    equal = invoke(0, command, baseline, candidate, *extra, "--baseline-unit", "ns",
                   "--candidate-unit", "ns")
    assert equal["units"] == {"baseline": "ns", "candidate": "ns"}
    mismatch = invoke(2, command, baseline, candidate, *extra, "--baseline-unit", "ns",
                      "--candidate-unit", "ms")
    assert mismatch == {"gate_failed": True, "outcome": "incomparable", "reason": "unit_mismatch",
                        "units": {"baseline": "ns", "candidate": "ms"}}
    invoke(2, command, baseline, candidate, *extra, "--baseline-unit", "ns")
    invoke(2, command, baseline, candidate, *extra, "--baseline-unit", "ticks",
           "--candidate-unit", "ticks")

source = Path(baseline).read_text().splitlines()
headers = [line for line in source if not line.startswith("Tag=")]
data = [line for line in source if line.startswith("Tag=")]
# A large comment, CRLF, out-of-order intervals and no final newline exercise the reader.
# The first data interval still uses the original explicit time origin.
reordered = directory / "reordered.hlog"
reordered.write_bytes(("\r\n".join(headers + ["#" + "x" * 100000] + list(reversed(data)))).encode())
for command, extra in (("compare", []), ("report", ["--window", "1"])):
    opts = ["--tag", "read", *extra, "--max-p99-increase-pct", "0"]
    original = invoke(0, command, baseline, baseline, *opts)
    assert invoke(0, command, baseline, reordered, *opts) == original
    selective = invoke(0, command, baseline, reordered, *opts, "--selected-only")
    validation = selective.pop("validation")
    assert selective == original
    assert validation == {"mode": "selected_only",
                          "baseline": {"checked_payloads": 2, "skipped_payloads": 1},
                          "candidate": {"checked_payloads": 2, "skipped_payloads": 1}}

# Only the payload of the non-selected write interval is malformed.
bad = directory / "unselected-corrupt.hlog"
bad.write_text("\n".join(headers + data[:2] + [data[2].rsplit(",", 1)[0] + ",?"]) + "\n")
strict = invoke(2, "summary", bad, "--tag", "read")
assert isinstance(strict, str) and "line " + str(len(headers) + 3) in strict and "invalid base64" in strict
expected = invoke(0, "summary", baseline, "--tag", "read")
fast = invoke(0, "summary", bad, "--tag", "read", "--selected-only")
assert fast.pop("validation") == {"checked_payloads": 2, "skipped_payloads": 1}
assert fast == expected
assert isinstance(invoke(2, "summary", bad, "--tag", "write", "--selected-only"), str)
STREAM_PY

echo "HdrHistogram Java interoperability and CLI gate contract passed."
