#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
architecture="${ARCH:-$(uname -m)}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
stem="OpenInsert-$version-macos-$architecture"
app=".build/app-staging.noindex/OpenInsert.app"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/$stem.zip"
mkdir -p .build/dmg-staging.noindex
dmg_root=$(mktemp -d "$PWD/.build/dmg-staging.noindex/dmg-root.XXXXXX")
trap 'rm -rf "$dmg_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$app" "$dmg_root/OpenInsert.app"
ln -sfn /Applications "$dmg_root/Applications"
cp LICENSE "$dmg_root/LICENSE.txt"
cp docs/INSTALL.txt "$dmg_root/INSTALL.txt"
hdiutil create -volname OpenInsert -srcfolder "$dmg_root" -ov -format UDZO "dist/$stem.dmg"
(cd dist && shasum -a 256 "$stem.zip" "$stem.dmg") > "dist/$stem-SHA256SUMS.txt"
echo "Packaged dist/$stem.zip and dist/$stem.dmg"
