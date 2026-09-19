# OpenInsert 架構與取捨

本文描述 0.2.3 原始碼的設計。平台為 macOS 13 以上，Swift Package 使用 Swift tools 5.9；程式本身不依賴第三方 package。編譯、單元測試、UI、真實 API 與跨應用插入屬不同驗證層，實際執行結果以 [VALIDATION.md](VALIDATION.md) 為準。

## 使用流程

使用者先儲存自己的 Gemini API key，明確同意錄音期間將音訊串流至 Google，以及啟用整理時傳送逐字稿，再核准麥克風與所需的輔助使用權限。0.2 使用獨立的 `liveCloudConsent` 設定，0.1 的上傳同意不會自動沿用。將游標放在其他 App 的文字欄位，以預設 **Option + Space** 開始。按住至少約 0.35 秒再放開會結束錄音；短按可開始，再按一次停止。可切換為 Control + Option + Space 或 Control + Shift + Space，避開其他軟體的快捷鍵。

沒有可驗證的目標欄位或沒有 Accessibility 權限時，仍可辨識並保留結果供手動複製；程式不會因此把內容貼到任意前景視窗。麥克風權限、有效金鑰與雲端同意仍為錄音／雲端路徑的必要條件。

0.2.2 在開啟麥克風前，先本機檢查保存的 key 是否能安全傳送，以及 ASR 模型名稱與詞彙設定。缺少 key、夾雜空白／控制字元、超過本機容量上限或不合規設定會回報具體原因；這不是向 Google 查詢憑證有效性，不能預先確認權限、額度或模型可用性。

「檢查 Gemini 連線（不錄音）」是另一個明確啟動的網路診斷：`DictationController.checkConnection` 要求已有 Keychain key、Google consent 且目前沒有其他工作，使用所選 `asrModel` 建立 `GeminiLiveTranscriber`，`languageCodes` 與 `vocabulary` 都沿用空陣列預設。它執行固定 Live setup／啟動控制訊號，等待 `start()` 成功後立即取消連線；不啟動 recorder、不送 PCM、逐字稿或自訂詞彙。成功只支持當時的認證連線與模型 setup 可用，不能外推 ASR、完成判定、Flash Lite 整理或文字插入成功，也不保證後續配額。

「測試辨識與後修（不錄音）」由 `testPipeline` 執行：需要同樣的金鑰與 Google consent，以本機語音合成建立固定測試句的 RAM PCM，約每 100 ms 發送一塊，使用所選 ASR 模型，再以所選後修模型與文字語言偏好測試整理；兩階段的自訂詞彙均為空。它不啟動麥克風、不捕捉插入目標、不插入文字，但會發送合成音訊與辨識文字到 Google，可能計費。診斷分別呈現連線、ASR 收尾及後修耗時，另提供定稿／暫稿計數和完成事件旗標。這些記憶體診斷不包含金鑰、音訊、詞彙、URL 或伺服器錯誤原文；測試文字仍可出現在結果 UI。測試成功不能證明實際麥克風、本人聲音或跨 App 插入正常。

`/Applications/OpenInsert.app/Contents/MacOS/OpenInsert --diagnose-pipeline` 是相同固定句路徑的 CLI 入口。App 啟動後檢查事先儲存的 Keychain key 與 consent，呼叫 `testPipeline`，最多等待 70 秒總經過時間；到期取消，完成或失敗後輸出一行 JSON 並結束 App。欄位為 `success`、固定分類的 `status`、`timing`、`syntheticResult`、`microphoneUsed: false`、`textInserted: false`；不輸出金鑰、使用者音訊或一般語音輸入內容。腳本應讀取 JSON 的 `success` 判斷結果。stdout 重新導向或終端保存會留下合成測試報告，不能將 CLI 描述為完全沒有文字輸出。這個 CLI 仍可能開啟 App 視窗，並非額外的背景服務。

```text
使用者快捷鍵／錄音按鈕
        │
        ├─ 記住目前應用、AX 元件及選取範圍（不讀文字）
        │
        ▼
AVAudioEngine → AVAudioConverter → 有界 RAM 音訊佇列
        │                          16 kHz / mono / Int16 PCM
        ▼
GeminiLiveTranscriber → WSS → gemini-3.5-transcribe-live
        │                         即時音訊 + 自訂詞彙
        ├─ interim → UI「未定稿」預覽，不插入
        ▼
停止錄音 → 排空音訊尾端 → activityEnd → 等待完成條件
        │
        ▼
確定 ASR 文字 → 本機繁中字形處理 → 保存在 RAM
        │
        ├─ 逐字模式 → 直接使用文字
        └─ 輕度整理 → HTTPS → gemini-3.5-flash-lite（只有文字）
                              │ 最多 8 秒；略過／暫時失敗 → 使用定稿 ASR
                              ▼
                         驗證整理結果
        │
        ├─ 原目標已改變／不可驗證 → 顯示結果供手動複製
        │
        └─ 可驗證原目標 → AXSelectedText
                              │ 不支援設定此屬性
                              ▼
                        剪貼簿 + Command-V
                              │
                              ▼
                        等待 800 ms 後條件式恢復
```

## 元件邊界

| 元件 | 職責 | 不承擔的責任 |
| --- | --- | --- |
| `App.swift`、`MainView.swift` | 原生選單列與 SwiftUI 設定／結果介面 | 不自行組合 HTTP request、不擷取其他 App 文字 |
| 浮動字幕 HUD | 以不啟用 App、不接收滑鼠點擊的面板呈現即時預覽、處理狀態及錯誤 | 不搶輸入焦點、不擷取背後畫面、不把預覽送進目標 |
| `DictationController` | 管理狀態、session、取消、錄音至插入的串接 | 不保存逐字稿資料庫 |
| `StreamingAudioRecorder` | 麥克風授權、音訊重取樣、PCM 分塊、音量與有界 RAM 佇列 | 不錄系統音效、不建立錄音檔案 |
| `GlobalHotKey` | Carbon hotkey 為主；必要時以指定按鍵狀態補回遺失的 release | 不安裝 event tap，不讀取其他按鍵 |
| `GeminiLiveTranscriber` | WebSocket setup、PCM 傳送、interim／final 解析、完成等待與取消 | 不把 interim 當定稿、不讀本機輸入欄位文字 |
| `GeminiClient.polish` | 文字整理的 HTTP request、大小限制與回覆解析 | 不重送音訊、不讀剪貼簿／AX、不執行模型產生的指令 |
| `TextInserter` | 目標捕捉、驗證、AX 寫入與剪貼簿交易 | 不從畫面收集上下文，不保證所有程式接受合成貼上 |
| `SettingsStore` | UserDefaults 中的模型、語言、詞彙、模式、快捷鍵與同意設定 | 不保存 key 或逐字稿 |
| `KeychainStore` | 儲存／刪除使用者 Gemini key | 不在 release 內提供共用 key |
| `GeminiAPIKey` | 共用的本機 header 傳輸安全檢查 | 不判斷 key 類型、Google 授權或服務可用性 |

## 狀態與取消

主要狀態為 `idle → preparing → recording → transcribing → polishing → inserting → idle`；逐字模式跳過 `polishing`，另有 `testing` 診斷／插入測試狀態。ASR 收尾與後修分別計時及顯示，不將 20 秒 Live 失敗誤報成 LLM 等待。MainActor 序列化 UI 與系統互動；每次工作有 generation UUID，舊的非同步回覆不能更新新的 session。

設定在錄音起始時擷取，避免處理途中改模型、模式或恢復選項造成同一段錄音前後不一致。按鍵 repeat 由 GlobalHotKey 去重；新 shortcut registration ID 可排除舊註冊遺留事件。0.2.2 以 Carbon `GetEventTime` 的原始按下／放開時間判斷 0.35 秒門檻，不以非同步 handler 到達時間計算；短按切換錄音、長按放開結束。註冊使用 `kEventHotKeyExclusive`，若其他 App 已占用而註冊失敗，顯示衝突錯誤並讓使用者改快捷鍵。若在麥克風授權彈窗期間放開，controller 記錄停止要求，準備完成後結束錄音。

0.2.3 在收到快捷鍵 press 且已有 Accessibility 授權時，啟動背景序列佇列的 `CGEventSource.keyState` 輪詢；約每 15 ms 一次、2 ms leeway，只檢查 Space 及所註冊快捷鍵需要的修飾鍵左右兩側。它在 press 尚未完成期間運作，偵測放開後多等 75 ms，優先採用 Carbon release 的實際時間。registration／press generation 防止延遲回呼重複完成或結束下一次錄音；取消註冊也停止輪詢。沒有可靠 held 樣本且延遲到無法區分短按／長按時，觸發 `onUncertainRelease`，controller 取消錄音並提示重試，避免默默持續錄音。此檢查不安裝 event tap、不要求 Input Monitoring、不讀其他按鍵，也不保存或上傳按鍵狀態；未授權 AX 時仍依 Carbon 路徑。

HUD 在其他 App 保持焦點時可見，呈現現有 controller 的狀態／未定稿文字／錯誤，不靠切換前景視窗更新。它不成為 key window，也不接收點擊。設定中的「預覽浮動字幕」使用合成文字，不啟動麥克風、網路或文字插入；此預覽只能檢查外觀，不能當作真實 ASR 驗證。

錄音與網路處理可取消。取消停止麥克風、釋放佇列並取消 WebSocket／HTTP；錄音期間已送往 Google 的 bytes 無法收回。停止錄音時，先排空已接受的錄音 buffer 與重取樣尾端，再傳送 `activityEnd`，避免結尾音節被本機提早截斷。插入開始後不提供「撤回貼上」式取消，因為文字可能已由目標接收；剪貼簿 fallback 的 800 ms 恢復等待也不因 task cancellation 提早結束。

如果此時要求正常結束 App，App delegate 會延後終止，等插入及剪貼簿恢復處理完成後才離開；強制終止或程序崩潰仍不受此流程保護。

## 音訊與記憶體

錄音使用系統預設麥克風，由 AVAudioEngine 擷取，AVAudioConverter 轉為 16 kHz、單聲道、signed Int16 little-endian **raw PCM**。一般輸出 chunk 為 100 ms（1,600 frames、3,200 bytes），最後一塊可不足 100 ms。不是 WAV，沒有 RIFF header；0.2 不建立音訊暫存檔案。

音訊串流佇列最多保留 128 個 chunks；音訊處理或網路跟不上而導致 buffer overflow／drop 時，回報錯誤並終止本次語音輸入，避免靜默漏字。128 個完整 chunks 的 PCM 本體約 409,600 bytes，但這不是整個 App 的 RAM 上限：另有硬體 buffer、轉換佇列、Base64／JSON、網路與 UI 開銷。

單次語音輸入限制約兩分鐘，UI 約在 119 秒結束錄音。短於約 0.35 秒時停止後不進入完成／插入流程；由於這是串流，**極短或取消的錄音也可能已有片段送出**。裝置變更／中斷會終止本次錄音，需重新開始。記憶體釋放不等於保證作業系統不產生 swap 或 crash diagnostics；沒有持久音訊／逐字稿歷史功能。

## Live ASR contract

ASR 預設 `gemini-3.5-transcribe-live`，對齊本次觀察到的 Dup 設定，證據見 [DUP_MODELS.md](DUP_MODELS.md)。固定連至 `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`。模型名稱先做格式檢查；key 依下述傳輸安全規則處理，只放 `x-goog-api-key` header，不放 URL。redirect 被拒絕，不自動重試可能收費的工作。

key 視為不解讀內容的 opaque 字串：去除貼上時的前後空白後，要求非空、最多 8,192 UTF-8 bytes，內部不得有空白，且只能有可見 ASCII（33–126）。這個 8 KiB 上限是本程式的防護，不是 Google 的格式規範。沒有固定前綴、舊的英數底線白名單或 256 字元上限，因此不再因 `AQ.` 形式的句點或長度本身拒絕金鑰。Live 與 HTTP 整理共用同一檢查；通過只代表可安全放入單一 header，伺服器才決定是否有效。

Google 說明 AI Studio 自 2026-05-28 起預設建立綁定 service account 的 authorization key；Cloud 文件將 `keyString` 定義為呼叫 API 使用的加密字串，未提供此處舊 regex 可依賴的固定長度／字元規範。OpenInsert 不解析、解碼或猜測 key 身分。這修正了可由原始碼確認的本機拒絕路徑；未讀取任何使用者實際 key，因此不能據此確認個別失敗的根因，也不能宣稱已完成真實服務驗證。[Gemini key 指引](https://ai.google.dev/gemini-api/docs/api-key)、[Google Cloud API keys](https://docs.cloud.google.com/docs/authentication/api-keys)

setup 指定 `responseModalities: ["TEXT"]`、`inputAudioTranscription.mode: "VERBATIM"`、自訂詞彙與 `languageCodes: []`。語言自動偵測，不把 UI 的自然語言偏好字串誤當 BCP-47 code；官方表未列台灣華語專用的繁中 code。0.2.3 的文字語言選單提供繁體中文（台灣）、自動、簡體中文、English、日本語、韓語與自訂；舊的已知標籤移轉至對應選項，其他自訂文字保留。繁／簡偏好在即時預覽及定稿後用本機 `Hans-Hant`／`Hant-Hans` 字形轉換，英文維持原樣；其他選項保留原字形，並作為可選整理的書寫偏好。此選單不指定翻譯目標，字形轉換也不能保證台灣用詞、專有名詞或一對多字形全正確。

採 manual VAD：關閉 `automaticActivityDetection`，收到 `setupComplete` 後才送 `activityStart` 及 PCM chunks；結束時送 `activityEnd`，不混用 auto VAD 路徑的 `audioStreamEnd`。`interimInputTranscription` 更新未定稿假說；`inputTranscription` 附加確定段落並清掉前一段 interim。未定稿預覽不寫入目的 App。[Live Transcription](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe)

**完成判定仍是有界等待策略。** 官方 Live Transcription 文件將 `inputTranscription` 定義為確定段落，未要求 dedicated ASR 以 `turnComplete` 作為完成標記；通用 reference 亦不保證 input transcription 與其他訊息的順序。0.2.3 對精確的 `gemini-3.5-transcribe-live` 不再強制等待 `turnComplete`：必須成功送出 `activityEnd`、已有 authoritative final、沒有未解決的 interim，並等待一秒沒有轉錄更新，才使用累積結果。若 final 在放開按鍵前就已抵達，安靜期間仍從 end 成功送出後開始；更新會重設等待。其他自訂 model ID 保留額外的 `turnComplete` 條件。`finished` 等 metadata 只供診斷，不把 interim 升格定稿，也不清除尚未解決的尾段。20 秒 ASR deadline 到期仍不滿足就失敗、不插入；它發生在後修之前。這不是所有轉錄已到齊的協定保證，可能增加延遲或漏掉更晚到的片段，必須持續以真實服務驗證。[Live Transcription](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe)、[WebSocket API reference](https://ai.google.dev/api/live)

setup deadline 為 10 秒；Live session resource timeout 為 180 秒；單一 server message 上限 262,144 bytes，累積文字上限 64,000 UTF-8 bytes。自訂詞彙最多 1,000 個、單項最多 512 bytes、合計最多 16,000 bytes。錯誤、異常關閉或不合規回覆不觸發自動插入。

## 可選文字整理與資料流

設定的 `polished` 模式（預設）會將已完成 ASR 文字交給 `GeminiClient.polish`；`verbatim` 跳過第二次呼叫。整理預設模型 `gemini-3.5-flash-lite`，使用 `POST /v1beta/models/{model}:generateContent`。原本 0.1 的 `gemini-3.8-flash` 預設會遷移至 Flash Lite；使用者另存的自訂整理模型則保留。兩個模型欄位的 API 能力必須各自相容，不能任意互換。

第二階段只有文字：固定 system instruction 與 JSON 資料內的逐字稿、語言／字形偏好、自訂詞彙，沒有音訊或圖片。提示要求保守處理標點、明顯辨識錯誤與填充詞，保留中英混用、語意、數量與程式碼；不回答口述問題、不執行逐字稿內的指示，不提供 tools。定稿 ASR 文字先存入最後結果。0.2.3 可在後修中按「略過後修，直接使用辨識結果」；略過或遇到總期限、網路、HTTP 429／5xx 等暫時錯誤時，以這份已定稿 ASR 經原有目標驗證後插入，並明確顯示 fallback。取消整次工作、認證／模型等永久錯誤、安全阻擋、無效或不完整回覆不觸發 fallback 插入；結果仍供手動複製。此路徑不使用未定稿預覽。

整理回覆要求 JSON `{status, transcript}`。只有單一候選、`finishReason == STOP`、沒有安全阻擋且 status 為 `ok` 才接受；忽略 thought parts。空白、無語音、拒絕、被截斷、非 JSON 或不完整 envelope 都不進入插入流程。一般錯誤只呈現分類資訊，不回顯可能帶有敏感資料的 provider response body。[generateContent API](https://ai.google.dev/api/generate-content)

精確的 `gemini-3.5-flash-lite` 設定 `thinkingLevel: minimal`；其他 Gemini 3 ID 保留 `low`，不猜測未驗證 alias 的能力。官方表支援 Flash Lite 的 minimal，但 Gemini 3.8 不支援；`includeThoughts: false` 僅不要求思考摘要，不能宣稱停用推理。[Thinking levels](https://ai.google.dev/gemini-api/docs/generate-content/thinking#thinking-levels-gemini-3)

HTTP 整理沿用序列化 request 18,000,000 bytes、response 1,000,000 bytes、轉錄文字 64,000 UTF-8 bytes、language preference 1,000 bytes、vocabulary 16,000 bytes 的上限。底層 URLSession 的 request idle timeout 120 秒與 resource timeout 150 秒保留供共用 client，但 `polish` 額外有 **8 秒總經過時間上限**，不因伺服器慢慢傳 bytes 而延長。可注入更短期限測試。單次完成閘門在期限或使用者取消時立即返回並取消 URLSession operation；不用會等待不合作子工作結束的 task group。晚到結果不得重新完成或覆寫文字。保留非 SSE 的 `generateContent`，只在收到完整 envelope 且通過檢查後回傳。輸出拒絕 NUL、ESC、backspace 等控制字元，保留 tab 與換行。這些限制防止非預期資料，**不能證明轉錄或整理語意一定正確**。

兩種網路 session 都使用 ephemeral configuration，停用 URL cache、cookie storage 與 credential storage；request 設定 `Cache-Control: no-store`，不建立 App 主動管理的 HTTP 磁碟快取。沒有螢幕、剪貼簿、游標周邊文字、應用名稱或 PID 送到 Google。此設定不能控制 Google、作業系統或目的 App 的保存行為。取消也不能收回已傳送的資料。模型可用性與退役需持續查核 [官方停用時程](https://ai.google.dev/gemini-api/docs/deprecations)。

## 文字插入的防護與取捨

### 捕捉與再驗證

已有 Accessibility 授權時，`TextInserter` 會在前景 App 切換及捕捉目標前，檢查實際 bundle 是否包含有效的 `Electron Framework.framework`。確認為 Electron 後，只讀 application role 及 `AXManualAccessibility` 能力／啟用旗標；旗標可寫且尚未啟用時，每次程序啟動最多嘗試設定一次，協助目標建立原生 AX 介面。成功設定後記錄 3 秒準備期間，不阻塞主執行緒等待；此期間僅將符合未就緒情況的焦點缺漏／不支援錯誤顯示為「準備中」。一般焦點與選取範圍讀取會保留實際 AX 屬性名稱及錯誤代碼，權限或安全欄位錯誤不改寫成準備中。這個初始化不列舉 UI 子元件、不讀游標周圍文字，也不上傳 bundle／AX 資訊。

錄音前記下前景 PID、focused AX element、可取得的選取範圍及應用名稱／bundle ID。拒絕自己的視窗、已停用控制項、密碼／受保護欄位；只接受已知文字 role 或可設定 `AXSelectedText` 的元件。macOS Secure Event Input 啟用時也一律拒絕自動插入，涵蓋部分仍暴露一般文字 role 的終端密碼提示。這些是本機插入定位資訊，不送 Google。

插入前重新確認 PID、元件身分與選取範圍相同，避免等待辨識時換 app、換欄位或移動游標造成誤貼。若 AX 未提供 range，前後同為 `nil` 不能偵測同元件內的游標移動。焦點檢查與實際事件派送亦非作業系統原子交易；檢查後瞬間切換仍是殘餘競態。目標應用可自動改內容而不改 range，程式也無法在不讀全文的前提下完整辨識此情況。

### 優先 AX，必要時剪貼簿

若 `AXSelectedText` 可設定，直接寫入。回報失敗時**不自動再貼一次**：timeout 可能發生在目標已消費寫入之後，重試會重複文字。使用者保留最後結果，可先檢查目標再決定手動複製。

只有不支援該寫入屬性時才採剪貼簿 fallback。啟用恢復時完整備份所有目前可取得的 pasteboard item/type 資料；任一格式無法讀取就停止，避免宣稱已備份但遺失資料。備份只在記憶體使用。

送出貼上前確認使用者已放開 Command／Control／Option／Shift，以免修飾鍵混入。寫入剪貼簿後再驗證目標與 `changeCount`，以 CGEvent 派送 Command-V。等待 800 ms，只有剪貼簿仍為自己的版本才恢復；若使用者期間複製新內容就保持新內容。停用恢復時，結果會留在剪貼簿。

這個路徑回報「Paste requested」，不宣稱已讀回確認目標文字。800 ms 是固定折衷，極忙的 App 可能更晚讀取，AX 也可能缺乏完整實作。故必須保留最後結果、手動複製與實際 app 相容性矩陣。

已知終端的 bundle ID 或名稱會觸發額外檢查，拒絕自動插入含換行或 tab 的文字，因為貼上也可能執行命令。這適用於 AX 及剪貼簿路徑，但無法可靠辨識一般編輯器內的整合終端，名稱偵測也可能漏判。OpenInsert 不模擬 Enter，也沒有自動送出功能；這不能保證目的 App 不因收到文字、換行或自訂事件而自行提交。受限結果保留供使用者檢查後手動複製。

## 權限與散布

- **Microphone：** 只在使用者明確開始或按權限按鈕時請求，錄音在目前程序中進行。
- **Accessibility：** 用於定位可編輯欄位與文字插入；不是 OCR 或畫面理解權限。
- **不要求 Screen Recording：** 沒有截圖、OCR、螢幕錄影或系統音效錄音管線。
- **快捷鍵：** 註冊特定 Carbon hotkey，不需要為全鍵盤監聽增加 Input Monitoring。
- **Keychain：** generic password，service `org.openinsert.OpenInsert`、account `gemini-api-key`；新增時為 `WhenUnlockedThisDeviceOnly`。

這是一般 macOS 桌面工具，不使用 App Sandbox。發行 entitlements 宣告 audio-input；Hardened Runtime／Developer ID／notarization 的建置狀態須由 release 產物驗證，不能因已有 entitlements 檔就聲稱完成簽章公證。

`scripts/build-app.sh` 依序選擇 `CODE_SIGN_IDENTITY`、repo 根目錄 `.local-signing-identity` 首行、最後才是 ad-hoc `-`。本機檔已 gitignore，只存既有憑證的 fingerprint 作為 selector，不保存或匯出私鑰，也不當 shell source 執行。非 ad-hoc 簽署使用現有 `codesign` identity、runtime 與 timestamp 選項；所需憑證和私鑰由使用者的本機環境提供。持續使用相同 Apple Development identity 與 app identifier，可維持較穩定的 designated requirement，避免本機每次 rebuild 只因 ad-hoc identity 改變而需重授權；由舊 ad-hoc 副本首次轉換仍可能需要重新授權，TCC 最終決定是否沿用。這不是 Developer ID 或公證；CI 不帶本機 identity 檔，公開預設仍 ad-hoc。個人憑證、email、fingerprint 與私鑰都不得進入公開 repo 或文件。[Apple code signing identity／DR](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

## 驗證範圍與限制

測試應分三層：可注入 HTTP transport 驗證整理 request／response；可注入 WebSocket transport 驗證 setup、PCM 傳送、interim／final、out-of-order 訊息、安靜等待、deadline 與取消；原生音訊測試驗證重取樣、尾端排空及 backpressure。0.1 的 19 個 HTTP 核心測試不能視為新 Live 管線已驗證。實際執行數目與結果由 [VALIDATION.md](VALIDATION.md) 記錄。

原生麥克風權限、TCC、按住／切換快捷鍵、真實語音品質、AX 寫入、剪貼簿競態、瀏覽器／Electron／終端／遠端桌面與乾淨安裝，都需要額外整合測試。建議矩陣在 [SURVEY.md](SURVEY.md)。沒有實測數據前，不承諾特定辨識率、延遲、CPU／RAM 或所有 App 支援。

後續改進依使用證據排序：真實 Live 完成訊號與繁中語料回歸、可調整貼上恢復延遲、更多目的 App 相容性、麥克風選擇、本地 Whisper provider，再評估跨平台。不為尚未完成的項目在產品 UI 顯示已支援。
