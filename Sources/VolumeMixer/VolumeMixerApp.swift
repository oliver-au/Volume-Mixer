import AppKit
import SwiftUI
import ServiceManagement
import MixerCore

@main
struct VolumeMixerMain {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--live-audio-check"), CommandLine.arguments.count > index + 1 {
            LiveAudioCheck.run(reportURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if CommandLine.arguments.contains("--quit-running") {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Preferences.bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            for app in apps { app.terminate() }
            let terminated = ApplicationTermination.wait(timeout: 12) { apps.allSatisfy(\.isTerminated) }
            exit(terminated ? 0 : 1)
        }
        if CommandLine.arguments.contains("--self-check") {
            let settings = Preferences()
            print("Bundle: \(Bundle.main.bundleIdentifier ?? "unbundled"); preferences loaded; enabled=\(settings.hasEnabledControl)")
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            do {
                let output = try HAL.defaultOutput()
                print("Output: \(output.name) | \(output.sampleRate) Hz | \(output.channels) channels")
                print("Streams: \(output.inputs.count) input, \(output.outputs.count) output")
                for app in try ProcessCatalog.scan() {
                    print("\(app.active ? "PLAYING" : "idle") | \(app.identity.name) | PIDs \(app.pids) | \(app.identity.detail ?? "") | devices \(app.outputDevices)")
                }
            } catch { print("Diagnostic failed: \(error.localizedDescription)"); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var menuPanel: MenuPanelController?
    private var model: MixerModel!
    private var observers: [NSObjectProtocol] = []
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview-panel") ||
            Bundle.main.object(forInfoDictionaryKey: "VolumeMixerPreview") as? Bool == true
        if preview {
            let appearance = PanelPreview.option("light") ? NSAppearance.Name.aqua : .darkAqua
            NSApp.appearance = NSAppearance(named: appearance)
        }
        // A second copy must never create a competing set of audio taps.
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? Preferences.bundleID)
        if let existing = instances.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(); NSApp.terminate(nil); return
        }
        model = preview ? MixerModel(engine: PanelPreview.makeEngine(), isPreview: true) : MixerModel()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image()
        item.button?.target = self; item.button?.action = #selector(togglePanel)
        item.button?.toolTip = "Volume Mixer — individual app volume"
        item.button?.setAccessibilityLabel("Volume Mixer")
        if let button = item.button { menuPanel = MenuPanelController(button: button, model: model) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.engine.setSleeping(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.engine.setSleeping(false) }
        })
        // A normal Finder launch opens the panel; a login launch stays unobtrusive.
        if !CommandLine.arguments.contains("--background") && NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue != keyAELaunchedAsLogInItem {
            menuPanel?.show()
        }
    }
    @objc private func togglePanel() { menuPanel?.toggle() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { menuPanel?.show(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !terminating else { return .terminateNow }
        terminating = true
        model.engine.shutdown { MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) } }
        // A stuck Core Audio server must not trap the user inside the app.
        // Process exit releases this process's private taps and their muting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

@MainActor
final class MixerModel: ObservableObject {
    let engine: MixerEngine
    let isPreview: Bool
    @Published var snapshot: MixerSnapshot?
    @Published var launchAtLogin: Bool
    @Published var operationError: String?
    @Published var uninstalling = false
    @Published var checkingAudio = false
    @Published var listContentHeight: CGFloat = 150
    @Published var maximumPanelHeight: CGFloat = 720
    var onResize: ((CGFloat) -> Void)?
    private var icons: [String: NSImage] = [:]

    init(engine: MixerEngine = MixerEngine(), isPreview: Bool = false) {
        self.engine = engine
        self.isPreview = isPreview
        self.launchAtLogin = !isPreview && SMAppService.mainApp.status == .enabled
        engine.start { [weak self] snapshot in
            Task { @MainActor in
                guard let self, !self.uninstalling else { return }
                self.snapshot = snapshot
                let iconKeys = Set(snapshot.rows.map { $0.identity.iconPath ?? $0.id })
                self.icons = self.icons.filter { iconKeys.contains($0.key) }
            }
        }
    }
    func icon(for row: MixerRow) -> NSImage {
        let key = row.identity.iconPath ?? row.id
        if let image = icons[key] { return image }
        let image = row.identity.iconPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: row.identity.isWine ? "gamecontroller.fill" : "app", accessibilityDescription: nil)!
        icons[key] = image; return image
    }
    func setLogin(_ value: Bool) {
        guard !isPreview else { return }
        Task {
            do {
                if value { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
                launchAtLogin = SMAppService.mainApp.status == .enabled
                if value && !launchAtLogin { operationError = "Allow Volume Mixer in System Settings → General → Login Items." }
            } catch { operationError = "Couldn't update launch at login: \(error.localizedDescription)" }
        }
    }
    func openPermissions() {
        guard !isPreview else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
    func checkAudioEngine() {
        guard !isPreview else { return }
        guard !checkingAudio, snapshot?.paused == true || snapshot?.enabled == false else { return }
        checkingAudio = true
        Task {
            let error: String? = await Task.detached(priority: .userInitiated) {
                do { try PlaybackProbe.run(); return nil as String? }
                catch { return error.localizedDescription }
            }.value
            checkingAudio = false
            let alert = NSAlert()
            alert.messageText = error == nil ? "Offline audio check passed" : "Offline audio check failed"
            alert.informativeText = error ?? "48 → 44.1 kHz stereo and 48 → 24 kHz mono conversion, pitch, volume and mute passed.\n\nThis used synthetic audio in memory. Bluetooth playback still needs a listening check."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset all app volumes and outputs?"
        alert.informativeText = "All saved levels will return to 100%, all apps will be unmuted, and their output selections will return to System output."
        alert.addButton(withTitle: "Reset"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { engine.resetLevels() }
    }
    func uninstall() {
        guard !isPreview else { return }
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        guard appURL.pathExtension == "app", Bundle.main.bundleIdentifier == Preferences.bundleID else {
            operationError = "Open the installed Volume Mixer app to uninstall it."; return
        }
        let readOnlyVolume = (try? appURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        guard !readOnlyVolume else {
            operationError = "This copy is on a read-only disk image. Eject the image, or uninstall the copy in Applications."; return
        }
        let alert = NSAlert()
        alert.messageText = "Uninstall Volume Mixer?"
        alert.informativeText = "This restores normal audio, removes Volume Mixer's saved settings and login item, and moves this app to Trash:\n\n\(appURL.path)\n\nYour other apps, project files, and installer are untouched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Uninstall")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        uninstalling = true
        // Restore playback before any login, preference, or filesystem operation.
        engine.shutdown { [weak self] in
            Task { @MainActor in await self?.finishUninstall(appURL: appURL) }
        }
    }
    private func finishUninstall(appURL: URL) async {
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            showUninstallFailure("Audio control has stopped. The app and its settings remain because the login item couldn't be removed: \(error.localizedDescription)")
            return
        }
        guard engine.clearSettingsAfterShutdown() else {
            showUninstallFailure("Audio control has stopped and the login item was removed. Saved settings could not be cleared; the app remains installed.")
            return
        }
        do { try OwnedFiles.removeCaches() }
        catch {
            showUninstallFailure("Audio control has stopped, but some app files could not be removed: \(error.localizedDescription)")
            return
        }
        NSWorkspace.shared.recycle([appURL]) { _, error in
            Task { @MainActor in
                if let error { self.showUninstallFailure("Settings were removed, but macOS couldn't move the app to Trash: \(error.localizedDescription)") }
                else { NSApp.terminate(nil) }
            }
        }
    }
    private func showUninstallFailure(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Uninstall incomplete"; alert.informativeText = message
        alert.addButton(withTitle: "Quit"); alert.runModal(); NSApp.terminate(nil)
    }
}
