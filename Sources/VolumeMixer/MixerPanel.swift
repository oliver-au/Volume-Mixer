import SwiftUI
import AppKit
import MixerCore

struct MixerPanel: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(spacing: 0) {
                        if !snapshot.enabled { welcome }
                        if let message = model.operationError ?? snapshot.error { errorBanner(message) }
                        if snapshot.paused && snapshot.enabled {
                            Label("Paused · original playback", systemImage: "pause.circle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .help("Apps use their original volume and output while control is paused")
                        }
                        if snapshot.rows.isEmpty { emptyState }
                        ForEach(snapshot.rows) { row in
                            AppVolumeRow(row: row, image: model.icon(for: row),
                                enabled: snapshot.enabled && !snapshot.paused,
                                outputs: snapshot.outputs, systemOutputName: snapshot.outputName,
                                route: { model.engine.setOutput(id: row.id, uid: $0) },
                                change: { model.engine.setLevel(id: row.id, volume: $0) },
                                editing: { model.engine.setEditing(id: row.id, editing: $0) },
                                mute: { model.engine.setLevel(id: row.id, toggleMute: true) },
                                retry: { model.engine.retry(id: row.id) },
                                permissions: { model.openPermissions() })
                            if row.id != snapshot.rows.last?.id { Divider().padding(.horizontal, 16) }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        if abs(model.listContentHeight - height) > 0.5 { model.listContentHeight = height }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(model.listContentHeight, max(80, model.maximumPanelHeight - 116)))
                Divider().padding(.horizontal, 16)
                footer(snapshot)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .frame(width: MenuPanelController.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { model.onResize?($0) }
        .disabled(model.uninstalling)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Volume Mixer").font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    if model.isPreview { Text("Interface preview · no audio or saved settings") }
                    Divider()
                    Button(model.checkingAudio ? "Checking audio engine…" : "Check audio engine…") { model.checkAudioEngine() }
                        .disabled(model.isPreview || model.checkingAudio || (model.snapshot?.paused != true && model.snapshot?.enabled != false))
                        .help("Pause control first. Checks conversion with synthetic audio in memory.")
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                        .disabled(model.isPreview)
                    Button("Audio permission settings…") { model.openPermissions() }.disabled(model.isPreview)
                    Button("Reset volumes and outputs…") { model.confirmReset() }
                    Divider()
                    Button("Uninstall Volume Mixer…") { model.uninstall() }.disabled(model.isPreview)
                    Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Settings").accessibilityLabel("Settings")
            }
            HStack(spacing: 6) {
                Image(systemName: outputSymbol).frame(width: 15).accessibilityHidden(true)
                Text(model.snapshot?.outputName ?? "Finding audio output…").lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("System output: \(model.snapshot?.outputName ?? "Finding audio output")")
            .help("Current system output. Each app can use its own output below.")
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
    }

    private var outputSymbol: String {
        model.snapshot?.outputSymbol ?? "speaker.wave.2"
    }

    private func footer(_ snapshot: MixerSnapshot) -> some View {
        HStack {
            if snapshot.enabled {
                Button { model.engine.setPaused(!snapshot.paused) } label: {
                    Label(snapshot.paused ? "Resume control" : "Pause control",
                          systemImage: snapshot.paused ? "play" : "pause")
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                .help(snapshot.paused ? "Apply saved app volumes and outputs" : "Restore original playback for every app")
            } else { Text("Audio stays on this Mac").foregroundStyle(.secondary) }
            Spacer()
            Text("\(snapshot.rows.count) \(snapshot.rows.count == 1 ? "app" : "apps")")
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
            Text("No apps are playing audio").font(.system(size: 13, weight: .medium))
            Text("Start a game, video, or music to see it here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 144)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A volume control for every app").font(.system(size: 13, weight: .semibold))
            Text("macOS will ask for System Audio Recording permission when you first adjust an app. Volume Mixer uses this to change playback levels. Nothing is recorded or uploaded.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Enable app control") { model.engine.enableControl() }.buttonStyle(.borderedProminent).controlSize(.small)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if model.operationError != nil {
                Button { model.operationError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss error")
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class RowInteraction: ObservableObject {
    @Published var draggingValue: Double?
    var editing = false
    @Published var showError = false
}

private struct AppVolumeRow: View {
    let row: MixerRow
    let image: NSImage
    let enabled: Bool
    let outputs: [OutputDevice]
    let systemOutputName: String
    let route: (String?) -> Void
    let change: (Float) -> Void
    let editing: (Bool) -> Void
    let mute: () -> Void
    let retry: () -> Void
    let permissions: () -> Void
    @StateObject private var interaction = RowInteraction()
    private var value: Double { interaction.draggingValue ?? Double(row.level.volume) }
    private var canControl: Bool { enabled && row.running && !row.connecting && row.error == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: 24, height: 24).accessibilityHidden(true)
                Text(row.identity.name).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).help(row.identity.name)
                Spacer(minLength: 4)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                VolumeSlider(value: Binding(get: { value }, set: { interaction.draggingValue = $0; change(Float($0)) }),
                       enabled: canControl, muted: row.level.muted, appName: row.identity.name,
                       editingChanged: { isEditing in
                           interaction.editing = isEditing
                           editing(isEditing)
                           if !isEditing { interaction.draggingValue = nil }
                       })
                    .onChange(of: row.level) { _, _ in
                        if !interaction.editing { interaction.draggingValue = nil }
                    }
                    .frame(height: 22)
                Button(action: mute) {
                    Image(systemName: row.level.muted || row.level.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14)).frame(width: 26, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(row.level.muted ? .secondary : .primary)
                .disabled(!canControl)
                .accessibilityLabel("\(row.level.muted ? "Unmute" : "Mute") \(row.identity.name)")
                .help(row.level.muted ? "Restore \(Int(row.level.volume * 100))% volume" : "Mute \(row.identity.name)")
            }
            HStack(spacing: 8) {
                Text("Play through").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("Play through", selection: Binding(get: { row.level.outputUID ?? "" }, set: { route($0.isEmpty ? nil : $0) })) {
                    Text("System output").tag("")
                    ForEach(outputs, id: \.uid) { output in
                        Text(output.controlUnavailableReason == nil ? output.name : "\(output.name) (unsupported)")
                            .tag(output.uid).disabled(output.controlUnavailableReason != nil)
                    }
                    if let uid = row.level.outputUID, !outputs.contains(where: { $0.uid == uid }) {
                        Text("\(row.level.outputName ?? "Saved output") (disconnected)").tag(uid).disabled(true)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).font(.system(size: 11))
                .frame(maxWidth: .infinity)
                .disabled(!enabled || !row.running || row.connecting)
                .accessibilityLabel("Play \(row.identity.name) through")
                .help(row.level.outputUID == nil ? "Follows the Mac's output: \(systemOutputName)" : "Only changes where this app plays")
            }
            status
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        if row.connecting {
            Text("Connecting audio…").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if let error = row.error {
            HStack {
                Button { interaction.showError = true } label: {
                    Label("Control unavailable", systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.plain).foregroundStyle(.orange).help(error)
                Spacer()
                Button("Retry", action: retry).buttonStyle(.bordered).controlSize(.mini)
                    .disabled(!enabled || !row.running)
                    .accessibilityLabel("Retry control for \(row.identity.name)")
            }
            .font(.system(size: 11))
            .popover(isPresented: $interaction.showError) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Control unavailable").font(.headline)
                    Text(error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Text("Original playback is restored.").font(.system(size: 12)).foregroundStyle(.secondary)
                    if error.localizedCaseInsensitiveContains("permission") {
                        Button("Audio permission settings…", action: permissions)
                    }
                    Button("Retry control") { interaction.showError = false; retry() }
                }.padding(16).frame(width: 270)
            }
        } else if row.level.muted || !row.running || row.identity.detail != nil {
            HStack(spacing: 6) {
                if row.level.muted { Text("Muted") }
                if !row.running { Text("Not running") }
                if let detail = row.identity.detail { Text(detail).lineLimit(1).help(detail) }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
