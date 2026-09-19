# Privacy / 隱私

This describes OpenInsert 0.1.0. OpenInsert has no product account, developer-operated server, analytics SDK, screenshot capture, OCR, or transcript-history database.

## English

**Cloud processing:** After you enable cloud consent and start dictation, your recording, language preference, custom vocabulary, and transcription instructions are sent directly to Google's Gemini API at `generativelanguage.googleapis.com`, using your own API key. Cleanup happens in the same request. Google receives the request and ordinary connection metadata such as your IP address. OpenInsert is not an offline recognizer. Google's [Gemini API terms](https://ai.google.dev/gemini-api/terms) govern provider processing; paid and unpaid service terms differ.

**On your Mac:** Your API key is stored in macOS Keychain. Model, language, vocabulary, shortcut, cleanup, clipboard and consent settings are stored in UserDefaults. Recordings use an app-created `OpenInsert-<UUID>` temporary directory and are deleted on normal stop, cancellation, or handled failure. Crashes, forced termination, power loss or a failed deletion can leave temporary files; deletion is not secure erasure. The most recent transcript is held in application memory until replaced, cleared, or the app exits. OpenInsert does not intentionally write a transcript log or history.

The default HTTP session is ephemeral, with URL cache, cookie storage and credential storage disabled. Requests specify `no-store`, and the session delegate refuses response caching. This does not control retention by Google, the operating system or destination apps.

**Other apps and clipboard:** Accessibility is used to inspect the focused app, element role/protection state, and selection range, and to insert text. OpenInsert does not read the text around your cursor or send accessibility metadata to Google. When direct insertion is unsupported, it temporarily writes the result to the system clipboard and requests Command-V. With clipboard restoration enabled, existing clipboard formats are read into memory solely for restoration and are never uploaded. Restoration occurs only if the clipboard has not changed. Copying a result manually intentionally leaves it on the clipboard. The destination app, clipboard managers and system clipboard features may retain or sync inserted/copied text under their own settings.

Automatic insertion is blocked while Secure Event Input is active and for newlines/tabs in recognized terminal apps. Embedded terminals may not be recognized. OpenInsert never simulates Enter; destination apps can still react to inserted text under their own behavior. A normal quit waits for any ongoing insertion and clipboard restoration to finish.

**Your controls:** Recording requires microphone access and an explicit start. You can cancel before insertion, clear the last result, delete the key from OpenInsert settings, disable cloud consent, or revoke permissions in System Settings. Cancelling cannot recall data already uploaded. Deleting the app does not automatically remove its Keychain entry, preferences or exceptional leftover temporary files; delete the key in settings before uninstalling if you want it removed. OpenInsert does not request Screen Recording permission or install an all-key keyboard event monitor.

## 繁體中文

**雲端處理：** 同意雲端處理並主動開始語音輸入後，錄音、語言偏好、自訂詞彙與轉錄指示會以你自己的 API key 直接送往 Google Gemini 的 `generativelanguage.googleapis.com`。文字清理在同次請求進行。Google 也會收到 IP 位址等一般連線資訊；OpenInsert 並非離線辨識工具。供應商資料處理依 [Gemini API 條款](https://ai.google.dev/gemini-api/terms)，付費與未付費服務條件不同。

**本機保存：** API key 存於 macOS Keychain；模型、語言、詞彙、快捷鍵、清理、剪貼簿與同意設定存於 UserDefaults。錄音使用 App 建立的 `OpenInsert-<UUID>` 暫存資料夾，正常停止、取消或已處理的失敗會刪除。崩潰、強制關閉、斷電或刪除失敗可能留下暫存；一般刪除也不等於安全抹除。最後一份結果保留於 App 記憶體，直到被取代、清除或 App 結束。App 不建立逐字稿歷史或內容日誌。

預設 HTTP session 為 ephemeral，停用 URL cache、cookie storage 與 credential storage，請求指定 `no-store`，delegate 也拒絕快取回覆。這不能控制 Google、作業系統或目的 App 的保存行為。

**其他 App 與剪貼簿：** 輔助使用 API 只檢查目前 App、焦點元件角色／保護狀態、選取範圍並插入文字，不讀游標周圍的文字，也不將這些定位資訊送 Google。無法直接插入時，暫用系統剪貼簿並發出 Command-V。啟用恢復時，原剪貼簿資料只在記憶體內備份、不上傳，且僅在剪貼簿尚未改變時恢復。手動複製會把結果留在剪貼簿；目的 App、剪貼簿管理器及系統剪貼簿功能可能依各自設定保存或同步文字。

Secure Event Input 啟用時會拒絕自動插入；辨識為終端 App 時也拒絕自動插入換行或 tab，但可能無法辨識嵌入其他 App 的終端。OpenInsert 不模擬 Enter，目的 App 仍可能依自身行為對插入文字作出反應。正常結束 App 會先等進行中的插入與剪貼簿恢復處理完成。

**你的控制：** 錄音需要麥克風權限與明確啟動，可在插入前取消、清除最後結果、在設定刪除金鑰、停用雲端同意，或在系統設定撤銷權限。取消無法收回已上傳資料。直接刪除 App 不會自動移除 Keychain 項目、偏好設定或例外留下的暫存檔；若要移除金鑰，請先在 App 設定刪除。OpenInsert 不要求螢幕錄製權限，也不安裝監聽所有按鍵的監視器。

Implementation details / 實作細節：[ARCHITECTURE.md](ARCHITECTURE.md)。
