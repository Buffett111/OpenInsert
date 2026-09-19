import AppKit
import Combine
import SwiftUI

/// A pass-through status display. Ordering this panel never activates OpenInsert
/// or changes the destination app's keyboard focus.
@MainActor
final class DictationHUD {
    private let controller: DictationController
    private let panel: DictationHUDPanel
    private let model = DictationHUDModel()
    private var subscriptions = Set<AnyCancellable>()
    private var refreshQueued = false
    private var closed = false
    private var wasBusy = false
    private var failureRevision: UInt64 = 0
    private var displayedFailureRevision: UInt64 = 0
    private var displayRevision: UInt64 = 0
    private var dismissWork: DispatchWorkItem?

    init(controller: DictationController) {
        self.controller = controller
        panel = DictationHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 176),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DictationHUDView(model: model))

        controller.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh()
        }.store(in: &subscriptions)
        // A repeated preflight failure can leave phase == idle and contain the
        // same text. Count publications so another attempt still shows its error.
        controller.$lastFailure.dropFirst().sink { [weak self] failure in
            guard let self, failure != nil else { return }
            self.failureRevision &+= 1
            self.scheduleRefresh()
        }.store(in: &subscriptions)
    }

    /// Demonstrates the display only: no recording, provider request, or controller mutation.
    func showPreview() {
        guard !controller.busy else { return }
        show(DictationHUDContent(
            title: "即時預覽顯示測試", message: "這只是畫面預覽，沒有錄音或連線。",
            transcript: "這是一段繁體中文與 English 混合的示範文字。說話時，辨識中的文字會顯示在這裡。",
            elapsed: 0, level: 0.35, recording: false, connected: false,
            failure: false, preview: true, showTranscript: true
        ), dismissAfter: 4)
    }

    func close() {
        closed = true
        displayRevision &+= 1
        dismissWork?.cancel()
        dismissWork = nil
        subscriptions.removeAll()
        panel.close()
    }

    private func scheduleRefresh() {
        guard !closed, !refreshQueued else { return }
        refreshQueued = true
        // objectWillChange precedes the @Published assignment. Read the complete
        // controller state on the next main-loop turn, coalescing meter updates.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    private func refresh() {
        guard !closed else { return }
        let previouslyBusy = wasBusy
        wasBusy = controller.busy
        if controller.busy {
            show(currentContent(failure: false), dismissAfter: nil)
        } else if controller.lastFailure != nil,
                  previouslyBusy || displayedFailureRevision != failureRevision {
            displayedFailureRevision = failureRevision
            show(currentContent(failure: true), dismissAfter: 10)
        } else if previouslyBusy {
            show(currentContent(failure: false), dismissAfter: 2)
        }
    }

    private func currentContent(failure: Bool) -> DictationHUDContent {
        DictationHUDContent(
            title: failure ? "語音輸入未完成" : controller.statusTitle,
            message: failure ? (controller.lastFailure ?? controller.message) : controller.message,
            transcript: controller.liveText, elapsed: controller.elapsed, level: controller.level,
            recording: controller.phase == .recording, connected: controller.liveConnected,
            failure: failure, preview: false,
            showTranscript: controller.phase == .preparing || controller.phase == .recording || controller.phase == .transcribing
        )
    }

    private func show(_ content: DictationHUDContent, dismissAfter delay: TimeInterval?) {
        guard !closed else { return }
        displayRevision &+= 1
        let revision = displayRevision
        dismissWork?.cancel()
        dismissWork = nil
        model.content = content
        positionPanel()
        // Deliberately neither makeKeyAndOrderFront nor NSApp.activate.
        panel.orderFrontRegardless()
        if let delay {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.displayRevision == revision else { return }
                self.panel.orderOut(nil)
                self.dismissWork = nil
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func positionPanel() {
        // Geometry only; no screen capture, OCR, or other app content is read.
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let bounds = screen.visibleFrame
        let width = min(480, max(200, bounds.width - 32))
        let rect = NSRect(x: bounds.midX - width / 2, y: bounds.minY + 24, width: width, height: 176)
        if panel.frame != rect { panel.setFrame(rect, display: true) }
    }
}

private final class DictationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct DictationHUDContent {
    var title = "OpenInsert"
    var message = ""
    var transcript = ""
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var recording = false
    var connected = false
    var failure = false
    var preview = false
    var showTranscript = false
}

@MainActor
private final class DictationHUDModel: ObservableObject {
    @Published var content = DictationHUDContent()
}

private struct DictationHUDView: View {
    @ObservedObject var model: DictationHUDModel
    private let accent = Color(red: 0.20, green: 0.64, blue: 0.48)

    var body: some View {
        let content = model.content
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: content.failure ? "exclamationmark.triangle.fill" : "waveform")
                    .foregroundStyle(content.failure ? .orange : accent)
                Text(content.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if content.recording {
                    Text(String(format: "%.1fs", content.elapsed)).font(.caption.monospacedDigit())
                } else {
                    Text("OpenInsert").font(.caption).foregroundStyle(.secondary)
                }
            }
            if content.recording || content.preview {
                ProgressView(value: Double(min(1, max(0, content.level))))
                    .progressViewStyle(.linear).tint(accent)
            }
            Text(content.message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(content.failure ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !content.failure && content.showTranscript {
                HStack {
                    Text("即時預覽 · 未定稿")
                    Spacer()
                    if content.recording { Text(content.connected ? "Live 已連線" : "正在連線") }
                }.font(.caption2).foregroundStyle(.secondary)
                Text(content.transcript.isEmpty ? "等待辨識文字…" : String(content.transcript.suffix(420)))
                    .font(.callout).lineLimit(4).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08)))
    }
}
