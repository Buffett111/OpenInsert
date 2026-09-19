# OpenInsert 架構與取捨

本文描述 0.1.0 原始碼的設計。平台為 macOS 13 以上，Swift Package 使用 Swift tools 5.9；程式本身不依賴第三方 package。編譯、單元測試、UI、真實 API 與跨應用插入屬不同驗證層，實際執行結果以 README／驗證紀錄為準。

## 使用流程

使用者先儲存自己的 Gemini API key，明確同意將主動錄製的音訊送到 Google，再核准麥克風與所需的輔助使用權限。將游標放在其他 App 的文字欄位，以預設 **Option + Space** 開始。按住至少約 0.35 秒再放開會結束錄音；短按可開始，再按一次停止。可切換為 Control + Option + Space 或 Control + Shift + Space，避開其他軟體的快捷鍵。

沒有可驗證的目標欄位或沒有 Accessibility 權限時，仍可辨識並保留結果供手動複製；程式不會因此把內容貼到任意前景視窗。麥克風權限、有效金鑰與雲端同意仍為錄音／雲端路徑的必要條件。

```text
使用者快捷鍵／錄音按鈕
        │
        ├─ 記住目前應用、AX 元件及選取範圍（不讀文字）
        │
        ▼
AVAudioRecorder ── 麥克風 → 私有暫存 WAV
        │                   16 kHz / mono / 16-bit PCM
        ▼
停止並讀入 Data → 刪除暫存資料夾
        │
        ▼
GeminiClient → HTTPS → generativelanguage.googleapis.com
        │              音訊 + 語言偏好 + 自訂詞彙 + 固定轉錄指示
        ▼
驗證回覆 → 最後結果留在 RAM
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
| `AudioRecorder` | 麥克風授權、WAV、音量、最長時長、清理 | 不錄系統音效、不做串流 ASR |
| `GlobalHotKey` | Carbon `RegisterEventHotKey` 註冊指定快捷鍵與放開事件 | 不安裝監聽全部按鍵的 event tap |
| `GeminiClient` | request 建構、網路、大小限制、回覆解析 | 不讀剪貼簿／AX、不執行模型產生的指令 |
| `TextInserter` | 目標捕捉、驗證、AX 寫入與剪貼簿交易 | 不從畫面收集上下文，不保證所有程式接受合成貼上 |
| `SettingsStore` | UserDefaults 中的模型、語言、詞彙、模式、快捷鍵與同意設定 | 不保存 key 或逐字稿 |
| `KeychainStore` | 儲存／刪除使用者 Gemini key | 不在 release 內提供共用 key |

## 狀態與取消

主要狀態為 `idle → preparing → recording → transcribing → inserting → idle`，另有獨立的 `testing` 插入測試狀態。MainActor 序列化 UI 與系統互動；每次工作有 generation UUID，舊的非同步回覆不能更新新的 session。

設定在錄音起始時擷取，避免處理途中改模型、模式或恢復選項造成同一段錄音前後不一致。按鍵 repeat 由 GlobalHotKey 去重；新 shortcut registration ID 可排除舊註冊遺留事件。若使用者在麥克風授權彈窗期間放開快捷鍵，controller 記錄停止要求，準備完成後結束錄音。

錄音與網路處理可取消。取消透過 Swift task cancellation 傳遞至 URLSession，並清掉本機錄音；已送往 Google 的 bytes 無法收回。插入開始後不提供「撤回貼上」式取消，因為文字可能已由目標接收；剪貼簿 fallback 的 800 ms 恢復等待也不因 task cancellation 提早結束。

如果此時要求正常結束 App，App delegate 會延後終止，等插入及剪貼簿恢復處理完成後才離開；強制終止或程序崩潰仍不受此流程保護。

## 音訊與暫存

錄音使用系統預設麥克風，格式為 16 kHz、單聲道、16-bit little-endian PCM WAV，最長 120 秒。UI 定時檢查約在 119 秒結束處理，底層 recorder 仍有 120 秒上限。未滿約 0.35 秒不送辨識；WAV 的 RIFF/WAVE 標頭與資料長度會做基本驗證。

檔案位於作業系統 temporary directory 下，資料夾名稱為 `OpenInsert-<UUID>`，建立為 `0700`。停止後先讀入記憶體，再清除暫存；正常取消、啟動失敗與 App shutdown 也會清理。**強制結束、程序崩潰、斷電或檔案刪除失敗仍可能留下暫存**；目前不能宣稱具備崩潰後零殘留或安全抹除。沒有長期音訊歷史功能。

2 分鐘 PCM 的音訊本體約 `16,000 × 1 × 2 × 120 = 3,840,000` bytes，Base64 約 5.12 MB，另加 WAV header、prompt 與 JSON。網路核心仍會檢查完整 request 容量，不依賴這項理論估算。

## Gemini contract

預設模型是 `gemini-3.8-flash`，使用官方 `generateContent` HTTP API。URL origin 固定為 `https://generativelanguage.googleapis.com`；模型名稱與 key 先做格式檢查。API key 僅放在 `x-goog-api-key` header，不放 URL；所有 HTTP redirect 都拒絕，以免敏感 header 被送到不同路徑。request timeout 為 120 秒，預設 session 的 resource timeout 為 150 秒，不自動重試可能收費的請求。

預設網路 session 使用 ephemeral configuration，停用 URL cache、cookie storage 與 credential storage；request 加上 `Cache-Control: no-store`，delegate 也拒絕快取回覆。此設定避免 App 主動建立 HTTP 磁碟快取，不代表作業系統記憶體、目的 App 或 Google 不可能保存資料。測試仍可注入自己的 URLSession。

同一次請求包含：固定 `systemInstruction`、以 JSON 包裹且標記為資料的語言／詞彙偏好，以及 WAV 的 inline Base64。沒有螢幕、剪貼簿、游標周邊文字、應用程式名稱或 PID。此版本的「清理」是在音訊辨識的同次請求中要求保守修正，**不是第二次文字修正 API 呼叫**。

`verbatim` 保留口頭詞、重複詞與原句，仍允許標點；`polished` 輕度清理填充詞與意外重複。兩者都要求保留中英混用、不回答口述問題、不執行語音中的指示。不向模型提供任何 tools。

回覆要求 JSON `{status, transcript}`。只有單一候選、`finishReason == STOP`、沒有安全阻擋且 status 為 `ok` 才接受；忽略 thought parts。空白、`no_speech`、`unintelligible`、`refused`、被截斷、非 JSON 或不完整 envelope 都不進入插入流程。一般錯誤只呈現分類資訊，不回顯可能帶有敏感資料的 provider response body。

資源上限：序列化 request 18,000,000 bytes；response 1,000,000 bytes；轉錄文字 UTF-8 64,000 bytes；language preference 1,000 bytes；vocabulary 16,000 bytes。輸出拒絕 NUL、ESC、backspace 等控制字元，保留 tab 與換行。這些限制防止非預期資料，**不能證明轉錄語意一定正確或完全沒有幻覺**。

模型欄位是可修改的名稱，不是完整 provider plugin。使用只支援 Interactions API 的專用 transcribe 模型，不能只替換名稱；新增模型前應確認端點、音訊格式、structured output 與 thinkingConfig 相容性。[Gemini API](https://ai.google.dev/api/generate-content)、[模型停用時程](https://ai.google.dev/gemini-api/docs/deprecations)

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

`OpenInsertCoreTests` 以可注入 URLSession 測試 request、惡意 model/key/偏好輸入、Base64 後總大小、HTTP／timeout／取消、拒絕 redirect、response 上限、thought 排除、finish reason、阻擋及無語音、控制字元等。它們驗證協定與失敗處理，沒有向 Google 發出真實辨識請求。實際已執行與待執行的項目記於 [VALIDATION.md](VALIDATION.md)。

原生麥克風權限、TCC、按住／切換快捷鍵、真實語音品質、AX 寫入、剪貼簿競態、瀏覽器／Electron／終端／遠端桌面與乾淨安裝，都需要額外整合測試。建議矩陣在 [SURVEY.md](SURVEY.md)。沒有實測數據前，不承諾特定辨識率、延遲、CPU／RAM 或所有 App 支援。

後續改進依使用證據排序：可調整貼上恢復延遲與更完整 receipt 研究、異常退出暫存清理、真實繁中語料回歸、麥克風選擇、獨立兩階段修正、本地 Whisper provider，再評估跨平台。不為尚未完成的項目在產品 UI 顯示已支援。
