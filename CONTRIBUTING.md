# Contributing

Use macOS 13+, Swift 5.9+ and Xcode with XCTest. Run `swift test` and `./scripts/build-app.sh` before submitting changes. Keep provider logic in OpenInsertCore and macOS integration in Services. Do not add a telemetry SDK, account backend, screen reading, or dependencies without discussing the product/privacy impact.

For insertion changes, test a disposable native text document and a browser textarea, verify selected-text replacement and clipboard preservation, then verify a focus change prevents stale insertion. Record the exact OS and app version. Keep accessibility, API fakes, real audio transcription, and human speech tests distinct. A fake response is not a live Gemini verification.

For API changes, add cases for success and failure, blocked/truncated responses, empty speech, cancellation, secrets in error bodies, and request/response limits. Never commit keys or private audio. Use synthetic public fixtures only. Issue reports should omit credentials, transcripts, clipboard data, and screenshots of private documents.

Submit pull requests with the behavior changed, why, and verification results. Contributions are licensed under this repository's MIT License.
