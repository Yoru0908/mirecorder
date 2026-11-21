import Foundation
import AVFoundation
import CoreImage
import AppKit
import Accelerate

/// 快速剪辑：两条路径
///  1. crop()      —— 只剪时间区间，AVAssetExportPresetPassthrough 无损，秒级完成（LosslessCut 同款）
///  2. cropFrame() —— 剪时间 + 裁画面，必须重编码（分辨率变了），速度快但非无损
enum Trimmer {

    struct Info {
        let duration: Double
        let naturalSize: CGSize
        let waveform: [Float]
        let conversation: Conversation?
    }

    struct Conversation {
        let start: Double
        let end: Double

        func selection(in duration: Double) -> ClosedRange<Double> {
            max(0, start - 0.35)...min(duration, end + 0.7)
        }
    }

    static func analyze(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw err("動画の長さを取得できません。") }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw err("動画トラックが見つかりません。")
        }
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let displayed = size.applying(transform)
        let naturalSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))

        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            return Info(duration: duration, naturalSize: naturalSize, waveform: [], conversation: nil)
        }
        let activity = try AudioActivity(asset: asset, track: audio, duration: duration)
        return Info(duration: duration, naturalSize: naturalSize, waveform: activity.waveform,
                    conversation: activity.conversation(in: duration))
    }

    // MARK: 无损剪（只切时间，不重编码）

    static func crop(_ url: URL, start: Double, end: Double,
                     progress: ((Float) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let total = CMTimeGetSeconds(try await asset.load(.duration))
        let s = max(0, min(start, total - 0.1))
        let e = min(total, max(s + 0.1, end))

        let out = sibling(url, suffix: "cut")
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetPassthrough) else {
            throw err("无法创建导出会话")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: s, preferredTimescale: 60000),
            duration: CMTime(seconds: e - s, preferredTimescale: 60000))

        let task = report(export, progress)
        await export.export()
        task.cancel()
        progress?(1)
        if let e = export.error { throw e }
        return out
    }

    // MARK: 剪时间 + 裁画面（重编码）

    /// rect 用**归一化坐标**（0...1，原点左上），方便 UI 用滑块给出。
    static func cropFrame(_ url: URL, start: Double, end: Double,
                          rect: CGRect, progress: ((Float) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let total = CMTimeGetSeconds(try await asset.load(.duration))
        let s = max(0, min(start, total - 0.1))
        let e = min(total, max(s + 0.1, end))

        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw err("没有视频轨")
        }
        let natural = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let nominalFR = try await vTrack.load(.nominalFrameRate)

        // 应用 preferredTransform 后的实际显示尺寸
        let displayed = natural.applying(transform)
        let dispSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))

        // 归一化 -> 像素（偶数对齐，H.264 要求）
        func even(_ v: CGFloat) -> CGFloat { CGFloat((Int(v) / 2) * 2) }
        var px = CGRect(x: rect.origin.x * dispSize.width,
                        y: rect.origin.y * dispSize.height,
                        width: rect.width * dispSize.width,
                        height: rect.height * dispSize.height)
        px = CGRect(x: even(px.origin.x), y: even(px.origin.y),
                    width: even(max(16, px.width)), height: even(max(16, px.height)))
        // 夹在画面内
        px.origin.x = max(0, min(px.origin.x, dispSize.width - px.width))
        px.origin.y = max(0, min(px.origin.y, dispSize.height - px.height))

        let out = sibling(url, suffix: "cropped")

        // 用 AVMutableComposition + AVMutableVideoComposition 做画面裁剪
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 60000),
                                duration: CMTime(seconds: e - s, preferredTimescale: 60000))

        guard let cv = comp.addMutableTrack(withMediaType: .video,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw err("无法添加视频轨")
        }
        try cv.insertTimeRange(range, of: vTrack, at: .zero)

        if let aTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let ca = comp.addMutableTrack(withMediaType: .audio,
                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? ca.insertTimeRange(range, of: aTrack, at: .zero)
        }

        // 裁剪指令
        let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: cv)
        let t = CGAffineTransform(translationX: -px.origin.x, y: -px.origin.y)
        layerInstr.setTransform(transform.concatenating(t), at: .zero)

        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instr.layerInstructions = [layerInstr]

        let vc = AVMutableVideoComposition()
        vc.renderSize = CGSize(width: px.width, height: px.height)
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(nominalFR.rounded()))))
        vc.instructions = [instr]

        // 高质量重编码
        guard let export = AVAssetExportSession(asset: comp,
                                                presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw err("无法创建导出会话")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = vc
        export.shouldOptimizeForNetworkUse = true

        let task = report(export, progress)
        await export.export()
        task.cancel()
        progress?(1)
        if let e = export.error { throw e }
        return out
    }

    @MainActor
    final class PreviewFrames {
        private let generator: AVAssetImageGenerator

        init(_ url: URL) {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 2240, height: 1560)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        }

        func image(at seconds: Double) async throws -> NSImage {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let result = try await generator.image(at: time)
            return NSImage(cgImage: result.image, size: .zero)
        }

        func cancel() { generator.cancelAllCGImageGeneration() }
    }

    // MARK: 工具

    private static func sibling(_ url: URL, suffix: String) -> URL {
        let df = DateFormatter(); df.dateFormat = "HH-mm-ss"
        let base = url.deletingPathExtension().lastPathComponent
        let out = url.deletingLastPathComponent()
            .appendingPathComponent("\(base)_\(suffix) \(df.string(from: Date())).mp4")
        try? FileManager.default.removeItem(at: out)
        return out
    }

    private static func report(_ e: AVAssetExportSession,
                               _ progress: ((Float) -> Void)?) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                progress?(e.progress)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "Trimmer", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}

private struct AudioActivity {
    private static let bucketsPerSecond = 10
    private static let rate: CMTimeScale = 48_000
    private static let framesPerBucket = Int(rate) / bucketsPerSecond
    private static let channels = 2

    private struct Bucket {
        var energy: Float = 0
        var peak: Float = 0

        var dBFS: Float {
            10 * log10(max(1e-12, energy / Float(AudioActivity.framesPerBucket * AudioActivity.channels)))
        }
    }

    private var buckets: [Bucket]
    private(set) var waveform: [Float]
    private let frameCount: Int

    init(asset: AVAsset, track: AVAssetTrack, duration: Double) throws {
        frameCount = max(1, Int((duration * Double(Self.rate)).rounded(.up)))
        buckets = Array(repeating: Bucket(), count: 1 + (frameCount - 1) / Self.framesPerBucket)
        waveform = Array(repeating: 0, count: min(1_200, buckets.count * 4))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: Self.channels
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NSError(domain: "mirecorder.Audio", code: 1) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "mirecorder.Audio", code: 2) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try append(buffer)
        }
        if let error = reader.error { throw error }
    }

    private mutating func append(_ buffer: CMSampleBuffer) throws {
        guard buffer.presentationTimeStamp.isNumeric else { return }
        let start = buffer.presentationTimeStamp.convertScale(Self.rate, method: .roundHalfAwayFromZero).value
        guard start >= -Int64(buffer.numSamples), start < Int64(frameCount) else { return }
        try buffer.withAudioBufferList { list, _ in
            guard let pcm = list.first, pcm.mNumberChannels == Self.channels, let data = pcm.mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            let frames = min(buffer.numSamples, Int(pcm.mDataByteSize) / (MemoryLayout<Float>.size * Self.channels))
            var frame = max(0, Int(start))
            let end = min(frameCount, Int(start) + frames)
            while frame < end {
                let bucket = frame / Self.framesPerBucket
                let mark = min(waveform.count - 1, frame * waveform.count / frameCount)
                let bucketEnd = (bucket + 1) * Self.framesPerBucket
                let markEnd = ((mark + 1) * frameCount + waveform.count - 1) / waveform.count
                let next = min(end, bucketEnd, markEnd)
                let count = vDSP_Length((next - frame) * Self.channels)
                let input = samples.advanced(by: (frame - Int(start)) * Self.channels)
                var energy: Float = 0
                var peak: Float = 0
                vDSP_svesq(input, 1, &energy, count)
                vDSP_maxmgv(input, 1, &peak, count)
                buckets[bucket].energy += energy.isFinite ? energy : 0
                buckets[bucket].peak = max(buckets[bucket].peak, peak)
                waveform[mark] = min(1, max(waveform[mark], peak))
                frame = next
            }
        }
    }

    func conversation(in duration: Double) -> Trimmer.Conversation? {
        let levels = buckets.map(\.dBFS)
        let ordered = levels.sorted()
        let floor = ordered[(ordered.count - 1) / 4]
        let gate = min(Float(-26), max(Float(-44), floor + 15))
        let activity = levels.indices.map { levels[$0] >= gate && buckets[$0].peak >= 0.015 }
        let window = min(50, activity.count)
        let required = max(6, (window + 1) / 2)
        guard window >= required else { return nil }

        // Keep only regions with sustained activity, merging short pauses between speakers.
        var prefix = [0]
        for active in activity { prefix.append(prefix[prefix.count - 1] + Int(active ? 1 : 0)) }
        var runs: [Range<Int>] = []
        var lastWindow: Int?
        for start in 0...(activity.count - window) where prefix[start + window] - prefix[start] >= required {
            let range = start..<(start + window)
            if let previous = lastWindow, start - previous <= 31, let run = runs.popLast() {
                runs.append(run.lowerBound..<range.upperBound)
            } else {
                runs.append(range)
            }
            lastWindow = start
        }
        var candidates: [Range<Int>] = []
        for run in runs {
            guard let first = run.first(where: { activity[$0] }),
                  let last = run.last(where: { activity[$0] }) else { continue }
            if let previous = candidates.last, first - previous.upperBound <= 3 * Self.bucketsPerSecond {
                candidates[candidates.count - 1] = previous.lowerBound..<(last + 1)
            } else {
                candidates.append(first..<(last + 1))
            }
        }
        func score(_ run: Range<Int>) -> Int { prefix[run.upperBound] - prefix[run.lowerBound] }
        guard let best = candidates.max(by: { score($0) < score($1) }) else { return nil }
        let scale = Double(Self.bucketsPerSecond)
        let start = Double(best.lowerBound) / scale
        let end = min(duration, Double(best.upperBound) / scale)
        return start < end ? Trimmer.Conversation(start: start, end: end) : nil
    }
}
