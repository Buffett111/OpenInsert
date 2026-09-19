#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Set DEVELOPER_DIR explicitly if you use standalone Command Line Tools.
configuration="${CONFIGURATION:-release}"
architecture="${ARCH:-$(uname -m)}"
case "$architecture" in arm64|x86_64|universal) ;; *) echo "ARCH must be arm64, x86_64, or universal" >&2; exit 1;; esac
mkdir -p .build/module-cache .build/cache dist
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
build_flags=(--cache-path .build/cache)
if [ "${SWIFTPM_DISABLE_SANDBOX:-0}" = 1 ]; then build_flags+=(--disable-sandbox); fi

build_arch() {
  swift build --configuration "$configuration" --arch "$1" "${build_flags[@]}"
  binary_dir=$(swift build --configuration "$configuration" --arch "$1" --show-bin-path "${build_flags[@]}")
  cp "$binary_dir/OpenInsert" ".build/OpenInsert-$1"
}
if [ "$architecture" = universal ]; then
  build_arch arm64
  build_arch x86_64
else
  build_arch "$architecture"
fi

# Keep the working bundle out of the public artifact directory and ordinary
# Spotlight discovery. Install and launch the copy in /Applications for use.
app=".build/app-staging.noindex/OpenInsert.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [ "$architecture" = universal ]; then
  lipo -create .build/OpenInsert-arm64 .build/OpenInsert-x86_64 -output "$app/Contents/MacOS/OpenInsert"
else
  cp ".build/OpenInsert-$architecture" "$app/Contents/MacOS/OpenInsert"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
swift scripts/make-icon.swift
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
identity="${CODE_SIGN_IDENTITY:-}"
# Optional machine-local certificate fingerprint; never source a shell file or
# commit a developer's signing identity. CI remains ad-hoc unless configured.
if [ -z "$identity" ] && [ -f .local-signing-identity ]; then
  IFS= read -r identity < .local-signing-identity
fi
identity="${identity:--}"
if [ "$identity" = - ]; then
  codesign --force --sign - --entitlements Resources/OpenInsert.entitlements "$app"
else
  codesign --force --options runtime --timestamp --sign "$identity" --entitlements Resources/OpenInsert.entitlements "$app"
fi
codesign --verify --deep --strict "$app"
echo "Built $PWD/$app ($architecture)."
