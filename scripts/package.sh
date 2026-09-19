#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
architecture="${ARCH:-$(uname -m)}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
stem="OpenInsert-$version-macos-$architecture"
ditto -c -k --sequesterRsrc --keepParent dist/OpenInsert.app "dist/$stem.zip"
mkdir -p dist/dmg-root
ditto dist/OpenInsert.app dist/dmg-root/OpenInsert.app
ln -sfn /Applications dist/dmg-root/Applications
cp LICENSE dist/dmg-root/LICENSE.txt
cp docs/INSTALL.txt dist/dmg-root/INSTALL.txt
hdiutil create -volname OpenInsert -srcfolder dist/dmg-root -ov -format UDZO "dist/$stem.dmg"
rm -rf dist/dmg-root
(cd dist && shasum -a 256 "$stem.zip" "$stem.dmg") > "dist/$stem-SHA256SUMS.txt"
echo "Packaged dist/$stem.zip and dist/$stem.dmg"
