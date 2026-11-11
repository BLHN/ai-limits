#!/bin/zsh
# Builds "AI Limits.app" (menu bar app + WidgetKit extension).
# Usage: ./build.sh [build_dir]            (default: ./build)
# Env:   AI_LIMITS_BUNDLE_ID      app bundle id, default "local.ai-limits"; the widget gets "<id>.widget"
#        AI_LIMITS_SIGN_IDENTITY  codesign identity, default "-" (ad-hoc)
#        DEVELOPER_DIR            Xcode to use, default: the selected one, else /Applications/Xcode.app
set -euo pipefail
source_dir="${0:A:h}"
build_dir="${1:-$source_dir/build}"
bundle_id="${AI_LIMITS_BUNDLE_ID:-local.ai-limits}"
sign_identity="${AI_LIMITS_SIGN_IDENTITY:--}"

# The widget needs xcodebuild and the full macOS SDK; Command Line Tools alone are not enough.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  selected="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$selected" == *.app/Contents/Developer ]]; then
    export DEVELOPER_DIR="$selected"
  else
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
fi
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  print -u2 "error: Xcode not found at $DEVELOPER_DIR. Install Xcode 16+ or set DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer."
  exit 1
fi

mkdir -p "$build_dir"
build_dir="${build_dir:A}"

# Host binary: every file under Sources/Shared and Sources/App. The widget target in
# AILimitsWidget.xcodeproj lists its files explicitly, so a new Sources/Shared file must
# also be added there (PBXFileReference + PBXBuildFile + Sources phase).
host_sources=("$source_dir"/Sources/Shared/*.swift(N) "$source_dir"/Sources/App/*.swift(N))
xcrun swiftc -parse-as-library -O -target arm64-apple-macos14.0 \
  -module-cache-path "$build_dir/module-cache" \
  "${host_sources[@]}" -o "$build_dir/AILimits"
"$build_dir/AILimits" --self-test

xcodebuild -quiet -project "$source_dir/AILimitsWidget.xcodeproj" \
  -target AILimitsWidget -configuration Release -sdk macosx \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id.widget" \
  SYMROOT="$build_dir/xcode" OBJROOT="$build_dir/xcode/obj" \
  CONFIGURATION_BUILD_DIR="$build_dir/widget" build

app_bundle="$build_dir/AI Limits.app"
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/PlugIns"
cp "$build_dir/AILimits" "$app_bundle/Contents/MacOS/AILimits"
cp "$source_dir/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$app_bundle/Contents/Info.plist"
ditto "$build_dir/widget/AILimitsWidget.appex" "$app_bundle/Contents/PlugIns/AILimitsWidget.appex"
codesign --force --sign "$sign_identity" --timestamp=none --entitlements "$source_dir/Resources/Widget.entitlements" \
  "$app_bundle/Contents/PlugIns/AILimitsWidget.appex"
codesign --force --sign "$sign_identity" --timestamp=none "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

print "Built: $app_bundle (install: scripts/install.sh \"$build_dir\"). The widget may need a real Apple Development identity: AI_LIMITS_SIGN_IDENTITY=\"Apple Development: ...\" ./build.sh"
