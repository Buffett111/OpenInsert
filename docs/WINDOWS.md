# OpenInsert for Windows / Windows 安裝指南

The Windows port is a native .NET desktop application in `windows/`. It keeps the existing macOS application in place. Windows source and packaging are available in this checkout; the previously published macOS v0.3.0 release does **not** automatically acquire Windows assets. A maintainer must build and publish a new release before Windows assets appear on the Releases page.

## Download and install

Use a supported **Windows 11** PC. Choose **x64** for most Intel/AMD PCs and **ARM64** for Windows on ARM. Find the architecture in **Settings → System → About → System type**. The installer permits Windows 10 build 17763 or newer, but that minimum is not a tested compatibility claim. .NET 10's supported Windows 10 editions are limited to supported LTSC/Enterprise versions; regular Windows 10 editions are not a supported deployment target. See [Microsoft's current Windows/.NET support table](https://learn.microsoft.com/dotnet/core/install/windows).

When Windows assets are available on [Releases](https://github.com/Buffett111/OpenInsert/releases), select one of:

| Asset | Usage |
| --- | --- |
| `OpenInsert-<version>-windows-x64-setup.exe` | Per-user installer for Intel/AMD PCs. |
| `OpenInsert-<version>-windows-arm64-setup.exe` | Per-user installer for ARM PCs. |
| `OpenInsert-<version>-windows-<architecture>.zip` | Portable application folder; extract **all** files, then open `OpenInsert.exe` inside the extracted architecture folder. |
| `OpenInsert-<version>-windows-<architecture>-SHA256SUMS.txt` | SHA-256 values for the corresponding downloadable files. |

Before a public release, review packages are downloadable from successful [Build and test workflow runs](https://github.com/Buffett111/OpenInsert/actions/workflows/ci.yml). Open a run for the intended commit and download the **OpenInsert-win-x64** or **OpenInsert-win-arm64** artifact (GitHub sign-in may be required). Extract that outer artifact archive to find the setup EXE, portable ZIP and checksum manifest. These are unsigned review builds; a successful CI run does not establish real microphone or Google API compatibility.

The setup EXE installs in `%LOCALAPPDATA%\Programs\OpenInsert`, adds a Start menu shortcut and can optionally create a desktop shortcut. It does not request administrator privileges. Both installation methods bundle the .NET runtime, so recipients do not install the SDK or runtime separately. Keep the entire extracted folder together; the EXE depends on the included DLLs and resources.

Initial Windows builds are **unsigned**. Windows SmartScreen or your organization's policy may block them; the project does not promise an identified publisher or SmartScreen reputation. Check the source and release origin, and respect your organization's policy. Do not disable Defender or system protections. A checksum verifies downloaded bytes against a manifest, not the identity of a publisher:

```powershell
Get-FileHash .\OpenInsert-<version>-windows-x64.zip -Algorithm SHA256
```

## First use

1. Start OpenInsert and open its settings window from the notification area. Switch between **繁體中文** and **English** as desired.
2. Save your own [Gemini API key](https://aistudio.google.com/apikey) in the connection settings. Paste the whole key. The app encrypts it with Windows **DPAPI for the current user**; it is not written as plain text in settings or included in packages.
3. Read and enable Google cloud consent. Recording streams microphone audio and vocabulary directly to Google; optional cleanup sends finalized text and writing preferences. API charges and Google's terms apply. Cancellation cannot recall data already sent.
4. In **Settings → Privacy & security → Microphone**, allow microphone access and **Let desktop apps access your microphone**. Select the intended default input device in Windows Sound settings. Microphone failure can also mean another program holds the device or the device is unavailable.
5. Focus a disposable text document. Hold **Ctrl + Space** for at least **350 ms**, speak after the listening status appears, and release to finish. Alternatively, tap once to start and again to stop. Keep the original input location focused while processing. Some Chinese input methods reserve Ctrl + Space. If it conflicts, choose Ctrl + Alt + Space or another custom shortcut.
6. Use the fixed-text insertion test to check your destination editor without microphone capture or a Google request. After its five-second countdown starts, switch to that editor. A connection check contacts Google without opening the microphone; success establishes only that Google accepted the connection and model settings at that time.

Close a conflicting shortcut owner or record another shortcut if registration fails. A shortcut conflict must be resolved before it can trigger dictation. Tap/hold operation depends on physical key release; keyboard layouts, AltGr combinations, remote desktop sessions and accessibility tools need separate testing.

## Text delivery, privacy and limitations

- Only finalized recognition results are eligible for delivery. The floating preview is not inserted. Cleanup can be skipped; a transient cleanup error falls back to finalized recognition, while cancellation or permanent provider errors stop automatic insertion.
- Windows UI Automation checks the original foreground window and input target before a standard **Ctrl + V** request. Secure fields are excluded. Focus changes or an unavailable safe target can leave finalized text copied for manual paste. A paste request is not proof that the editor accepted the text.
- Some applications expose incomplete accessibility information. Elevated applications, terminal inputs, embedded editors, games and remote desktops may reject automatic insertion or require manual paste. Run OpenInsert as your normal user; administrator elevation is not the compatibility workaround.
- Normal paste restores supported clipboard data only while OpenInsert still owns that clipboard version. Deliberately copied fallback text stays in the clipboard. Clipboard managers and Windows clipboard history/sync may retain copied text separately from OpenInsert.
- The Windows port uses DPAPI rather than macOS Keychain and Windows microphone privacy settings rather than macOS Accessibility authorization. Preferences and the encrypted key are under `%LOCALAPPDATA%\OpenInsert`. They stay after uninstall so an update/reinstall can preserve them. The encrypted key is tied to your Windows account; do not copy it to another account or computer as a setup method.
- No OpenInsert account, screen capture, transcription history database, developer backend or audio files are used. Audio is buffered in memory. There is no offline recognition mode.

The default models match the existing application: `gemini-3.5-transcribe-live` for live recognition and `gemini-3.5-flash-lite` for optional cleanup. Availability depends on your Google account, region, authorization and quota. Dedicated Transcribe Live finalization uses bounded quiet waiting after the final input activity message; this is a heuristic and cannot guarantee the absence of late segments. Review important text.

## Build and package

Build on Windows with the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0). The application uses Windows desktop framework APIs. The SDK restores the required runtime packs for self-contained publication, so the first build requires network access.

```powershell
git clone https://github.com/Buffett111/OpenInsert.git
cd OpenInsert
dotnet run --project windows/OpenInsert.Core.Tests -c Release
dotnet run --project windows/OpenInsert.Windows.Tests -c Release
dotnet run --project windows/OpenInsert.Platform.Tests -c Release
./scripts/build-windows.ps1 -Runtime win-x64
./scripts/package-windows.ps1 -Runtime win-x64
./scripts/package-windows.ps1 -Runtime win-arm64
```

The build outputs are `dist/windows/publish/win-x64` and `dist/windows/publish/win-arm64`; ZIPs and checksum manifests are in `dist/windows`. The scripts clean only the selected architecture's generated publish directory. Do not store unrelated files there.

To build a setup EXE, install [Inno Setup 6](https://jrsoftware.org/isdl.php) (6.3 or newer) and run:

```powershell
./scripts/package-windows.ps1 -Runtime win-x64 -Installer
# A nonstandard compiler location can be supplied explicitly:
./scripts/package-windows.ps1 -Runtime win-x64 -Installer -InnoSetupCompiler 'C:\Tools\Inno Setup 6\ISCC.exe'
```

`-Version v0.3.0` and `-Version 0.3.0` normalize to the same version. A supplied version must match `windows/OpenInsert.Windows/OpenInsert.Windows.csproj`. Before creating a new release tag, update both that project and macOS `Resources/Info.plist`. The scripts provide repeatable packaging commands; archives are not claimed to be byte-for-byte reproducible across SDK versions or build times.

An offline package smoke test can be run without microphone capture, a key, or any Google request:

```powershell
$app = Start-Process .\dist\windows\publish\win-x64\OpenInsert.exe -ArgumentList '--smoke-test' -PassThru -Wait
$app.ExitCode # 0 means the smoke checks passed
```

CI uses the .NET 10 SDK and the Inno Setup installation documented in the [GitHub Windows runner image](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md). Installer packaging fails clearly if Inno Setup is unavailable. CI runs the offline core, UI/settings and native platform harnesses and an extracted x64 archive smoke test, then retains both architectures' archives, installers and checksums. The default native harness checks DPAPI, Chinese conversion and shortcut registration without touching saved keys or the clipboard. Interactive clipboard, paste and microphone tests are opt-in and are not run by CI. Release jobs collect all platform assets before creating one draft release. See [RELEASING.md](RELEASING.md).

## Validation status

Windows validation is separate from [the historical macOS results](VALIDATION.md). CI definitions describe checks to run; adding them does not prove a hosted run has passed. Offline core tests and `--smoke-test` do not establish a successful real microphone → Google → destination-app session. They cannot validate Google's current model access or SmartScreen behavior on a freshly downloaded unsigned artifact.

Local checks on **2026-09-22** used Windows x64 **10.0.26200**, .NET SDK **10.0.203**, runtime **10.0.7**, and Inno Setup **6.7.3**:

| Check | Result and scope |
| --- | --- |
| Core | 35 offline checks passed. |
| Windows UI/settings | 21 checks passed, including rendering both interface languages, Ctrl + Space default, consent and shortcut validation. |
| Native platform | 11 default checks passed: in-memory DPAPI encryption, Chinese conversion, shortcut conflicts and timing boundaries. The optional desktop suite passed 27 checks, including real paste into a separate disposable test editor, clipboard restoration, changed-selection fallback, a stalled-UI key release, and ordered rapid presses after a stall. |
| Packages | x64 and ARM64 self-contained ZIPs and setup EXEs built. Both executable architecture headers and bundled .NET 10.0.7 runtime metadata were checked; SHA-256 manifests verified. ARM64 was cross-compiled, not executed on ARM hardware. |
| x64 launch | Release build had zero warnings/errors. The application and the extracted portable ZIP's `--smoke-test` exited 0. |
| x64 installer | Silent per-user installation to an isolated workspace directory, installed-app smoke check, and uninstall each exited 0. No pre-existing OpenInsert install was present; temporary uninstall registration and test application were removed. `/NOICONS` was used. No saved user settings/key were deleted or loaded. This does not test clean-machine SmartScreen, Start menu UI, upgrade, or reinstall persistence. |
| Workflows | Actionlint 1.7.12 passed both workflows' syntax/schema/expression checks. [Hosted CI run 35687189550](https://github.com/Buffett111/OpenInsert/actions/runs/35687189550) passed the unchanged macOS test/build job and both Windows package jobs for commit `399065e`; that run is evidence for that commit, not subsequent refinements. |

Windows packages are unsigned. No default microphone was available on the local host, so actual microphone capture and real Google transcription/cleanup remain unverified. Native editor fixtures establish only those controlled cases, not compatibility with every app or the ChatGPT/Codex input. A clean computer without .NET installed, ARM64 hardware, microphone permission behavior and genuinely downloaded-install behavior still need testing.

Before publishing, record results for: fresh installation and uninstall/reinstall; x64 and ARM64 hardware; physical hold/tap and custom shortcuts; microphone permission denial and unplugging; mixed-language voice with a real key; ASR finalization and cleanup; cancellation; focus movement and password fields; clipboard restore and interference; and insertion into Notepad, browser textareas, Word and the intended ChatGPT/Codex inputs. Leave any untested row marked pending. A cross-compiled ARM64 package is not an ARM64 runtime test.

## 繁體中文操作說明

這次移植提供原生 Windows 桌面程式、可攜 ZIP、免管理員權限的安裝程式，以及 GitHub Actions 打包流程；macOS 程式仍保留。**既有 v0.3.0 發布頁是 macOS 版**，不會因原始碼新增 Windows 支援就自動出現 Windows 下載。維護者發布新版本前，可到成功的 [Build and test 執行紀錄](https://github.com/Buffett111/OpenInsert/actions/workflows/ci.yml)下載 **OpenInsert-win-x64** 或 **OpenInsert-win-arm64** artifact（可能需要登入 GitHub）；解壓外層檔案後即可取得安裝檔、ZIP 與 SHA-256。也可依本頁指令自行編譯。這些是尚未簽章的測試套件。

請使用仍受支援的 **Windows 11**。Intel／AMD 電腦選 `windows-x64`，ARM 電腦選 `windows-arm64`；可在「設定 → 系統 → 關於 → 系統類型」確認。安裝程式技術上允許 Windows 10 build 17763 以上，但不代表這些版本已通過相容性測試；.NET 10 的 Windows 10 支援僅限仍受支援的 LTSC／Enterprise 版本。

1. 下載對應的 `-setup.exe` 並安裝，或將 ZIP **完整解壓縮**後執行資料夾中的 `OpenInsert.exe`。不要只複製 EXE。兩種版本都已包含 .NET runtime，不必另外安裝。安裝版位於 `%LOCALAPPDATA%\Programs\OpenInsert`。
2. 從通知區域開啟設定，可選繁體中文／English 介面。儲存自己的 Gemini API key，並閱讀、勾選 Google 雲端使用同意。金鑰以 Windows DPAPI 加密，綁定目前 Windows 帳戶；不會寫入明文設定或打包進程式。
3. 在「設定 → 隱私權與安全性 → 麥克風」允許麥克風存取，以及「讓桌面應用程式存取您的麥克風」。輸入裝置以 Windows 音效設定中的預設裝置為準。
4. 將游標放到測試文字文件，按住 **Ctrl + Space 至少 350 毫秒**，顯示正在聆聽後說話，放開結束；也可短按開始、再按一次結束。處理期間保持原輸入位置的焦點。部分中文輸入法會佔用 Ctrl + Space；若有衝突，可改為 Ctrl + Alt + Space 或其他自訂組合。
5. 先用固定文字插入測試驗證編輯器；按下後有五秒切換到空白測試文件，不用麥克風或 API。連線測試會聯絡 Google，但不錄音；成功只代表當時連線與模型設定獲接受。

Windows 版透過 UI Automation 檢查輸入位置，再請求標準 **Ctrl + V**。無法驗證安全目標時，完成的文字可複製後手動貼上；不是所有 App、系統管理員視窗、終端機或遠端桌面都支援自動插入。不要以管理員權限執行來繞過限制。一般貼上只在剪貼簿仍屬於本次操作時還原；自動複製的備用結果會留在剪貼簿，可能被 Windows 剪貼簿歷程或同步功能保留。

**開源不等於離線。** 錄音時音訊與詞彙直接傳 Google；可選文字整理會傳送逐字稿與偏好，可能產生 API 費用。程式不建立音訊檔、截圖或逐字稿歷史資料庫。取消無法收回已傳送內容。設定與加密金鑰儲存在 `%LOCALAPPDATA%\OpenInsert`，解除安裝時保留，不會把金鑰搬到其他帳戶。

初期 Windows 套件**尚未簽章**，SmartScreen 或組織政策可能阻擋。請確認來源、核對 SHA-256 並遵守組織政策，不要關閉 Defender 或系統防護。macOS 既有測試結果不能代表 Windows 已驗證；離線測試與啟動檢查也不能證明真人麥克風、Gemini API、所有編輯器或 ARM64 實機已可正常使用。發布前需完成上方驗證項目並保留未測項目的實際狀態。
