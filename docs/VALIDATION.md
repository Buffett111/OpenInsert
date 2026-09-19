# 驗證紀錄

記錄日期：2026-09-19；目前版本：0.2.2。測試環境為 macOS 27.0（26A428）、arm64、Apple Swift 6.4、Command Line Tools MacOSX27.0 SDK。此頁區分新版已執行檢查、待驗證項目與 0.1 歷史證據；建置成功不代表真實語音辨識及所有應用程式插入已驗證。

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
