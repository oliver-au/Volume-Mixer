import AppKit

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}
final class SliderTarget: NSObject {
    var values: [Double] = []
    @objc func changed(_ sender: NSSlider) { values.append(sender.doubleValue) }
}

// Native controls only: no windows, production app, audio or preferences.
_ = NSApplication.shared
let target = SliderTarget()
let slider = KeyboardVolumeSlider(value: 0.8, minValue: 0, maxValue: 1,
    target: target, action: #selector(SliderTarget.changed(_:)))
var editing: [Bool] = []
slider.editingChanged = { editing.append($0) }
func press(_ code: UInt16, repeatKey: Bool = false, shift: Bool = false) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: repeatKey, keyCode: code)!
    slider.keyDown(with: event)
}
for i in 0..<20 { press(123, repeatKey: i > 0) }
check(target.values.count == 20, "Every arrow key applies volume immediately")
check(abs(slider.doubleValue - 0.6) < 0.00001, "Twenty keypresses adjust twenty percentage points")
check(editing.isEmpty, "Key repeats must not emit drag-end preference flushes")
print("CHECK: native keyboard repeat actions and editing callbacks")

press(124, shift: true)
check(abs(slider.doubleValue - 0.7) < 0.00001, "Shift-arrow uses ten percentage points")
for _ in 0..<20 { press(126, shift: true) }
check(slider.doubleValue == 1, "Up-arrow clamps at 100 percent")
for _ in 0..<20 { press(125, shift: true) }
check(slider.doubleValue == 0, "Down-arrow clamps at zero")
print("CHECK: native keyboard increments and bounds")

var terminated = false
let timer = Timer(timeInterval: 0.02, repeats: false) { _ in terminated = true }
RunLoop.main.add(timer, forMode: .common)
check(ApplicationTermination.wait(timeout: 1) { terminated }, "Termination wait must service the run loop")
timer.invalidate()
check(ApplicationTermination.wait(timeout: 0) { true }, "Already exited applications return immediately")
print("CHECK: delayed and already-complete termination")

var ticks = 0
let heartbeat = Timer(timeInterval: 0.005, repeats: true) { _ in ticks += 1 }
RunLoop.main.add(heartbeat, forMode: .common)
let began = ProcessInfo.processInfo.systemUptime
check(!ApplicationTermination.wait(timeout: 0.05) { false }, "A live app must reach the bounded timeout")
let elapsed = ProcessInfo.processInfo.systemUptime - began
heartbeat.invalidate()
check(elapsed >= 0.04 && elapsed < 1, "Termination timeout stays bounded")
check(ticks > 0, "The run loop remains responsive during the timeout")
print("CHECK: timeout and run-loop responsiveness")
print("4 AppKit scenarios; \(failures) failed assertions")
exit(failures == 0 ? 0 : 1)
