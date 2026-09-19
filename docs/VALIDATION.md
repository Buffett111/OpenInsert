# 驗證紀錄

記錄日期：2026-09-19；目前驗證版本：0.2.6／build 8（尚未發布）。測試環境為 macOS 27.0（26A428）、arm64、Apple Swift 6.4、Command Line Tools MacOSX27.0 SDK。此頁區分新版已執行檢查、待驗證項目與歷史證據；建置成功不代表真實語音辨識及所有應用程式插入已驗證。

## 0.2.6 Accessibility 初始化（待實機驗證，未發布）

- 已核對受影響桌面 App 的 bundle metadata：framework 名稱為 `Codex Framework.framework`，`NSPrincipalClass` 為 `BrowserCrApplication`。這支持 Chromium-based 的判斷，不能把它當成只改名的 Electron，也不證明其 AX 輸入介面已啟用。
- 原始碼移除 Electron framework 檔名限制，改依 `AXManualAccessibility` 的實際可寫能力與 Boolean 狀態判斷；只有精確的 `BrowserCrApplication` 且 Manual 無法使用，才改要求 `AXEnhancedUserInterface`。Manual 查詢的權限／通訊錯誤及無效資料不進入替代路徑。每個目標程序啟動在本次 OpenInsert 執行期間只嘗試一次寫入，成功後保留 3 秒準備期間；嚴格焦點檢查及貼上／自動複製規則保留。這是原始碼核對，不是實機修復成功的宣告。
- **實際 XCTest 105／105 通過，0 failures**：97 項既有測試加上 8 項初始化決策測試；使用實際 XCTest runner。新測試驗證能力與 principal class 的決策，不會啟用真實 App 的 AX 或驗證輸入框內容。
- **建置檢查通過**：macOS 13／Swift 5 typecheck、原生與 arm64／x86_64 universal 建置、架構檢查及 strict codesign 驗證通過。新產物的本機 designated requirement 與目前安裝的 0.2.5 相同；這尚不能替代更新後權限狀態的確認。
- **GitHub CI 通過**：[Build and test](https://github.com/Buffett111/OpenInsert/actions/runs/35445093242)（commit `8ed16b1`）的 105 項單元測試、15 項合成 PCM 檢查與 universal 建置全部成功。這些檢查不包含受影響 App 的實機輸入。
- **CI 下載產物核對通過**：等待下載程序成功結束後，核對 `OpenInsert-universal.zip` 完整性、解壓後 App strict codesign、x86_64／arm64、版本 0.2.6／build 8 與最低 macOS 13.0。確認為 ad-hoc 簽章且無本機開發者識別；未執行或安裝該產物。此為 CI artifact，尚未發布 ZIP／DMG Release。
- **尚未安裝 0.2.6**：本機鎖定，等待使用者解鎖；未操作權限或進行新版 UI／直接插入測試。0.2.5 的失敗與剪貼簿測試限制保留於下節。

| 項目 | 狀態 | 後續需要的證據 |
| --- | --- | --- |
| 0.2.6 安裝、設定與權限保留 | **Pending** | 更新後確認版本、金鑰／同意及麥克風／Accessibility 狀態 |
| 受影響 Chromium 編輯器直接插入 | **Pending** | 新初始化後取得有效焦點，並確認該次完成文字實際出現在輸入框 |
| 自動複製與剪貼簿還原 | **Pending** | 沒有並行錄音干擾的固定句與剪貼簿所有權測試 |
| 0.2.6 CI 與公開 Release | **CI Passed；未發布 Release** | 實機問題尚待確認，不將建置通過視為發布完成 |

## 0.2.5 焦點取得與完成結果自動複製（內部版本，未發布）

此次實機錯誤為 `AXFocusedUIElement` 回傳 `AX -25212`（no value）：沒有取得可驗證的輸入元素。新版先查 system-wide focus，僅在 no value、attribute unsupported 或 not implemented 時，再查同一前景 App；查詢前後與回傳元素皆檢查 PID，每次取得焦點最多兩次查詢。這是焦點取得策略調整，不能由單元測試推論目標編輯器已提供可用的 Accessibility 元素。

- **Universal 建置通過**：0.2.5／build 7 包含 arm64 與 x86_64；Intel 架構為交叉編譯，未在 Intel 實機執行。
- **實際 XCTest 97／97 通過**：原有 88 項加上 9 項 `FocusedTargetResolverTests`。新測試涵蓋 system-wide 優先、no value 後同 App 恢復、前景 PID 在查詢中改變、外來元素 PID、權限／失效／無回應錯誤不重試，以及兩次查詢上限。這些是可控制的焦點結果與 fake transport 測試，沒有使用真實麥克風、Google API 或目標 App。
- **安裝與設定保留通過**：已安裝 App 的 UI 顯示 0.2.5，麥克風與輔助使用均為「已啟用」，既存 Keychain 金鑰與 Google 同意保留；本次未重設權限，也未讀出金鑰內容。
- 原始碼已加入完成結果的自動複製：被接受的 final ASR／後修結果若沒有有效目標，或遇到允許的派送前插入錯誤，改為永久寫入剪貼簿，並顯示約六秒的複製提示。取消、未定稿、永久提供者錯誤、未知錯誤、貼上派送後錯誤，以及剪貼簿所有權／讀寫錯誤不觸發第二次自動寫入；正常貼上仍以原有 800 ms 與所有權檢查還原剪貼簿。這段描述的是程式行為範圍，不是所有分支均已通過實機測試。
- **自動複製提示可見**：內建五秒固定句測試在捕捉焦點得到 `AX -25212` 後，UI 顯示「已複製到剪貼簿，按 ⌘V 即可貼上」及固定結果。接著在 TextEdit 新文件按 Command-V 出現「測試測試。」；重新查看 App 時，使用者已在並行進行真正錄音，App 的最新結果也已變成該句。因此只能確認當時手動貼上的文字與最新結果一致，不能把這次交錯操作當成固定句剪貼簿內容與持久性的獨立驗證。
- **ChatGPT／Codex 桌面直接插入仍失敗**：使用者測試 0.2.5 後的截圖與 App UI 再次顯示 `AXFocusedUIElement`／`AX -25212`。辨識已完成，App 顯示自動複製提示，但文字沒有直接出現在輸入框。此結果證明此次 global focus 調整仍不足以修復該實機情境；不能沿用 0.2.4 固定文字測試的成功，宣稱新版完整流程已通過。

| 項目 | 狀態 | 後續需要的證據 |
| --- | --- | --- |
| ChatGPT／Codex 桌面直接插入 | **Failed，修復中** | 取得有效目標後，重新確認完成的語音文字實際出現在原輸入框 |
| 自動複製後手動貼上 | **Pending** | 在沒有並行錄音的情況下，核對該次完成結果、複製提示及目的地實際貼上的文字 |
| 正常貼上的剪貼簿還原與失敗分支 | **Pending** | 分別確認所有權未變時還原、使用者更新剪貼簿時不覆寫，以及派送後不重複插入 |
| 0.2.5 CI、Release 與公開下載產物 | **未發布（內部版本）** | 實機焦點修復不足，保留本次證據，改由 0.2.6 繼續修復與驗證 |

## 0.2.4 編輯器貼上相容性

使用者手動確認 0.2.3 可以插入 TextEdit，但不能插入其改名為 ChatGPT 的 Codex 桌面版。當時 OpenInsert 顯示 `Inserted into ChatGPT using Accessibility.`，與使用者未見文字的結果不一致：AX setter 回傳成功不能作為編輯器已更新的證據。

0.2.4 改用剪貼簿與標準 Command-V 作為插入路徑，不再直接設定 `AXSelectedText`；保留既有焦點、前景程序、選取範圍、密碼欄與剪貼簿所有權檢查。僅送出一次貼上，不在已派送後重試；OS 沒有貼上完成回條，因此訊息說明請求已發出並請使用者檢查目的地。

- 完整 macOS 13／Swift 5 typecheck、arm64／x86_64 universal 建置與 strict codesign 驗證通過。
- 已更新 `/Applications/OpenInsert.app`；原生 UI 確認版本 0.2.4，API key 已儲存、Google 同意保留，麥克風與輔助使用均顯示「已啟用」，沒有快捷鍵註冊錯誤。
- 0.2.3 與 0.2.4 的本機 designated requirement 相同；本次更新未重設任何權限。先前待確認的麥克風重設已不需要，沒有執行。
- **ChatGPT／Codex 桌面插入成功（使用者手動確認）**：更新 0.2.4 後，使用者執行內建五秒固定文字測試，明確回覆「文字已成功出現」。這是該實機、該輸入框的可見結果，不等於所有 App 相容性；兩種快捷鍵的實際語音整合另行驗證。

GitHub macOS 15 [Build and test](https://github.com/Buffett111/OpenInsert/actions/runs/35435222368) 與 [Release](https://github.com/Buffett111/OpenInsert/actions/runs/35435286689) 均通過（commit `09a4255`），包括 88 個 XCTest、15 項合成 PCM 檢查與 universal 封裝。等待下載程序成功退出後，獨立核對 ZIP／DMG 的 SHA-256、ZIP 完整性、DMG checksum 與 App strict codesign，全部通過；確認公開包為 ad-hoc、無本機簽署者識別，包含 x86_64 與 arm64，版本 0.2.4／build 6。[v0.2.4](https://github.com/Buffett111/OpenInsert/releases/tag/v0.2.4) 已公開為 prerelease。

## 0.2.3 收尾、後修、語言與放鍵修正

- **真實 Google 辨識與後修成功**：從本機 App 的 `--diagnose-pipeline` 執行與 UI 按鈕相同的固定句路徑。系統語音在記憶體中合成約 7.63 秒繁中／英文混合測試句，送至 `gemini-3.5-transcribe-live`，再用 `gemini-3.5-flash-lite` 整理。連線 **0.37 秒**、停止送音後 ASR 收尾 **1.37 秒**、後修 **0.90 秒**。這是一次固定句測量，不代表所有網路／句長的延遲。
- 收尾收到 **1 段 authoritative final，沒有 `turnComplete`**，新規則仍成功完成；這是舊規則會等到逾時的真實服務事件組合。未定稿文字沒有被升格。結果含繁體中文；測試句的 OpenInsert 名稱被辨識成 `open insert`，此測試不宣稱專有名詞或辨識品質完美。
- 上述診斷**沒有開麥克風、沒有擷取輸入位置、沒有插入文字**，沒有讀出 Keychain 金鑰；發送的是固定合成句與空詞彙。合成器獨立 harness 另確認 244,050 bytes 的 16 kHz mono Int16 PCM 與非零振幅。
- 實際 XCTest **88／88 通過**（後修／HTTP 30、Live 28、語言 9、原有手勢 6、金鑰 4、放鍵 recovery 7、輔助介面準備狀態 4）。涵蓋 final-only 收尾、未解 interim 不完成、metadata-only 不清除 interim、8 秒總期限的縮時取消測試、晚到回覆、語言遷移、放鍵順序及無法判定時的取消。
- 原生／universal 編譯與 macOS 13 typecheck 通過。初期 UI 自動化逾時時，使用者仍能看見主畫面，程序取樣也顯示主執行緒正常等待事件；解鎖後已重新取得原生 UI 狀態，不能把先前工具逾時說成 App 當機。
- 輔助使用授權已恢復：系統設定啟用目前安裝版本後，App 重新查詢顯示「已啟用」，正常重啟後仍維持。另發現專案 `dist` 副本與 `/Applications` 副本同時執行；只關閉前者並重啟後者，`eventHotKeyExistsErr (-9878)` 消失。此結果確認註冊成功，不等於實體長按／短按已實測。
- 自動化操作新的 TextEdit 空白文件時曾讀到 `AXWindow` 而拒絕插入；後續使用者手動確認 TextEdit 插入成功，但其改名為 ChatGPT 的 Codex 桌面版仍沒有文字，與 AX setter 成功回報不一致。此差異是 0.2.4 調整插入路徑的依據，不是放寬焦點檢查的理由。麥克風系統開關為 on、App 判定未啟用；尚未重設或錄音，不能宣稱完整語音流程成功。

本機改以既有 Apple Development 憑證簽署，指定需求依 app identifier 與簽章憑證辨識；兩次包含程式修改的重建之 designated requirement 相同且不含 cdhash。最終版已安裝至 `/Applications/OpenInsert.app`，strict codesign 驗證通過；依使用者先前同意，僅清除本 App 舊 Accessibility 紀錄並重新授權，未重設麥克風。這不是 Developer ID 或 notarization；公開 CI 仍不含本機憑證、採 ad-hoc community build。

0.2.3 的 GitHub macOS 15 [Build and test](https://github.com/Buffett111/OpenInsert/actions/runs/35433492829) 與 [Release](https://github.com/Buffett111/OpenInsert/actions/runs/35433595989) 均通過（commit `3e3bc8a`）：完整 Xcode 的 88 個單元測試、15 項合成 PCM 檢查、universal 建置及 ZIP／DMG 封裝成功。這些 CI 檢查不包含使用者實機的 TCC 授權或 Codex 插入。

從 GitHub 下載完整產物後，ZIP／DMG 的 SHA-256、ZIP 完整性、DMG checksum、App strict codesign 驗證全部通過；公開執行檔包含 x86_64 與 arm64，確認為 ad-hoc 簽章且沒有本機開發者識別。[v0.2.3](https://github.com/Buffett111/OpenInsert/releases/tag/v0.2.3) 已公開為 prerelease。

## 0.2.2 快捷鍵、金鑰與浮動字幕修正

- 實際 XCTest **56／56 通過**：原有 46 個 Live／REST 測試，加上 4 個金鑰與 6 個快捷鍵測試。確認含點號、超過舊 256 字元限制的合成金鑰可安全置於 header，無效輸入得到不含金鑰的具體錯誤；沒有讀取使用者金鑰來判斷格式。
- 快捷鍵測試涵蓋短按開始／再次按下停止、長按放開停止、延遲派送仍以原始事件時間計算、準備期間停止、busy 與 reset。這些是手勢狀態機測試，實體按鍵及真實錄音仍需 UI 驗證。
- 完整 app 原生建置與 universal 封裝成功。兩個架構的最低版本均為 macOS 13.0；codesign strict verification、ZIP 完整性、DMG checksum 及 SHA-256 驗證通過。仍為 ad-hoc 簽章，尚未公證。
- 已安裝 `/Applications/OpenInsert.app` 0.2.2，UI 確認既存金鑰、Google 同意、兩個模型與 Option + Space 設定保留。經先前同意重設並重新授權本 App 的 Accessibility，App 重新查詢後顯示已啟用。
- **真實 Google Live setup 通過**：從 App 點選「檢查 Gemini 連線（不錄音）」，既存 Keychain 金鑰成功連線 `gemini-3.5-transcribe-live`。UI 顯示 `Gemini Live 連線成功`。未開麥克風、未傳送音訊／自訂詞彙，也沒有讀出金鑰內容；此結果只支持當時連線與模型 setup。
- 浮動字幕按鈕已從原生 UI 觸發；自動化目前只能擷取主視窗，尚未取得浮動 panel 的可視證據，不能宣稱真實即時字幕已驗證。更新後麥克風權限需要重新授權，真正錄音、兩種實體按鍵手勢與 ASR／插入整合仍待使用者測試。

0.2.2 的 GitHub macOS 15 [Build and test](https://github.com/Buffett111/OpenInsert/actions/runs/35431003101) 與 [Release](https://github.com/Buffett111/OpenInsert/actions/runs/35431126641) 均通過（commit `8c6e3e1`），包含完整 Xcode 的 `swift test`、合成 PCM 檢查與 universal 建置。[v0.2.2](https://github.com/Buffett111/OpenInsert/releases/tag/v0.2.2) 已公開為未公證的 prerelease，附 ZIP、DMG 與 SHA-256。

使用者回報「麥克風約兩秒後消失」時，0.2.1 UI 顯示本機 `invalidConfiguration` 訊息，且麥克風與輔助使用仍為已啟用。已確認舊版金鑰 regex 有誤擋路徑；尚不能僅憑此訊息確定使用者個別故障原因。0.2.2 改為開啟麥克風前執行具體 preflight，並加入可由 App 自行使用既存 Keychain 金鑰、完全不開麥克風的 Live 連線檢查。

## 0.2 即時串流管線

以下結果已在本機實際執行。核心測試使用 fake HTTP／WebSocket transport；音訊檢查使用合成訊號，均不需要 API key 或錄製麥克風。

| 項目 | 狀態 | 證據與範圍 |
| --- | --- | --- |
| 0.2 原生／universal build 與 release 產物 | **Passed** | 原生編譯、x86_64／arm64 universal 交叉編譯通過；兩者 minimum macOS 13.0。ZIP 解壓測試、DMG checksum、SHA-256 及 codesign strict verification 通過；ad-hoc 簽章，尚未公證 |
| Live transport 與文字整理單元測試 | **Passed：46／46** | 0.2.1 實際 XCTest runner：23 個 GeminiClient 測試（含 text-only cleanup 與繁中字形）及 23 個 Live 測試；涵蓋 setup、manual VAD、PCM、interim／final、完成等待、錯誤、取消與失效計時器。fake transport 不等於真實 API |
| PCM 轉換與 buffer 驗證 | **Passed：15／15** | `./scripts/test-audio.sh`；8／16／44.1／48／96 kHz、單／雙聲道合成 440 Hz 訊號轉為 16 kHz mono；100 ms 分塊、尾端排空、來源緩衝區複製、溢位失敗、取消，以及訂閱前 12 秒資料保留 |
| 0.2 原生 UI | **Passed** | 0.2.0 初始狀態確認 ⌥ Space、兩個正確模型欄位、未設定 key、串流同意預設關閉。0.2.1 安裝至 Applications 後確認設定保留、麥克風及輔助使用均顯示已啟用；沒有讀出金鑰內容 |
| 升級與其他作業系統 | **Pending** | 舊自訂模型／同意遷移的完整情境、Intel 實機與 macOS 13 實機；目前只在 arm64 macOS 27 執行 |
| 真實 Google Live ASR 與 Flash Lite 整理 | **Pending** | 使用自備 key 與明確同意；尤其 turnComplete + 1 秒 quiet heuristic 的真實完成行為及 late final |
| TextEdit 文字插入與權限恢復 | **Passed（單一 App）** | 經使用者同意，僅重設本 App 的失效 Accessibility 紀錄，重新註冊目前已安裝副本並由系統授權；App 即時查詢變為已啟用。內建 5 秒測試將固定句子插入原本空白的 TextEdit 文件；可見文字與 `Inserted into TextEdit using Accessibility.` 訊息吻合。未使用錄音或 Gemini |
| 麥克風、全域快捷鍵及其他插入路徑 | **Pending** | 真正錄音、取消、焦點變更、剪貼簿 fallback／恢復、終端及其他 App 相容性尚未實測；單一 TextEdit 的 AX 成功不代表通用相容性 |

0.2.1 的 GitHub macOS 15 [Build and test](https://github.com/Buffett111/OpenInsert/actions/runs/35429372035) 與 [Release](https://github.com/Buffett111/OpenInsert/actions/runs/35429477688) 均成功：完整 Xcode 的 `swift test`、合成音訊檢查及 universal 建置通過；Release 另產生 ZIP／DMG／SHA-256。[0.2.1](https://github.com/Buffett111/OpenInsert/releases/tag/v0.2.1) 以未公證的 prerelease 公開。

0.2.0 的本機 43 個測試通過，但同一 commit 的兩個 GitHub 工作有不同結果：一個全數通過，另一個 late-final 測試回報 `CancellationError`。僅憑紀錄不能確定原始原因。0.2.1 改用不拋錯的可取消時鐘、以 generation／write identity 拒絕失效計時器回呼，並把 late-final 測試改成可控制時鐘。另在暫存副本移除兩個保護後，兩個新回歸測試確實分別以 setup timeout／network error 失敗；沒有以重跑掩蓋失敗。

本機亦重現 ad-hoc 重建造成的輔助使用授權不匹配：系統設定的開關開啟，`AXIsProcessTrusted()` 卻為 false；TCC 紀錄顯示 `Failed to match existing code requirement`，保存的 cdhash 與新執行檔不同。重新啟動或刷新 UI 不會修正這種不匹配；必須對目前安裝版本重新授權。這不是 API key 或麥克風權限錯誤。

## 0.1.0 歷史驗證

以下是在改用 Live 前完成的 batch 管線紀錄，只支持當時版本。它們不能取代 0.2 的重新建置與回歸測試。

| 項目 | 狀態 | 證據與範圍 |
| --- | --- | --- |
| 原生 source build | **Passed** | 在 macOS 27、arm64 主機完成原生編譯 |
| 核心 XCTest | **Passed：19／19** | 使用實際 XCTest runner 執行，全部通過；HTTP 為 URLProtocol fake，沒有連線至 Gemini |
| macOS service 相容性檢查 | **Passed** | 系統服務以 macOS 13 deployment target、Swift 5 mode 獨立 typecheck；不是 macOS 13 實機執行測試 |
| Universal binary | **Passed（交叉編譯）** | `lipo -archs` 為 x86_64 與 arm64；兩者 `LC_BUILD_VERSION` minimum macOS 13.0；只有 arm64 目前主機執行已驗證 |
| Release 打包與產物檢查 | **Passed** | `.app`、ZIP、DMG、SHA-256 產物已建立；codesign strict verification、ZIP 內容及 hdiutil checksum 驗證通過；只連結系統 framework |
| 原生 UI | **Passed（初始介面／權限不足）** | 實際開啟 app，AX 與畫面確認首頁、Option + Space、Gemini 模型欄位、未設定 key 及尚未授權狀態；5 秒插入測試在缺少 Accessibility 時顯示錯誤並回到 idle，未擅自輸入；不等於錄音／插入成功 |
| 麥克風與全域快捷鍵 | **Pending** | 待測 TCC 核准／拒絕、按住／短按及取消 |
| 真實 Gemini 語音請求 | **Pending** | 需要使用者自己的金鑰與明確雲端同意；未宣稱繁中辨識率或 API 端到端成功 |
| 跨 App 文字插入 | **Pending** | 待驗證 AX、剪貼簿 fallback、焦點變更與剪貼簿恢復；尚未宣稱通用相容性 |
| Developer ID 簽章與公證 | **未完成** | 本次為 ad hoc 簽章，沒有 Developer ID 發布憑證與 notarization；下載後可能被 macOS 阻擋 |

## 0.1 核心測試涵蓋

19 個 XCTest 包含固定 HTTPS origin、API key header、inline audio、詞彙作為資料、model／key／偏好格式檢查、Base64 後容量上限、MIME／空音訊、fake network round trip、錯誤內容不外洩、timeout、取消、拒絕 redirect、response 大小、thought 排除、完成狀態、安全阻擋、無語音與拒絕回覆、缺漏／多候選／錯誤 JSON、轉錄長度及控制字元。

以上確認的是 request／response contract 與失敗處理。URLProtocol fake 不會測到 Google 實際服務、模型識別、音訊辨識品質、付費額度、網路延遲或 macOS 目標應用是否接收到貼上。

## 本機工具鏈說明

本次主機的預設 Xcode 工具受「授權條款尚未接受」狀態影響；驗證使用已可執行的 Command Line Tools 編譯器，以 native build system、明確指定已安裝 Xcode 的 XCTest frameworks 與 Swift overlay include/library 路徑，建出測試 bundle，再使用 Xcode 的 `xctest` runner 實際執行。沒有自動接受 Xcode 授權，也不將此替代流程描述成未經調整的 `swift test` 成功。

一般貢獻者應先使用已完成授權與初始化的支援工具鏈，依 README 的建置／測試流程重現。macOS 13 deployment target 只證明對該目標的編譯檢查，不等於已在 macOS 13、Intel Mac 或全新使用者帳號上完成整合測試。

完整建議矩陣見 [SURVEY.md](SURVEY.md)，殘餘競態與資料保存邊界見 [ARCHITECTURE.md](ARCHITECTURE.md) 與 [PRIVACY.md](PRIVACY.md)。
