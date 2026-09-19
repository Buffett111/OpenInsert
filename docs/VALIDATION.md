# 驗證紀錄

記錄日期：2026-09-19；版本：0.1.0。測試環境為 macOS 27.0（26A428）、arm64、Apple Swift 6.4、Command Line Tools MacOSX27.0 SDK。此頁區分實際通過與尚待完成的項目；建置成功不代表真實語音辨識及所有應用程式插入已驗證。

| 項目 | 狀態 | 證據與範圍 |
| --- | --- | --- |
| 原生 source build | **Passed** | 在 macOS 27、arm64 主機完成原生編譯 |
| 核心 XCTest | **Passed：19／19** | 使用實際 XCTest runner 執行，全部通過；HTTP 為 URLProtocol fake，沒有連線至 Gemini |
| macOS service 相容性檢查 | **Passed** | 系統服務以 macOS 13 deployment target、Swift 5 mode 獨立 typecheck；不是 macOS 13 實機執行測試 |
| Universal binary | **Passed（交叉編譯）** | `lipo -archs` 為 x86_64 與 arm64；兩者 `LC_BUILD_VERSION` minimum macOS 13.0；只有 arm64 目前主機執行已驗證 |
| Release 打包與產物檢查 | **Passed** | `.app`、ZIP、DMG、SHA-256 產物已建立；codesign strict verification、ZIP 內容及 hdiutil checksum 驗證通過；只連結系統 framework |
| 原生 UI | **Passed（初始介面）** | 實際開啟 app，AX 與畫面確認首頁、Option + Space、Gemini 模型欄位、未設定 key 及尚未授權狀態；不等於錄音／插入成功 |
| 麥克風與全域快捷鍵 | **Pending** | 待測 TCC 核准／拒絕、按住／短按及取消 |
| 真實 Gemini 語音請求 | **Pending** | 需要使用者自己的金鑰與明確雲端同意；未宣稱繁中辨識率或 API 端到端成功 |
| 跨 App 文字插入 | **Pending** | 待驗證 AX、剪貼簿 fallback、焦點變更與剪貼簿恢復；尚未宣稱通用相容性 |
| Developer ID 簽章與公證 | **未完成** | 本次為 ad hoc 簽章，沒有 Developer ID 發布憑證與 notarization；下載後可能被 macOS 阻擋 |

## 核心測試涵蓋

19 個 XCTest 包含固定 HTTPS origin、API key header、inline audio、詞彙作為資料、model／key／偏好格式檢查、Base64 後容量上限、MIME／空音訊、fake network round trip、錯誤內容不外洩、timeout、取消、拒絕 redirect、response 大小、thought 排除、完成狀態、安全阻擋、無語音與拒絕回覆、缺漏／多候選／錯誤 JSON、轉錄長度及控制字元。

以上確認的是 request／response contract 與失敗處理。URLProtocol fake 不會測到 Google 實際服務、模型識別、音訊辨識品質、付費額度、網路延遲或 macOS 目標應用是否接收到貼上。

## 本機工具鏈說明

本次主機的預設 Xcode 工具受「授權條款尚未接受」狀態影響；驗證使用已可執行的 Command Line Tools 編譯器，以 native build system、明確指定已安裝 Xcode 的 XCTest frameworks 與 Swift overlay include/library 路徑，建出測試 bundle，再使用 Xcode 的 `xctest` runner 實際執行。沒有自動接受 Xcode 授權，也不將此替代流程描述成未經調整的 `swift test` 成功。

一般貢獻者應先使用已完成授權與初始化的支援工具鏈，依 README 的建置／測試流程重現。macOS 13 deployment target 只證明對該目標的編譯檢查，不等於已在 macOS 13、Intel Mac 或全新使用者帳號上完成整合測試。

完整建議矩陣見 [SURVEY.md](SURVEY.md)，殘餘競態與資料保存邊界見 [ARCHITECTURE.md](ARCHITECTURE.md) 與 [PRIVACY.md](PRIVACY.md)。
