#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -x "$1" ]]; then
    echo "Usage: $0 PATH_TO_HLOG_EXECUTABLE" >&2
    exit 2
fi
hlog=$1
project_root=$(cd "$(dirname "$0")/.." && pwd)
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

echo "HdrHistogram Java interoperability passed for summaries, rewrites, window reports, and exit codes."
