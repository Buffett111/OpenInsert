import SwiftUI
import OpenInsertCore

// Use the property wrapper across SDK versions, including SDKs that also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct MainView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: SettingsStore
    @ViewState private var tab = 0
    @ViewState private var keyDraft = ""
    private let accent = Color(red: 0.20, green: 0.64, blue: 0.48)
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "waveform").font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 56, height: 56)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 5) {
                    Text("OpenInsert").font(.system(size: 29, weight: .bold, design: .rounded))
                    Text("你的聲音，你的文字。開源語音輸入。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("MIT · v0.2.0").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(.quaternary, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(controller.phase == .recording ? .red : accent).frame(width: 8, height: 8)
                    Text(controller.statusTitle).font(.title3.weight(.semibold))
                    Spacer()
                    if controller.phase == .recording { Text(String(format: "%.1fs / 120s", controller.elapsed)).monospacedDigit() }
                    if controller.busy && controller.phase != .recording { ProgressView().controlSize(.small) }
                }
                Text(controller.message).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if controller.busy {
                    HStack {
                        if controller.phase == .recording {
                            Button("完成錄音") { controller.finishRecording() }.buttonStyle(.borderedProminent).tint(accent)
                        }
                        Button("取消") { controller.cancel() }.disabled(controller.phase == .inserting)
                    }
                }
                if let error = controller.hotKeyError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))

            Picker("頁面", selection: $tab) {
                Text("開始使用").tag(0); Text("辨識偏好").tag(1); Text("連線與權限").tag(2); Text("關於與隱私").tag(3)
            }.pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case 0: home
                    case 1: preferences
                    case 2: connection
                    default: about
                    }
                }.padding(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(accent)
                Text("不擷取螢幕 · 不儲存歷史 · API key 存於 Keychain").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(28).frame(minWidth: 650, minHeight: 600).tint(accent)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                step("1", "完成設定", "填入 Gemini API key，啟用麥克風與輔助使用權限。")
                step("2", "放好游標", "切換到你要輸入文字的 App 或瀏覽器欄位。")
                step("3", "按鍵說話", "按住 \(settings.hotKey.displayName) 錄音，放開即完成。")
            }
            HStack {
                Label(settings.hotKey.displayName, systemImage: "keyboard").font(.headline)
                Text("短按開始，再按結束；長按錄音，放開結束。").font(.caption).foregroundStyle(.secondary)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            if !controller.liveText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("即時預覽 · 尚未定稿").font(.caption.weight(.semibold)).foregroundStyle(accent)
                    Text(controller.liveText).font(.body).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Text("最近一次結果").font(.headline)
                Spacer()
                Button("清除") { controller.clearResult() }.disabled(controller.lastText.isEmpty || controller.busy)
                Button("複製文字") { controller.copyResult() }.disabled(controller.lastText.isEmpty)
            }
            TextEditor(text: $controller.lastText).font(.body).frame(minHeight: 125)
                .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                .accessibilityLabel("最近一次辨識結果")
            Text("若辨識期間切換輸入位置，結果會保留在這裡供你複製。程式不會模擬 Enter；已知終端機的多行貼上會改為手動複製。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("測試文字插入（5 秒倒數）") { controller.testInsertion() }.disabled(controller.busy)
                Spacer()
                Button("前往設定") { tab = 2 }
            }
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 18) {
            setting("全域快捷鍵", detail: "預設 Option + Space。請先結束占用同一快捷鍵的 App；若快捷鍵已被占用會顯示錯誤。") {
                Picker("快捷鍵", selection: $settings.hotKey) {
                    ForEach(HotKeyChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden().onChange(of: settings.hotKey) { _ in controller.registerShortcut() }
            }
            setting("輸出方式", detail: "輕度整理會移除口頭贅詞、加入標點，保留原意；逐字模式保留原來說法。") {
                Picker("輸出方式", selection: $settings.mode) {
                    Text("輕度整理").tag(CleanupMode.polished); Text("逐字辨識").tag(CleanupMode.verbatim)
                }.pickerStyle(.segmented).labelsHidden()
            }
            setting("文字語言偏好", detail: "ASR 自動偵測中英混用。預設在本機轉成繁中字形；輕度整理也會套用此偏好。") {
                TextField("語言", text: $settings.language).textFieldStyle(.roundedBorder)
            }
            setting("自訂詞彙", detail: "例如人名、產品名與術語，每行一個。這些詞彙會和錄音一起送到 Google。") {
                TextEditor(text: $settings.vocabulary).frame(height: 80).padding(5).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityLabel("自訂詞彙")
            }
            Toggle("貼上後還原剪貼簿", isOn: $settings.restoreClipboard)
            Text("會保留剪貼簿的各種格式；若其他 App 在等待期間更新剪貼簿，就不覆蓋它。少數慢速 App 若貼上不完整，可關閉還原後再試。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(controller.busy)
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(controller.hasAPIKey ? "Gemini API key 已儲存" : "Gemini API key 尚未設定", systemImage: controller.hasAPIKey ? "checkmark.circle.fill" : "key")
                    .font(.headline)
                Spacer()
                Link("取得 API key ↗", destination: URL(string: "https://aistudio.google.com/apikey")!)
            }
            HStack {
                SecureField("貼上你的 Gemini API key", text: $keyDraft).textFieldStyle(.roundedBorder)
                Button("儲存到 Keychain") { if controller.saveKey(keyDraft) { keyDraft = "" } }.disabled(keyDraft.isEmpty)
                Button("刪除") { controller.deleteKey() }.disabled(!controller.hasAPIKey)
            }.disabled(controller.busy)
            setting("即時 ASR 模型", detail: "與你安裝的 Dup 相同：Gemini 3.5 Transcribe Live，透過 Live API 串流辨識。") {
                TextField("Live ASR 模型 ID", text: $settings.asrModel).textFieldStyle(.roundedBorder).disabled(controller.busy)
            }
            setting("文字整理模型", detail: "與 Dup 相同：Gemini 3.5 Flash Lite。只在「輕度整理」模式將逐字稿另送一次整理請求。") {
                TextField("文字模型 ID", text: $settings.model).textFieldStyle(.roundedBorder).disabled(controller.busy)
            }
            Toggle("我同意錄音時即串流音訊與詞彙至 Google，並依模式傳送逐字稿整理", isOn: $settings.cloudConsent)
                .disabled(controller.busy)
            Text("使用自己的 API key，費用與資料處理規則依你的 Google 帳號方案。OpenInsert 不經過開發者的伺服器。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            permission("麥克風", granted: controller.microphoneGranted, description: "只在你啟動錄音時使用。", action: controller.requestMicrophone)
            permission("輔助使用", granted: controller.accessibilityGranted, description: "把辨識結果放到目前輸入位置；不讀取整份文件。", action: controller.requestAccessibility)
            Button("重新檢查權限") { controller.refreshPermissions() }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("一條簡單、可檢查的資料路徑。").font(.title3.weight(.semibold))
            Text("麥克風 → Transcribe Live → Flash Lite（可選）→ 文字插入")
                .font(.body.monospaced()).padding(16).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            Text("• 沒有螢幕截圖、OCR、螢幕錄製權限或分析追蹤。\n• 音訊以 PCM 在記憶體中緩衝並串流，不寫錄音檔。\n• 取消會停止錄音與連線；已送出的音訊無法收回。\n• 最近結果只保留在記憶體，結束 App 即消失。\n• 切換 App／欄位時停止自動插入，密碼欄位不支援。")
                .font(.callout).lineSpacing(7)
            HStack {
                Link("Google API 資料政策 ↗", destination: URL(string: "https://ai.google.dev/gemini-api/terms")!)
                Link("Gemini 模型文件 ↗", destination: URL(string: "https://ai.google.dev/gemini-api/docs/models")!)
            }
            Text("OpenInsert 0.2.0 · MIT License\n採用與 Dup 設定相同的 ASR 與文字模型；提示詞與程式由本專案獨立實作。與 Dup 無隸屬關係。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number).font(.caption.weight(.bold)).foregroundStyle(accent).frame(width: 24, height: 24).background(accent.opacity(0.12), in: Circle())
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func setting<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            content()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func permission(_ title: String, granted: Bool, description: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? accent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline); Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "已啟用" : "啟用") { action() }.disabled(granted || controller.busy)
        }
    }
}
