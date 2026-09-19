# Dup 模型查證

查證日期：2026-09-19。範圍為本次實際檢查的 macOS Dup **1.20260913.0**；其他版本、使用者設定與未來更新可能不同。

## 查證結果

這個版本的 Dup 將語音辨識和語言模型分成兩個供應商設定。它的語音辨識設定為 **Gemini 3.5 Transcribe Live**，語言模型設定為 **Gemini 3.5 Flash Lite**；不能只用畫面上的「Gemini」供應商名稱判斷模型。

| 功能 | 本機 Dup 設定介面顯示 | 已安裝程式內的模型識別字串 | 證據強度 |
| --- | --- | --- | --- |
| Live transcription／ASR | Gemini → Gemini 3.5 Transcribe Live | `gemini-3.5-transcribe-live` | 高：可見設定與程式內識別字串互相吻合 |
| Language model／文字處理 | Gemini → Gemini 3.5 Flash Lite | `gemini-3.5-flash-lite` | 高：可見設定與程式內識別字串互相吻合 |

本機證據來自 Dup 自己的「AI providers」介面與已安裝 app 的模型名稱字串；檢查未讀取 API key、偏好檔中的憑證或帳戶內容。介面將即時轉錄描述為傳送麥克風音訊及詞彙提示；語言模型則用於螢幕脈絡、writing styles 與選取文字編輯。這足以確認當時選定的模型與用途分類，**不能證明每一段語音都會另外呼叫 Flash Lite**。

Google 的官方 [Live Transcription 文件](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe)確認 `gemini-3.5-transcribe-live` 是透過 WebSocket 接收音訊的即時語音辨識模型；[Flash Lite 模型頁](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite)確認 `gemini-3.5-flash-lite` 的正式識別字、文字輸出與 structured outputs 能力，並列明它本身不支援 Live API。官方文件證明模型及 API 的能力；Dup 的選擇則由上述本機觀察支持。

## 對 OpenInsert 的決策

OpenInsert 0.2 以 `gemini-3.5-transcribe-live` 作為 ASR 預設模型，並以 `gemini-3.5-flash-lite` 提供可選的轉錄文字整理。這是對齊已觀察到的模型組合，不是宣稱重現 Dup 未公開的提示詞、所有設定或辨識品質。OpenInsert 獨立實作，不複製 Dup 程式碼；不擷取螢幕、不上傳畫面或周邊輸入內容。

語音辨識模型與一般 `generateContent` 音訊請求不是可以只替換模型名稱的相同流程：前者需要即時 WebSocket 連線、PCM 音訊分塊與結束錄音的協定訊號；後者可用於已完成轉錄的文字整理。0.2 的實際行為以 [ARCHITECTURE.md](ARCHITECTURE.md) 與程式碼為準。

## Live API 實作查核

官方教學分開 interim 與 finalized 轉錄：`interimInputTranscription` 用於更新預覽；`inputTranscription` 是可累積的確定段落。Push-to-talk 可關閉自動 VAD，以 `activityStart`／`activityEnd` 控制；`audioStreamEnd` 則屬於自動 VAD 路徑。見 [Live Transcription](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe)。

[WebSocket API reference](https://ai.google.dev/api/live)要求先等待 `setupComplete`；也明確指出 `inputTranscription` 與其他 server 訊息沒有保證順序，因此 `turnComplete` 不能單獨當成所有轉錄已收到的證明。Live setup 不支援 batch structured-output 的 `responseMimeType`／`responseJsonSchema`。

查證當天另有文件差異：WebSocket reference 的 transcription schema 只列 `text`、`languageCode`，Google 官方 [Python SDK](https://github.com/googleapis/python-genai/blob/main/google/genai/types.py)與 [JavaScript SDK](https://github.com/googleapis/js-genai/blob/main/src/types.ts)則另列 optional `finished`，表示轉錄結束。SDK 欄位的存在不等於此特定模型每次必定傳送；自動插入前的完成判定必須測試實際服務，不能把 fake transport 測試視為確認。

## 已知限制

- 這次沒有攔截 Dup 的網路流量，沒有重放它的 API 請求，也沒有使用它保存的金鑰。因此模型的實際每次呼叫、fallback、遠端更新、提示詞、VAD 參數及 `SMART`／`VERBATIM` 模式均未確認。
- 語言模型支援畫面輸入，不代表 OpenInsert 需要該能力；本專案不實作 screen context。
- 使用相同模型仍可能因音訊前處理、語言提示、詞彙、整理方式與 API 版本而產生不同結果，尚不能聲稱與 Dup 相同的速度或辨識率。
- 未找到可驗證上述 Dup 模型設定的公開官方版本說明；同名產品搜尋結果不作為證據。這份紀錄刻意區分本機可見設定、Google 公開規格與尚未量測的執行行為。
