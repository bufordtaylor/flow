import AppKit
import AVFoundation
import FlowCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var step = 0
    @State private var tryText = ""
    @State private var promptedAX = false
    var onFinish: () -> Void

    private let steps = ["Microphone", "Accessibility", "Speech model", "Done"]
    private var coordinator: AppCoordinator { AppCoordinator.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            progressRow
            Divider()
            Group {
                switch step {
                case 0: microphone
                case 1: accessibility
                case 2: model
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("Back") { step -= 1 }.disabled(step == 0)
                Spacer()
                if step < 3 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") { Settings.shared.onboardingDone = true; onFinish() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private var progressRow: some View {
        HStack(spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 6) {
                    Image(systemName: stepDone(i) ? "checkmark.circle.fill" : (i == step ? "circle.inset.filled" : "circle"))
                        .foregroundStyle(stepDone(i) ? .green : (i == step ? Color.accentColor : .secondary))
                    Text(name).font(.callout).foregroundStyle(i == step ? .primary : .secondary).lineLimit(1).fixedSize()
                        .clipCheck("onboarding", "step-\(i)")
                }
                .layoutPriority(1)
                if i < steps.count - 1 { Rectangle().fill(.quaternary).frame(height: 1).frame(maxWidth: .infinity) }
            }
        }
    }

    private func stepDone(_ i: Int) -> Bool {
        switch i {
        case 0: return state.micGranted
        case 1: return state.axTrusted
        case 2: return state.modelInstalled
        default: return false
        }
    }

    private func title(_ t: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t).font(.title2.weight(.semibold)).clipCheck("onboarding", t)
            Text(body).fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary).clipCheck("onboarding", "\(t)-body")
        }
    }

    private func statusLine(_ ok: Bool, _ okText: String, _ badText: String) -> some View {
        Label(ok ? okText : badText, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? .green : .secondary)
            .clipCheck("onboarding", okText)
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Microphone", "Flow listens only while you hold the hotkey. Audio is processed on this Mac and never stored.")
            statusLine(state.micGranted, "Microphone access granted", "Microphone access not granted yet")
            HStack {
                Button("Allow microphone") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in coordinator.refreshPermissions() } }
                }
                if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                    Button("Open Microphone settings") { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
                }
            }
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Accessibility", "The Accessibility permission lets Flow see the hotkey in any app and put text at the caret. The checkmark below flips on its own once you switch it on.")
            statusLine(state.axTrusted, "Accessibility granted", "Accessibility not granted yet")
            Button("Open Accessibility settings") {
                openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
            if !state.axTrusted && state.wasEverTrusted {
                Text("Already switched on for Flow? Turn it off and on again. A rebuilt app loses the grant.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .clipCheck("onboarding", "rebuilt-hint")
            }
        }
        .onAppear {
            guard !promptedAX else { return }
            promptedAX = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Speech model", "Flow will download Parakeet TDT 0.6B v3 (about 600 MB) from Hugging Face into \(Settings.shared.modelPath.path). This is the only time the app will ever use the network.")
            if let p = state.downloadProgress {
                ProgressView(value: p.fraction) {
                    Text(p.file.isEmpty ? "Starting…" : p.file).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Text(String(format: "%.0f of %.0f MB", Double(p.bytesReceived) / 1e6, Double(p.bytesTotal) / 1e6)).font(.caption).foregroundStyle(.secondary)
            } else if state.modelInstalled {
                statusLine(true, "Model installed", "")
                if let c = state.modelChecksum {
                    HStack { Text("Checksum").foregroundStyle(.secondary); Text(c).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle) }
                }
                HStack(alignment: .top) {
                    Text("Cleanup").foregroundStyle(.secondary)
                    Text(state.cleanupSummary).fixedSize(horizontal: false, vertical: true).clipCheck("onboarding", "cleanup-summary")
                    if state.availability[.apple]?.available != true && state.availability[.ollama]?.available != true {
                        Link("ollama.com", destination: URL(string: "https://ollama.com")!)
                    }
                }
            } else {
                statusLine(false, "", "No model yet")
            }
            if let e = state.downloadError { Text(e).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(state.modelInstalled ? "Re-download" : "Download") { coordinator.downloadModel() }.disabled(state.downloadProgress != nil)
                Button("Load from folder…") { pickFolder() }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Ready", "Hold \(state.hotkey.displayString) while you speak, release, and the cleaned text lands at the caret. Escape cancels.")
            HStack { Text("Hotkey").foregroundStyle(.secondary); Text(state.hotkey.displayString).font(.title3.weight(.medium)) }
            Text("Try it here").font(.callout).foregroundStyle(.secondary)
            TextField("Click here, then hold the hotkey and talk", text: $tryText, axis: .vertical).lineLimit(3...6)
        }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "Pick the folder that holds parakeet-tdt-0.6b-v3-coreml and silero-vad-coreml"
        if p.runModal() == .OK, let url = p.url { coordinator.importModel(from: url) }
    }
}
