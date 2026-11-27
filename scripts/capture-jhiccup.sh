#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -e "$1" || -L "$1" ]]; then
    echo "Usage: $0 NEW_OUTPUT.hlog" >&2
    exit 2
fi

capture_dir=$(mktemp -d)
trap 'rm -rf -- "$capture_dir"' EXIT
archive="$capture_dir/jHiccup-2.0.10-dist.zip"
expected_digest=7bb1145d211d140b4f81184df7eb9cea90f56720ad7504fac43c0c398f38a7d8
curl -fsSL --retry 2 --max-time 60 \
    https://www.azul.com/wp-content/uploads/jHiccup-2.0.10-dist.zip -o "$archive"
if command -v sha256sum >/dev/null; then
    digest=$(sha256sum < "$archive")
else
    digest=$(shasum -a 256 < "$archive")
fi
if [[ ${digest%% *} != "$expected_digest" ]]; then
    echo "jHiccup 2.0.10 archive checksum mismatch" >&2
    exit 2
fi

unzip -p "$archive" jHiccup-2.0.10/jHiccup.jar > "$capture_dir/jHiccup.jar"
java -jar "$capture_dir/jHiccup.jar" -d 0 -i 1000 -t 3500 -l "$capture_dir/capture.hlog"
if ! [[ -s "$capture_dir/capture.hlog" ]] || ! awk '
    !/^#/ && !/^"StartTimestamp"/ && NF { found = 1 }
    END { exit !found }
' "$capture_dir/capture.hlog"; then
    echo "jHiccup produced no histogram intervals" >&2
    exit 2
fi
cp "$capture_dir/capture.hlog" "$1"
printf 'Captured jHiccup 2.0.10 platform latency (nanoseconds) in %s\n' "$1"
