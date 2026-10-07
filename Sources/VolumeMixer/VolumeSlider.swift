import AppKit
import SwiftUI

/// Native AppKit slider with explicit focus on click, so arrow-key adjustment
/// also works when the user's system-wide keyboard navigation setting is off.
struct VolumeSlider: NSViewRepresentable {
    var value: Binding<Double>
    let enabled: Bool
    let muted: Bool
    let appName: String
    let editingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> KeyboardVolumeSlider {
        let slider = KeyboardVolumeSlider(value: value.wrappedValue, minValue: 0, maxValue: 1,
                                          target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.editingChanged = { context.coordinator.parent.editingChanged($0) }
        updateNSView(slider, context: context)
        return slider
    }

    func updateNSView(_ slider: KeyboardVolumeSlider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = value.wrappedValue
        slider.isEnabled = enabled
        slider.trackFillColor = muted ? .secondaryLabelColor : .controlAccentColor
        slider.setAccessibilityLabel("\(appName) volume")
        slider.setAccessibilityValueDescription("\(Int((value.wrappedValue * 100).rounded())) percent\(muted ? ", muted" : "")")
    }

    final class Coordinator: NSObject {
        var parent: VolumeSlider
        init(_ parent: VolumeSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) { parent.value.wrappedValue = slider.doubleValue }
    }
}

final class KeyboardVolumeSlider: NSSlider {
    var editingChanged: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        editingChanged?(true)
        super.mouseDown(with: event)
        editingChanged?(false)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, [123, 124, 125, 126].contains(event.keyCode) else {
            super.keyDown(with: event); return
        }
        let direction: Double = event.keyCode == 123 || event.keyCode == 125 ? -1 : 1
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.01
        // Key repeats are discrete actions. Let the engine debounce their saves;
        // only a mouse drag has an editing session that flushes when it ends.
        doubleValue = min(maxValue, max(minValue, doubleValue + direction * step))
        sendAction(action, to: target)
    }
}
