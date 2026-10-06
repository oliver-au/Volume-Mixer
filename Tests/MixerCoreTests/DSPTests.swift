import Foundation
import CoreAudio
import AudioDSP

final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int
    init(channels: [Int], frames: Int, fill: Float = 0) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: channels.count)
        list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channels.count)
        for (i, count) in channels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * count)
            data.initialize(repeating: fill, count: frames * count)
            list[i] = AudioBuffer(mNumberChannels: UInt32(count), mDataByteSize: UInt32(frames * count * 4), mData: data)
        }
    }
    func samples(_ buffer: Int = 0) -> UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: list[buffer].mData!.assumingMemoryBound(to: Float.self), count: Int(list[buffer].mDataByteSize) / 4)
    }
    deinit { for b in list { b.mData?.deallocate() }; free(list.unsafeMutablePointer) }
}

final class DSPTests {
    func testStereoAttenuationAndIndependentSessions() throws {
        let input = Buffers(channels: [2], frames: 64, fill: 0.8)
        let a = Buffers(channels: [2], frames: 64), b = Buffers(channels: [2], frames: 64)
        let first = try require(VMCreateDSP(0.5, 48000, 0, 2, 2))
        let second = try require(VMCreateDSP(0.25, 48000, 0, 2, 2))
        defer { VMDestroyDSP(first); VMDestroyDSP(second) }
        VMRender(first, input.list.unsafePointer, a.list.unsafeMutablePointer)
        VMRender(second, input.list.unsafePointer, b.list.unsafeMutablePointer)
        checkTrue(a.samples().allSatisfy { abs($0 - 0.4) < 0.0001 })
        checkTrue(b.samples().allSatisfy { abs($0 - 0.2) < 0.0001 })
    }
    func testMuteRampsWithoutClickThenOutputsZero() throws {
        let input = Buffers(channels: [2], frames: 512, fill: 1)
        let output = Buffers(channels: [2], frames: 512)
        let state = try require(VMCreateDSP(1, 48000, 0, 2, 2)); defer { VMDestroyDSP(state) }
        VMSetGain(state, 0); VMRender(state, input.list.unsafePointer, output.list.unsafeMutablePointer)
        let values = Array(output.samples())
        checkGreater(values[0], 0.99)
        checkEqual(values.last!, 0, accuracy: 0.00001)
        for i in stride(from: 2, to: values.count, by: 2) { checkLessEqual(values[i], values[i-2]); checkLess(abs(values[i]-values[i-2]), 0.003) }
    }
    func testPhysicalInputChannelsAreSkippedAndPlanarIsSupported() throws {
        let input = Buffers(channels: [1, 1, 1], frames: 32)
        for i in 0..<32 { input.samples(0)[i] = 100; input.samples(1)[i] = 0.2; input.samples(2)[i] = 0.4 }
        let output = Buffers(channels: [1, 1], frames: 32)
        let state = try require(VMCreateDSP(1, 48000, 1, 2, 2)); defer { VMDestroyDSP(state) }
        VMRender(state, input.list.unsafePointer, output.list.unsafeMutablePointer)
        checkEqual(output.samples(0)[0], 0.2, accuracy: 0.00001)
        checkEqual(output.samples(1)[0], 0.4, accuracy: 0.00001)
    }
    func testMonoAndStereoMapping() throws {
        let input = Buffers(channels: [2], frames: 16)
        for i in stride(from: 0, to: 32, by: 2) { input.samples()[i] = 0.2; input.samples()[i+1] = 0.6 }
        let output = Buffers(channels: [1], frames: 16)
        let state = try require(VMCreateDSP(1, 24000, 0, 2, 1)); defer { VMDestroyDSP(state) }
        VMRender(state, input.list.unsafePointer, output.list.unsafeMutablePointer)
        checkTrue(output.samples().allSatisfy { abs($0 - 0.4) < 0.0001 })
        let stereo = Buffers(channels: [2], frames: 16)
        let monoState = try require(VMCreateDSP(1, 24000, 0, 1, 2)); defer { VMDestroyDSP(monoState) }
        VMRender(monoState, output.list.unsafePointer, stereo.list.unsafeMutablePointer)
        checkTrue(stereo.samples().allSatisfy { abs($0 - 0.4) < 0.0001 })
    }
    func testMissingInputClearsOutputAndNonFiniteSamplesAreContained() throws {
        let output = Buffers(channels: [2], frames: 16, fill: 99)
        let state = try require(VMCreateDSP(1, 48000, 0, 2, 2)); defer { VMDestroyDSP(state) }
        VMRender(state, nil, output.list.unsafeMutablePointer)
        checkTrue(output.samples().allSatisfy { $0 == 0 })
        let input = Buffers(channels: [2], frames: 16, fill: .nan)
        VMRender(state, input.list.unsafePointer, output.list.unsafeMutablePointer)
        checkTrue(output.samples().allSatisfy { $0 == 0 })
        checkEqual(VMGetCallbackCount(state), 2)
    }
    func testInvalidLayoutsAreRejected() {
        checkNil(VMCreateDSP(1, 0, 0, 2, 2))
        checkNil(VMCreateDSP(1, 48000, 0, 6, 2))
        checkNil(VMCreateDSP(1, .nan, 0, 2, 2))
    }
    func testUnmuteRampsAndLayoutChangesClearOutput() throws {
        let state = try require(VMCreateDSP(0, 48000, 0, 2, 2)); defer { VMDestroyDSP(state) }
        let input = Buffers(channels: [2], frames: 512, fill: 1)
        let output = Buffers(channels: [2], frames: 512, fill: 99)
        VMSetGain(state, 0.6); VMRender(state, input.list.unsafePointer, output.list.unsafeMutablePointer)
        let values = output.samples()
        checkLess(values[0], 0.003); checkGreater(values[0], 0)
        checkEqual(values.last!, 0.6, accuracy: 0.00001)
        for i in stride(from: 2, to: values.count, by: 2) {
            checkTrue(values[i] >= values[i-2]); checkLess(abs(values[i]-values[i-2]), 0.003)
        }
        let changedInput = Buffers(channels: [1], frames: 512, fill: 1)
        VMRender(state, changedInput.list.unsafePointer, output.list.unsafeMutablePointer)
        checkTrue(output.samples().allSatisfy { $0 == 0 }); checkNotEqual(VMGetFault(state), 0)
    }
}
