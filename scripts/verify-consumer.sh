#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo "Usage: $0 PATH_TO_MOON_PACKAGE_ZIP" >&2
    exit 2
fi
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
project_root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

# Use only the packaged library and an independent consumer module.
mkdir -p "$test_dir/library" "$test_dir/consumer" "$test_dir/bin"
unzip -q "$archive" -d "$test_dir/library"
cp "$project_root"/examples/consumer/{moon.mod,moon.pkg,api.mbt,api_test.mbt} "$test_dir/consumer/"
(
    cd "$test_dir"
    moon work init library consumer
    cd consumer
    moon test --target all --deny-warn
)
moon install "$test_dir/library/cmd/hlog" --bin "$test_dir/bin"
binary="$test_dir/bin/hlog"
if [[ ! -x "$binary" && -x "$binary.exe" ]]; then
    binary="$binary.exe"
fi
"$binary" summary "$test_dir/library/tests/fixtures/baseline.hlog" --tag read --json > "$test_dir/summary.json"
python3 - "$test_dir/summary.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    summary = json.load(stream)
assert summary["samples"] == 1100
assert summary["p99"] == 10007
PY

echo "Independent module import on four targets and installed CLI verified."
