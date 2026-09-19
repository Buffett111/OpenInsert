OpenInsert 0.1.0 is an early macOS release of an MIT-licensed, Gemini BYOK dictation app.

- Option + Space: hold to dictate or tap to toggle.
- Traditional Chinese with spoken English preserved, vocabulary hints, verbatim or conservative cleanup.
- Focus-aware text insertion, clipboard fallback and guarded clipboard restoration.
- No account service, screen capture, analytics, or persistent transcription history.
- API key in macOS Keychain; your audio goes directly to Google Gemini.

Requires macOS 13+, microphone/Accessibility permissions, and your own compatible Gemini API key. See the repository's validation report for exactly what was tested.

This early community build is **ad-hoc signed, not Developer ID signed or notarized**. macOS may block downloaded builds. Do not disable Gatekeeper. Users can inspect and build the source; see INSTALL.txt and Apple's official guidance. Compatibility with every editor and successful transcription for every account/model is not guaranteed.
