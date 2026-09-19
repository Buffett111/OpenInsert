OpenInsert 0.2.4 changes text insertion to use standard clipboard paste.

The previous build could report a successful Accessibility text write while the desktop chat editor showed no text. The user reported that TextEdit accepted that path; success there did not establish compatibility with the other editor. This release removes the direct `AXSelectedText` write and requests **Command-V once** for every validated input target.

- Keeps the original app, focused element, editable-role, selection-range and secure-field checks. A selected-text capability check remains metadata only; it does not read or write selected text.
- Keeps all readable clipboard formats in memory for restoration when enabled. After 800 ms, the app restores them only if it still owns the clipboard version. It preserves clipboard content copied by the user during the wait.
- Reports **paste requested**, without claiming an OS delivery receipt. It does not follow a paste with an AX write or automatic second paste.

The user confirmed that the fixed insertion test now displays text in the affected **ChatGPT/Codex desktop input** on macOS 27. This is a manual result for that target; it does not establish compatibility with every editor or validate all dictation modes. Check the destination before copying or retrying manually. Slow editors can read the clipboard after the fixed restore interval, and some apps reject synthesized paste. Known terminal apps still reject multiline/tab insertion; embedded terminals may not be recognized. OpenInsert never synthesizes Return, but destination apps can react to pasted text under their own rules.

Gemini ASR, optional text cleanup, shortcuts, cloud consent and storage behavior are unchanged from 0.2.3. No surrounding text or clipboard content is sent to Google. Every automatic insertion now uses the system clipboard, so clipboard managers and system clipboard features may retain or sync the result under their own settings. See [privacy](PRIVACY.md), [architecture](ARCHITECTURE.md) and the separate [validation report](VALIDATION.md).

Requires macOS 13+, the appropriate microphone/Accessibility permissions, and your own Gemini key for dictation. Public CI builds remain ad-hoc signed and unnotarized unless explicitly configured. Local signing identity files are not included in releases. See [installation](INSTALL.txt) for setup and permission guidance.
