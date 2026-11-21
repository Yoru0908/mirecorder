import Foundation
import AVFoundation
import CoreMedia

/// Buffers the two inputs on the capture queue and mixes their overlapping samples.
final class AudioMixer {
    private struct Item {
        let start: Int64
        let samples: [Float]

        var end: Int64 { start + Int64(samples.count / 2) }
    }

    private static let rate: CMTimeScale = 48_000
    private let chunkFrames: Int64 = 480
    private let joinFrames: Int64 = 3_840
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 48_000, channels: 2, interleaved: true)!.formatDescription

    var micGain: Float = 1.6
    var sysGain: Float = 2.0

    private var system: [Item] = []
    private var microphone: [Item] = []
    private var outputFrame: Int64?
    private var latestFrame: Int64?

    func reset() {
        system.removeAll()
        microphone.removeAll()
        outputFrame = nil
        latestFrame = nil
    }

    func begin(at time: CMTime) {
        outputFrame = Self.frame(at: time)
    }

    func pushSystem(_ buffer: CMSampleBuffer) -> Float {
        push(buffer, gain: sysGain, into: &system)
    }

    func pushMic(_ buffer: CMSampleBuffer) -> Float {
        push(buffer, gain: micGain, into: &microphone)
    }

    private func push(_ buffer: CMSampleBuffer, gain: Float, into queue: inout [Item]) -> Float {
        guard let (item, peak) = Self.convert(buffer, gain: gain) else { return 0 }
        latestFrame = max(latestFrame ?? item.end, item.end)
        if item.end > (outputFrame ?? item.start) {
            queue.append(item)
            if queue.count > 256 { queue.removeFirst(queue.count - 256) }
        }
        return min(1, peak)
    }

    func next(flushing: Bool = false) -> CMSampleBuffer? {
        guard let outputFrame, let latestFrame else { return nil }
        system.removeAll { $0.end <= outputFrame }
        microphone.removeAll { $0.end <= outputFrame }
        let earliest = [system.first?.start, microphone.first?.start].compactMap { $0 }.min()
        guard let earliest else { return nil }

        let start = max(outputFrame, earliest)
        let available = latestFrame - (flushing ? 0 : joinFrames) - start
        guard available >= chunkFrames || (flushing && available > 0) else { return nil }
        let frames = min(chunkFrames, available)
        let end = start + frames
        var samples = [Float](repeating: 0, count: Int(frames) * 2)
        Self.mix(system, into: &samples, start: start, end: end)
        Self.mix(microphone, into: &samples, start: start, end: end)
        for i in samples.indices { samples[i] = max(-1, min(1, samples[i])) }
        self.outputFrame = end
        return makeSampleBuffer(samples, frames: Int(frames), start: start)
    }

    private static func mix(_ items: [Item], into output: inout [Float], start: Int64, end: Int64) {
        for item in items {
            if item.start >= end { break }
            let overlapStart = max(start, item.start)
            let overlapEnd = min(end, item.end)
            guard overlapStart < overlapEnd else { continue }
            let inputOffset = Int(overlapStart - item.start) * 2
            let outputOffset = Int(overlapStart - start) * 2
            for offset in 0..<(Int(overlapEnd - overlapStart) * 2) {
                output[outputOffset + offset] += item.samples[inputOffset + offset]
            }
        }
    }

    private static func frame(at time: CMTime) -> Int64 {
        time.convertScale(rate, method: .roundHalfAwayFromZero).value
    }

    private static func convert(_ buffer: CMSampleBuffer, gain: Float) -> (Item, Float)? {
        guard let asbd = buffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0, buffer.presentationTimeStamp.isNumeric else { return nil }
        let float = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let int16 = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && asbd.mBitsPerChannel == 16
        guard (float && asbd.mBitsPerChannel == 32) || int16 else { return nil }
        let ratio = Double(rate) / asbd.mSampleRate
        return try? buffer.withAudioBufferList { buffers, _ in
            guard let first = buffers.first, let left = first.mData, first.mNumberChannels > 0 else { return nil }
            let last = first.mNumberChannels == 1 && buffers.count > 1 ? buffers[1] : first
            guard let right = last.mData, last.mNumberChannels > 0 else { return nil }
            let leftStride = Int(first.mNumberChannels)
            let rightStride = Int(last.mNumberChannels)
            let rightOffset = leftStride > 1 ? 1 : 0
            let byteWidth = Int(asbd.mBitsPerChannel) / 8
            let sourceFrames = min(buffer.numSamples,
                                   Int(first.mDataByteSize) / (byteWidth * leftStride),
                                   Int(last.mDataByteSize) / (byteWidth * rightStride))
            guard sourceFrames > 0 else { return nil }
            let frames = max(1, Int((Double(sourceFrames) * ratio).rounded()))
            let start = frame(at: buffer.presentationTimeStamp)
            var peak: Float = 0
            var samples = [Float](repeating: 0, count: frames * 2)

            for frame in 0..<frames {
                let position = Double(frame) / ratio
                let before = min(sourceFrames - 1, Int(position))
                let after = min(sourceFrames - 1, before + 1)
                let fraction = Float(position - Double(before))
                let l = interpolate(left, stride: leftStride, offset: 0, before: before,
                                    after: after, fraction: fraction, float: float)
                let r = interpolate(right, stride: rightStride, offset: rightOffset, before: before,
                                    after: after, fraction: fraction, float: float)
                peak = max(peak, abs(l), abs(r))
                samples[2 * frame] = l * gain
                samples[2 * frame + 1] = r * gain
            }
            return (Item(start: start, samples: samples), peak)
        }
    }

    private static func interpolate(_ data: UnsafeRawPointer, stride: Int, offset: Int,
                                    before: Int, after: Int, fraction: Float, float: Bool) -> Float {
        let a = before * stride + offset
        let b = after * stride + offset
        let x: Float
        let y: Float
        if float {
            let values = data.assumingMemoryBound(to: Float.self)
            x = values[a]
            y = values[b]
        } else {
            let values = data.assumingMemoryBound(to: Int16.self)
            x = Float(values[a]) / 32_768
            y = Float(values[b]) / 32_768
        }
        let value = x + (y - x) * fraction
        return value.isFinite ? value : 0
    }

    private func makeSampleBuffer(_ samples: [Float], frames: Int, start: Int64) -> CMSampleBuffer? {
        let sampleSize = 2 * MemoryLayout<Float>.size
        let bytes = frames * sampleSize
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let status = samples.withUnsafeBytes { data in
            CMBlockBufferReplaceDataBytes(with: data.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }
        guard status == noErr else { return nil }
        var result: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Self.rate),
                                        presentationTimeStamp: CMTime(value: start, timescale: Self.rate),
                                        decodeTimeStamp: .invalid)
        var size = sampleSize
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }
}
