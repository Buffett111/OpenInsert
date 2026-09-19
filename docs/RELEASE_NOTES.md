OpenInsert 0.2.0 is an early macOS release of an MIT-licensed, Gemini BYOK dictation app.

- Option + Space: hold to dictate or tap to toggle.
- Live ASR with `gemini-3.5-transcribe-live`, matching the model setting observed in Dup 1.20260913.0. See `docs/DUP_MODELS.md` for evidence and limits.
- Optional, text-only `gemini-3.5-flash-lite` cleanup; verbatim mode skips it. If cleanup fails, the finalized ASR result remains available for manual copy and no automatic insertion occurs.
- AVAudioEngine streams raw 16 kHz mono Int16 PCM in roughly 100 ms chunks. Bounded memory buffers fail on overflow; no audio files are created.
- Unfinalized live preview stays separate from the final result and is never inserted.
- Automatic spoken-language detection, custom vocabulary hints, and local Traditional Chinese character conversion with spoken English preserved.
- Focus-aware text insertion, clipboard fallback and guarded clipboard restoration.
- No account service, screen capture, analytics, or persistent transcription history.
- API key in macOS Keychain; your audio goes directly to Google Gemini.

Requires macOS 13+, microphone/Accessibility permissions, and your own compatible Gemini API key. See the repository's validation report for exactly what was tested.

**Upgrade from 0.1:** consent must be granted again because audio now leaves the Mac while recording. The previous default model `gemini-3.8-flash` changes to the cleanup default; other saved custom cleanup models are retained. ASR and cleanup now have separate model settings.

**Known limitation:** input transcripts have no documented ordering barrier with other Live server messages. Completion uses `turnComplete`, no unresolved interim text, and one second without transcript updates, with a 20-second deadline. This heuristic can add delay or miss a sufficiently late segment; it needs real-service validation. The 0.1 batch tests do not establish Live ASR compatibility, latency, or recognition quality.

This early community build is **ad-hoc signed, not Developer ID signed or notarized**. macOS may block downloaded builds. Do not disable Gatekeeper. Users can inspect and build the source; see INSTALL.txt and Apple's official guidance. Compatibility with every editor and successful transcription for every account/model is not guaranteed.
