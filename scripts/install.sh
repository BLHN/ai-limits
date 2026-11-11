#!/bin/zsh
# Installs a built "AI Limits.app" into ~/Applications and opens it.
# Usage: scripts/install.sh [build_dir]    (default: ./build next to build.sh)
set -euo pipefail
repo_dir="${0:A:h:h}"
build_dir="${1:-$repo_dir/build}"
source_app="${build_dir:A}/AI Limits.app"
target_dir="$HOME/Applications"
target_app="$target_dir/AI Limits.app"

if [[ ! -d "$source_app" ]]; then
  print -u2 "error: $source_app not found. Run ./build.sh first."
  exit 1
fi
bundle_id="$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")"

# Ask a running copy to quit through Apple Events so it can save state; never force-kill it.
if pgrep -xq AILimits; then
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -xq AILimits || break
    sleep 0.25
  done
  if pgrep -xq AILimits; then
    print -u2 "error: AI Limits is still running. Quit it from the menu bar and run this again."
    exit 1
  fi
fi

mkdir -p "$target_dir"
rm -rf "$target_app"
ditto "$source_app" "$target_app"
codesign --verify --deep --strict "$target_app"
open "$target_app"
print "Installed: $target_app"
