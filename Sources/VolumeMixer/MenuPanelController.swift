import AppKit
import SwiftUI

/// An arrowless, key-capable menu panel. All positioning uses the status item's
/// screen coordinates, including displays whose origin is negative.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 340
    private let panel = MixerMenuWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 260),
        styleMask: [.borderless], backing: .buffered, defer: false)
    private weak var button: NSStatusBarButton?
    private let model: MixerModel
    private let glass = NSGlassEffectView()
    private var clickMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var anchorObserver: NSObjectProtocol?
    private var requestedHeight: CGFloat = 260

    init(button: NSStatusBarButton, model: MixerModel) {
        self.button = button
        self.model = model
        super.init()
        panel.delegate = self
        panel.title = "Volume Mixer"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.escape = { [weak self] in self?.dismiss() }
        glass.style = .regular
        glass.cornerRadius = 20
        let host = NSHostingView(rootView: MixerPanel(model: model))
        host.sizingOptions = []
        glass.contentView = host
        panel.contentView = glass
        model.onResize = { [weak self] height in
            guard let self, abs(height - self.requestedHeight) > 0.5 else { return }
            self.requestedHeight = height
            if self.panel.isVisible { self.position() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        if let statusWindow = button.window {
            anchorObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: statusWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isVisible == true { self?.position() } }
            }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? dismiss() : show() }

    func show() {
        guard button?.window != nil else { return }
        position()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        button?.highlight(true)
        installMonitors()
        if model.isPreview { PanelPreview.recordEvent("show") }
        // A hosted SwiftUI view reports its natural content height after layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.position()
            self.panel.recalculateKeyViewLoop()
        }
    }

    func dismiss() {
        panel.orderOut(nil)
        button?.highlight(false)
        removeMonitors()
        if model.isPreview { PanelPreview.recordEvent("dismiss") }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Menus/popovers own a child key window while tracking. Allow those
        // controls to finish; clicks outside are handled by the monitors.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.panel.isKeyWindow else { return }
            if let key = NSApp.keyWindow, key.parent == self.panel || key is NSPanel { return }
            self.dismiss()
        }
    }

    private func position() {
        guard let button, let statusWindow = button.window,
              let screen = statusWindow.screen ?? NSScreen.main else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // visibleFrame keeps the panel out of the Dock; anchor.minY handles the
        // menu-bar height and its temporary reveal when auto-hide is enabled.
        let available = screen.visibleFrame
        // Newly inserted status items can briefly report a zero/offscreen frame.
        // Use the visible menu-bar edge until AppKit supplies the real anchor.
        let hasAnchor = anchor.intersects(screen.frame) && anchor.minY > screen.frame.midY
        let top = (hasAnchor ? min(anchor.minY, screen.frame.maxY) :
                   min(available.maxY, screen.frame.maxY - NSStatusBar.system.thickness)) - 4
        let maximumHeight = max(160, top - available.minY - 8)
        let contentLimit = min(720, maximumHeight)
        if abs(model.maximumPanelHeight - contentLimit) > 0.5 { model.maximumPanelHeight = contentLimit }
        let height = min(requestedHeight, contentLimit)
        let right = hasAnchor ? anchor.maxX : available.maxX - 8
        let x = min(max(right - Self.width, available.minX + 8), available.maxX - Self.width - 8)
        panel.setFrame(NSRect(x: x, y: max(available.minY + 8, top - height),
                              width: Self.width, height: height), display: true)
        if model.isPreview {
            PanelPreview.recordLayout(screen: screen, anchor: anchor, frame: panel.frame,
                requestedHeight: requestedHeight, listHeight: model.listContentHeight)
        }
    }

    private func installMonitors() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53,
               event.window === self.panel || self.panel.isKeyWindow {
                self.dismiss(); return nil
            }
            if event.type != .keyDown {
                // The status button's own action handles a second click. Let
                // popovers and native menus track without dismissing the parent.
                if event.window === self.button?.window || event.window === self.panel ||
                    event.window?.parent === self.panel || (event.window?.level.rawValue ?? 0) >= NSWindow.Level.popUpMenu.rawValue {
                    return event
                }
                self.dismiss()
            }
            return event
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        clickMonitor = nil; localMonitor = nil
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let anchorObserver { NotificationCenter.default.removeObserver(anchorObserver) }
    }
}

private final class MixerMenuWindow: NSPanel {
    var escape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { escape?() }
}
