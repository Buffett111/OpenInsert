# Releasing OpenInsert

1. Update Info.plist version/build, README, validation report and release notes. Use a clean checkout.
2. Run `swift test`. Exercise real microphone capture, a real Gemini key and mixed-language speech. Verify no-speech, cancellation, focus changes and permission denial. Update the cross-app matrix; do not mark untested cases as passed.
3. Build `ARCH=universal ./scripts/package.sh`. The working app is `.build/app-staging.noindex/OpenInsert.app`; public ZIP, DMG and checksum files remain in `dist`. DMG staging uses a unique temporary directory under `.build` and is cleaned on exit. Check `lipo -archs`, Info.plist, archive contents and checksums. Intel cross-compilation is not equivalent to an Intel runtime test.
4. For a normal public installer, use **Developer ID Application** signing with hardened runtime. Apple Development or ad-hoc signing is not equivalent. Never put certificates/passwords in the repository.
5. Submit the signed zip using `xcrun notarytool submit <archive.zip> --keychain-profile <profile> --wait`. The maintainer must configure this profile and accept any Apple agreements themselves.
6. After acceptance, staple with `xcrun stapler staple .build/app-staging.noindex/OpenInsert.app`, regenerate the zip/DMG and checksums from that stapled bundle, and notarize/staple the DMG as appropriate. Do not rerun `build-app.sh` or `package.sh` for this archive regeneration: both rebuild and replace the stapled app. Verify with `codesign --verify --deep --strict`, `xcrun stapler validate`, and `spctl --assess --type execute` on the final app. Test a genuinely downloaded artifact on a clean Mac.
7. Publish the draft release only with accurate signing and validation status. The current workflow intentionally makes a draft, ad-hoc-signed early release; it is not a notarization pipeline.

Official guidance: [Apple code signing](https://developer.apple.com/documentation/security/code-signing-services), [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Gatekeeper](https://support.apple.com/en-us/102445).
