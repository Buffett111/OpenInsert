# 全域語音輸入與文字插入技術調查

調查日期：2026-09-19。目標：為 macOS 做一個開源、可自行編譯與散布、使用者自備 Gemini API key 的語音輸入工具；錄音後將文字放進使用者原本正在編輯的位置，不使用螢幕截圖、OCR 或畫面內容作為模型上下文。

## 結論與定位

**這個功能已有成熟開源實作，並非 Dup 獨有。** Handy、VoiceInk、OpenWhispr 都值得先試用。新專案的價值應是範圍清楚：macOS 原生、Gemini BYOK、不要求產品帳號、不讀螢幕、對繁體中文與中英混合輸入友善，讓使用者能審查完整資料流。

本案採 **Swift + AppKit/SwiftUI + AVFoundation + URLSession + Keychain**。第一版使用短錄音、停止後辨識，將原樣／清理偏好放在同次請求，優先以 Accessibility 寫入選取位置，不支援時改用剪貼簿加模擬貼上。這是工程取捨，不是已完成的速度或辨識率比較：相較引入 Electron/Tauri 與大型本地模型，原生小工具可減少打包與系統整合層，但未來支援 Windows/Linux 必須另做平台實作。

最難的部分通常不是呼叫辨識 API，而是焦點改變、權限未核准、輸入法、剪貼簿復原時機、遠端桌面，以及雲端失敗後仍不遺失結果。產品不應承諾「任何應用程式、任何欄位都保證成功」；應公布實測相容性與可手動複製的補救路徑。

## 調查方法與證據界線

- 依專案官方 repository、實際 source file、LICENSE、Google 與 Apple 官方文件查證。未採用第三方排行榜的辨識率或速度數字。
- 「已查證」表示閱讀文件或原始碼，**不等於已在本機安裝並完成競品端到端測試**。
- 本文提出的架構、測試門檻與預設值是本案建議；目前專案實際完成範圍以 README、原始碼與驗證紀錄為準。
- 對 Dup 的認識限於使用者提供的截圖及需求描述；沒有逆向、擷取其程式碼或讀取其 API key。截圖顯示恢復剪貼簿與文字插入診斷，但不能據此證明其內部演算法。
- Repository 的 `main` 會變動。抽查時 OpenWhispr 的 tree SHA 為 `6d56d75e7e13ec47009e573e9ff4cded0d0ccc61`，VoiceInk 為 `af5ca313219c15f6af6ddc1edeece5acd1f6fc1b`；文末提供實作檔案連結以利重查。

## 既有專案比較

| 專案 | 授權與架構 | 辨識／修正 | 全域輸入與本案適合度 |
| --- | --- | --- | --- |
| [Handy](https://github.com/cjpais/Handy) | MIT；Tauri、Rust 與前端 UI；macOS、Windows、Linux | 官方主軸是離線 Whisper／Parakeet，含 VAD；不能把「可擴充」直接等同已驗證 Gemini 音訊辨識 | 全域快捷鍵、按住／切換錄音、貼至目前欄位。最接近簡單開源聽寫工具，若主要想要現成離線工具，應優先評估 |
| [VoiceInk（Beingpax）](https://github.com/Beingpax/VoiceInk) | GPLv3；原生 macOS Swift；官方二進位有商業發行模式 | 本地 Whisper、Parakeet 等；目前 source 有 Gemini transcription provider | 全域快捷鍵、貼上、辭典、模式等功能完整。可自行編譯；若 fork，必須遵守 GPL。不是本案 MIT 程式碼的複製來源 |
| [OpenWhispr](https://github.com/OpenWhispr/openwhispr) | MIT；Electron、React、TypeScript；跨平台 | 本地 Whisper／Parakeet 等、BYOK 雲端；目前 source 有 Gemini 專用辨識與 Gemini 推論 provider | 可自動貼入游標位置。已擴展會議、筆記、助理與分享，功能範圍大於本案；直接使用通常比重造完整套件省時 |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | MIT；C/C++ 推論引擎 | 本地 Whisper，支援 CPU、Metal、Core ML 等 | 是 ASR 元件，不是完整全域語音輸入產品；需另補錄音、快捷鍵、UI、插入及模型管理 |
| [WhisperKit／Argmax OSS Swift](https://github.com/argmaxinc/argmax-oss-swift) | MIT；Swift 套件與 Apple 平台本地推論 | WhisperKit 提供本地轉錄、模型下載與 Swift 整合 | 若日後需要 Apple Silicon 離線模式，是比跨語言橋接更直接的候選；仍須下載模型與測量記憶體／延遲 |
| [Talon](https://talonvoice.com/) | 核心為專有軟體 EULA；部分社群腳本另有開源授權 | 語音控制、腳本、眼動等輔助輸入生態 | 適合完整免手操作研究，但核心不符合本案「完整開源且可散布」目標，不能把社群腳本開源誤認為 Talon 本身開源 |

授權來源：[Handy LICENSE](https://github.com/cjpais/Handy/blob/main/LICENSE)、[VoiceInk LICENSE](https://github.com/Beingpax/VoiceInk/blob/main/LICENSE)、[OpenWhispr LICENSE](https://github.com/OpenWhispr/openwhispr/blob/main/LICENSE)、[whisper.cpp LICENSE](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE)、[Argmax LICENSE](https://github.com/argmaxinc/argmax-oss-swift/blob/main/LICENSE)、[Talon EULA](https://talonvoice.com/EULA.txt)。Handy 的 README 另明示品牌名稱、圖示與品牌資產不屬於其開源程式碼授權；新專案需使用自己的名稱與素材。

搜尋 VoiceInk 或 OpenWhispr 時會出現同名、不相關或 fork 專案。上述比較固定指向表格列出的 owner/repository，不能只憑產品名稱推論授權。

### 從既有實作得到的具體證據

1. **「貼上命令已送出」與「文字已進入目標」是不同結果。** VoiceInk 的 `CursorPaster` 使用明確的 `commandPosted` 狀態；其 CGEvent／AppleScript 路徑不提供通用的目標編輯器回覆。[VoiceInk CursorPaster](https://github.com/Beingpax/VoiceInk/blob/af5ca313219c15f6af6ddc1edeece5acd1f6fc1b/VoiceInk/Infrastructure/SystemIntegration/Paste/CursorPaster.swift)
2. **剪貼簿恢復有競態。** Handy 官方 troubleshooting 記錄接收程式延後讀取時，固定時間恢復可能導致貼出原本內容，並提供實驗性的 Reliable Paste 或延長等待時間。[Handy troubleshooting](https://github.com/cjpais/Handy#previous-clipboard-content-is-pasted-instead-of-the-transcription)
3. **跨平台產品仍常用原生 helper。** OpenWhispr 的 macOS helper 檢查 Accessibility trust，再用 CGEvent 發出 Command-V；Electron 本身不是跨應用輸入的完整解答。[macOS helper](https://github.com/OpenWhispr/openwhispr/blob/6d56d75e7e13ec47009e573e9ff4cded0d0ccc61/resources/macos-fast-paste.swift)
4. **Gemini 不只用於後修正。** OpenWhispr 的 Gemini transcription helper 使用 Interactions API 與 `gemini-3.5-transcribe`；VoiceInk provider 也列出該模型。這是 source inspection，未使用本人的金鑰執行競品請求。[OpenWhispr Gemini helper](https://github.com/OpenWhispr/openwhispr/blob/6d56d75e7e13ec47009e573e9ff4cded0d0ccc61/src/helpers/geminiTranscription.js)、[VoiceInk Gemini provider](https://github.com/Beingpax/VoiceInk/blob/af5ca313219c15f6af6ddc1edeece5acd1f6fc1b/VoiceInk/Infrastructure/Providers/Transcription/Cloud/GeminiProvider.swift)

## Text insertion 的可行路徑

| 路徑 | 優點 | 主要問題 | 本案建議 |
| --- | --- | --- | --- |
| 剪貼簿暫存＋CGEvent 模擬 Command-V | 可處理長文字、Unicode、中英混合；許多一般編輯器原生支援貼上 | 要 Accessibility；借用剪貼簿；貼上是非同步且未必有成功回執 | 第一版的 fallback；保護剪貼簿、確認焦點，保留手動複製 |
| Accessibility 設定 `AXSelectedText` | 可避免剪貼簿改動；對有完整 AX 支援的可編輯欄位有用 | 控制項可能不支援或不允許設定；不能假定所有 Electron、瀏覽器、終端一致 | 第一版確認 settable 時優先使用；不設定整個 `AXValue`，避免粗暴取代全文 |
| CGEvent 逐字 Unicode 注入 | 不借用剪貼簿 | 對字串長度、組字、特殊控制項及鍵盤事件處理有較多邊界 | 保留為特定應用相容性研究，不作第一版唯一方法 |
| AppleScript／System Events 貼上 | 既有工具常用、容易診斷 | 增加 Automation 權限與 script 路徑；焦點競態仍在 | 不為 MVP 另外擴增權限；有確定相容性需求再加 |
| Input Method Kit 輸入法 | 可依輸入法的文字輸入協定整合 | 使用者要安裝／切換輸入法，產品操作與安裝複雜度增加 | 適合完整輸入法產品；與本案一鍵語音小工具的第一版需求不同 |

Apple 的 AX API 明確可能回傳「屬性不支援」、「物件失效」或「應用未完整實作」。因此有 AX API 並不代表所有文字欄位可寫。[AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)、[kAXSelectedTextAttribute](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)

### 建議的插入生命週期

1. 使用者在目的欄位按下全域快捷鍵。記下前景應用 PID；如要更嚴格防止同一應用換欄位，可保留 focused AX element 的身分，不讀取其文字。
2. 錄音與辨識期間只顯示不搶焦點的狀態。設定視窗不要自動出現，避免接管游標。
3. 辨識完成後重新檢查目標。如果使用者已切到別的應用或可確認已換欄位，顯示結果讓使用者複製，不強行把視窗切回去。僅驗證 PID 仍無法察覺同一 app 內換欄位，此限制要公開。
4. 如啟用剪貼簿恢復，保存現有項目的各種資料格式，再寫入結果並記錄 `changeCount` 或唯一 session marker；等待短暫寫入穩定後發出 Command-V。
5. 延遲恢復前確認剪貼簿仍屬於這次 session。若使用者其間複製了新內容，保留新內容，不覆蓋。
6. 對恢復等待時間提供可調整值；延遲只能降低貼上競態，不能當成接收端已讀取的證明。提供關閉恢復與再次複製結果的選項。

此流程是設計建議。`NSPasteboard.changeCount` 可作為剪貼簿變動檢查的一環；「未變動」不表示目標已讀取。來源：[Apple NSPasteboard.changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)。即使完整備份了可取得的 pasteboard data，延遲提供的資料、檔案 promise、跨裝置剪貼簿也應另測。

「不讀螢幕上下文」可以與上述插入設計共存：不請求 Screen Recording、不用 ScreenCaptureKit、不抓截圖、不讀 `AXValue`／周邊段落給 AI；如使用 AX，也只為確認輸入目標或執行插入。系統的 Accessibility 授權本身較廣，真正限制必須由可審查的程式碼與網路 payload 保證。

## Gemini 路線與辨識／修正的分工

### A. 一次多模態請求

錄音 → Gemini 音訊輸入 → 輸出整理後逐字稿 → 插入。Google 官方文件確認 Gemini 可接收音訊並產生轉錄；inline request 有 20 MB 的總請求限制，較大資料應用 Files API。[Audio understanding](https://ai.google.dev/gemini-api/docs/audio)

**本案取捨：** 短篇語音輸入先採單一 inline 請求，可減少 API 往返與遠端檔案管理。總容量限制要包含 Base64 膨脹與 JSON，不是只檢查原始音訊小於 20 MB。錄音設定、最大時長與上傳上限應互相一致。

若使用 `generateContent`，官方仍提供 `POST /v1beta/models/{model}:generateContent`、`systemInstruction`、音訊 parts 與候選回覆。不要將另一個端點的 response schema 混用。[generateContent API](https://ai.google.dev/api/generate-content)

### B. 先辨識，再獨立文字修正

錄音 → 忠實逐字稿 → 可選修正 → 插入。工程優點是保留原始文字、修正失敗可回退、容易獨立比較 ASR 與修正造成的錯誤；缺點是多一次請求與等待。

建議提供「原樣」與「清理」兩種明確模式。清理只處理標點、口頭填充詞和使用者立即自我更正，保留專有名詞、數字、語言與語意；不要把口述的問題當成對 AI 的提問。字詞表以資料輸入，不成為額外 system instruction。OpenWhispr 的公開 issue 顯示 cleanup 模型把問題回答成文章的真實使用者回報，屬風險案例而非普遍故障率證據。[Issue #833](https://github.com/OpenWhispr/openwhispr/issues/833)

### 模型選擇應可以更新

查證時 `gemini-2.5-flash` 的官方 model card 仍列為 stable、支援音訊輸入與文字輸出。停用時程表亦列出新一代 `gemini-3.5-transcribe`、`gemini-3.5-transcribe-live`；因此不能把模型名稱永久寫死，也不能假設所有 Gemini 模型共用同一端點。[2.5 Flash model card](https://ai.google.dev/gemini-api/docs/models/gemini-2.5-flash)、[Gemini deprecations](https://ai.google.dev/gemini-api/docs/deprecations)

對第一版而言，選擇已支援的 Flash + `generateContent` 是控制實作範圍的決策，不代表其繁體中文表現勝過最新專用轉錄模型。日後加入專用轉錄 provider 時，應實作正確的 Interactions API contract，而不是只在舊 URL 換掉 model ID。模型速度、台灣口音、中英混用與用詞錯誤須以自己的語料量測。

本專案目前預設 `gemini-3.8-flash`，並允許修改 model ID；不是以舊版 2.5 作為預設。上述 2.5 調查用於說明現存相容路線，不能解讀為推薦舊版優於新版。實際 API 組裝與限制見 [ARCHITECTURE.md](ARCHITECTURE.md)。

### 金鑰與資料流

- 每位使用者自行提供金鑰，存於 macOS Keychain；不隨 binary、repository、範例設定或 crash log 散布共同 key。HTTP key 放 header，避免出現在 URL 與一般 URL log。Google 官方要求保密且不要將 key 放入 source control。[API key 指引](https://ai.google.dev/gemini-api/docs/api-key)
- 音訊與選用詞彙會直接送往 Google；啟用第二階段修正時，逐字稿也會送往 Google。無產品後端與無畫面擷取，仍不等於完全離線。
- Google 對未付費／付費服務的資料使用條件不同：未付費服務可能用於改善服務並經人工檢閱；付費服務不以提示與回覆改善產品，但仍有特定日誌保留。發布頁應連結官方條款，而非自行宣稱零保留。[Gemini API 條款](https://ai.google.dev/gemini-api/terms)
- 本機暫存音訊應在完成、取消及失敗路徑刪除；若 App 崩潰可能留下暫存，啟動時只清理本 App 的過期檔案。結果可在記憶體保留供重試／複製，持久歷史預設不開啟。
- API 費用由使用者自己的 Google project 承擔；定價、免費額度與 rate limit 會變動。不要在產品文案保證免費或固定每月費用，依選用模型連到[官方定價](https://ai.google.dev/gemini-api/docs/pricing)。

## 建議的第一版架構

```text
全域快捷鍵
    ↓
錄音狀態機（idle → recording → transcribing → ready / failed）
    ↓
AVFoundation 麥克風錄音 → 僅 App 自己的短期音訊檔
    ↓
Gemini provider（使用者金鑰 / timeout / cancellation / response validation）
    ↓
可選文字修正 → 記憶體中的最後結果
    ↓
目標確認 → 剪貼簿交易 → Command-V → 條件式恢復
```

建議將錄音、網路、設定／金鑰、快捷鍵與文字插入拆成元件；辨識核心應可注入 HTTP transport，以離線 fixture 測試空候選、blocked response、截斷輸出、429、非 JSON 與取消。UI 不需要把每個 HTTP 細節暴露給一般使用者，但錯誤應能分辨「沒有金鑰」、「權限未開」、「額度／頻率限制」、「辨識失敗」與「未自動插入」。

全域快捷鍵應支援避開 Spotlight、輸入法切換及其他聽寫工具的衝突，註冊失敗時顯示可操作的錯誤。第一版可以先做切換錄音；若做按住說話，還要處理 modifiers、repeat、失去 key-up、Secure Input 與取消，不能只把同一 toggle handler 掛到 keyDown/keyUp。

## 測試與驗收建議

以下是建議矩陣，不是宣稱本版本已通過；發布時填入實際結果、macOS 版本與 App 版本。

| 測試 | 至少觀察的結果 |
| --- | --- |
| TextEdit 純文字／富文字、Notes、瀏覽器 textarea／contenteditable、常用程式碼編輯器 | 中文、emoji、換行、長文字、取代選取範圍；焦點與 undo 行為 |
| Terminal、遠端桌面、Electron 輸入框 | 個別公布支援狀態；不因送出 CGEvent 就標示成功 |
| 辨識期間切 app；同 app 換輸入框 | 不意外貼到無關位置，或明確呈現尚不能偵測的限制 |
| 原剪貼簿是文字、圖片、檔案、多格式；等待期間複製新內容 | 保存可恢復格式；不覆蓋使用者後來複製的內容 |
| 麥克風／Accessibility 拒絕後再開啟；錄音中撤銷權限 | 能離開忙碌狀態、引導到正確設定、不假成功 |
| 取消、timeout、離線、429、401／403、空回覆、截斷回覆 | 不插入錯誤訊息、不重複插入；結果／重試狀態可理解 |
| 台灣口音、國英切換、人名、產品名、數字、日期、程式碼 | 分別計算辨識錯誤與修正新增錯誤，人工核對語意 |
| 僅背景噪音、靜音、極短錄音 | 不把幻覺文字自動貼出；記錄尚未達成的防護 |
| 冷啟動與連續多次輸入 | 記錄停止錄音至結果、至貼上命令的 P50/P95；不以主觀「很快」代替數據 |

建議用自願提供且可公開的固定音檔建立基準，與指定模型／prompt version 一起保留。不要把真實工作輸入內容默默當作測試資料。單元測試證明 payload 或狀態機正確，不能替代真實 API 音訊測試與真人目標應用插入測試。

## 開源散布與後續路線

建議本案獨立撰寫程式，以 MIT 授權發布，附 LICENSE、建置方法、隱私資料流、限制、貢獻方式、問題回報範本與版本化 changelog。本文只分析公開技術路徑，不搬用競品程式碼；若日後引入外部程式／模型，逐項保存其版本與 license。

「有 `.app`」和「一般使用者可安心下載安裝」是不同階段。對外發行建議提供 Developer ID 簽章、Hardened Runtime、notarization、stapled ticket、校驗碼以及對應 source tag。Apple 官方說明了 Gatekeeper、Developer ID 與 notarization 的分工；沒有發行憑證時應誠實標示 development build，不教使用者全域關閉 Gatekeeper。[Apple Developer ID](https://developer.apple.com/developer-id/)、[macOS distribution](https://developer.apple.com/macos/distribution/)

優先順序建議：

1. **可用核心：** 權限、錄音、Gemini、取消、目標確認、可恢復剪貼簿、最後結果複製、原生打包。
2. **可驗證公開版：** 真實繁中 API 測試、多個應用的插入測試、簽章與公證發行、乾淨新帳號安裝驗證。
3. **改善可用性：** 可配置快捷鍵、麥克風選擇、字詞表、選用修正、受控重試、可調恢復延遲。
4. **離線與跨平台：** 有實際需求後加入 WhisperKit／whisper.cpp provider；Windows/Linux 各自驗證輸入與權限，不把 macOS 成功外推。

如果目標只是立即取代閉源聽寫工具，先試 Handy 或 OpenWhispr 最有效率；如果目標是建立可審查、最小化、macOS + Gemini 的開源專案，OpenInsert 的上述範圍有清楚的維護界線。
