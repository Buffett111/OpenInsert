# Privacy / 隱私

This describes OpenInsert 0.2.3. OpenInsert has no product account, developer-operated server, analytics SDK, screenshot capture, OCR, or transcript-history database.

## English

**Cloud processing:** After you enable live cloud consent and start dictation, raw microphone audio streams directly to Google's Gemini API at `generativelanguage.googleapis.com` **while you speak**, using your own API key. ASR uses `gemini-3.5-transcribe-live`, automatic language detection, and your custom vocabulary. With cleanup enabled (the default), a separate text-only request sends the finalized transcript, writing-language preference, vocabulary, and editing instructions to `gemini-3.5-flash-lite`. Verbatim mode skips that request. Google also receives connection metadata such as your IP address. OpenInsert is not offline. Google's [Gemini API terms](https://ai.google.dev/gemini-api/terms) govern provider processing; paid and unpaid service terms differ.

**On your Mac:** Your API key is stored in macOS Keychain. ASR/cleanup models, language selection and custom preference, vocabulary, shortcut, cleanup, clipboard and consent settings are stored in UserDefaults. Audio uses bounded RAM buffers; 0.2 creates no recording files. Live previews and final transcripts are held in app memory. The last finalized result remains available until replaced, cleared, or the app exits. Skipping cleanup or a temporary cleanup failure uses the finalized ASR result for insertion after the usual target checks and reports the fallback. Cancelling the whole operation or receiving a permanent, blocked or invalid response stops automatic insertion. Unfinalized previews are never inserted. Traditional/Simplified Chinese character conversion happens locally; language choices do not request translation. OpenInsert does not intentionally write transcript logs or history. Memory-only processing does not guarantee that the operating system never writes swap or crash diagnostics.

The WebSocket and cleanup HTTP sessions are ephemeral, with URL cache, cookie storage and credential storage disabled. Requests specify `no-store`; the app does not intentionally create a persistent network cache. This does not control retention by Google, the operating system or destination apps.

**Local checks and preview:** Before opening the microphone, OpenInsert checks the saved key for header safety and checks local ASR settings. This does not contact Google or prove that the key is authorized. It does not inspect the key's identity or log its contents. A floating, nonactivating panel displays the current transcript preview, status, or error without capturing the screen or reading the app behind it. The **預覽浮動字幕** button shows synthetic text only, with no microphone, network request, or insertion.

**Shortcut release recovery:** Carbon hotkey events are the primary input. During an outstanding shortcut press, an existing Accessibility grant also allows limited background polling of Space and only that shortcut's required modifier keys to detect release. No other keys are read; no event tap or Input Monitoring request is added, and key-state samples are not logged or uploaded. Ambiguous timing cancels the dictation with a retry message.

**Optional connection check:** **檢查 Gemini 連線（不錄音）** requires a saved Keychain key and Google consent. It contacts Google with that key, the selected Live model, and fixed session settings, then closes the session. The custom vocabulary is empty; no microphone, audio, transcript, or insertion is involved. Google receives the authentication and ordinary connection metadata. Success confirms only that the connection and model setup were accepted, not successful ASR or insertion.

**Optional speech pipeline test:** **測試辨識與後修（不錄音）** requires the same saved key and consent. It synthesizes a fixed sentence in memory and sends the resulting audio to the selected Google ASR model, then sends its transcript to the selected cleanup model with your writing preference. Both stages use empty custom vocabulary. This uses the real API and may incur charges, but never opens the microphone or inserts text. Diagnostics show stage durations and event counts/flags in memory, excluding keys, audio, vocabulary and raw server errors. The generated test transcript can appear in the result UI. A successful synthetic test does not verify your voice, microphone or editor.

Running the installed executable with `--diagnose-pipeline` performs that same test, requires the key and consent to be set up beforehand, and exits after completion or a 70-second overall deadline. It prints a JSON status/timing report and the fixed synthetic sentence's result to standard output. It does not print credentials or ordinary user dictation. Terminal logging or redirecting stdout can retain this synthetic test report.

**Other apps and clipboard:** Accessibility is used to inspect the focused app, element role/protection state, and selection range, and to insert text. OpenInsert does not read the text around your cursor or send accessibility metadata to Google. When direct insertion is unsupported, it temporarily writes the result to the system clipboard and requests Command-V. With clipboard restoration enabled, existing clipboard formats are read into memory solely for restoration and are never uploaded. Restoration occurs only if the clipboard has not changed. Copying a result manually intentionally leaves it on the clipboard. The destination app, clipboard managers and system clipboard features may retain or sync inserted/copied text under their own settings.

With Accessibility already granted, OpenInsert can prepare a foreground Electron app's accessibility bridge. It verifies the actual Electron framework bundle, reads the application role and capability flag, and attempts to enable `AXManualAccessibility` once per process launch when supported and disabled. A three-second preparation window allows the bridge to become ready; other focus/selection failures retain their AX attribute and error code. This does not enumerate UI children, read surrounding text, or upload app/AX metadata.

Automatic insertion is blocked while Secure Event Input is active and for newlines/tabs in recognized terminal apps. Embedded terminals may not be recognized. OpenInsert never simulates Enter; destination apps can still react to inserted text under their own behavior. A normal quit waits for any ongoing insertion and clipboard restoration to finish.

**Your controls:** Recording requires microphone access and an explicit start. Upgrading from 0.1 requires new live-streaming consent; the earlier upload consent is not reused. You can cancel before insertion, skip cleanup and use finalized ASR, clear the last result, delete the key from settings, disable consent, or revoke permissions in System Settings. Cleanup has an eight-second total limit; timeout or skip cancels the local request. Even a very short or cancelled recording may already have sent audio; cancellation cannot recall audio or text already sent and does not guarantee that Google stops processing it. Deleting the app does not automatically remove its Keychain entry or preferences; delete the key in settings before uninstalling if desired. Old 0.1 crash leftovers, if any, are not removed by the new memory-only pipeline. OpenInsert does not request Screen Recording permission or install an all-key keyboard event monitor.

**Updates and permissions:** Updating or rebuilding an ad-hoc signed copy can invalidate its previous Accessibility grant. An enabled-looking entry in System Settings may belong to the old build. If needed, remove that entry and add the current installed app; its local path is shown in Connection & Permissions. OpenInsert does not grant, reset, or bypass system permissions automatically.

Source builders may use a gitignored `.local-signing-identity` containing an existing certificate's fingerprint, with `CODE_SIGN_IDENTITY` taking precedence. The file is a selector, not a private key; signing uses the existing identity on that Mac. Reusing a stable identity can preserve local permission continuity, subject to macOS policy. Apple Development signing does not provide Developer ID distribution or notarization. Public CI does not include this local file or any personal signing identity.

## 繁體中文

**雲端處理：** 同意即時雲端處理並主動開始後，原始麥克風音訊會**在說話期間**透過你自己的 API key，直接串流到 Google Gemini 的 `generativelanguage.googleapis.com`。ASR 使用 `gemini-3.5-transcribe-live`、自動語言偵測與自訂詞彙。啟用輕度整理（預設）時，再以獨立的純文字請求，將確定的逐字稿、書寫語言偏好、詞彙與整理指示送至 `gemini-3.5-flash-lite`；逐字模式跳過第二階段。Google 也會收到 IP 位址等連線資訊。OpenInsert 並非離線辨識工具，供應商處理依 [Gemini API 條款](https://ai.google.dev/gemini-api/terms)，付費與未付費服務條件不同。

**本機保存：** API key 存於 macOS Keychain；ASR／整理模型、語言選項與自訂偏好、詞彙、快捷鍵、整理、剪貼簿與同意設定存於 UserDefaults。音訊使用有界 RAM 緩衝，0.2 不建立錄音檔案。未定稿預覽與確定文字保存在 App 記憶體；最後結果可供複製，直到被取代、清除或 App 結束。略過後修或後修暫時失敗時，會告知改用定稿 ASR，經原有目標檢查後插入；取消整次工作、永久錯誤、安全阻擋或無效回覆不觸發自動插入。未定稿預覽不會直接插入。繁／簡中文字形轉換在本機進行，語言選項不要求翻譯。App 不建立逐字稿歷史或內容日誌；僅用記憶體不等於保證作業系統不產生 swap 或崩潰診斷資料。

WebSocket 與文字整理的 HTTP session 為 ephemeral，停用 URL cache、cookie storage 與 credential storage，請求指定 `no-store`；App 不主動建立持久網路快取。這不能控制 Google、作業系統或目的 App 的保存行為。

**本機檢查與預覽：** 開啟麥克風前，程式會檢查保存的 key 能否安全放入 header，以及本機 ASR 設定；此步驟不連線 Google，也不證明金鑰已授權，不解析 key 身分或記錄其內容。浮動面板不啟用 App、不搶焦點，只顯示目前的逐字稿預覽、狀態或錯誤，不擷取背後的畫面或文字。「預覽浮動字幕」只顯示合成範例，不啟用麥克風、不發送網路請求、不插入文字。

**快捷鍵放開補救：** 主要輸入仍是 Carbon hotkey 事件。快捷鍵 press 尚未完成且已有輔助使用授權時，程式會在背景只檢查 Space 與該快捷鍵需要的修飾鍵狀態，補回可能遺失的放開事件；不讀其他按鍵、不安裝 event tap、不增加 Input Monitoring 請求，也不記錄或上傳按鍵狀態。時間資訊不足以判斷短按／長按時，取消本次錄音並提示重試。

**選用連線檢查：**「檢查 Gemini 連線（不錄音）」需要已保存的 Keychain 金鑰與 Google 同意，會以該金鑰、所選 Live 模型及固定 session 設定連線 Google，然後關閉。自訂詞彙為空，不開麥克風、不送音訊或逐字稿、不插入文字。Google 會收到認證與一般連線資訊。成功僅表示當時連線與模型 setup 獲接受，不是 ASR 或插入成功的證據。

**選用辨識與後修測試：**「測試辨識與後修（不錄音）」需要同樣的金鑰與同意，會在記憶體中合成固定測試句，將合成音訊送到所選 Google ASR 模型，再將其辨識文字和你的書寫偏好送到所選後修模型；兩階段自訂詞彙皆為空。它不開麥克風、不插入文字，但會使用真實 API，可能產生費用。記憶體診斷只顯示各階段時間及事件計數／旗標，不包含金鑰、音訊、詞彙或伺服器錯誤原文；合成句的辨識文字可能顯示在結果 UI。成功不能證明本人聲音、麥克風或目的編輯器已驗證。

以 `--diagnose-pipeline` 啟動已安裝的執行檔會進行相同測試，須事先完成金鑰與同意設定，完成或超過 70 秒總期限後離開。stdout 會輸出 JSON 狀態、耗時及固定合成句的測試結果，不輸出憑證或一般使用者語音輸入內容。終端紀錄或 stdout 重新導向可能保存這份合成測試報告。

**其他 App 與剪貼簿：** 輔助使用 API 只檢查目前 App、焦點元件角色／保護狀態、選取範圍並插入文字，不讀游標周圍的文字，也不將這些定位資訊送 Google。無法直接插入時，暫用系統剪貼簿並發出 Command-V。啟用恢復時，原剪貼簿資料只在記憶體內備份、不上傳，且僅在剪貼簿尚未改變時恢復。手動複製會把結果留在剪貼簿；目的 App、剪貼簿管理器及系統剪貼簿功能可能依各自設定保存或同步文字。

已有輔助使用授權時，OpenInsert 可初始化前景 Electron App 的原生 AX 介面：確認實際 Electron framework bundle，只讀 application role 與能力旗標；支援且尚未啟用時，每次程序啟動最多嘗試一次 `AXManualAccessibility` 設定，成功後保留 3 秒準備期間。其他焦點／選取範圍失敗保留 AX 屬性與錯誤代碼。這不列舉 UI 子元件、不讀周圍文字，也不上傳 App／AX 定位資訊。

Secure Event Input 啟用時會拒絕自動插入；辨識為終端 App 時也拒絕自動插入換行或 tab，但可能無法辨識嵌入其他 App 的終端。OpenInsert 不模擬 Enter，目的 App 仍可能依自身行為對插入文字作出反應。正常結束 App 會先等進行中的插入與剪貼簿恢復處理完成。

**你的控制：** 錄音需要麥克風權限與明確啟動。由 0.1 升級必須重新同意串流，舊的上傳同意不沿用。可在插入前取消、略過後修改用定稿 ASR、清除最後結果、在設定刪除金鑰、停用同意，或在系統設定撤銷權限。後修有 8 秒總期限；逾時或略過會取消本機請求。極短或取消的錄音也可能已傳送部分音訊；取消不能收回已送出的音訊／文字，也不能保證 Google 已停止處理。直接刪除 App 不會自動移除 Keychain 項目與偏好；若要移除金鑰，請先在設定刪除。新的記憶體管線也不會清除舊版 0.1 崩潰時可能留下的暫存。OpenInsert 不要求螢幕錄製權限，也不安裝監聽所有按鍵的監視器。

**更新與權限：** ad-hoc 簽署的 App 在更新或重新建置後，原有輔助使用授權可能失效；系統設定中看似啟用的項目可能仍對應舊版本。必要時請移除舊項目，重新加入目前安裝的 App；「連線與權限」會顯示本機執行路徑，協助辨識正確副本。OpenInsert 不會自動授權、重設或繞過系統權限。

自行建置可在已 gitignore 的 `.local-signing-identity` 保存既有憑證的 fingerprint；`CODE_SIGN_IDENTITY` 優先。該檔只選擇本機簽署身分，不是私鑰；重用穩定身分可協助沿用本機權限，仍依 macOS 政策判定。Apple Development 簽署不是 Developer ID 散布簽章或公證；公開 CI 不包含這個本機檔案或任何個人簽署身分。

Implementation details / 實作細節：[ARCHITECTURE.md](ARCHITECTURE.md)。
