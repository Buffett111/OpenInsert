# OpenInsert

**Hold Option + Space. Speak. Put the words where your cursor is.**

An MIT-licensed macOS menu bar dictation app using your own Gemini API key. Built for **multilingual dictation and code-switching**, with editable writing-language preferences. Native Swift, no third-party package dependencies, no OpenInsert account, no screen capture.

**Early release 0.2.7:** read [validation status](docs/VALIDATION.md) before relying on it. The source is open; Google Gemini is a cloud service, not an open or local speech model. API charges and Google's data terms apply.

[繁體中文說明](#繁體中文快速開始) · [Detailed survey](docs/SURVEY.md) · [Dup model evidence](docs/DUP_MODELS.md) · [Architecture](docs/ARCHITECTURE.md) · [Privacy](docs/PRIVACY.md)

## What it does

- **Option + Space** by default: hold for at least 0.35 seconds and release to finish, or tap once to start and again to stop. Duration uses the original keyboard event timestamps; conflicting shortcut registrations report an error.
- If a release event is delayed, a limited key-state check can recover the release using the existing Accessibility grant. It reads only Space and the chosen shortcut's modifiers while that shortcut is held. If timing is too uncertain to distinguish a hold from a tap, dictation is cancelled with a retry message.
- Streams microphone audio directly to **Gemini 3.5 Transcribe Live** over WebSocket while you speak. Raw 16 kHz mono PCM stays in bounded memory buffers; no audio file is created. Dictation is limited to about two minutes.
- Shows live previews, processing status, and errors in a floating panel while you keep typing in another app. The panel does not activate OpenInsert or intercept clicks. **Unfinalized previews are never inserted.**
- Offers verbatim output or a separate, text-only cleanup request to **Gemini 3.5 Flash Lite**, using minimal thinking with an eight-second total deadline. You can skip cleanup while waiting. A skip or temporary cleanup failure uses the finalized ASR text and reports the fallback; cancellation, invalid/blocked responses, and permanent errors stop automatic insertion.
- Provides a writing-language menu: Traditional Chinese (Taiwan), automatic, Simplified Chinese, English, Japanese, Korean, or custom. ASR still detects spoken languages automatically; mixed-language speech is preserved. Chinese character conversion happens locally, including live previews; the menu does not request translation.
- Uses Accessibility to validate the input target, then requests a standard **Command-V clipboard paste** in every supported app. It does not write transcript text through AX attributes or synthesize Return. The floating panel hides as soon as the paste is dispatched, while clipboard restoration completes in the background; it does not linger over the editor with a completion message.
- Checks the original app, input element, and available selection metadata before insertion. If a completed dictation has no valid input target or a supported insertion error occurs before paste is dispatched, it automatically copies the finalized result and shows a copied status in the floating panel. You can paste it yourself without reopening OpenInsert.
- Normal paste restores all readable clipboard formats only if the clipboard has not changed. Automatic copy is intentional and persistent: it replaces the clipboard without restoring its old contents, even when paste restoration is enabled. Cancellation, missing final text, permanent provider failures, and clipboard ownership/read/write errors do not trigger automatic copy.
- Stores the API key in macOS Keychain. No transcription history, analytics, developer backend, screenshots, OCR, or screen recording permission.
- Accepts opaque Google API key strings, including dotted `AQ.` forms and keys longer than the old 256-character limit. Local checks catch unsafe paste characters before opening the microphone; Google still determines whether the key is authorized.

There is no guarantee that every editor accepts automatic insertion. Secure fields are excluded. A missing Accessibility selection range limits cursor-change detection, and a paste request has no OS delivery receipt. A user confirmed the 0.2.4 fixed paste test in the affected ChatGPT/Codex desktop input, but the internal, unreleased 0.2.5 still failed to obtain that editor's focused element during later dictation. Version 0.2.6 revises accessibility initialization for apps exposing the supported capability and a narrowly identified Chromium app class. The user has now confirmed a successful spoken dictation directly into the affected ChatGPT/Codex input on 0.2.6; repeated restarts and compatibility with other editors remain unverified. It reads no input content. Known terminal apps reject automatic multiline/tab insertion because terminals can execute pasted newlines; embedded terminals and unknown apps need separate testing.

## Download and setup

Get published `.dmg` or `.zip` builds from [Releases](https://github.com/Buffett111/OpenInsert/releases). [Version 0.2.7](https://github.com/Buffett111/OpenInsert/releases/tag/v0.2.7) includes the latest clipboard and input compatibility fixes. Universal builds contain Apple Silicon and Intel executables. macOS 13 or newer is required.

1. Move `OpenInsert.app` to Applications and open it.
2. Quit Dup or another app that already owns Option + Space.
3. Open **連線與權限**. Paste your own [Gemini API key](https://aistudio.google.com/apikey) into the secure field and choose **儲存到 Keychain**. Do not share the key in issues or screenshots.
4. Read and enable consent for live audio streaming and optional transcript cleanup, then grant microphone and Accessibility permissions. **Upgrading from 0.1 requires new consent.** Screen Recording and Input Monitoring are not requested.
5. Focus a text field in another app. Hold Option + Space, speak, release, and keep the original input position focused while processing.
6. Use **預覽浮動字幕** to see a synthetic overlay without recording, connecting to Google, or inserting text. To test insertion separately, use **測試文字插入（5 秒倒數）** and switch to a disposable text document during the countdown; it uses the same paste-or-copy delivery rules with a fixed sentence, without microphone capture or an API request.

After saving a Keychain key and enabling Google consent, **檢查 Gemini 連線（不錄音）** can open a short Live session using the selected ASR model and fixed setup settings. It sends no custom vocabulary or audio and never opens the microphone. A successful check confirms that this connection and model setup were accepted at that time; it does not test transcription, Flash Lite cleanup, or text insertion. This check contacts Google; the synthetic overlay preview does not.

**測試辨識與後修（不錄音）** goes further: it synthesizes a fixed test sentence in memory, sends that audio to Google, then tests text cleanup with empty custom vocabulary. It requires the saved key and Google consent, reports ASR finalization and cleanup time separately, and performs no microphone recording or insertion. This is a real, potentially billable API test; it does not test your voice or destination editor.

The same test is available from Terminal after configuring the key and consent in the app:

```sh
/Applications/OpenInsert.app/Contents/MacOS/OpenInsert --diagnose-pipeline
```

It exits after completion or a 70-second overall deadline. Standard output contains a JSON report with status, separate timings, and only the fixed sentence's synthetic result; it does not print the key or capture microphone input. If you redirect this output, the chosen file will retain that test report.

Google AI Studio has issued authorization keys by default since May 28, 2026. Paste the complete key; do not shorten it or remove punctuation to fit an older example. OpenInsert checks only that it is safe to transmit as one header value, not that its permissions, billing, or model access are valid. See [Google's API key guide](https://ai.google.dev/gemini-api/docs/api-key). Fixing the earlier local format restriction does not establish the cause of every connection failure; real ASR service verification remains listed separately in [validation](docs/VALIDATION.md).

The initial community build is **ad-hoc signed, not Apple Developer ID signed or notarized**. Downloaded builds may be blocked by macOS. Inspect/build the source or follow [Apple's official guidance](https://support.apple.com/en-us/102445) if you choose to open it. Do not disable Gatekeeper. A future notarized release requires a maintainer's Developer ID certificate and Apple notarization credentials.

Default ASR model: `gemini-3.5-transcribe-live`. Default cleanup model: `gemini-3.5-flash-lite`. These match the model settings observed in Dup 1.20260913.0; see [the evidence and its limits](docs/DUP_MODELS.md). ASR uses the Live transcription protocol; cleanup uses text-only `generateContent` with structured output. The two model fields are not interchangeable. The old 0.1 default `gemini-3.8-flash` migrates to the cleanup default; another saved custom cleanup model is retained. Model availability and quotas depend on your Google account and region.

**Live finalization is still an integration limitation:** for the default dedicated Transcribe Live model, OpenInsert uses accumulated authoritative `inputTranscription` segments only once `activityEnd` has been sent successfully, no interim text remains unresolved, and one second passes without transcript updates. It no longer requires the conversational `turnComplete` event for that exact model. Other model IDs retain that additional requirement. The 20-second ASR deadline is separate from the eight-second cleanup deadline. Quiet waiting is a heuristic, not a guaranteed receipt for every late segment. See [validation](docs/VALIDATION.md) and review important text.

## Build from source

Use macOS with Swift 5.9 or newer and a compatible SDK. A current Xcode installation is recommended for XCTest.

```sh
git clone https://github.com/Buffett111/OpenInsert.git
cd OpenInsert
swift test
./scripts/build-app.sh
```

The working app is created at `.build/app-staging.noindex/OpenInsert.app`, outside normal Spotlight discovery. ZIP, DMG and checksum files are placed in `dist`. Build/install the app bundle rather than running the bare executable: microphone permissions require its Info.plist and a stable app identity.

```sh
# Both Apple Silicon and Intel, including zip, DMG and SHA-256 checksums:
ARCH=universal ./scripts/package.sh

# Use an existing Developer ID identity for hardened-runtime signing:
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ARCH=universal ./scripts/package.sh
```

For repeated local builds, you can put the fingerprint of an **existing** signing certificate in the first line of `.local-signing-identity` at the repository root. This gitignored file contains a certificate selector, not a private key; the certificate and its private key must already be available to `codesign` on your Mac. `CODE_SIGN_IDENTITY` takes priority. Reusing an Apple Development identity can keep the app's designated requirement stable and avoid repeated Accessibility grants across local rebuilds. The first switch from an ad-hoc build may still need a new grant; system policy remains authoritative. Apple Development signing does not provide Developer ID distribution or notarization. Public CI has no local file and remains ad-hoc unless explicitly configured. Do not commit a personal certificate, identity, fingerprint, or private key. See [Apple's code identity explanation](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

If you intentionally use standalone Command Line Tools instead of Xcode, set `DEVELOPER_DIR=/Library/Developer/CommandLineTools` for the command. Some CLT installations do not include XCTest. See [validation](docs/VALIDATION.md) for this development machine's exact toolchain caveats.

Build scripts use project-local caches. In an environment that forbids nested `sandbox-exec`, `SWIFTPM_DISABLE_SANDBOX=1` disables only SwiftPM's manifest subprocess sandbox for this dependency-free source build. It is unnecessary for normal local builds.

## Distribution

[CI](.github/workflows/ci.yml) runs tests and builds a universal app. Pushing a `v*` tag runs the [release workflow](.github/workflows/release.yml), which prepares a **draft** release for maintainer review. See [release checklist](docs/RELEASING.md) for signing, notarization, and compatibility checks. It never bundles an API key.

## 繁體中文快速開始

OpenInsert 0.2.7 是支援多語言混用（code-switching）的開源 macOS 語音輸入工具，目前提供 early release。預設 **Option + Space**：按住至少 0.35 秒說話、放開完成；也可短按開始、再按一次結束。說話時透過你自己的 Gemini API key，將音訊直接串流到 **Gemini 3.5 Transcribe Live**。選擇輕度整理時，確定的逐字稿再交給 **Gemini 3.5 Flash Lite**；逐字模式跳過這一步。

第一次使用請在「連線與權限」儲存 API key、同意即時音訊串流與可選文字整理、開啟麥克風與輔助使用權限，並先結束 Dup 避免快捷鍵衝突。由 0.1 升級需要重新同意。「文字語言偏好」可選繁體中文（台灣）、自動、簡體中文、English、日本語、韓語或自訂。ASR 仍自動偵測語言；繁／簡選項在本機轉換中文字形（含即時字幕），保留原本的多語言混用，不要求翻譯。

後修使用 minimal thinking，最多等待 8 秒，可按「略過後修，直接使用辨識結果」。略過或遇到逾時、網路、429／5xx 等暫時錯誤時，會明確告知改用已定稿 ASR，並經相同的焦點檢查後插入。取消整次工作、永久錯誤、被拒絕或不完整的回覆不觸發自動插入；未定稿預覽永遠不會升格使用。介面分開顯示 ASR 收尾與後修時間。

自 0.2.4 起統一使用剪貼簿加 Command-V，先透過 AX 驗證原輸入位置，再請求標準貼上。啟用剪貼簿恢復時，等待 800 ms 後只在仍持有同一剪貼簿版本時恢復。狀態只表示已請求貼上，沒有系統收件證明，也不會再用 AX 寫入重試。使用者曾確認 0.2.4 固定測試句能出現在 ChatGPT／Codex 桌面輸入框，但未發布的內部 0.2.5 仍在後續語音測試遇到焦點缺值。0.2.6 改依實際能力初始化 AX，並加入限於特定 Chromium App class 的初始化路徑，不讀輸入內容；使用者已確認 0.2.6 語音文字成功直接進入該 ChatGPT／Codex 輸入框；重啟後的重複測試及其他 App 相容性仍待驗證。

目前版本包含內部 0.2.5 加入的自動複製：完成的語音輸入沒有有效目標，或貼上事件送出前遇到可回退的插入錯誤時，會自動複製已定稿結果，浮動字幕明確顯示已複製；直接按 Command-V 即可使用，不必再開啟 OpenInsert。這會取代目前剪貼簿內容並持續保留，即使啟用「恢復剪貼簿」也不恢復舊內容；正常貼上仍沿用 800 ms 條件式恢復。取消、尚未定稿、供應商永久錯誤，以及剪貼簿已變更／無法備份／寫入失敗，都不會再次自動複製；已請求貼上後也不會重複複製。只有剪貼簿寫入成功才顯示已複製，失敗則顯示錯誤並保留 App 中的結果。固定句的自動複製與手動貼上已通過單次獨立測試，ChatGPT 直接插入也已有使用者確認；剪貼簿還原與其他相容性測試仍待完成，詳見驗證紀錄。

浮動字幕會在其他 App 保持焦點時顯示即時文字、處理狀態與錯誤，不搶游標，也不攔截滑鼠點擊。「預覽浮動字幕」只顯示合成範例，不錄音、不連線、不插入。0.2.2 也修正含句點及較長金鑰被本機誤拒的問題；請完整貼上 Google 提供的 key。錄音前的檢查只確認能安全放入 HTTP header，不能證明 Google 已授權或額度足夠。

儲存 Keychain 金鑰並同意使用 Google 後，可按「檢查 Gemini 連線（不錄音）」：它以所選 Live ASR 模型與固定設定建立短暫連線，自訂詞彙為空、不開麥克風、不送音訊。成功只表示當時連線及模型設定獲接受，不代表 ASR、文字整理或插入已成功。

「測試辨識與後修（不錄音）」則會在記憶體中合成固定測試句，將合成音訊送 Google，再以空自訂詞彙測試後修，分別量測兩階段。它不開麥克風、不插入文字，但確實使用 API、可能產生費用；不能取代本人聲音與目的 App 的相容性測試。

完成金鑰與同意設定後，也可用上面的 `--diagnose-pipeline` 指令執行相同測試。總上限 70 秒，完成後離開；stdout 只輸出狀態、時間及固定合成句的測試結果，不輸出 key。若將 stdout 重新導向檔案，該檔會留下測試報告。

本程式不建立音訊檔案，沒有螢幕截圖、screen context 或歷史紀錄功能。**開源不等於離線**：Google 會在錄音期間收到音訊與詞彙；輕度整理也會傳送逐字稿、語言偏好及詞彙。取消不能收回已傳送的資料。Live 完成判定仍採有界等待策略，不能保證沒有延遲到達的段落。這個早期版本尚未取得 Developer ID 公證，真實辨識與各 App 相容性的驗證狀態請看 [VALIDATION](docs/VALIDATION.md)。

詳細比較 Handy、VoiceInk、OpenWhispr 等方案及選型理由，請看 [繁中研究報告](docs/SURVEY.md)。

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Useful next steps include a measured cross-app insertion matrix, configurable clipboard restore timing, English UI localization, a local transcription provider, and a notarized distribution channel. Windows/Linux are not implemented.

MIT License. Independently implemented; not affiliated with Dup or the surveyed projects.
