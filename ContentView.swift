import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

@available(macOS 15.0, *)
struct ContentView: View {
    @StateObject private var engine = RecordEngine()

    private struct FileLoad {
        let url: URL
        // 同じ動画を開き直した場合も、別の読み込みとして扱う。
        let id = UUID()
    }

    @State private var fileLoad: FileLoad?
    @State private var openingFile = false
    @State private var showsEditor = false
    @State private var editorSize = CGSize(width: 1000, height: 792)
    @State private var showsLargePreview = false
    @State private var largePreviewSize = CGSize(width: 1000, height: 680)
    @State private var trimInfo: Trimmer.Info?
    @State private var trimRange: ClosedRange<Double> = 0...0
    @State private var analyzing = false
    @State private var trimming = false
    @State private var trimProgress: Float = 0
    @State private var trimMessage = ""

    // 画面裁剪：左上角原点，坐标归一化到 0...1
    @State private var cropRect: CGRect?
    @GestureState private var cropDraft: CGRect? = nil
    @State private var previewFrame: NSImage?
    @State private var previewSeconds: Double = 0
    @State private var previewFrames: Trimmer.PreviewFrames?
    @State private var previewTask: Task<Void, Never>?
    @State private var loadingFrame = false
    @State private var previewFailed = false
    @State private var cropMode: CropMode = .none

    private var displayedCrop: CGRect? { cropDraft ?? (cropMode == .none ? nil : cropRect) }

    enum CropMode: String, CaseIterable {
        case none = "なし"
        case center9x16 = "9:16"
        case center1x1 = "1:1"
        case center16x9 = "16:9"
        case freeform = "自由"

        var aspectRatio: CGFloat? {
            switch self {
            case .center9x16: 9.0 / 16.0
            case .center1x1: 1
            case .center16x9: 16.0 / 9.0
            case .none, .freeform: nil
            }
        }
    }

    @State private var applications: [NSRunningApplication] = []
    @State private var mics: [RecordEngine.MicOption] = []
    private var canChangeSource: Bool { !engine.isRecording && !engine.isBusy }

    private func refreshMicrophones() {
        let available = RecordEngine.availableMics()
        if available != mics { mics = available }
    }

    private func refreshApplications() {
        applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted {
            ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
        }
    }

    private let bg = LinearGradient(
        colors: [Color(red: 0.09, green: 0.10, blue: 0.12),
                 Color(red: 0.06, green: 0.06, blue: 0.08)],
        startPoint: .top, endPoint: .bottom)
    private let card = Color.white.opacity(0.055)
    private let stroke = Color.white.opacity(0.09)

    var body: some View {
        let load = fileLoad
        ZStack {
            bg.ignoresSafeArea()
            VStack(spacing: 0) {
                workspaceBar
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                ScrollView {
                    VStack(spacing: 18) {
                        if showsEditor, let load {
                            trimCard(file: load.url).id(load.id)
                        } else {
                            heroCard
                            settingsCard
                            if let error = engine.lastError {
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
        .frame(width: showsEditor ? editorSize.width : 720, height: showsEditor ? editorSize.height : 560)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsLargePreview) {
            if let info = trimInfo { largePreview(info: info) }
        }
        .onAppear {
            refreshApplications()
            refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification).receive(on: RunLoop.main)) { _ in
            refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification).receive(on: RunLoop.main)) { _ in
            refreshMicrophones()
        }
        .onChange(of: canChangeSource) { _, canChange in
            if canChange { refreshMicrophones() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshApplications()
        }
        .onChange(of: engine.finishedFile) { _, file in
            if let file { loadFile(file) }
        }
        .task(id: load?.id) {
            if let load { await analyze(load) }
        }
    }

    private var workspaceBar: some View {
        HStack(spacing: 12) {
            Picker("作業モード", selection: $showsEditor) {
                Label("録画", systemImage: "record.circle").tag(false)
                Label("編集", systemImage: "scissors").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 178)
            .disabled(!canChangeSource || fileLoad == nil || trimming)
            Spacer()
            openVideoButton
        }
    }

    private var openVideoButton: some View {
        Button(action: openVideo) {
            Label("動画を開く…", systemImage: "folder")
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(openingFile || trimming || !canChangeSource)
    }

    private func openVideo() {
        guard !openingFile, !trimming, canChangeSource else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "開く"
        panel.message = "編集する動画を選択してください。"
        openingFile = true
        panel.begin { response in
            openingFile = false
            if response == .OK, let url = panel.url { loadFile(url) }
        }
    }

    private func loadFile(_ url: URL) {
        trimInfo = nil
        trimRange = 0...0
        trimMessage = ""
        cropMode = .none
        cropRect = nil
        previewTask?.cancel()
        previewFrames?.cancel()
        previewTask = nil
        previewFrames = nil
        previewFrame = nil
        previewSeconds = 0
        previewFailed = false
        analyzing = true
        loadingFrame = true
        showsLargePreview = false
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.size
            editorSize = CGSize(width: max(720, min(1040, visible.width - 56)),
                                height: max(580, min(792, visible.height - 72)))
        }
        fileLoad = FileLoad(url: url)
        showsEditor = true
    }

    // MARK: - Hero（录制主控）

    private var heroCard: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                // 录制指示环
                ZStack {
                    Circle()
                        .stroke(engine.isRecording ? Color.red.opacity(0.22) : Color.white.opacity(0.07),
                                lineWidth: 3)
                        .frame(width: 76, height: 76)
                    if engine.isRecording {
                        Circle().fill(Color.red.opacity(0.2))
                            .frame(width: 76, height: 76)
                            .scaleEffect(engine.elapsed.truncatingRemainder(dividingBy: 2) < 1 ? 1.12 : 0.96)
                            .animation(.easeInOut(duration: 1), value: engine.elapsed)
                    }
                    Circle()
                        .fill(engine.isRecording ? Color.red : Color.white.opacity(0.16))
                        .frame(width: 30, height: 30)
                    if !engine.isRecording {
                        Image(systemName: "record.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.isRecording ? "録画中" : "待機中")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(engine.isRecording ? Color.red : .secondary)
                        .tracking(0.5)
                    Text(timeString(engine.elapsed))
                        .font(.system(size: 40, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(engine.isRecording ? .white : .white.opacity(0.35))
                }

                Spacer()

                HStack(spacing: 14) {
                    meter(title: "MIC", value: engine.micLevel, tint: .green,
                          sub: micShortName)
                    if engine.includeSystemAudio {
                        meter(title: "SYS", value: engine.sysLevel, tint: .cyan, sub: "システム音声")
                    }
                }
            }

            Button {
                engine.isRecording ? engine.stop() : engine.start()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: engine.isRecording ? "stop.fill" : "record.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(engine.isRecording ? "停止" : "録画開始")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(engine.isRecording
                              ? LinearGradient(colors: [Color(red: 0.85, green: 0.22, blue: 0.22),
                                                        Color(red: 0.68, green: 0.13, blue: 0.18)],
                                               startPoint: .top, endPoint: .bottom)
                              : LinearGradient(colors: [Color(red: 0.30, green: 0.52, blue: 1.0),
                                                        Color(red: 0.20, green: 0.38, blue: 0.9)],
                                               startPoint: .top, endPoint: .bottom))
                        .shadow(color: engine.isRecording
                                ? Color.red.opacity(0.35) : Color.blue.opacity(0.35),
                                radius: 12, y: 5)
                }
            }
            .buttonStyle(.plain)
            .disabled(engine.isBusy)
        }
        .padding(20)
        .background(cardBackground)
    }

    private func meter(title: String, value: Float, tint: Color, sub: String) -> some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            // 竖向电平
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 16, height: 56)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LinearGradient(
                        colors: value > 0.88 ? [.yellow, .red] : [tint.opacity(0.55), tint],
                        startPoint: .bottom, endPoint: .top))
                    .frame(width: 16, height: max(3, CGFloat(min(1, value)) * 56))
                    .animation(.linear(duration: 0.06), value: value)
            }
            .frame(height: 56)
            Text(sub)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 58)
        }
    }

    private var micShortName: String {
        if engine.selectedMicID.isEmpty { return "既定" }
        if let m = mics.first(where: { $0.id == engine.selectedMicID }) {
            return String(m.name.prefix(12))
        }
        return "—"
    }

    // MARK: - 设置

    private var settingsCard: some View {
        VStack(spacing: 0) {
            sectionTitle("入力ソース", icon: "waveform")

            row {
                Text("録画対象").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Picker("録画対象", selection: $engine.selectedApplicationPID) {
                    Text("画面全体").tag(pid_t(0))
                    ForEach(applications, id: \.processIdentifier) { application in
                        Text(application.localizedName ?? "アプリ").tag(application.processIdentifier)
                    }
                    if engine.selectedApplicationPID != 0,
                       !applications.contains(where: { $0.processIdentifier == engine.selectedApplicationPID }) {
                        Text("終了したアプリ").tag(engine.selectedApplicationPID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!canChangeSource)
            }

            divider

            row {
                Text("マイク").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Picker("マイク", selection: $engine.selectedMicID) {
                    Text("システム既定").tag("")
                    ForEach(mics) { mic in Text(mic.name).tag(mic.id) }
                    if !engine.selectedMicID.isEmpty, !mics.contains(where: { $0.id == engine.selectedMicID }) {
                        Text("選択中のマイク（未接続）").tag(engine.selectedMicID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!canChangeSource)
            }

            divider

            gainRow(title: "MIC ゲイン", value: $engine.micGain, tint: .green)
            divider
            gainRow(title: "SYS ゲイン", value: $engine.sysGain, tint: .cyan)

            divider

            row {
                Toggle(isOn: $engine.includeSystemAudio) {
                    HStack(spacing: 6) {
                        Text("システム音声（相手の声）")
                            .font(.system(size: 12))
                        Text(engine.selectedApplicationPID == 0 ? "画面外の音も拾う" : "選んだアプリの音声")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!canChangeSource)
            }
        }
        .padding(18)
        .background(cardBackground)
    }

    private func gainRow(title: String, value: Binding<Float>, tint: Color) -> some View {
        row {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Float($0) }
            ), in: 0.2...6.0)
            .tint(tint)
            Text(String(format: "%.1f×", value.wrappedValue))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 42, alignment: .trailing)
            Text(dbString(value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private func dbString(_ g: Float) -> String {
        g <= 0.001 ? "-∞" : String(format: "%+.1f dB", 20 * log10(g))
    }

    // MARK: - 裁剪

    private func trimCard(file: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                sectionTitle("動画の編集", icon: "scissors")
                Spacer()
                if analyzing {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("解析中").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            Text(file.lastPathComponent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 5)

            if let info = trimInfo {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            sectionTitle("プレビュー", icon: "viewfinder")
                            Spacer()
                            Button(action: openLargePreview) {
                                Label("拡大", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .help("プレビューを拡大")
                            .accessibilityLabel("プレビューを拡大")
                            .disabled(previewFrame == nil || trimming)
                        }
                        let previewHeight = max(185, editorSize.height - 473)
                        previewBox(info: info, bounds: CGSize(width: editorSize.width - 88, height: previewHeight))
                            .frame(maxWidth: .infinity, minHeight: previewHeight)
                            .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
                        previewControls(info)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("タイムライン", icon: "waveform")
                        TrimTimeline(info: info, selection: $trimRange, previewSeconds: previewSeconds, seek: queuePreview)
                            .disabled(trimming)
                    }

                    Divider()
                    cropControls(info: info)

                    // 执行
                    HStack(spacing: 12) {
                        if trimming {
                            ProgressView(value: Double(trimProgress))
                                .frame(width: 150)
                            Text("\(Int(trimProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if !trimMessage.isEmpty {
                            Text(trimMessage)
                                .font(.caption)
                                .foregroundStyle(trimMessage.hasPrefix("✓") ? Color.green : Color.orange)
                                .lineLimit(1)
                        } else {
                            Label(cropMode == .none ? "時間カットのみ・再エンコードなし" : "画面の切り抜き・再エンコードあり",
                                  systemImage: cropMode == .none ? "scissors" : "crop")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await doTrim() }
                        } label: {
                            Label(cropMode == .none ? "無劣化カットを書き出す" : "切り抜いて書き出す",
                                  systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(trimming || (cropMode != .none && cropRect == nil))
                    }
                }
                .padding(18)
            } else if !trimMessage.isEmpty {
                Text(trimMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            } else {
                Spacer().frame(height: 40)
            }
        }
        .background(cardBackground)
    }

    private func openLargePreview() {
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.size
            largePreviewSize = CGSize(width: min(1120, visible.width - 56), height: min(780, visible.height - 72))
        }
        showsLargePreview = true
    }

    private func largePreview(info: Trimmer.Info) -> some View {
        let bounds = CGSize(width: largePreviewSize.width - 44, height: largePreviewSize.height - 166)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("切り抜きプレビュー", systemImage: "crop").font(.headline)
                Spacer()
                Button("完了") { showsLargePreview = false }
                    .keyboardShortcut(.defaultAction)
            }
            Spacer(minLength: 0)
            previewBox(info: info, bounds: bounds).frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            previewControls(info)
            cropControls(info: info)
        }
        .padding(22)
        .frame(width: largePreviewSize.width, height: largePreviewSize.height)
    }

    private func previewControls(_ info: Trimmer.Info) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            PreviewTimeBar(seconds: previewSeconds, duration: info.duration, seek: queuePreview)
            if previewFailed {
                Text("この位置のフレームを表示できませんでした。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .disabled(trimming)
    }

    private func cropControls(info: Trimmer.Info) -> some View {
        let size = info.naturalSize
        return HStack(spacing: 12) {
            Picker("画面の切り抜き", selection: Binding(
                get: { cropMode },
                set: { applyCropPreset($0, size: size) }
            )) {
                ForEach(CropMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)
            .disabled(previewFrame == nil || trimming)
            Spacer()
            if let rect = displayedCrop {
                let width = max(16, Int(size.width * rect.width) / 2 * 2)
                let height = max(16, Int(size.height * rect.height) / 2 * 2)
                if cropMode == .freeform {
                    Text("枠内で移動 · 枠外または ⌥ で描き直し")
                }
                Text("出力 \(width) × \(height) px").monospacedDigit()
            } else {
                Text("プレビューをドラッグして切り抜き")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func previewBox(info: Trimmer.Info, bounds: CGSize) -> some View {
        let sourceSize = info.naturalSize
        let size = fittedPreviewSize(sourceSize, in: bounds)
        let border = RoundedRectangle(cornerRadius: 8, style: .continuous)

        return ZStack {
            if let img = previewFrame {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .overlay { cropOverlay(size: size) }
                    .contentShape(Rectangle())
                    .gesture(cropDrag(in: size, sourceSize: sourceSize))
                    .accessibilityLabel("切り抜きプレビュー")
                    .accessibilityHint("ドラッグで切り抜き。自由枠の内側をドラッグすると移動します")
            } else {
                Color.black.opacity(0.65)
                if loadingFrame { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(border)
        .overlay { border.strokeBorder(stroke, lineWidth: 1).allowsHitTesting(false) }
        .frame(width: bounds.width)
    }

    private func fittedPreviewSize(_ source: CGSize, in bounds: CGSize) -> CGSize {
        guard source.width >= 1, source.height >= 1,
              source.width.isFinite, source.height.isFinite else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    @ViewBuilder
    private func cropOverlay(size: CGSize) -> some View {
        if let selection = displayedCrop {
            let rect = CGRect(x: selection.minX * size.width, y: selection.minY * size.height,
                              width: selection.width * size.width, height: selection.height * size.height)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                Path { $0.addRect(rect) }
                    .stroke(.white, lineWidth: 1.5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func cropDrag(in size: CGSize, sourceSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($cropDraft) { drag, draft, _ in
                draft = dragCropRect(drag, in: size, sourceSize: sourceSize)
            }
            .onEnded { drag in
                guard let rect = dragCropRect(drag, in: size, sourceSize: sourceSize) else { return }
                cropRect = rect
                cropMode = .freeform
            }
    }

    private func dragCropRect(_ drag: DragGesture.Value, in size: CGSize, sourceSize: CGSize) -> CGRect? {
        func normalize(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(1, max(0, point.x / size.width)),
                    y: min(1, max(0, point.y / size.height)))
        }
        let start = normalize(drag.startLocation)
        let end = normalize(drag.location)
        if cropMode == .freeform, let rect = cropRect, rect.contains(start),
           !NSEvent.modifierFlags.contains(.option) {
            let x = rect.minX + drag.translation.width / size.width
            let y = rect.minY + drag.translation.height / size.height
            return CGRect(x: max(0, min(1 - rect.width, x)), y: max(0, min(1 - rect.height, y)),
                          width: rect.width, height: rect.height)
        }
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        // 导出要求每条边至少 16 像素。
        guard width * sourceSize.width >= 16, height * sourceSize.height >= 16 else { return nil }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: width, height: height)
    }

    private func applyCropPreset(_ mode: CropMode, size: CGSize) {
        if let target = mode.aspectRatio {
            guard size.width >= 1, size.height >= 1,
                  size.width.isFinite, size.height.isFinite else { return }
            let aspect = size.width / size.height
            let width = min(1, target / aspect)
            let height = min(1, aspect / target)
            cropRect = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        } else if mode == .none || cropMode == .none {
            cropRect = nil
        }
        cropMode = mode
    }

    // MARK: - 动作

    private func analyze(_ load: FileLoad) async {
        guard fileLoad?.id == load.id, !Task.isCancelled else { return }
        defer {
            if fileLoad?.id == load.id, !Task.isCancelled { analyzing = false }
        }
        do {
            let info = try await Trimmer.analyze(load.url)
            guard fileLoad?.id == load.id, !Task.isCancelled else { return }
            trimRange = info.suggestedTrimRange
            trimInfo = info
            previewFrames = Trimmer.PreviewFrames(load.url)
            queuePreview(info.conversationCandidate?.start ?? 0)
        } catch {
            if fileLoad?.id == load.id, !Task.isCancelled {
                loadingFrame = false
                trimMessage = "動画を解析できませんでした。\(error.localizedDescription)"
            }
        }
    }

    private func queuePreview(_ seconds: Double) {
        guard let load = fileLoad, let info = trimInfo, let frames = previewFrames, seconds.isFinite else { return }
        let duration = info.duration
        previewSeconds = min(duration, max(0, seconds))
        guard previewTask == nil else { return }
        loadingFrame = true
        previewTask = Task {
            await updatePreview(loadID: load.id, frames: frames, duration: duration)
        }
    }

    private func updatePreview(loadID: UUID, frames: Trimmer.PreviewFrames, duration: Double) async {
        while fileLoad?.id == loadID, !Task.isCancelled {
            let requested = previewSeconds
            let frameTime = min(requested, max(0, duration - 1.0 / 120.0))
            let image = try? await frames.image(at: frameTime)
            guard fileLoad?.id == loadID, !Task.isCancelled else { return }
            let isCurrent = abs(previewSeconds - requested) < 0.001
            if let image { previewFrame = image }
            if isCurrent {
                previewFailed = image == nil
                loadingFrame = false
                previewTask = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(45))
        }
    }

    private func doTrim() async {
        guard !trimming, let load = fileLoad else { return }
        let range = trimRange
        let rect = cropMode == .none ? nil : cropRect
        guard range.lowerBound < range.upperBound, cropMode == .none || rect != nil else { return }

        trimming = true
        trimProgress = 0
        trimMessage = ""
        defer { trimming = false }
        let progress: (Float) -> Void = { value in
            DispatchQueue.main.async {
                if fileLoad?.id == load.id, trimming { trimProgress = value }
            }
        }
        do {
            let out: URL
            if let rect {
                out = try await Trimmer.cropFrame(load.url, start: range.lowerBound, end: range.upperBound,
                                                  rect: rect, progress: progress)
            } else {
                out = try await Trimmer.crop(load.url, start: range.lowerBound, end: range.upperBound,
                                             progress: progress)
            }
            guard fileLoad?.id == load.id else { return }
            trimMessage = "✓ \(out.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } catch {
            if fileLoad?.id == load.id {
                trimMessage = "動画を書き出せませんでした。\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 小部件

    private func sectionTitle(_ s: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(s)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
        }
    }

    private func badge(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private func row<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }
            .frame(height: 34)
    }

    private var divider: some View {
        Rectangle().fill(stroke).frame(height: 1).padding(.vertical, 2)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(card)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

private extension Trimmer.Info {
    var minimumTrimLength: Double { min(0.1, duration) }

    var conversationCandidate: Trimmer.Conversation? {
        guard let conversation, conversation.start >= 0,
              conversation.start <= conversation.end, conversation.end <= duration else { return nil }
        return conversation
    }

    var suggestedTrimRange: ClosedRange<Double> {
        guard let conversationCandidate else { return 0...duration }
        let suggestion = conversationCandidate.selection(in: duration)
        let start = min(max(0, suggestion.lowerBound), duration - minimumTrimLength)
        let end = min(duration, max(suggestion.upperBound, start + minimumTrimLength))
        return start...end
    }
}

private struct PreviewTimeBar: View {
    let seconds: Double
    let duration: Double
    let seek: (Double) -> Void
    @FocusState private var editing: Bool
    @State private var entry = ""
    @State private var invalid = false

    var body: some View {
        HStack(spacing: 10) {
            step("gobackward", label: "1秒戻る", by: -1)
            step("goforward", label: "1秒進む", by: 1)
            Slider(value: Binding(get: { seconds }, set: seek), in: 0...duration) {
                Text("プレビュー位置")
            }
            .labelsHidden()
            TextField("プレビュー時刻", text: $entry)
                .labelsHidden()
                .font(.system(.callout, design: .monospaced))
                .frame(width: 78)
                .focused($editing)
                .onSubmit(commit)
                .help("3:21 または秒数を入力")
            Button("移動", action: commit)
            Text("/ \(editorTimecode(duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if invalid {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .help("3:21 の形式で入力してください")
                    .accessibilityLabel("時刻の形式が正しくありません")
            }
        }
        .font(.callout)
        .controlSize(.small)
        .onAppear { entry = editorTimecode(seconds) }
        .onChange(of: seconds) { _, value in
            if !editing { entry = editorTimecode(value) }
        }
    }

    private func step(_ icon: String, label: String, by offset: Double) -> some View {
        Button { seek(seconds + offset) } label: {
            Image(systemName: icon).frame(width: 18)
        }
        .help(label)
        .accessibilityLabel(label)
    }

    private func commit() {
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let values = parts.compactMap { Double($0) }
        guard (1...3).contains(parts.count), parts.count == values.count,
              values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.dropFirst().allSatisfy({ $0 < 60 }) else {
            invalid = true
            return
        }
        let value = values.reduce(0) { $0 * 60 + $1 }
        guard value.isFinite else { invalid = true; return }
        invalid = false
        let target = min(duration, value)
        seek(target)
        entry = editorTimecode(target)
        editing = false
    }
}

private func editorTimecode(_ seconds: Double) -> String {
    let rounded = (seconds * 100).rounded() / 100
    return String(format: "%.0f:%05.2f", floor(rounded / 60), rounded.truncatingRemainder(dividingBy: 60))
}

@available(macOS 15.0, *)
private struct TrimTimeline: View {
    let info: Trimmer.Info
    @Binding var selection: ClosedRange<Double>
    let previewSeconds: Double
    let seek: (Double) -> Void
    @GestureState private var draft: ClosedRange<Double>?
    @Environment(\.isEnabled) private var isEnabled

    private enum Edge: CaseIterable {
        case start, end

        var label: String { self == .start ? "IN" : "OUT" }
        var accessibilityLabel: String { self == .start ? "開始位置（秒）" : "終了位置（秒）" }
        var candidateLabel: String { self == .start ? "会話開始の候補" : "会話終了の候補" }
        var candidateIcon: String { self == .start ? "arrowtriangle.down.fill" : "diamond.fill" }
        var candidateColor: Color { self == .start ? .yellow : .cyan }

        func time(in range: ClosedRange<Double>) -> Double {
            self == .start ? range.lowerBound : range.upperBound
        }
    }

    private let handleWidth: CGFloat = 24
    private let markerHeight: CGFloat = 24
    private let waveformHeight: CGFloat = 54
    private let coordinateSpace = "trimTimeline"
    private var shownRange: ClosedRange<Double> { draft ?? selection }

    var body: some View {
        VStack(spacing: 8) {
            track
            HStack {
                if let candidate = info.conversationCandidate {
                    Button(action: selectCandidate) {
                        HStack(spacing: 9) {
                            ForEach(Edge.allCases, id: \.self) { edge in
                                let time = edge == .start ? candidate.start : candidate.end
                                Label("\(edge.candidateLabel) \(timecode(time))", systemImage: edge.candidateIcon)
                            }
                        }
                    }
                    .controlSize(.small)
                    .help("会話の候補区間を選択")
                } else {
                    Text("会話の候補区間なし").foregroundStyle(.secondary)
                }
                Spacer()
                Text("選択 \(timecode(shownRange.upperBound - shownRange.lowerBound)) / 全体 \(timecode(info.duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))

            HStack(spacing: 12) {
                timeField(.start)
                timeField(.end)
                Spacer()
            }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 2 * handleWidth)
            let axisY = markerHeight + waveformHeight / 2
            let start = position(shownRange.lowerBound, width: width)
            let end = position(shownRange.upperBound, width: width)
            let candidate = info.conversationCandidate

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let bounds = CGRect(origin: .zero, size: size)
                    context.fill(Path(roundedRect: bounds, cornerRadius: 6), with: .color(.white.opacity(0.06)))
                    let highlight = CGRect(x: start, y: 0, width: end - start, height: size.height)
                    context.fill(Path(highlight), with: .color(.accentColor.opacity(0.20)))
                    let waveform = waveformPath(width: width, height: size.height)
                    context.stroke(waveform, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    if let candidate {
                        for edge in Edge.allCases {
                            let marker = position(edge == .start ? candidate.start : candidate.end, width: width)
                            context.stroke(verticalLine(x: marker, height: size.height), with: .color(edge.candidateColor),
                                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                    }
                    let playhead = verticalLine(x: position(previewSeconds, width: width), height: size.height)
                    context.stroke(playhead, with: .color(.black.opacity(0.75)), lineWidth: 4)
                    context.stroke(playhead, with: .color(.white), lineWidth: 1.5)
                }
                .frame(width: geometry.size.width, height: waveformHeight)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                    .onChanged { seekWaveform($0.location.x, width: width) }
                    .onEnded { seekWaveform($0.location.x, width: width) }, isEnabled: isEnabled)
                .help("波形をクリック・ドラッグしてプレビュー")
                .position(x: geometry.size.width / 2, y: axisY)
                .accessibilityHidden(true)

                if let candidate {
                    ForEach(Edge.allCases, id: \.self) { edge in
                        let time = edge == .start ? candidate.start : candidate.end
                        candidateMarker(edge, time: time)
                            .position(x: position(time, width: width), y: markerHeight / 2)
                    }
                }

                handle(.start, width: width)
                    .position(x: start - handleWidth / 2, y: axisY)
                handle(.end, width: width)
                    .position(x: end + handleWidth / 2, y: axisY)
            }
        }
        .coordinateSpace(.named(coordinateSpace))
        .frame(height: markerHeight + waveformHeight)
    }

    private func candidateMarker(_ edge: Edge, time: Double) -> some View {
        Button {
            selection = info.suggestedTrimRange
            seek(time)
        } label: {
            Image(systemName: edge.candidateIcon)
                .font(.system(size: 11))
                .foregroundStyle(edge.candidateColor)
                .frame(width: 32, height: markerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(edge.candidateLabel) \(timecode(time)) · 会話の候補区間を選択")
        .accessibilityLabel("\(edge.candidateLabel) \(timecode(time))")
    }

    private func handle(_ edge: Edge, width: CGFloat) -> some View {
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .updating($draft) { value, draft, _ in
                draft = draggedRange(edge, distance: value.translation.width, width: width)
            }
            .onChanged { value in
                let range = draggedRange(edge, distance: value.translation.width, width: width)
                seek(edge.time(in: range))
            }
            .onEnded { value in
                selection = draggedRange(edge, distance: value.translation.width, width: width)
                seek(edge.time(in: selection))
            }

        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .overlay {
                Capsule().fill(.white).frame(width: 2, height: 12)
            }
            .frame(width: 10)
            .frame(width: handleWidth, height: waveformHeight, alignment: edge == .start ? .trailing : .leading)
            .contentShape(Rectangle())
            .gesture(drag, isEnabled: isEnabled)
            .help(edge.accessibilityLabel)
            .accessibilityElement()
            .accessibilityLabel(edge.accessibilityLabel)
            .accessibilityValue(timecode(edge.time(in: shownRange)))
            .accessibilityAdjustableAction { direction in
                let current = edge.time(in: selection)
                switch direction {
                case .increment: selection = range(moving: edge, to: current + 0.1)
                case .decrement: selection = range(moving: edge, to: current - 0.1)
                @unknown default: return
                }
                seek(edge.time(in: selection))
            }
    }

    private func verticalLine(x: CGFloat, height: CGFloat) -> Path {
        Path {
            $0.move(to: CGPoint(x: x, y: 0))
            $0.addLine(to: CGPoint(x: x, y: height))
        }
    }

    private func seekWaveform(_ x: CGFloat, width: CGFloat) {
        seek(info.duration * Double(min(1, max(0, (x - handleWidth) / width))))
    }

    private func position(_ time: Double, width: CGFloat) -> CGFloat {
        handleWidth + CGFloat(time / info.duration) * width
    }

    private func waveformPath(width: CGFloat, height: CGFloat) -> Path {
        let peaks = info.waveform
        let center = height / 2
        let columns = min(peaks.count, max(1, Int(width / 2)))
        return Path { path in
            path.move(to: CGPoint(x: handleWidth, y: center))
            path.addLine(to: CGPoint(x: handleWidth + width, y: center))
            for column in 0..<columns {
                let first = column * peaks.count / columns
                let limit = (column + 1) * peaks.count / columns
                let peak = peaks[first..<limit].max() ?? 0
                guard peak.isFinite, peak > 0 else { continue }
                let x = handleWidth + (CGFloat(column) + 0.5) * width / CGFloat(columns)
                let amplitude = CGFloat(min(1, peak)) * (center - 4)
                path.move(to: CGPoint(x: x, y: center - amplitude))
                path.addLine(to: CGPoint(x: x, y: center + amplitude))
            }
        }
    }

    private func draggedRange(_ edge: Edge, distance: CGFloat, width: CGFloat) -> ClosedRange<Double> {
        let time = edge.time(in: selection) + Double(distance / width) * info.duration
        return range(moving: edge, to: time)
    }

    private func range(moving edge: Edge, to time: Double) -> ClosedRange<Double> {
        guard time.isFinite else { return selection }
        let start = selection.lowerBound
        let end = selection.upperBound
        switch edge {
        case .start:
            let latest = max(0, end - info.minimumTrimLength)
            return min(max(0, time), latest)...end
        case .end:
            let earliest = min(info.duration, start + info.minimumTrimLength)
            return start...max(earliest, min(time, info.duration))
        }
    }

    private func selectCandidate() {
        selection = info.suggestedTrimRange
        seek(info.conversationCandidate?.start ?? selection.lowerBound)
    }

    private func timeField(_ edge: Edge) -> some View {
        let value = Binding(
            get: { edge.time(in: shownRange) },
            set: { requested in
                selection = range(moving: edge, to: requested)
                seek(edge.time(in: selection))
            }
        )
        return HStack(spacing: 5) {
            Text(edge.label).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            TextField(edge.accessibilityLabel, value: value, format: .number.grouping(.never).precision(.fractionLength(2...3)))
                .labelsHidden()
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 78)
        }
    }

    private func timecode(_ seconds: Double) -> String { editorTimecode(seconds) }
}
