import Cocoa
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// MARK: - 录音引擎

@available(macOS 15.0, *)
final class RecordEngine: NSObject, ObservableObject {

    // 状态
    @Published var isRecording = false
    @Published private(set) var isBusy = false
    @Published var elapsed: TimeInterval = 0
    @Published var statusText = "待機中"
    @Published var finishedFile: URL?      // 录制完成后的文件（供裁剪 UI 使用）
    @Published var micLevel: Float = 0      // 0...1
    @Published var sysLevel: Float = 0      // 0...1
    @Published var lastError: String?

    // 可配置
    @Published var selectedMicID: String = ""
    @Published var includeSystemAudio = true
    @Published var selectedApplicationPID: pid_t = 0
    @Published var micGain: Float = 1.6 {
        didSet { streamQueue.async { [mixer, micGain] in mixer.micGain = micGain } }
    }
    @Published var sysGain: Float = 2.0 {
        didSet { streamQueue.async { [mixer, sysGain] in mixer.sysGain = sysGain } }
    }

    private var stream: SCStream?
    private let streamQueue = DispatchQueue(label: "stream.out", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var outputURL: URL?
    private var startedAt: CMTime?
    private var timer: Task<Void, Never>?

    // The capture queue owns the mixer and the first frame's timestamp.
    private let mixer = AudioMixer()

    // MARK: 可用麦克风列表

    struct MicOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static func availableMics() -> [MicOption] {
        let types: [AVCaptureDevice.DeviceType] =
            [.microphone, .external, AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeContinuityMicrophone")]
        let devs = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .audio, position: .unspecified).devices
        return devs.map { MicOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    // MARK: 开始录制

    @MainActor
    func start() {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        Task { await startAsync() }
    }

    @MainActor
    private func startAsync() async {
        defer { isBusy = false }
        lastError = nil
        micLevel = 0
        sysLevel = 0
        do {
            let (display, filter) = try await captureSource()
            let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            if !microphoneAllowed {
                lastError = "マイクを録音するには、システム設定の「マイク」で mirecorder を許可してください。"
            }
            if microphoneAllowed, !selectedMicID.isEmpty,
               !Self.availableMics().contains(where: { $0.id == selectedMicID }) {
                throw NSError(domain: "mirecorder", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "選択したマイクが接続されていません。再接続するか、別のマイクを選んでください。"
                ])
            }

            let cfg = SCStreamConfiguration()
            cfg.width = display.width * 2   // Retina
            cfg.height = display.height * 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.queueDepth = 8
            cfg.showsCursor = true
            cfg.capturesAudio = includeSystemAudio
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true

            cfg.captureMicrophone = microphoneAllowed
            if microphoneAllowed, !selectedMicID.isEmpty {
                cfg.microphoneCaptureDeviceID = selectedMicID
            }

            // 输出文件
            let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("mirecorder", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let url = dir.appendingPathComponent("mirecorder \(df.string(from: Date())).mp4")
            outputURL = url

            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

            // 视频
            let vSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: cfg.width,
                AVVideoHeightKey: cfg.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 20_000_000,       // 20 Mbps 高码率
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: 60
                ]
            ]
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
            vIn.expectsMediaDataInRealTime = true
            w.add(vIn)
            videoIn = vIn

            // 音频：单条合成轨（AAC 192k 立体声）
            let aSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 192_000
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            aIn.expectsMediaDataInRealTime = true
            w.add(aIn)
            audioIn = aIn

            guard w.startWriting() else {
                throw w.error ?? NSError(domain: "mirecorder", code: 2,
                                         userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter 启动失败"])
            }
            writer = w
            streamQueue.sync {
                mixer.reset()
                mixer.micGain = micGain
                mixer.sysGain = sysGain
            }

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: streamQueue)
            if includeSystemAudio {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: streamQueue)
            }
            if microphoneAllowed {
                try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: streamQueue)
            }
            try await s.startCapture()
            stream = s

            isRecording = true
            statusText = "录画中"
            startTimer()
        } catch {
            lastError = error.localizedDescription
            statusText = "失败: \(error.localizedDescription)"
            writer?.cancelWriting()
            cleanup()
        }
    }

    private func captureSource() async throws -> (SCDisplay, SCContentFilter) {
        let fullDisplay = selectedApplicationPID == 0
        let content = try await SCShareableContent.excludingDesktopWindows(!fullDisplay, onScreenWindowsOnly: fullDisplay)
        guard let firstDisplay = content.displays.first else {
            throw NSError(domain: "mirecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "録画できるディスプレイが見つかりません。"
            ])
        }
        guard selectedApplicationPID != 0 else {
            return (firstDisplay, SCContentFilter(display: firstDisplay, excludingWindows: []))
        }
        let windows = content.windows.filter { $0.owningApplication?.processID == selectedApplicationPID }
        guard let app = content.applications.first(where: { $0.processID == selectedApplicationPID }),
              !windows.isEmpty else {
            throw NSError(domain: "mirecorder", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "選択したアプリのウインドウを画面に表示してから録画してください。"
            ])
        }
        let display = content.displays.max {
            Self.visibleArea(of: windows, on: $0) < Self.visibleArea(of: windows, on: $1)
        } ?? firstDisplay
        return (display, SCContentFilter(display: display, including: [app], exceptingWindows: []))
    }

    private static func visibleArea(of windows: [SCWindow], on display: SCDisplay) -> CGFloat {
        windows.reduce(0) { area, window in
            let overlap = display.frame.intersection(window.frame)
            return overlap.isNull ? area : area + overlap.width * overlap.height
        }
    }

    // MARK: 停止

    @MainActor
    func stop() {
        guard isRecording, !isBusy else { return }
        isBusy = true
        Task { await stopAsync() }
    }

    @MainActor
    private func stopAsync() async {
        defer { isBusy = false }
        isRecording = false
        stopTimer()
        statusText = "正在保存…"

        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil

        guard let w = writer, let url = outputURL else {
            cleanup()
            return
        }
        let sessionStarted = streamQueue.sync {
            guard startedAt != nil else { return false }
            writeAvailableAudio(flushing: true)
            videoIn?.markAsFinished()
            audioIn?.markAsFinished()
            return true
        }
        if sessionStarted {
            await w.finishWriting()
        } else {
            w.cancelWriting()
        }
        cleanup()
        guard w.status == .completed else {
            let message = w.error?.localizedDescription ?? "録画フレームを保存できませんでした。"
            lastError = message
            statusText = "失敗: \(message)"
            return
        }
        statusText = "已保存: \(url.lastPathComponent)"
        finishedFile = url
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func cleanup() {
        streamQueue.sync {
            writer = nil
            videoIn = nil
            audioIn = nil
            startedAt = nil
        }
        stream = nil
        outputURL = nil
    }

    @MainActor
    private func startTimer() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateElapsed()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @MainActor
    private func updateElapsed() {
        guard let start = streamQueue.sync(execute: { startedAt }) else { return }
        elapsed = max(0, CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()) - start))
    }

    @MainActor
    private func stopTimer() {
        timer?.cancel()
        timer = nil
        elapsed = 0
    }
}

// MARK: - SCStreamOutput

@available(macOS 15.0, *)
extension RecordEngine: SCStreamOutput, SCStreamDelegate {

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }

        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let st = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: st) == .complete else { return }
            guard let writer, writer.status == .writing, let vIn = videoIn else { return }
            if startedAt == nil {
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                guard pts.isNumeric else { return }
                writer.startSession(atSourceTime: pts)
                startedAt = pts
                mixer.begin(at: pts)
            }
            if vIn.isReadyForMoreMediaData { vIn.append(sb) }

        case .audio:
            let level = mixer.pushSystem(sb)
            DispatchQueue.main.async { self.sysLevel = level }

        case .microphone:
            let level = mixer.pushMic(sb)
            DispatchQueue.main.async { self.micLevel = level }

        @unknown default:
            break
        }

        // 尝试写出合成音频
        writeAvailableAudio()
    }

    private func writeAvailableAudio(flushing: Bool = false) {
        guard let audioIn else { return }
        while audioIn.isReadyForMoreMediaData, let sample = mixer.next(flushing: flushing) {
            if !audioIn.append(sample) { break }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard stream === self.stream else { return }
            self.lastError = error.localizedDescription
            self.statusText = "流中断: \(error.localizedDescription)"
            self.stop()
        }
    }
}
