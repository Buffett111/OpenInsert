# Contributing

OpenInsert is a multilingual dictation app with code-switching support. Product copy should describe multilingual use, and contributions should preserve the languages a speaker uses. Writing-language preferences control orthography, not translation; keep existing user preferences intact.

For interface translations, use the shared localization resources and follow [the localization guide](docs/LOCALIZATION.md). Keep language-file keys and format placeholders consistent. Interface language must not alter recognition or writing preferences.

Use macOS 13+, Swift 5.9+ and Xcode with XCTest. Run `swift test` and `./scripts/build-app.sh` before submitting changes. Keep provider logic in OpenInsertCore and macOS integration in Services. Do not add a telemetry SDK, account backend, screen reading, or dependencies without discussing the product/privacy impact.

For insertion changes, test a disposable native text document and a browser textarea, verify selected-text replacement and clipboard preservation, then verify a focus change prevents stale insertion. Also test the intentional persistent-copy fallback for a missing target or eligible pre-dispatch error, no second clipboard mutation after ownership/read/write errors, and no copy for cancellation, unfinalized output, unknown or unhandled provider errors, or a dispatched paste. The fixed-text five-second test can exercise delivery without microphone or API calls. Record the exact OS and app version. Keep accessibility, API fakes, real audio transcription, and human speech tests distinct. A fake response is not a live Gemini verification.

For accessibility initialization, record actual capability results and bundle metadata rather than inferring a framework from the app's display name. Keep `AXManualAccessibility` capability checks separate from the narrow `NSPrincipalClass = BrowserCrApplication` fallback. Test one activation attempt per process launch, preparation timing, PID changes, and unsupported/error paths without reading input contents. Enabling an AX flag or receiving a successful API return does not prove that the focused field is available or that pasted text appeared. See [architecture](docs/ARCHITECTURE.md) for the upstream Chromium evidence and limitations.

For API changes, add cases for success and failure, blocked/truncated responses, empty speech, cancellation, secrets in error bodies, and request/response limits. Never commit keys or private audio. Use synthetic public fixtures only. Issue reports should omit credentials, transcripts, clipboard data, and screenshots of private documents.

Submit pull requests with the behavior changed, why, and verification results. Contributions are licensed under this repository's MIT License.
