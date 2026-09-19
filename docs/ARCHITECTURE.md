# OpenInsert 架構與取捨

本文描述 0.2.1 原始碼的設計。平台為 macOS 13 以上，Swift Package 使用 Swift tools 5.9；程式本身不依賴第三方 package。編譯、單元測試、UI、真實 API 與跨應用插入屬不同驗證層，實際執行結果以 [VALIDATION.md](VALIDATION.md) 為準。

## 使用流程

使用者先儲存自己的 Gemini API key，明確同意錄音期間將音訊串流至 Google，以及啟用整理時傳送逐字稿，再核准麥克風與所需的輔助使用權限。0.2 使用獨立的 `liveCloudConsent` 設定，0.1 的上傳同意不會自動沿用。將游標放在其他 App 的文字欄位，以預設 **Option + Space** 開始。按住至少約 0.35 秒再放開會結束錄音；短按可開始，再按一次停止。可切換為 Control + Option + Space 或 Control + Shift + Space，避開其他軟體的快捷鍵。

沒有可驗證的目標欄位或沒有 Accessibility 權限時，仍可辨識並保留結果供手動複製；程式不會因此把內容貼到任意前景視窗。麥克風權限、有效金鑰與雲端同意仍為錄音／雲端路徑的必要條件。

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
                              │ 失敗 → 保留 ASR 結果供手動複製
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
| `DictationController` | 管理狀態、session、取消、錄音至插入的串接 | 不保存逐字稿資料庫 |
| `StreamingAudioRecorder` | 麥克風授權、音訊重取樣、PCM 分塊、音量與有界 RAM 佇列 | 不錄系統音效、不建立錄音檔案 |
| `GlobalHotKey` | Carbon `RegisterEventHotKey` 註冊指定快捷鍵與放開事件 | 不安裝監聽全部按鍵的 event tap |
| `GeminiLiveTranscriber` | WebSocket setup、PCM 傳送、interim／final 解析、完成等待與取消 | 不把 interim 當定稿、不讀本機輸入欄位文字 |
| `GeminiClient.polish` | 文字整理的 HTTP request、大小限制與回覆解析 | 不重送音訊、不讀剪貼簿／AX、不執行模型產生的指令 |
| `TextInserter` | 目標捕捉、驗證、AX 寫入與剪貼簿交易 | 不從畫面收集上下文，不保證所有程式接受合成貼上 |
| `SettingsStore` | UserDefaults 中的模型、語言、詞彙、模式、快捷鍵與同意設定 | 不保存 key 或逐字稿 |
| `KeychainStore` | 儲存／刪除使用者 Gemini key | 不在 release 內提供共用 key |

## 狀態與取消

主要狀態為 `idle → preparing → recording → transcribing → inserting → idle`，另有獨立的 `testing` 插入測試狀態。MainActor 序列化 UI 與系統互動；每次工作有 generation UUID，舊的非同步回覆不能更新新的 session。

設定在錄音起始時擷取，避免處理途中改模型、模式或恢復選項造成同一段錄音前後不一致。按鍵 repeat 由 GlobalHotKey 去重；新 shortcut registration ID 可排除舊註冊遺留事件。若使用者在麥克風授權彈窗期間放開快捷鍵，controller 記錄停止要求，準備完成後結束錄音。

錄音與網路處理可取消。取消停止麥克風、釋放佇列並取消 WebSocket／HTTP；錄音期間已送往 Google 的 bytes 無法收回。停止錄音時，先排空已接受的錄音 buffer 與重取樣尾端，再傳送 `activityEnd`，避免結尾音節被本機提早截斷。插入開始後不提供「撤回貼上」式取消，因為文字可能已由目標接收；剪貼簿 fallback 的 800 ms 恢復等待也不因 task cancellation 提早結束。

如果此時要求正常結束 App，App delegate 會延後終止，等插入及剪貼簿恢復處理完成後才離開；強制終止或程序崩潰仍不受此流程保護。

## 音訊與記憶體

錄音使用系統預設麥克風，由 AVAudioEngine 擷取，AVAudioConverter 轉為 16 kHz、單聲道、signed Int16 little-endian **raw PCM**。一般輸出 chunk 為 100 ms（1,600 frames、3,200 bytes），最後一塊可不足 100 ms。不是 WAV，沒有 RIFF header；0.2 不建立音訊暫存檔案。

音訊串流佇列最多保留 128 個 chunks；音訊處理或網路跟不上而導致 buffer overflow／drop 時，回報錯誤並終止本次語音輸入，避免靜默漏字。128 個完整 chunks 的 PCM 本體約 409,600 bytes，但這不是整個 App 的 RAM 上限：另有硬體 buffer、轉換佇列、Base64／JSON、網路與 UI 開銷。

單次語音輸入限制約兩分鐘，UI 約在 119 秒結束錄音。短於約 0.35 秒時停止後不進入完成／插入流程；由於這是串流，**極短或取消的錄音也可能已有片段送出**。裝置變更／中斷會終止本次錄音，需重新開始。記憶體釋放不等於保證作業系統不產生 swap 或 crash diagnostics；沒有持久音訊／逐字稿歷史功能。

## Live ASR contract

ASR 預設 `gemini-3.5-transcribe-live`，對齊本次觀察到的 Dup 設定，證據見 [DUP_MODELS.md](DUP_MODELS.md)。固定連至 `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`。模型與 key 先做格式檢查，API key 只放 `x-goog-api-key` header，不放 URL。redirect 被拒絕，不自動重試可能收費的工作。

setup 指定 `responseModalities: ["TEXT"]`、`inputAudioTranscription.mode: "VERBATIM"`、自訂詞彙與 `languageCodes: []`。語言自動偵測，不把 UI 的自然語言偏好字串誤當 BCP-47 code；官方表未列台灣華語專用的繁中 code。繁中偏好改在定稿後用本機 `Hans-Hant` 字形轉換，英文維持原樣。這是字形轉換，不能保證台灣用詞、專有名詞或一對多字形全正確。

採 manual VAD：關閉 `automaticActivityDetection`，收到 `setupComplete` 後才送 `activityStart` 及 PCM chunks；結束時送 `activityEnd`，不混用 auto VAD 路徑的 `audioStreamEnd`。`interimInputTranscription` 更新未定稿假說；`inputTranscription` 附加確定段落並清掉前一段 interim。未定稿預覽不寫入目的 App。[Live Transcription](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe)

**完成判定是目前的主要限制。** 官方 reference 不保證 input transcription 與其他 server 訊息的順序；SDK optional `finished` 亦未被保證每次傳送。0.2 在送出 `activityEnd` 後，需要收到 `turnComplete`、沒有未解決的 interim，並等待一秒沒有轉錄更新，才使用累積結果；更新會重設等待。20 秒 deadline 到期仍不滿足時回報失敗、不自動插入。這是有界等待的 heuristic，並非伺服器確認所有轉錄到齊的 barrier；可能增加延遲，也可能漏掉一秒以後才到的片段。必須以真實服務測試，不能用 fake transport 推論完整性。[WebSocket API reference](https://ai.google.dev/api/live)

setup deadline 為 10 秒；Live session resource timeout 為 180 秒；單一 server message 上限 262,144 bytes，累積文字上限 64,000 UTF-8 bytes。自訂詞彙最多 1,000 個、單項最多 512 bytes、合計最多 16,000 bytes。錯誤、異常關閉或不合規回覆不觸發自動插入。

## 可選文字整理與資料流

設定的 `polished` 模式（預設）會將已完成 ASR 文字交給 `GeminiClient.polish`；`verbatim` 跳過第二次呼叫。整理預設模型 `gemini-3.5-flash-lite`，使用 `POST /v1beta/models/{model}:generateContent`。原本 0.1 的 `gemini-3.8-flash` 預設會遷移至 Flash Lite；使用者另存的自訂整理模型則保留。兩個模型欄位的 API 能力必須各自相容，不能任意互換。

第二階段只有文字：固定 system instruction 與 JSON 資料內的逐字稿、語言／字形偏好、自訂詞彙，沒有音訊或圖片。提示要求保守處理標點、明顯辨識錯誤與填充詞，保留中英混用及語意；不回答口述問題、不執行逐字稿內的指示，不提供 tools。定稿 ASR 文字先存入最後結果；若整理失敗，仍可手動複製這份文字，但本次不自動插入。

整理回覆要求 JSON `{status, transcript}`。只有單一候選、`finishReason == STOP`、沒有安全阻擋且 status 為 `ok` 才接受；忽略 thought parts。空白、無語音、拒絕、被截斷、非 JSON 或不完整 envelope 都不進入插入流程。一般錯誤只呈現分類資訊，不回顯可能帶有敏感資料的 provider response body。[generateContent API](https://ai.google.dev/api/generate-content)

HTTP 整理沿用序列化 request 18,000,000 bytes、response 1,000,000 bytes、轉錄文字 64,000 UTF-8 bytes、language preference 1,000 bytes、vocabulary 16,000 bytes 的上限；request timeout 為 120 秒、resource timeout 為 150 秒。輸出拒絕 NUL、ESC、backspace 等控制字元，保留 tab 與換行。這些限制防止非預期資料，**不能證明轉錄或整理語意一定正確**。

兩種網路 session 都使用 ephemeral configuration，停用 URL cache、cookie storage 與 credential storage；request 設定 `Cache-Control: no-store`，不建立 App 主動管理的 HTTP 磁碟快取。沒有螢幕、剪貼簿、游標周邊文字、應用名稱或 PID 送到 Google。此設定不能控制 Google、作業系統或目的 App 的保存行為。取消也不能收回已傳送的資料。模型可用性與退役需持續查核 [官方停用時程](https://ai.google.dev/gemini-api/docs/deprecations)。

## 文字插入的防護與取捨

### 捕捉與再驗證

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

## 驗證範圍與限制

測試應分三層：可注入 HTTP transport 驗證整理 request／response；可注入 WebSocket transport 驗證 setup、PCM 傳送、interim／final、out-of-order 訊息、安靜等待、deadline 與取消；原生音訊測試驗證重取樣、尾端排空及 backpressure。0.1 的 19 個 HTTP 核心測試不能視為新 Live 管線已驗證。實際執行數目與結果由 [VALIDATION.md](VALIDATION.md) 記錄。

原生麥克風權限、TCC、按住／切換快捷鍵、真實語音品質、AX 寫入、剪貼簿競態、瀏覽器／Electron／終端／遠端桌面與乾淨安裝，都需要額外整合測試。建議矩陣在 [SURVEY.md](SURVEY.md)。沒有實測數據前，不承諾特定辨識率、延遲、CPU／RAM 或所有 App 支援。

後續改進依使用證據排序：真實 Live 完成訊號與繁中語料回歸、可調整貼上恢復延遲、更多目的 App 相容性、麥克風選擇、本地 Whisper provider，再評估跨平台。不為尚未完成的項目在產品 UI 顯示已支援。
