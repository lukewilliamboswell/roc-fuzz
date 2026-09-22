#!/usr/bin/env bash
set -euo pipefail

: "${RELEASE_VERSION:?RELEASE_VERSION is required}"
: "${RELEASE_NOTES_PATH:?RELEASE_NOTES_PATH is required}"
: "${RELEASE_BUNDLES_PATH:?RELEASE_BUNDLES_PATH is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

source_path="docs/releases/$RELEASE_VERSION.adoc"
if [[ ! -s "$source_path" ]]; then
  echo "Missing release notes: $source_path" >&2
  exit 1
fi

if [[ "$(head -n 1 "$source_path")" != "= roc-fuzz $RELEASE_VERSION" ]]; then
  echo "Release note title must be: = roc-fuzz $RELEASE_VERSION" >&2
  exit 1
fi

if [[ "$(jq 'length' "$RELEASE_BUNDLES_PATH")" -ne 1 ]]; then
  echo "Expected exactly one release bundle in $RELEASE_BUNDLES_PATH" >&2
  exit 1
fi

artifact_file="$(jq -er '.[0].artifact_file' "$RELEASE_BUNDLES_PATH")"
release_root="https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_VERSION"
platform_url="$release_root/$artifact_file"
manual_url="$release_root/roc-fuzz-$RELEASE_VERSION.pdf"

# GitHub release descriptions are Markdown. Release notes are kept in AsciiDoc
# with the rest of the documentation, so translate the small syntax subset used
# by release notes and resolve URLs which only become known after packaging.
awk -v platform_url="$platform_url" -v manual_url="$manual_url" '
  function resolve(line) {
    gsub(/\{platform-url\}/, platform_url, line)
    gsub(/\{manual-url\}/, manual_url, line)
    return line
  }
  /^= /  { print "# " resolve(substr($0, 3)); next }
  /^== / { print "## " resolve(substr($0, 4)); next }
  /^\[source,[^]]+\]$/ {
    language = $0
    sub(/^\[source,/, "", language)
    sub(/\]$/, "", language)
    getline
    if ($0 != "----") {
      print "Expected ---- after source block declaration" > "/dev/stderr"
      exit 1
    }
    print "```" language
    in_source = 1
    next
  }
  in_source && /^----$/ { print "```"; in_source = 0; next }
  { print resolve($0) }
  END {
    if (in_source) {
      print "Unclosed source block" > "/dev/stderr"
      exit 1
    }
  }
' "$source_path" > "$RELEASE_NOTES_PATH"

if grep -Eq '\{(platform|manual)-url\}' "$RELEASE_NOTES_PATH"; then
  echo "Release notes contain an unresolved release URL" >&2
  exit 1
fi
