# OpenInsert

**Hold Option + Space. Speak. Put the words where your cursor is.**

An MIT-licensed macOS menu bar dictation app using your own Gemini API key. Native Swift, no third-party package dependencies, no service account, no screen capture. Designed for Traditional Chinese and spoken English together; language preferences are editable.

**Early release:** read [validation status](docs/VALIDATION.md) before relying on it. The source is open; Google Gemini is a cloud service, not an open or local speech model. API charges and Google's data terms apply.

[繁體中文說明](#繁體中文快速開始) · [Detailed survey](docs/SURVEY.md) · [Architecture](docs/ARCHITECTURE.md) · [Privacy](docs/PRIVACY.md)

## What it does

- **Option + Space** by default: hold for at least 0.35 seconds and release to finish, or tap once to start and again to stop.
- Records up to 120 seconds of mono WAV audio and sends one direct HTTPS request to Gemini.
- Verbatim or conservative cleanup, mixed-language dictation, and custom vocabulary hints.
- Inserts through Accessibility when supported, otherwise requests a clipboard paste. Never synthesizes a Return key.
- Checks the original app, input element, and available selection metadata before insertion. Keeps the result for manual copy when the target changes.
- Restores all readable clipboard formats only if the clipboard has not changed since insertion.
- Stores the API key in macOS Keychain. No transcription history, analytics, developer backend, screenshots, OCR, or screen recording permission.

There is no guarantee that every editor accepts automatic insertion. Secure fields are excluded. A missing Accessibility selection range limits cursor-change detection, and clipboard fallback has no OS delivery receipt. Known terminal apps reject automatic multiline/tab insertion because terminals can execute pasted newlines; embedded terminals and unknown apps need separate testing.

## Download and setup

Get the `.dmg` or `.zip` matching your Mac from this repository's **Releases**. Universal builds contain Apple Silicon and Intel executables. macOS 13 or newer is required.

1. Move `OpenInsert.app` to Applications and open it.
2. Quit Dup or another app that already owns Option + Space.
3. Open **連線與權限**. Paste your own [Gemini API key](https://aistudio.google.com/apikey) into the secure field and choose **儲存到 Keychain**. Do not share the key in issues or screenshots.
4. Read and enable the Google audio-upload consent, then grant microphone and Accessibility permissions. Screen Recording and Input Monitoring are not requested.
5. Focus a text field in another app. Hold Option + Space, speak, release, and keep the original input position focused while processing.
6. If needed, use **測試文字插入（5 秒倒數）** first. It inserts a fixed test sentence with no recording or API request. Switch to a disposable text document during the countdown.

The initial community build is **ad-hoc signed, not Apple Developer ID signed or notarized**. Downloaded builds may be blocked by macOS. Inspect/build the source or follow [Apple's official guidance](https://support.apple.com/en-us/102445) if you choose to open it. Do not disable Gatekeeper. A future notarized release requires a maintainer's Developer ID certificate and Apple notarization credentials.

Default model: `gemini-3.8-flash`, based on Google's documentation checked on 2026-09-19. You may set another model supporting **audio input + JSON structured output on `generateContent`**. Dedicated Interactions-only transcription model names cannot simply be substituted. Model availability and quotas depend on your Google account and region.

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

OpenInsert 是開源 macOS 語音輸入工具。預設 **Option + Space**：長按說話、放開完成；也可短按開始、再按一次結束。錄音經你自己的 Gemini API key 直接送到 Google，同次請求完成辨識與輕度修正，再插入原本的輸入位置。

第一次使用請在「連線與權限」儲存 API key、同意傳送錄音、開啟麥克風與輔助使用權限，並先結束 Dup 避免快捷鍵衝突。預設使用繁體中文並保留說出的英文；可設定詞彙、逐字或輕度整理模式。辨識失敗、切換欄位或不支援插入時，最近結果可手動複製。

本程式沒有螢幕截圖、screen context 或歷史紀錄功能。**開源不等於音訊留在本機**：Google 仍會收到音訊與詞彙；政策依你的方案而異。這個早期版本尚未取得 Developer ID 公證，真實辨識與各 App 相容性的驗證狀態請看 [VALIDATION](docs/VALIDATION.md)。

詳細比較 Handy、VoiceInk、OpenWhispr 等方案及選型理由，請看 [繁中研究報告](docs/SURVEY.md)。

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Useful next steps include a measured cross-app insertion matrix, configurable clipboard restore timing, English UI localization, a local transcription provider, and a notarized distribution channel. Windows/Linux are not implemented.

MIT License. Independently implemented; not affiliated with Dup or the surveyed projects.
