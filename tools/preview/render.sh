#!/bin/zsh
# Renders the widget and popover views with fixture data into PNGs, without running the app.
# Usage: tools/preview/render.sh [out_dir]    (default: tools/preview/out)
set -euo pipefail
tool_dir="${0:A:h}"
repo_dir="${tool_dir:h:h}"
out_dir="${1:-$tool_dir/out}"
mkdir -p "$out_dir"
out_dir="${out_dir:A}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  selected="$(xcode-select -p 2>/dev/null || true)"
  [[ "$selected" == *.app/Contents/Developer ]] && export DEVELOPER_DIR="$selected" \
    || export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# AILimits.swift is left out: it holds the app's @main, and Preview.swift has its own.
sources=("$repo_dir"/Sources/Shared/*.swift(N) "$repo_dir"/Sources/App/*.swift(N))
sources=(${sources:#*/AILimits.swift})
xcrun swiftc -parse-as-library -O -target arm64-apple-macos14.0 \
  -module-cache-path "$out_dir/.module-cache" \
  "$tool_dir/Preview.swift" "${sources[@]}" -o "$out_dir/.preview"
"$out_dir/.preview" "$out_dir"
rm -f "$out_dir/.preview"
print "Rendered: $out_dir"
