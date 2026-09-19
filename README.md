# OpenInsert

**Hold Option + Space. Speak. Put the words where your cursor is.**

An MIT-licensed macOS menu bar dictation app using your own Gemini API key. Native Swift, no third-party package dependencies, no OpenInsert account, no screen capture. Designed for Traditional Chinese and spoken English together; language preferences are editable.

**Early release 0.2.2:** read [validation status](docs/VALIDATION.md) before relying on it. The source is open; Google Gemini is a cloud service, not an open or local speech model. API charges and Google's data terms apply.

[繁體中文說明](#繁體中文快速開始) · [Detailed survey](docs/SURVEY.md) · [Dup model evidence](docs/DUP_MODELS.md) · [Architecture](docs/ARCHITECTURE.md) · [Privacy](docs/PRIVACY.md)

## What it does

- **Option + Space** by default: hold for at least 0.35 seconds and release to finish, or tap once to start and again to stop. Duration uses the original keyboard event timestamps; conflicting shortcut registrations report an error.
- Streams microphone audio directly to **Gemini 3.5 Transcribe Live** over WebSocket while you speak. Raw 16 kHz mono PCM stays in bounded memory buffers; no audio file is created. Dictation is limited to about two minutes.
- Shows live previews, processing status, and errors in a floating panel while you keep typing in another app. The panel does not activate OpenInsert or intercept clicks. **Unfinalized previews are never inserted.**
- Offers verbatim output or a separate, text-only cleanup request to **Gemini 3.5 Flash Lite**. Cleanup is enabled by default; if it fails, the finalized ASR result remains available for manual copy and nothing is automatically inserted.
- Supports custom vocabulary, automatic spoken-language detection, and local Simplified-to-Traditional character conversion when Traditional Chinese is selected, preserving spoken English.
- Inserts through Accessibility when supported, otherwise requests a clipboard paste. Never synthesizes a Return key.
- Checks the original app, input element, and available selection metadata before insertion. Keeps the result for manual copy when the target changes.
- Restores all readable clipboard formats only if the clipboard has not changed since insertion.
- Stores the API key in macOS Keychain. No transcription history, analytics, developer backend, screenshots, OCR, or screen recording permission.
- Accepts opaque Google API key strings, including dotted `AQ.` forms and keys longer than the old 256-character limit. Local checks catch unsafe paste characters before opening the microphone; Google still determines whether the key is authorized.

There is no guarantee that every editor accepts automatic insertion. Secure fields are excluded. A missing Accessibility selection range limits cursor-change detection, and clipboard fallback has no OS delivery receipt. Known terminal apps reject automatic multiline/tab insertion because terminals can execute pasted newlines; embedded terminals and unknown apps need separate testing.

## Download and setup

Get the `.dmg` or `.zip` from [Releases](https://github.com/Buffett111/OpenInsert/releases). Universal builds contain Apple Silicon and Intel executables. macOS 13 or newer is required.

1. Move `OpenInsert.app` to Applications and open it.
2. Quit Dup or another app that already owns Option + Space.
3. Open **連線與權限**. Paste your own [Gemini API key](https://aistudio.google.com/apikey) into the secure field and choose **儲存到 Keychain**. Do not share the key in issues or screenshots.
4. Read and enable consent for live audio streaming and optional transcript cleanup, then grant microphone and Accessibility permissions. **Upgrading from 0.1 requires new consent.** Screen Recording and Input Monitoring are not requested.
5. Focus a text field in another app. Hold Option + Space, speak, release, and keep the original input position focused while processing.
6. Use **預覽浮動字幕** to see a synthetic overlay without recording, connecting to Google, or inserting text. To test insertion separately, use **測試文字插入（5 秒倒數）** and switch to a disposable text document during the countdown; it inserts a fixed sentence without an API request.

After saving a Keychain key and enabling Google consent, **檢查 Gemini 連線（不錄音）** can open a short Live session using the selected ASR model and fixed setup settings. It sends no custom vocabulary or audio and never opens the microphone. A successful check confirms that this connection and model setup were accepted at that time; it does not test transcription, Flash Lite cleanup, or text insertion. This check contacts Google; the synthetic overlay preview does not.

Google AI Studio has issued authorization keys by default since May 28, 2026. Paste the complete key; do not shorten it or remove punctuation to fit an older example. OpenInsert checks only that it is safe to transmit as one header value, not that its permissions, billing, or model access are valid. See [Google's API key guide](https://ai.google.dev/gemini-api/docs/api-key). Fixing the earlier local format restriction does not establish the cause of every connection failure; real ASR service verification remains listed separately in [validation](docs/VALIDATION.md).

The initial community build is **ad-hoc signed, not Apple Developer ID signed or notarized**. Downloaded builds may be blocked by macOS. Inspect/build the source or follow [Apple's official guidance](https://support.apple.com/en-us/102445) if you choose to open it. Do not disable Gatekeeper. A future notarized release requires a maintainer's Developer ID certificate and Apple notarization credentials.

Default ASR model: `gemini-3.5-transcribe-live`. Default cleanup model: `gemini-3.5-flash-lite`. These match the model settings observed in Dup 1.20260913.0; see [the evidence and its limits](docs/DUP_MODELS.md). ASR uses the Live transcription protocol; cleanup uses text-only `generateContent` with structured output. The two model fields are not interchangeable. The old 0.1 default `gemini-3.8-flash` migrates to the cleanup default; another saved custom cleanup model is retained. Model availability and quotas depend on your Google account and region.

**Live finalization is still an integration limitation:** the server does not document a complete ordering barrier for input transcripts. OpenInsert waits for `turnComplete`, no unresolved interim text, and one second without transcript updates; it fails after a 20-second finalization deadline. This is a heuristic, not proof that every late transcript has arrived. Read [validation status](docs/VALIDATION.md) for real-service testing; check important text before using it.

## Build from source

Use macOS with Swift 5.9 or newer and a compatible SDK. A current Xcode installation is recommended for XCTest.

```sh
git clone https://github.com/Buffett111/OpenInsert.git
cd OpenInsert
swift test
./scripts/build-app.sh
```

The app is created at `dist/OpenInsert.app`. Build/install the app bundle rather than running the bare executable: microphone permissions require its Info.plist and a stable app identity.

```sh
# Both Apple Silicon and Intel, including zip, DMG and SHA-256 checksums:
ARCH=universal ./scripts/package.sh

# Use an existing Developer ID identity for hardened-runtime signing:
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ARCH=universal ./scripts/package.sh
```

If you intentionally use standalone Command Line Tools instead of Xcode, set `DEVELOPER_DIR=/Library/Developer/CommandLineTools` for the command. Some CLT installations do not include XCTest. See [validation](docs/VALIDATION.md) for this development machine's exact toolchain caveats.

Build scripts use project-local caches. In an environment that forbids nested `sandbox-exec`, `SWIFTPM_DISABLE_SANDBOX=1` disables only SwiftPM's manifest subprocess sandbox for this dependency-free source build. It is unnecessary for normal local builds.

## Distribution

[CI](.github/workflows/ci.yml) runs tests and builds a universal app. Pushing a `v*` tag runs the [release workflow](.github/workflows/release.yml), which prepares a **draft** release for maintainer review. See [release checklist](docs/RELEASING.md) for signing, notarization, and compatibility checks. It never bundles an API key.

## 繁體中文快速開始

OpenInsert 0.2.2 是開源 macOS 語音輸入工具。預設 **Option + Space**：按住至少 0.35 秒說話、放開完成；也可短按開始、再按一次結束。說話時透過你自己的 Gemini API key，將音訊直接串流到 **Gemini 3.5 Transcribe Live**。選擇輕度整理時，確定的逐字稿再交給 **Gemini 3.5 Flash Lite**；逐字模式跳過這一步。

第一次使用請在「連線與權限」儲存 API key、同意即時音訊串流與可選文字整理、開啟麥克風與輔助使用權限，並先結束 Dup 避免快捷鍵衝突。由 0.1 升級需要重新同意。ASR 自動偵測語言；繁中偏好會在本機轉換中文字形並保留英文，可設定詞彙及逐字／輕度整理模式。整理失敗時保留確定的 ASR 結果供手動複製，不自動插入；未定稿預覽不會直接插入。

浮動字幕會在其他 App 保持焦點時顯示即時文字、處理狀態與錯誤，不搶游標，也不攔截滑鼠點擊。「預覽浮動字幕」只顯示合成範例，不錄音、不連線、不插入。0.2.2 也修正含句點及較長金鑰被本機誤拒的問題；請完整貼上 Google 提供的 key。錄音前的檢查只確認能安全放入 HTTP header，不能證明 Google 已授權或額度足夠。

儲存 Keychain 金鑰並同意使用 Google 後，可按「檢查 Gemini 連線（不錄音）」：它以所選 Live ASR 模型與固定設定建立短暫連線，自訂詞彙為空、不開麥克風、不送音訊。成功只表示當時連線及模型設定獲接受，不代表 ASR、文字整理或插入已成功。

本程式不建立音訊檔案，沒有螢幕截圖、screen context 或歷史紀錄功能。**開源不等於離線**：Google 會在錄音期間收到音訊與詞彙；輕度整理也會傳送逐字稿、語言偏好及詞彙。取消不能收回已傳送的資料。Live 完成判定仍採有界等待策略，不能保證沒有延遲到達的段落。這個早期版本尚未取得 Developer ID 公證，真實辨識與各 App 相容性的驗證狀態請看 [VALIDATION](docs/VALIDATION.md)。

詳細比較 Handy、VoiceInk、OpenWhispr 等方案及選型理由，請看 [繁中研究報告](docs/SURVEY.md)。

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Useful next steps include a measured cross-app insertion matrix, configurable clipboard restore timing, English UI localization, a local transcription provider, and a notarized distribution channel. Windows/Linux are not implemented.

MIT License. Independently implemented; not affiliated with Dup or the surveyed projects.
