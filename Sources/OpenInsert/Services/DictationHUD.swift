import AppKit
import Combine
import SwiftUI
import OpenInsertCore

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
        model.localizer = controller.settings.localizer
        panel = DictationHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 176),
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

        controller.settings.$interfaceLanguage.removeDuplicates().sink { [weak self] language in
            guard let self else { return }
            // @Published delivers the new value before SettingsStore is assigned.
            self.model.localizer = AppLocalizer(language: language)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.panel.isVisible else { return }
                if self.controller.pasteDispatched { self.hide(); return }
                if self.model.content.preview {
                    self.model.update(self.previewContent())
                } else {
                    self.model.update(self.currentContent(failure: self.model.content.failure))
                }
            }
        }.store(in: &subscriptions)
        controller.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh()
        }.store(in: &subscriptions)
        // Repeated attempts still show identical failures. Re-rendering an old
        // error after a language change does not create another failure event.
        controller.$failureRevision.dropFirst().sink { [weak self] revision in
            guard let self else { return }
            self.failureRevision = revision
            self.scheduleRefresh()
        }.store(in: &subscriptions)
        // The new published value is available before the controller assignment.
        // Hide synchronously when paste is dispatched, without waiting for the
        // coalesced refresh or the clipboard restoration interval.
        controller.$pasteDispatched.removeDuplicates().sink { [weak self] dispatched in
            if dispatched { self?.hide() }
        }.store(in: &subscriptions)
    }

    /// Demonstrates the display only: no recording, provider request, or controller mutation.
    func showPreview() {
        guard !controller.busy else { return }
        show(previewContent(), dismissAfter: 8)
    }

    private func previewContent() -> DictationHUDContent {
        DictationHUDContent(
            title: model.localizer.text("hud.previewTitle", table: "Status"), message: "",
            transcript: model.localizer.text("hud.previewText", table: "Status"),
            elapsed: 0, level: 0.35, recording: false, connected: false,
            failure: false, preview: true, showTranscript: true
        )
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
            if controller.pasteDispatched { hide() }
            else { show(currentContent(failure: false), dismissAfter: nil) }
        } else if controller.lastFailure != nil,
                  previouslyBusy || displayedFailureRevision != failureRevision {
            displayedFailureRevision = failureRevision
            show(currentContent(failure: true), dismissAfter: 10)
        } else if previouslyBusy {
            if controller.copiedToClipboard { show(currentContent(failure: false), dismissAfter: 6) }
            else { hide() }
        }
    }

    private func hide() {
        guard !closed else { return }
        displayRevision &+= 1
        dismissWork?.cancel()
        dismissWork = nil
        panel.orderOut(nil)
    }

    private func currentContent(failure: Bool) -> DictationHUDContent {
        DictationHUDContent(
            title: failure ? model.localizer.text("hud.failure", table: "Status") : controller.statusTitle,
            message: failure ? (controller.lastFailure ?? controller.message) : controller.message,
            transcript: controller.liveText, elapsed: controller.elapsed, level: controller.level,
            recording: controller.phase == .recording, connected: controller.liveConnected,
            failure: failure, copied: controller.copiedToClipboard, preview: false,
            showTranscript: controller.phase == .preparing || controller.phase == .recording || controller.phase == .transcribing || (controller.phase == .testing && controller.testingPipeline)
        )
    }

    private func show(_ content: DictationHUDContent, dismissAfter delay: TimeInterval?) {
        guard !closed else { return }
        displayRevision &+= 1
        let revision = displayRevision
        dismissWork?.cancel()
        dismissWork = nil
        model.update(content)
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
        let width = min(400, max(1, bounds.width - 32))
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
    var copied = false
    var preview = false
    var showTranscript = false
}

@MainActor
private final class DictationHUDModel: ObservableObject {
    @Published var content = DictationHUDContent()
    @Published var localizer = AppLocalizer(language: .english)
    @Published private(set) var levels = Array(repeating: CGFloat.zero, count: DictationWaveform.barCount)
    private var sampledElapsed: TimeInterval = -1

    func update(_ next: DictationHUDContent) {
        if !next.recording || !content.recording || next.elapsed < content.elapsed {
            levels = Array(repeating: 0, count: DictationWaveform.barCount)
            sampledElapsed = -1
        }
        // The controller already samples real microphone RMS every 100 ms.
        // Advance on elapsed time, including equal levels and silence; transcript
        // publications must not add extra samples or speed up the waveform.
        if next.recording && (sampledElapsed < 0 || next.elapsed - sampledElapsed >= 0.08) {
            levels.removeFirst()
            levels.append(DictationWaveform.amplitude(next.level))
            sampledElapsed = next.elapsed
        }
        content = next
    }
}

private enum DictationWaveform {
    static let barCount = 96

    static func amplitude(_ rms: Float) -> CGFloat {
        guard rms.isFinite, rms > 0 else { return 0 }
        // Display gain only: leave recorded/transmitted PCM untouched. A dB
        // scale makes ordinary speech visible without treating silence as audio.
        let decibels = 20 * log10(Double(min(1, rms)))
        return CGFloat(min(1, max(0, (decibels + 55) / 43)))
    }
}

private struct DictationWaveformView: View {
    let levels: [CGFloat]
    let animate: Bool
    let localizer: AppLocalizer

    var body: some View {
        GeometryReader { geometry in
            // Fixed, dense 2 pt strokes with 2 pt gaps. Narrower screens show
            // fewer recent samples rather than squeezing the transcript or
            // stretching the spacing between columns.
            let count = max(1, min(levels.count, Int((geometry.size.width + 2) / 4)))
            let visibleLevels = Array(levels.suffix(count))
            HStack(alignment: .center, spacing: 2) {
                ForEach(visibleLevels.indices, id: \.self) { index in
                    Capsule()
                        .fill(LinearGradient(colors: [Color(red: 0.32, green: 0.88, blue: 0.60),
                                                       Color(red: 0.10, green: 0.66, blue: 0.40)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 2, height: 2 + 26 * visibleLevels[index])
                }
            }
            .frame(width: geometry.size.width, height: 28)
        }
        .frame(height: 28)
        .animation(animate ? .linear(duration: 0.1) : nil, value: levels)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localizer.text("hud.microphone", table: "Status"))
        .accessibilityValue("\(Int((levels.last ?? 0) * 100))%")
    }
}

/// Synthetic motion is exclusive to the explicitly labelled, microphone-free preview.
private struct DictationWaveformPreview: View {
    let reduceMotion: Bool
    let localizer: AppLocalizer

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let levels = (0..<DictationWaveform.barCount).map { index in
                let t = time - Double(DictationWaveform.barCount - index - 1) * 0.1
                return CGFloat(pow(max(0, sin(t * 2.8)), 2) * (0.4 + 0.6 * abs(sin(t * 7.3))))
            }
            DictationWaveformView(levels: levels, animate: !reduceMotion, localizer: localizer)
                .accessibilityLabel(localizer.text("hud.simulated", table: "Status"))
        }
    }
}

private struct DictationHUDView: View {
    @ObservedObject var model: DictationHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let accent = Color(red: 0.20, green: 0.64, blue: 0.48)

    var body: some View {
        let content = model.content
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: content.failure ? "exclamationmark.triangle.fill" : (content.copied ? "doc.on.clipboard" : "waveform"))
                    .foregroundStyle(content.failure ? .orange : accent)
                Text(content.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if content.recording {
                    Text(model.localizer.text("hud.elapsed", table: "Status", arguments: [content.elapsed])).font(.caption.monospacedDigit())
                } else {
                    Text("OpenInsert").font(.caption).foregroundStyle(.secondary)
                }
            }
            if content.preview {
                DictationWaveformPreview(reduceMotion: reduceMotion, localizer: model.localizer)
            } else if content.recording {
                DictationWaveformView(levels: model.levels, animate: !reduceMotion, localizer: model.localizer)
            }
            // Keep recovery notices and the insertion-test countdown, but reserve
            // the dictation area for sound and words instead of shortcut/debug tips.
            if content.failure || content.copied || (!content.showTranscript && !content.message.isEmpty) {
                Text(content.message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(content.failure || content.copied ? 4 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !content.failure && content.showTranscript {
                HStack {
                    Text(model.localizer.text(content.preview ? "hud.previewCaption" : "hud.live", table: "Status"))
                    Spacer()
                    if content.recording { Text(model.localizer.text(content.connected ? "hud.interim" : "hud.connecting", table: "Status")) }
                }.font(.caption2).foregroundStyle(.secondary)
                Text(content.transcript.isEmpty ? model.localizer.text("hud.waiting", table: "Status") : String(content.transcript.suffix(420)))
                    .font(.callout).lineLimit(4).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.08)))
    }
}
