# Privacy / 隱私

This describes OpenInsert 0.2.2. OpenInsert has no product account, developer-operated server, analytics SDK, screenshot capture, OCR, or transcript-history database.

## English

**Cloud processing:** After you enable live cloud consent and start dictation, raw microphone audio streams directly to Google's Gemini API at `generativelanguage.googleapis.com` **while you speak**, using your own API key. ASR uses `gemini-3.5-transcribe-live`, automatic language detection, and your custom vocabulary. With cleanup enabled (the default), a separate text-only request sends the finalized transcript, writing-language preference, vocabulary, and editing instructions to `gemini-3.5-flash-lite`. Verbatim mode skips that request. Google also receives connection metadata such as your IP address. OpenInsert is not offline. Google's [Gemini API terms](https://ai.google.dev/gemini-api/terms) govern provider processing; paid and unpaid service terms differ.

**On your Mac:** Your API key is stored in macOS Keychain. ASR/cleanup models, language, vocabulary, shortcut, cleanup, clipboard and consent settings are stored in UserDefaults. Audio uses bounded RAM buffers; 0.2 creates no recording files. Live previews and final transcripts are held in app memory. The last finalized result remains available until replaced, cleared, or the app exits; a cleanup failure preserves the finalized ASR result for manual copy without inserting it. Traditional Chinese character conversion happens locally. OpenInsert does not intentionally write transcript logs or history. Memory-only processing does not guarantee that the operating system never writes swap or crash diagnostics.

The WebSocket and cleanup HTTP sessions are ephemeral, with URL cache, cookie storage and credential storage disabled. Requests specify `no-store`; the app does not intentionally create a persistent network cache. This does not control retention by Google, the operating system or destination apps.

**Local checks and preview:** Before opening the microphone, OpenInsert checks the saved key for header safety and checks local ASR settings. This does not contact Google or prove that the key is authorized. It does not inspect the key's identity or log its contents. A floating, nonactivating panel displays the current transcript preview, status, or error without capturing the screen or reading the app behind it. The **預覽浮動字幕** button shows synthetic text only, with no microphone, network request, or insertion.

**Optional connection check:** **檢查 Gemini 連線（不錄音）** requires a saved Keychain key and Google consent. It contacts Google with that key, the selected Live model, and fixed session settings, then closes the session. The custom vocabulary is empty; no microphone, audio, transcript, or insertion is involved. Google receives the authentication and ordinary connection metadata. Success confirms only that the connection and model setup were accepted, not successful ASR or insertion.

**Other apps and clipboard:** Accessibility is used to inspect the focused app, element role/protection state, and selection range, and to insert text. OpenInsert does not read the text around your cursor or send accessibility metadata to Google. When direct insertion is unsupported, it temporarily writes the result to the system clipboard and requests Command-V. With clipboard restoration enabled, existing clipboard formats are read into memory solely for restoration and are never uploaded. Restoration occurs only if the clipboard has not changed. Copying a result manually intentionally leaves it on the clipboard. The destination app, clipboard managers and system clipboard features may retain or sync inserted/copied text under their own settings.

Automatic insertion is blocked while Secure Event Input is active and for newlines/tabs in recognized terminal apps. Embedded terminals may not be recognized. OpenInsert never simulates Enter; destination apps can still react to inserted text under their own behavior. A normal quit waits for any ongoing insertion and clipboard restoration to finish.

**Your controls:** Recording requires microphone access and an explicit start. Upgrading from 0.1 requires new live-streaming consent; the earlier upload consent is not reused. You can cancel before insertion, clear the last result, delete the key from settings, disable consent, or revoke permissions in System Settings. Even a very short or cancelled recording may already have sent audio; cancellation cannot recall it. Deleting the app does not automatically remove its Keychain entry or preferences; delete the key in settings before uninstalling if desired. Old 0.1 crash leftovers, if any, are not removed by the new memory-only pipeline. OpenInsert does not request Screen Recording permission or install an all-key keyboard event monitor.

**Updates and permissions:** Updating or rebuilding an ad-hoc signed copy can invalidate its previous Accessibility grant. An enabled-looking entry in System Settings may belong to the old build. If needed, remove that entry and add the current installed app; its local path is shown in Connection & Permissions. OpenInsert does not grant, reset, or bypass system permissions automatically.

## 繁體中文

**雲端處理：** 同意即時雲端處理並主動開始後，原始麥克風音訊會**在說話期間**透過你自己的 API key，直接串流到 Google Gemini 的 `generativelanguage.googleapis.com`。ASR 使用 `gemini-3.5-transcribe-live`、自動語言偵測與自訂詞彙。啟用輕度整理（預設）時，再以獨立的純文字請求，將確定的逐字稿、書寫語言偏好、詞彙與整理指示送至 `gemini-3.5-flash-lite`；逐字模式跳過第二階段。Google 也會收到 IP 位址等連線資訊。OpenInsert 並非離線辨識工具，供應商處理依 [Gemini API 條款](https://ai.google.dev/gemini-api/terms)，付費與未付費服務條件不同。

**本機保存：** API key 存於 macOS Keychain；ASR／整理模型、語言、詞彙、快捷鍵、整理、剪貼簿與同意設定存於 UserDefaults。音訊使用有界 RAM 緩衝，0.2 不建立錄音檔案。未定稿預覽與確定文字保存在 App 記憶體；最後結果可供複製，直到被取代、清除或 App 結束。整理失敗時保留確定的 ASR 文字，不自動插入。繁中文字形轉換在本機進行。App 不建立逐字稿歷史或內容日誌；僅用記憶體不等於保證作業系統不產生 swap 或崩潰診斷資料。

WebSocket 與文字整理的 HTTP session 為 ephemeral，停用 URL cache、cookie storage 與 credential storage，請求指定 `no-store`；App 不主動建立持久網路快取。這不能控制 Google、作業系統或目的 App 的保存行為。

**本機檢查與預覽：** 開啟麥克風前，程式會檢查保存的 key 能否安全放入 header，以及本機 ASR 設定；此步驟不連線 Google，也不證明金鑰已授權，不解析 key 身分或記錄其內容。浮動面板不啟用 App、不搶焦點，只顯示目前的逐字稿預覽、狀態或錯誤，不擷取背後的畫面或文字。「預覽浮動字幕」只顯示合成範例，不啟用麥克風、不發送網路請求、不插入文字。

**選用連線檢查：**「檢查 Gemini 連線（不錄音）」需要已保存的 Keychain 金鑰與 Google 同意，會以該金鑰、所選 Live 模型及固定 session 設定連線 Google，然後關閉。自訂詞彙為空，不開麥克風、不送音訊或逐字稿、不插入文字。Google 會收到認證與一般連線資訊。成功僅表示當時連線與模型 setup 獲接受，不是 ASR 或插入成功的證據。

**其他 App 與剪貼簿：** 輔助使用 API 只檢查目前 App、焦點元件角色／保護狀態、選取範圍並插入文字，不讀游標周圍的文字，也不將這些定位資訊送 Google。無法直接插入時，暫用系統剪貼簿並發出 Command-V。啟用恢復時，原剪貼簿資料只在記憶體內備份、不上傳，且僅在剪貼簿尚未改變時恢復。手動複製會把結果留在剪貼簿；目的 App、剪貼簿管理器及系統剪貼簿功能可能依各自設定保存或同步文字。

Secure Event Input 啟用時會拒絕自動插入；辨識為終端 App 時也拒絕自動插入換行或 tab，但可能無法辨識嵌入其他 App 的終端。OpenInsert 不模擬 Enter，目的 App 仍可能依自身行為對插入文字作出反應。正常結束 App 會先等進行中的插入與剪貼簿恢復處理完成。

**你的控制：** 錄音需要麥克風權限與明確啟動。由 0.1 升級必須重新同意串流，舊的上傳同意不沿用。可在插入前取消、清除最後結果、在設定刪除金鑰、停用同意，或在系統設定撤銷權限。極短或取消的錄音也可能已傳送部分音訊，取消無法收回。直接刪除 App 不會自動移除 Keychain 項目與偏好；若要移除金鑰，請先在設定刪除。新的記憶體管線也不會清除舊版 0.1 崩潰時可能留下的暫存。OpenInsert 不要求螢幕錄製權限，也不安裝監聽所有按鍵的監視器。

**更新與權限：** ad-hoc 簽署的 App 在更新或重新建置後，原有輔助使用授權可能失效；系統設定中看似啟用的項目可能仍對應舊版本。必要時請移除舊項目，重新加入目前安裝的 App；「連線與權限」會顯示本機執行路徑，協助辨識正確副本。OpenInsert 不會自動授權、重設或繞過系統權限。

Implementation details / 實作細節：[ARCHITECTURE.md](ARCHITECTURE.md)。
