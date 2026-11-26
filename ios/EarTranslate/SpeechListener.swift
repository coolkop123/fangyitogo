import AVFoundation
import Speech

enum ListenerError: LocalizedError {
    case unavailable(String)
    case micBusy(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let id): return "此设备暂不支持「\(id)」的语音识别，或识别服务不可用。"
        case .micBusy(let detail):
            return "麦克风打不开。请从屏幕右上角下拉打开控制中心，看看顶部写的是哪个 App 在用麦克风，把它关掉（或结束通话）后再试；如果还不行，把酷天同声从后台划掉重新打开。\n\n\(detail)"
        }
    }
}

/// 一段话在某种语言下的识别结果。
struct Candidate: Sendable {
    let index: Int          // 对应 start(locales:) 里的第几种语言
    let text: String
    let confidence: Float   // 0~1，只有识别完成（final）时才有值
}

/// 把音频线程收到的缓冲区同时交给所有识别请求（双语同传时有两个）。
/// 小声说话时自动放大（最多 maxGain 倍），大声时不放大；太安静的背景噪音不放大。
private final class BufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var muted = false
    private var maxGain: Float = 4
    private var gain: Float = 1
    func set(_ r: [SFSpeechAudioBufferRecognitionRequest]) { lock.lock(); requests = r; lock.unlock() }
    func setMuted(_ m: Bool) { lock.lock(); muted = m; lock.unlock() }
    func setMaxGain(_ g: Float) { lock.lock(); maxGain = max(1, g); lock.unlock() }
    func append(_ b: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !muted, !requests.isEmpty else { return }
        let out = boost(b) ?? b
        for r in requests { r.append(out) }
    }

    private func boost(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard maxGain > 1.01, let src = b.floatChannelData, b.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength),
              let dst = copy.floatChannelData else { return nil }
        let n = Int(b.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += src[0][i] * src[0][i] }
        let rms = (sum / Float(n)).squareRoot()
        // 目标音量约 0.08；低于噪声门（0.002）当作安静，不放大
        let want: Float = rms < 0.002 ? 1 : min(maxGain, max(1, 0.08 / rms))
        gain = want < gain ? gain * 0.6 + want * 0.4 : gain * 0.9 + want * 0.1   // 变小快、变大慢，避免忽大忽小
        copy.frameLength = b.frameLength
        for ch in 0..<Int(b.format.channelCount) {
            for i in 0..<n {
                let x = src[ch][i] * gain
                dst[ch][i] = x > 0.95 || x < -0.95 ? tanh(x) : x                // 太响时柔和压住，避免爆音
            }
        }
        return copy
    }
}

/// 在音频线程上算麦克风音量，大约每 0.1 秒交给界面一次。
private final class LevelMeter: @unchecked Sendable {
    private var count = 0
    var onLevel: (@Sendable (Float) -> Void)?
    func feed(_ b: AVAudioPCMBuffer) {
        count += 1
        guard count % 4 == 0, let ch = b.floatChannelData?[0], b.frameLength > 0 else { return }
        let n = Int(b.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(n)).squareRoot()
        onLevel?(min(1, rms * 8))
    }
}

/// 连续语音识别。
/// - 面对面：一种语言，一直累积到手动停止。
/// - 同传：同时用两种语言识别同一路声音，停顿后比较两边的把握度，交给调用方选择。
@MainActor
final class SpeechListener: ObservableObject {
    /// 每种语言当前的实时识别文字（同传时屏幕上同时显示）。
    @Published private(set) var partials: [String] = []
    @Published private(set) var isRunning = false
    /// 麦克风音量 0~1（说话时会跳动）。
    @Published private(set) var level: Float = 0
    /// 识别连续出错时的原因（显示在屏幕上）。
    @Published private(set) var problem: String?

    /// 一段话结束：给出每种语言的识别结果。
    var onSegment: (([Candidate]) -> Void)?
    var silenceTimeout: TimeInterval = 1.0

    private var engine = AVAudioEngine()
    private let sink = BufferSink()
    private let meter = LevelMeter()
    private var dead: [Bool] = []          // 这一段里已经出错的识别器
    private var failStreak: [Int] = []     // 每个识别器连续出错的次数
    private var recognizers: [SFSpeechRecognizer] = []
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var tasks: [SFSpeechRecognitionTask] = []
    private var texts: [String] = []
    private var confs: [Float] = []
    private var finals: [Bool] = []
    private var generation = 0
    private var segmentOnSilence = true
    private var finishing = false
    private var committed = ""          // 面对面：已完成的句子
    private var silenceTimer: Timer?
    private var finishTimer: Timer?

    var partial: String { partials.filter { !$0.isEmpty }.joined(separator: "\n") }

    static func requestPermissions() async -> Bool {
        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        return speechOK && micOK
    }

    func start(locales: [Locale], segmentOnSilence: Bool) throws {
        stop(flush: false)
        var recs: [SFSpeechRecognizer] = []
        for l in locales {
            guard let r = SFSpeechRecognizer(locale: l), r.isAvailable else { throw ListenerError.unavailable(l.identifier) }
            recs.append(r)
        }
        recognizers = recs
        self.segmentOnSilence = segmentOnSilence
        committed = ""
        failStreak = Array(repeating: 0, count: recs.count)
        problem = nil
        meter.onLevel = { [weak self] v in Task { @MainActor in self?.level = v } }

        // 依次尝试几种录音设置，前一种打不开就换下一种
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                Self.prepareSession(attempt: attempt)
                try startEngine()
                lastError = nil
                break
            } catch {
                lastError = error
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        if let lastError {
            Self.prepareSession(attempt: 0)          // 恢复正常设置，不影响播报
            throw ListenerError.micBusy(Self.diagnose(lastError))
        }
        isRunning = true
        beginRequests()
    }

    /// 每次新建一个录音引擎（避免沿用旧的麦克风格式），确认麦克风可用后再启动。
    private func startEngine() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "麦克风格式无效", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "采样率 \(Int(format.sampleRate))，声道 \(format.channelCount)"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(sink, meter))
        engine.prepare()
        do { try engine.start() } catch {
            let ns = error as NSError
            throw NSError(domain: "启动录音", code: ns.code, userInfo: [NSLocalizedDescriptionKey: ns.localizedDescription])
        }
    }

    /// 第 0 种：正常设置；1：先停用再重新激活；2：去掉蓝牙等选项；3：只录音模式。
    static func prepareSession(attempt: Int) {
        let s = AVAudioSession.sharedInstance()
        switch attempt {
        case 0:
            if s.category != .playAndRecord {
                try? s.setCategory(.playAndRecord, mode: .default,
                                   options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
            }
        case 1:
            try? s.setActive(false, options: .notifyOthersOnDeactivation)
            try? s.setCategory(.playAndRecord, mode: .default,
                               options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        case 2:
            try? s.setActive(false, options: .notifyOthersOnDeactivation)
            try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        default:
            try? s.setActive(false, options: .notifyOthersOnDeactivation)
            try? s.setCategory(.record, mode: .default, options: [])
        }
        try? s.setActive(true)
    }

    /// 打不开麦克风时，把当时的音频状态写进提示，方便排查。
    static func diagnose(_ error: Error) -> String {
        let s = AVAudioSession.sharedInstance()
        let ns = error as NSError
        let inputs = s.availableInputs?.map(\.portName).joined(separator: "、") ?? "无"
        let perm: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted: perm = "已允许"
        case .denied: perm = "已拒绝"
        default: perm = "未决定"
        }
        return "失败步骤：\(ns.domain)（代码 \(ns.code)）\n可用麦克风：\(inputs)\n麦克风权限：\(perm)\n其他 App 正在用音频：\(s.isOtherAudioPlaying ? "是" : "否")"
    }


    /// 稍等让最后几个字识别出来，再停止并提交。
    func stopAndFlush() async {
        try? await Task.sleep(for: .milliseconds(450))
        stop(flush: true)
    }

    func setMuted(_ muted: Bool) { sink.setMuted(muted) }
    /// 收音灵敏度：小声说话时最多放大几倍（1 = 不放大）。
    func setSensitivity(_ maxGain: Double) { sink.setMaxGain(Float(maxGain)) }

    func stop(flush: Bool) {
        guard isRunning else { return }
        isRunning = false
        let lastTexts = texts
        endRequests()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        Self.prepareSession(attempt: 0)          // 如果刚才用的是「只录音」模式，恢复成能播报的设置
        if flush {
            if segmentOnSilence {
                emit(lastTexts.enumerated().map { Candidate(index: $0.offset, text: $0.element, confidence: 0) })
            } else {
                let all = join(committed, lastTexts.first ?? "")
                emit([Candidate(index: 0, text: all, confidence: 1)])
            }
        }
        committed = ""
        partials = []
        level = 0
    }

    // MARK: - 内部

    private func beginRequests() {
        guard isRunning else { return }
        generation += 1
        let gen = generation
        finishing = false
        let n = recognizers.count
        texts = Array(repeating: "", count: n)
        confs = Array(repeating: 0, count: n)
        finals = Array(repeating: false, count: n)
        dead = Array(repeating: false, count: n)
        partials = segmentOnSilence ? texts : [committed]

        var reqs: [SFSpeechAudioBufferRecognitionRequest] = []
        var tks: [SFSpeechRecognitionTask] = []
        for (i, rec) in recognizers.enumerated() {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            // 不强制离线：能离线就离线，离线资源没准备好时交给苹果服务器，避免悄悄失败
            req.requiresOnDeviceRecognition = false
            reqs.append(req)
            tks.append(rec.recognitionTask(with: req, resultHandler: Self.makeHandler { [weak self] text, isFinal, conf, err in
                self?.handle(gen: gen, index: i, text: text, isFinal: isFinal, confidence: conf, error: err)
            }))
        }
        requests = reqs
        tasks = tks
        sink.set(reqs)
    }

    private func endRequests() {
        silenceTimer?.invalidate(); silenceTimer = nil
        finishTimer?.invalidate(); finishTimer = nil
        generation += 1                       // 忽略之后迟到的回调
        sink.set([])
        requests.forEach { $0.endAudio() }
        tasks.forEach { $0.cancel() }
        requests = []; tasks = []
    }

    private func handle(gen: Int, index i: Int, text: String?, isFinal: Bool, confidence: Float, error: (code: Int, message: String)?) {
        guard gen == generation, isRunning, i < texts.count else { return }
        let failed = error != nil
        // 出错又什么都没识别出来：只停这一个识别器，不影响另一个
        if let error, (text ?? "").isEmpty, texts[i].isEmpty {
            dead[i] = true; finals[i] = true
            let benign = error.code == 1110 || error.code == 203 || error.code == 216 || error.code == 301   // 没听到说话 / 被取消
            if !benign {
                failStreak[i] += 1
                if failStreak[i] >= 2 {
                    let name = recognizers[i].locale.localizedString(forIdentifier: recognizers[i].locale.identifier) ?? recognizers[i].locale.identifier
                    problem = "「\(name)」识别出错：\(error.message)（代码 \(error.code)）"
                }
            }
            if !dead.contains(false) {
                // 所有识别器都停了：稍等后重新开始（连续出错时等久一点）
                let wait = min(3.0, 0.4 * Double(max(1, failStreak.max() ?? 1)))
                endRequests()
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    Task { @MainActor in self?.beginRequests() }
                }
            } else if finishing, !finals.contains(false) {
                completeSegment()
            }
            return
        }
        if let t = text, !t.isEmpty { failStreak[i] = 0; if !failStreak.contains(where: { $0 >= 2 }) { problem = nil } }
        if let text, !text.isEmpty {
            texts[i] = text
            if segmentOnSilence { partials = texts } else { partials = [join(committed, text)] }
            if !finishing { armSilenceTimer() }
        }
        if isFinal || failed {
            finals[i] = true
            if isFinal { confs[i] = confidence }
        }

        if segmentOnSilence {
            if finishing {
                if !finals.contains(false) { completeSegment() }
            } else if isFinal || failed {
                // 某个识别器自己结束了（停顿太久或到了约 1 分钟上限）：整段收尾
                if texts.contains(where: { !$0.isEmpty }) {
                    startFinishing()
                } else if !dead.contains(false) || !finals.contains(false) {
                    endRequests()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        Task { @MainActor in self?.beginRequests() }
                    }
                }
            }
        } else if isFinal || failed {
            // 面对面：累积这一段，接着开新任务
            committed = join(committed, texts[0])
            endRequests()
            let delay: Double = (failed && texts[0].isEmpty) ? 0.3 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in self?.beginRequests() }
            }
        }
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        guard segmentOnSilence else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startFinishing() }
        }
    }

    /// 停顿了：让所有识别器收尾，拿到带把握度的最终结果。
    private func startFinishing() {
        guard isRunning, segmentOnSilence, !finishing else { return }
        guard texts.contains(where: { !$0.isEmpty }) else { return }
        finishing = true
        silenceTimer?.invalidate()
        sink.set([])                          // 后面的声音不再算进这一段
        requests.forEach { $0.endAudio() }
        if !finals.contains(false) { completeSegment(); return }
        finishTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.completeSegment() }   // 最多等 1.5 秒
        }
    }

    private func completeSegment() {
        guard finishing else { return }
        let cands = texts.enumerated().map { Candidate(index: $0.offset, text: $0.element, confidence: confs[$0.offset]) }
        endRequests()
        emit(cands)
        beginRequests()
    }

    private func emit(_ cands: [Candidate]) {
        let clean = cands.map { Candidate(index: $0.index, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), confidence: $0.confidence) }
        guard clean.contains(where: { !$0.text.isEmpty }) else { return }
        onSegment?(clean)
    }

    private func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    // 这两个闭包在音频线程 / 识别线程上运行，必须不属于 MainActor。
    nonisolated private static func makeTap(_ sink: BufferSink, _ meter: LevelMeter) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer); meter.feed(buffer) }
    }

    nonisolated private static func makeHandler(
        _ cb: @escaping @MainActor @Sendable (String?, Bool, Float, (code: Int, message: String)?) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let segs = result?.bestTranscription.segments ?? []
            let conf: Float = segs.isEmpty ? 0 : segs.map(\.confidence).reduce(0, +) / Float(segs.count)
            let err: (code: Int, message: String)? = error.map { e in
                let ns = e as NSError
                return (ns.code, ns.localizedDescription)
            }
            Task { @MainActor in cb(text, isFinal, conf, err) }
        }
    }
}
