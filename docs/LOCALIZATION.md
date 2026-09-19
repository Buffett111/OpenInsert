# Interface localization

OpenInsert uses Swift Package Manager localized resources and Foundation bundles. The app's interface language is an explicit, persisted preference. It is independent of spoken language detection, writing-language preferences, vocabulary and transcript content; switching the interface never translates a dictation or changes an ASR request.

Translations live in `Sources/OpenInsertCore/Resources/<language>.lproj/*.strings`. `AppLocalizer` loads the selected language explicitly and falls back to English for a missing translation. Views, the floating panel, status messages and app menu use semantic keys through the same API; do not put language-selection branches into views.

To add a language:

1. Add a language case and its native display name to `InterfaceLanguage`.
2. Copy the English `.lproj` folder to the new language identifier and translate every table, keeping the keys unchanged.
3. Preserve all format placeholders and their types, such as `%@`, `%d` and `%.2f`. Do not translate model identifiers, keyboard symbols or diagnostic codes.
4. Add a matching `Resources/<language>.lproj/InfoPlist.strings` for the system microphone prompt and register the language in `Resources/Info.plist`.
5. Run `swift test` to check resource parity and formatting. Build the app, move a copy away from the checkout and verify that the selected language still loads. `scripts/build-app.sh` includes the Swift package resource bundle inside the app before signing.
6. Inspect every page, error/copy notices, the shortcut recorder and the floating panel in the new language. Check narrow layouts and long translations, then switch languages without restarting.

macOS-owned permission dialogs use the system's localization rules. OpenInsert does not change the global `AppleLanguages` preference. User-entered vocabulary, provider model IDs and transcript text are not translation resources.

Official references: [Localizing package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources) and [Bundling resources with a Swift package](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package).
