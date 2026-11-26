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

/// 在音频线程上算麦克风音量，大约每 0.1 秒交给界面一次；同时记下最近一次收到声音、有人说话、声音偏小的时间（给看门狗用）。
private final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastBuffer: TimeInterval = 0
    private var lastLoud: TimeInterval = 0
    private var weakSince: TimeInterval = 0
    var onLevel: (@Sendable (Float) -> Void)?
    func feed(_ b: AVAudioPCMBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); lastBuffer = now; count += 1; let c = count; lock.unlock()
        guard c % 4 == 0, let ch = b.floatChannelData?[0], b.frameLength > 0 else { return }
        let n = Int(b.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(n)).squareRoot()
        lock.lock()
        if rms > 0.01 { lastLoud = now }
        // 有声音但偏小（远处说话）：0.004 ~ 0.015
        if rms > 0.004 && rms < 0.015 { if weakSince == 0 { weakSince = now } } else { weakSince = 0 }
        lock.unlock()
        onLevel?(min(1, rms * 8))
    }
    func reset() { lock.lock(); lastBuffer = ProcessInfo.processInfo.systemUptime; lastLoud = 0; weakSince = 0; lock.unlock() }
    /// (距上次收到声音, 距上次有人说话, 声音偏小已持续) 秒数
    func ages() -> (buffer: TimeInterval, loud: TimeInterval, faint: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        return (now - lastBuffer, lastLoud == 0 ? .infinity : now - lastLoud, weakSince == 0 ? 0 : now - weakSince)
    }
}

/// 诊断日志：记录识别会话起止和原因、断句定版、语种判定、播报起止、音量提示。「我的」页可导出。
final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()
    private let lock = NSLock()
    private var lines: [String] = []
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"; return f
    }()
    func log(_ event: String, _ detail: String = "") {
        lock.lock(); defer { lock.unlock() }
        lines.append("[\(fmt.string(from: Date()))] \(event) \(detail)")
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
    }
    func exportText() -> String {
        lock.lock(); defer { lock.unlock() }
        let info = Bundle.main.infoDictionary
        let head = "酷天同声 诊断日志 \(info?["CFBundleShortVersionString"] ?? "")(\(info?["CFBundleVersion"] ?? ""))  iOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        return head + lines.joined(separator: "\n")
    }
    func clear() { lock.lock(); lines.removeAll(); lock.unlock() }
}

/// 一段已经断句、正在等最终结果的识别（新的一段同时已经开始收音，不丢字头）。
private struct Closing {
    var texts: [String]
    var confs: [Float]
    var finals: [Bool]
    var tasks: [SFSpeechRecognitionTask]
}

/// 连续语音识别。
/// - 面对面：一种语言，一直累积到手动停止。
/// - 同传：同时用两种语言识别同一路声音；一句话说完（停顿约 1.4 秒）才定版，比较两边把握度选一种语言，
///   一句话里不会中途换语言。断句的同时就开始收下一句，不吞字头。
@MainActor
final class SpeechListener: ObservableObject {
    /// 每种语言当前的实时识别文字（同传时屏幕上同时显示，不进入气泡）。
    @Published private(set) var partials: [String] = []
    @Published private(set) var isRunning = false
    /// 正在重新连接麦克风 / 识别（界面显示「重连中」，不假装在听）。
    @Published private(set) var reconnecting = false
    /// 声音偏小，提示靠近手机。
    @Published private(set) var quiet = false
    /// 麦克风音量 0~1（说话时会跳动）。
    @Published private(set) var level: Float = 0
    /// 识别连续出错时的原因（显示在屏幕上）。
    @Published private(set) var problem: String?

    /// 一段话定版：给出每种语言的识别结果。
    var onSegment: (([Candidate]) -> Void)?
    /// 停顿多久算一句（秒）。
    var silenceTimeout: TimeInterval = 1.4

    private let log = DiagnosticLogger.shared
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
    private var closing: [Int: Closing] = [:]   // 已断句、等最终结果的段（按 generation）
    private var generation = 0
    private var segmentOnSilence = true
    private var committed = ""          // 面对面：已完成的句子
    private var silenceTimer: Timer?
    private var watchdog: Timer?
    private var configObserver: NSObjectProtocol?
    private var segmentStarted: TimeInterval = 0     // 这一段识别开始的时间
    private var lastResult: TimeInterval = 0         // 最近一次收到识别文字的时间
    private var lastRestart: TimeInterval = 0
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

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
        log.log("listen_start", "locales=\(locales.map(\.identifier)) segment=\(segmentOnSilence) silence=\(silenceTimeout)s route=\(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName))")
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
            log.log("mic_open_failed", "\(lastError)")
            Self.prepareSession(attempt: 0)          // 恢复正常设置，不影响播报
            throw ListenerError.micBusy(Self.diagnose(lastError))
        }
        isRunning = true
        meter.reset()
        beginRequests()
        startWatching()
    }

    // MARK: - 自动恢复

    /// 外放 / 耳机切换等音频变化会让系统悄悄停掉录音引擎：收到通知就重启；
    /// 另外每秒检查一次：没声音进来、识别卡住、到了单次识别时长上限，都自动接上，让同传一直连续工作。
    private func startWatching() {
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
            ) { [weak self] note in
                let source = (note.object as AnyObject?).map(ObjectIdentifier.init)
                Task { @MainActor in
                    guard let self, source == nil || source == ObjectIdentifier(self.engine) else { return }
                    self.restartEngine(reason: "audio_config_change")
                }
            }
        }
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
    }

    private func stopWatching() {
        watchdog?.invalidate(); watchdog = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
    }

    private func checkHealth() {
        guard isRunning else { return }
        let ages = meter.ages()
        // 1. 2 秒多没有任何声音进来：录音引擎停了，重启
        if ages.buffer > 2.5 || !engine.isRunning {
            level = 0
            restartEngine(reason: "no_audio_\(Int(ages.buffer))s")
            return
        }
        let hasText = texts.contains { !$0.isEmpty }
        // 声音一直偏小又没识别出字：提示靠近手机
        let q = ages.faint > 3 && !hasText
        if q != quiet { quiet = q; if q { log.log("warn_low_volume") } }
        guard segmentOnSilence else { return }
        let age = now - segmentStarted
        if hasText {
            if age > 55 {
                // 苹果单次识别约 1 分钟上限：赶在被掐断前主动断句、无缝开新一段
                startFinishing(reason: "rotate_55s")
            } else if now - lastResult > silenceTimeout + 3 {
                startFinishing(reason: "watchdog_silence")      // 停顿计时器没触发：手动收尾
            }
        } else if (ages.loud < 2 && age > 6) || age > 50 {
            // 一直有人说话却 6 秒没有任何识别文字，或空等快到上限：换新的识别任务
            log.log("session_rotate", ages.loud < 2 ? "stuck_while_talking" : "idle_50s")
            endRequests()
            beginRequests()
        }
    }

    private func restartEngine(reason: String) {
        guard isRunning, now - lastRestart > 0.8 else { return }   // 防止短时间内反复重启
        lastRestart = now
        reconnecting = true
        log.log("engine_restart", reason)
        var ok = false
        for attempt in 0..<4 {
            Self.prepareSession(attempt: attempt)
            if (try? startEngine()) != nil { ok = true; break }
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        meter.reset()
        guard ok else { log.log("engine_restart_failed"); return }    // 看门狗 1 秒后再试，期间显示「重连中」
        reconnecting = false
        // 麦克风格式可能变了：把已听到的这段定版，再开新的识别任务
        if segmentOnSilence, texts.contains(where: { !$0.isEmpty }) {
            startFinishing(reason: "engine_restart")
        } else {
            if !segmentOnSilence { committed = join(committed, texts.first ?? "") }
            endRequests(); beginRequests()
        }
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
        stopWatching()
        log.log("listen_stop", "flush=\(flush)")
        let lastTexts = texts
        let lastConfs = confs
        endRequests()
        // 已断句、还在等最终结果的段：用现有文字直接定版
        for gen in closing.keys.sorted() { flushClosing(gen, emitIt: flush) }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        Self.prepareSession(attempt: 0)          // 如果刚才用的是「只录音」模式，恢复成能播报的设置
        if flush {
            if segmentOnSilence {
                emit(lastTexts.enumerated().map { Candidate(index: $0.offset, text: $0.element, confidence: lastConfs[$0.offset]) })
            } else {
                let all = join(committed, lastTexts.first ?? "")
                emit([Candidate(index: 0, text: all, confidence: 1)])
            }
        }
        committed = ""
        partials = []
        level = 0
        reconnecting = false
        quiet = false
    }

    // MARK: - 内部

    private func beginRequests() {
        guard isRunning else { return }
        generation += 1
        let gen = generation
        segmentStarted = now
        lastResult = now
        reconnecting = false
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
            req.taskHint = .dictation
            // 不强制离线：能离线就离线，离线资源没准备好时交给苹果服务器，避免悄悄失败
            req.requiresOnDeviceRecognition = false
            reqs.append(req)
            tks.append(rec.recognitionTask(with: req, resultHandler: Self.makeHandler { [weak self] text, isFinal, conf, err in
                self?.handle(gen: gen, index: i, text: text, isFinal: isFinal, confidence: conf, error: err)
            }))
        }
        requests = reqs
        tasks = tks
        sink.set(reqs)                         // 新一段立即接上麦克风
    }

    /// 取消当前这一段（不定版）。
    private func endRequests() {
        silenceTimer?.invalidate(); silenceTimer = nil
        generation += 1                       // 忽略之后迟到的回调
        sink.set([])
        requests.forEach { $0.endAudio() }
        tasks.forEach { $0.cancel() }
        requests = []; tasks = []
    }

    private func handle(gen: Int, index i: Int, text: String?, isFinal: Bool, confidence: Float, error: (code: Int, message: String)?) {
        guard isRunning else { return }
        if gen != generation {
            handleClosing(gen: gen, index: i, text: text, isFinal: isFinal, confidence: confidence, failed: error != nil)
            return
        }
        guard i < texts.count else { return }
        let failed = error != nil
        if let error { log.log("recognizer_error", "gen=\(gen) idx=\(i) code=\(error.code) \(error.message) text=\"\(texts[i])\"") }
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
                // 所有识别器都停了：稍等后重新开始（连续出错时等久一点），期间显示「重连中」
                let streak = failStreak.max() ?? 0
                let wait = streak == 0 ? 0.0 : [0.0, 0.5, 1.5, 3.0][min(3, streak)]
                endRequests()
                if wait > 0.2 { reconnecting = true }
                log.log("session_reconnect", "wait=\(wait)s")
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    Task { @MainActor in self?.beginRequests() }
                }
            }
            return
        }
        if let t = text, !t.isEmpty { failStreak[i] = 0; if !failStreak.contains(where: { $0 >= 2 }) { problem = nil } }
        if let text, !text.isEmpty {
            lastResult = now
            texts[i] = text
            if segmentOnSilence { partials = texts } else { partials = [join(committed, text)] }
            armSilenceTimer()
        }
        if isFinal || failed {
            finals[i] = true
            if isFinal { confs[i] = confidence }
        }

        if segmentOnSilence {
            if isFinal || failed {
                // 某个识别器自己结束了（停顿太久或到了约 1 分钟上限）：整段定版
                if texts.contains(where: { !$0.isEmpty }) {
                    startFinishing(reason: isFinal ? "recognizer_final_\(i)" : "recognizer_error_\(i)")
                } else if !finals.contains(false) {
                    endRequests(); beginRequests()
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

    /// 已断句的段收到迟到的结果：更新文字和把握度，全部结束后定版。
    private func handleClosing(gen: Int, index i: Int, text: String?, isFinal: Bool, confidence: Float, failed: Bool) {
        guard var c = closing[gen], i < c.texts.count else { return }
        if let text, !text.isEmpty { c.texts[i] = text }
        if isFinal { c.confs[i] = confidence }
        if isFinal || failed { c.finals[i] = true }
        closing[gen] = c
        if !c.finals.contains(false) { flushClosing(gen, emitIt: true) }
    }

    private func flushClosing(_ gen: Int, emitIt: Bool) {
        guard let c = closing.removeValue(forKey: gen) else { return }
        c.tasks.forEach { $0.cancel() }
        guard emitIt else { return }
        let cands = c.texts.enumerated().map { Candidate(index: $0.offset, text: $0.element, confidence: c.confs[$0.offset]) }
        log.log("utterance_commit", "gen=\(gen) " + cands.map { "[\($0.index)] conf=\(String(format: "%.2f", $0.confidence)) \"\($0.text)\"" }.joined(separator: " "))
        emit(cands)
    }

    /// 静音断句：最后一次出字后停顿 silenceTimeout 秒才定版；如果麦克风里仍然有人在说话（识别慢了），再多等一会儿。
    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        guard segmentOnSilence else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.silenceElapsed() }
        }
    }

    private func silenceElapsed() {
        guard isRunning, segmentOnSilence else { return }
        let stillTalking = meter.ages().loud < 0.6
        if stillTalking && now - lastResult < 4 {
            // 还在说话，只是识别结果还没跟上：不切句
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.silenceElapsed() }
            }
            return
        }
        startFinishing(reason: "silence_\(silenceTimeout)s")
    }

    /// 断句：这一段停止收音、等最终结果（最多 2 秒）；同时立刻开始收下一段，不丢字头。
    private func startFinishing(reason: String) {
        guard isRunning, segmentOnSilence else { return }
        guard texts.contains(where: { !$0.isEmpty }) else { return }
        silenceTimer?.invalidate(); silenceTimer = nil
        let gen = generation
        log.log("utterance_endpoint", "gen=\(gen) reason=\(reason) age=\(String(format: "%.1f", now - segmentStarted))s")
        requests.forEach { $0.endAudio() }
        closing[gen] = Closing(texts: texts, confs: confs, finals: finals, tasks: tasks)
        requests = []; tasks = []
        beginRequests()                        // 新一段马上接上麦克风
        if let c = closing[gen], !c.finals.contains(false) { flushClosing(gen, emitIt: true); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            Task { @MainActor in self?.flushClosing(gen, emitIt: true) }   // 最多等 2 秒
        }
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
