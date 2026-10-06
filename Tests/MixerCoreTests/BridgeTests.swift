import Foundation
import CoreAudio
import AudioDSP

final class BridgeTests {
    func testConcurrentCaptureAndPlayback() throws {
        let bridge = try require(VMCreateBridge(0.5, 48000, 2, 2)); defer { VMDestroyBridge(bridge) }
        let group = DispatchGroup(), result = ConcurrentResult()
        let total = 512 * 1000, deadline = Date().addingTimeInterval(10)
        DispatchQueue.global().async(group: group) {
            let input = Buffers(channels: [2], frames: 256)
            var written = 0
            while written < total, Date() < deadline {
                if VMBridgeQueuedFrames(bridge) > 32768 { Thread.sleep(forTimeInterval: 0.0001); continue }
                for i in 0..<256 {
                    let value = Float((written + i) % 997) / 1000
                    input.samples()[2*i] = value; input.samples()[2*i + 1] = -value
                }
                VMBridgeCapture(bridge, input.list.unsafePointer); written += 256
            }
            if written != total { result.fail("Capture timed out") }
        }
        DispatchQueue.global().async(group: group) {
            let output = Buffers(channels: [1, 1], frames: 512)
            var read = 0
            while read < total, Date() < deadline {
                if VMBridgeQueuedFrames(bridge) < min(4096, total - read) { Thread.sleep(forTimeInterval: 0.0001); continue }
                VMBridgeRender(bridge, 512, output.list.unsafeMutablePointer)
                for i in 0..<512 {
                    let expected = Float((read + i) % 997) / 2000
                    if abs(output.samples(0)[i] - expected) > 0.000001 || abs(output.samples(1)[i] + expected) > 0.000001 {
                        result.fail("Concurrent sample ordering changed"); return
                    }
                }
                read += 512
            }
            if read != total { result.fail("Playback timed out") }
        }
        group.wait()
        checkNil(result.error)
        checkEqual(VMBridgeFault(bridge), 0); checkEqual(VMBridgeUnderruns(bridge), 0)
        checkEqual(VMBridgeDeliveredFrames(bridge), UInt64(total))
    }
    func testIndependentCallbackSizesAndChannelMapping() throws {
        let bridge = try require(VMCreateBridge(0.25, 48000, 2, 2))
        defer { VMDestroyBridge(bridge) }
        var written = 0, read = 0, chunk = 0
        let captureSizes = [64, 512, 73, 1024, 127], renderSizes = [32, 257, 89, 509]
        while read < 200000 {
            while written - read < 4096 {
                let size = captureSizes[chunk % captureSizes.count]
                let input = Buffers(channels: [2], frames: size)
                for i in 0..<size {
                    let value = Float((written + i) % 997) / 1000
                    input.samples()[2*i] = value; input.samples()[2*i + 1] = -value
                }
                VMBridgeCapture(bridge, input.list.unsafePointer)
                written += size; chunk += 1
            }
            let size = min(renderSizes[chunk % renderSizes.count], 200000 - read)
            let output = Buffers(channels: [1, 1], frames: size, fill: 99)
            VMBridgeRender(bridge, UInt32(size), output.list.unsafeMutablePointer)
            for i in 0..<size {
                let expected = Float((read + i) % 997) / 4000
                checkEqual(output.samples(0)[i], expected, accuracy: 0.000001)
                checkEqual(output.samples(1)[i], -expected, accuracy: 0.000001)
            }
            read += size
        }
        checkEqual(VMBridgeFault(bridge), 0); checkEqual(VMBridgeUnderruns(bridge), 0)
        checkEqual(VMBridgeDeliveredFrames(bridge), 200000)
    }
    func testGainMuteAndUnmute() throws {
        let bridge = try require(VMCreateBridge(1, 48000, 2, 1)); defer { VMDestroyBridge(bridge) }
        let input = Buffers(channels: [1, 1], frames: 8192, fill: 1)
        VMBridgeCapture(bridge, input.list.unsafePointer)
        let output = Buffers(channels: [1], frames: 512)
        VMBridgeSetGain(bridge, 0)
        VMBridgeRender(bridge, 512, output.list.unsafeMutablePointer)
        checkGreater(output.samples()[0], 0.99); checkEqual(output.samples().last!, 0)
        for i in 1..<512 { checkLessEqual(output.samples()[i], output.samples()[i-1]); checkLess(abs(output.samples()[i]-output.samples()[i-1]), 0.003) }
        VMBridgeRender(bridge, 512, output.list.unsafeMutablePointer)
        checkTrue(output.samples().allSatisfy { $0 == 0 })
        VMBridgeSetGain(bridge, 0.37)
        VMBridgeRender(bridge, 512, output.list.unsafeMutablePointer)
        checkEqual(output.samples().last!, 0.37)
        checkEqual(VMBridgeFault(bridge), 0)
    }
    func testStartupIdleAndBounds() throws {
        let bridge = try require(VMCreateBridge(1, 48000, 2, 2)); defer { VMDestroyBridge(bridge) }
        let output = Buffers(channels: [2], frames: 512, fill: 99)
        VMBridgeRender(bridge, 512, output.list.unsafeMutablePointer)
        checkTrue(output.samples().allSatisfy { $0 == 0 })
        checkEqual(VMBridgeUnderruns(bridge), 0)
        let input = Buffers(channels: [2], frames: 2048, fill: 0.3)
        VMBridgeCapture(bridge, input.list.unsafePointer)
        for _ in 0..<4 {
            VMBridgeRender(bridge, 512, output.list.unsafeMutablePointer)
            checkTrue(output.samples().allSatisfy { $0 == 0.3 })
        }
        VMBridgeRender(bridge, 512, output.list.unsafeMutablePointer)
        checkEqual(VMBridgeUnderruns(bridge), 1)
        checkEqual(VMBridgeFault(bridge), 0)
        checkTrue(output.samples().allSatisfy { $0 == 0 })
        let resumed = Buffers(channels: [2], frames: 2048, fill: 0.7)
        VMBridgeCapture(bridge, resumed.list.unsafePointer)
        VMBridgeRender(bridge, 512, output.list.unsafeMutablePointer)
        checkTrue(output.samples().allSatisfy { $0 == 0.7 })
        VMBridgeRender(bridge, 256, output.list.unsafeMutablePointer) // Capacity exceeds the requested slice.
        checkEqual(VMBridgeFault(bridge), 0)
        checkTrue(output.samples().prefix(512).allSatisfy { $0 == 0.7 })
        checkTrue(output.samples().suffix(512).allSatisfy { $0 == 0 })
        VMBridgeRender(bridge, 513, output.list.unsafeMutablePointer) // Deliberately undersized ABL.
        checkEqual(VMBridgeFault(bridge), 1)
        checkTrue(output.samples().allSatisfy { $0 == 0 })
        let overflow = try require(VMCreateBridge(1, 48000, 2, 2)); defer { VMDestroyBridge(overflow) }
        let huge = Buffers(channels: [2], frames: 65537, fill: 1)
        VMBridgeCapture(overflow, huge.list.unsafePointer)
        VMBridgeRender(overflow, 512, output.list.unsafeMutablePointer)
        checkEqual(VMBridgeFault(overflow), 3)
        checkTrue(output.samples().allSatisfy { $0 == 0 })
        checkNil(VMCreateBridge(1, .nan, 2, 2)); checkNil(VMCreateBridge(1, 48000, 6, 2))
    }
}

private final class ConcurrentResult: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var error: String?
    func fail(_ value: String) { lock.lock(); error = value; lock.unlock() }
}
