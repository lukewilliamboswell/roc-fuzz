#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dependencies="$root/scripts/workspace-deps.json"
compiler="${CXX:-clang++}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

version="$(jq -er '.libfuzzer.version' "$dependencies")"
url="$(jq -er '.libfuzzer.url' "$dependencies")"
expected_sha256="$(jq -er '.libfuzzer.sha256' "$dependencies")"
archive="$work/libfuzzer-sys.crate"

curl --fail --location --silent --show-error --output "$archive" "$url"
printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum --check --status
tar -xzf "$archive" -C "$work"

source_dir="$work/libfuzzer-sys-$version/libfuzzer"
test -f "$source_dir/FuzzerMain.cpp"

"$compiler" \
  -std=c++17 \
  -O1 \
  -g \
  -fno-omit-frame-pointer \
  -fsanitize=address \
  "$source_dir"/Fuzzer*.cpp \
  "$root/tests/native/libfuzzer_smoke.cpp" \
  -o "$work/libfuzzer-sanitizer-smoke"

mkdir "$work/corpus"
printf 'roc-fuzz\0native\377' > "$work/corpus/seed"

ASAN_OPTIONS='detect_leaks=1:halt_on_error=1:strict_string_checks=1' \
  "$work/libfuzzer-sanitizer-smoke" \
  -runs=1000 \
  -max_len=4096 \
  "$work/corpus"
