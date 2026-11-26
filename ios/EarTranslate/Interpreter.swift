import SwiftUI
import AVFoundation
import Translation

/// 把「听 → 译 → 说」串起来的核心逻辑。
@MainActor
final class Interpreter: ObservableObject {
    // 语言
    @Published var mine: Lang { didSet { languagesChanged() } }
    @Published var theirs: Lang { didSet { languagesChanged() } }

    // 状态
    @Published var mode: Mode = .talk
    @Published var items: [Utterance] = []
    @Published private(set) var listeningSide: Side?
    @Published var errorMessage: String?
    @Published var bigText: Utterance?

    // 设置
    @Published var autoSpeak: Bool { didSet { defaults.set(autoSpeak, forKey: "autoSpeak") } }
    @Published var myOutput: MyOutput { didSet { defaults.set(myOutput.rawValue, forKey: "myOutput") } }
    /// 所有译文都用手机扬声器外放（不戴耳机、或想让周围的人都听到时）。
    @Published var allSpeaker: Bool { didSet { defaults.set(allSpeaker, forKey: "allSpeaker") } }
    @Published var speechRate: Float { didSet { speaker.rate = speechRate; defaults.set(speechRate, forKey: "rate") } }
    /// 收音灵敏度：1 标准 / 4 高 / 10 很高
    @Published var sensitivity: Double { didSet { listener.setSensitivity(sensitivity); defaults.set(sensitivity, forKey: "sensitivity") } }
    @Published var silenceTimeout: Double { didSet { listener.silenceTimeout = silenceTimeout; defaults.set(silenceTimeout, forKey: "silence") } }

    // 两个方向各一个翻译会话（由视图上的 .translationTask 驱动）
    @Published var configMeToThem: TranslationSession.Configuration?
    @Published var configThemToMe: TranslationSession.Configuration?

    let listener = SpeechListener()
    let speaker = Speaker()
    let router = AudioRouter()

    private let defaults = UserDefaults.standard
    private var queues: [Side: AsyncStream<TranslationJob>.Continuation] = [:]
    private var pending: [UUID: (Side, TranslationJob)] = [:]
    private var permitted = false
    private var speakingCount = 0
    private var warnedNoHeadset = false
    /// 同传 + 全部外放时打开系统回声消除，播报期间不用暂停收音
    private var echoCancel = false
    private let log = DiagnosticLogger.shared

    init() {
        let d = UserDefaults.standard
        mine = Lang.find(d.string(forKey: "mine")) ?? Lang.all[0]
        theirs = Lang.find(d.string(forKey: "theirs")) ?? Lang.all[3]
        autoSpeak = d.object(forKey: "autoSpeak") as? Bool ?? true
        myOutput = MyOutput(rawValue: d.string(forKey: "myOutput") ?? "") ?? .speaker
        allSpeaker = d.bool(forKey: "allSpeaker")
        speechRate = d.object(forKey: "rate") as? Float ?? AVSpeechUtteranceDefaultSpeechRate
        // 断句停顿默认 1.4 秒（旧版默认 1.0 秒太短，长句会被切成只剩第一个词）
        if !d.bool(forKey: "silenceV2") {
            d.set(true, forKey: "silenceV2")
            if (d.object(forKey: "silence") as? Double ?? 0) < 1.2 { d.set(1.4, forKey: "silence") }
        }
        silenceTimeout = d.object(forKey: "silence") as? Double ?? 1.4
        sensitivity = d.object(forKey: "sensitivity") as? Double ?? 4
        speaker.rate = speechRate
        listener.silenceTimeout = silenceTimeout
        listener.setSensitivity(sensitivity)
        makeConfigs()
    }

    func prepare() {
        do { try router.configure() }
        catch { errorMessage = "音频初始化失败：\(error.localizedDescription)" }
    }

    // MARK: - 语言

    func swapLanguages() {
        let a = mine
        mine = theirs
        theirs = a
    }

    private func languagesChanged() {
        defaults.set(mine.speechID, forKey: "mine")
        defaults.set(theirs.speechID, forKey: "theirs")
        stopListening()
        makeConfigs()
        Task { await checkAvailability() }
    }

    private func makeConfigs() {
        configMeToThem = .init(source: mine.language, target: theirs.language)
        configThemToMe = .init(source: theirs.language, target: mine.language)
    }

    private func checkAvailability() async {
        let status = await LanguageAvailability().status(from: mine.language, to: theirs.language)
        if status == .unsupported {
            errorMessage = "系统翻译暂不支持「\(mine.name) ↔ \(theirs.name)」，请换一组语言。"
        }
    }

    // MARK: - 收音

    func toggle(_ side: Side) async {
        if listeningSide != nil {
            await stopListeningAndFlush()
            return
        }
        speaker.stop()
        router.setSpeakerOverride(false)

        if !permitted {
            permitted = await SpeechListener.requestPermissions()
            guard permitted else {
                errorMessage = "需要麦克风和语音识别权限：请到 设置 › 酷天同声 中打开。"
                return
            }
        }
        prepare()

        do {
            if mode == .live {
                if !router.isBluetooth && !warnedNoHeadset {
                    warnedNoHeadset = true
                    errorMessage = allSpeaker
                        ? "未检测到耳机：译文从手机外放时，可能会漏识别对方的话，建议佩戴耳机。"
                        : "未检测到耳机：同传的译文只显示在屏幕上，不会播报。戴上蓝牙耳机后译文会在耳机里播放（或在「我的」里打开「全部用手机外放」）。"
                    log.log("warn_no_headset", "allSpeaker=\(allSpeaker)")
                }
                echoCancel = allSpeaker
                router.setEchoCancellation(echoCancel)
                // 同传：中文、英文（两种语言）同时识别同一路声音，说完后选把握度高的那个
                listener.onSegment = { [weak self] cands in self?.handleLive(cands) }
                try listener.start(locales: [mine.locale, theirs.locale], segmentOnSilence: true)
                listeningSide = .them
            } else {
                let lang = side == .me ? mine : theirs
                listener.onSegment = { [weak self] cands in
                    if let t = cands.first?.text, !t.isEmpty { self?.submit(t, side: side) }
                }
                try listener.start(locales: [lang.locale], segmentOnSilence: false)
                listeningSide = side
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopListeningAndFlush() async {
        await listener.stopAndFlush()
        listeningSide = nil
        endEchoCancel()
    }

    func stopListening() {
        listener.stop(flush: false)
        listeningSide = nil
        endEchoCancel()
    }

    private func endEchoCancel() {
        guard echoCancel else { return }
        echoCancel = false
        router.setEchoCancellation(false)
    }

    // MARK: - 同传：判断是谁在说

    /// 两个识别器各给出一个结果：选把握度高的；把握度都没有时，按文字类型判断。
    func handleLive(_ cands: [Candidate]) {
        guard let best = Self.pick(cands, languages: [mine, theirs]) else { return }
        log.log("language_pick", "lang=\(best.index == 0 ? mine.speechID : theirs.speechID) text=\"\(best.text)\"")
        submit(best.text, side: best.index == 0 ? .me : .them)
    }

    nonisolated static func pick(_ cands: [Candidate], languages: [Lang]) -> Candidate? {
        let valid = cands.filter { !$0.text.isEmpty && $0.index < languages.count }
        guard !valid.isEmpty else { return nil }
        if valid.count == 1 { return valid[0] }
        func score(_ c: Candidate) -> Float {
            // 识别出的文字类型和该语言相符（中文识别器出汉字、英文识别器出字母）就加分
            let expectsCJK = ["zh", "ja", "ko"].contains(String(languages[c.index].speechID.prefix(2)))
            let ratio = cjkRatio(c.text)
            let match: Float = expectsCJK ? ratio : (1 - ratio)
            return c.confidence + 0.25 * match
        }
        return valid.max { score($0) < score($1) }
    }

    /// 文字里汉字 / 假名 / 谚文所占比例（按字母数计）。
    nonisolated static func cjkRatio(_ t: String) -> Float {
        var cjk = 0, latin = 0
        for u in t.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF: cjk += 2   // 一个汉字信息量约等于两个字母
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            default: break
            }
        }
        return cjk + latin == 0 ? 0 : Float(cjk) / Float(cjk + latin)
    }

    // MARK: - 翻译

    func submit(_ text: String, side: Side, origin: Origin? = nil) {
        let u = Utterance(side: side, source: text, origin: origin ?? (mode == .live ? .live : .talk))
        items.append(u)
        let job = TranslationJob(id: u.id, text: text)
        pending[u.id] = (side, job)
        queues[side]?.yield(job)
    }

    func translateTyped(_ text: String, side: Side = .me) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        submit(t, side: side, origin: .typed)
    }

    func items(_ origin: Origin) -> [Utterance] { items.filter { $0.origin == origin } }

    /// 由 .translationTask 调用：在会话有效期间不断处理该方向的翻译队列。
    func serve(_ session: TranslationSession, side: Side) async {
        let (stream, continuation) = AsyncStream.makeStream(of: TranslationJob.self)
        queues[side] = continuation
        // 会话重建前没译完的，重新排队
        for (_, entry) in pending where entry.0 == side { continuation.yield(entry.1) }

        do {
            try await session.prepareTranslation()   // 需要时会弹出下载语言包的提示
        } catch {
            errorMessage = "语言包未就绪：\(error.localizedDescription)"
        }

        for await job in stream {
            do {
                let response = try await session.translate(job.text)
                deliver(job.id, text: response.targetText)
            } catch is CancellationError {
                break
            } catch {
                fail(job.id, message: "翻译失败")
            }
        }
    }

    private func deliver(_ id: UUID, text: String) {
        pending[id] = nil
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].translation = text
        let u = items[i]
        guard autoSpeak, u.origin != .typed else { return }   // 打字翻译不自动播报，点「播放」再读

        if u.side == .me && myOutput == .textOnly {
            bigText = u
            return
        }
        // 面对面模式里，下一个人已经开始说时不打断；同传模式只在戴着耳机时播报（避免外放被麦克风回收）
        if mode == .talk && listeningSide != nil { return }
        if mode == .live && !router.isBluetooth && !allSpeaker { return }
        Task { await speak(u) }
    }

    private func fail(_ id: UUID, message: String) {
        pending[id] = nil
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].failed = message }
    }

    // MARK: - 播报

    func speak(_ u: Utterance) async {
        guard let text = u.translation else { return }
        let target = u.side == .me ? theirs : mine
        let toSpeaker = allSpeaker || (u.side == .me && myOutput == .speaker)
        // 声音从扬声器出来时，暂时屏蔽麦克风，防止回声被识别
        let muteMic = listeningSide != nil && (toSpeaker || !router.isBluetooth) && !echoCancel
        speakingCount += 1
        if toSpeaker { router.setSpeakerOverride(true) }
        if muteMic { listener.setMuted(true) }
        log.log("tts_start", "lang=\(target.speechID) speaker=\(toSpeaker) muteMic=\(muteMic) len=\(text.count)")
        await speaker.speak(text, language: target.speechID, id: u.id)
        log.log("tts_end")
        speakingCount -= 1
        if speakingCount == 0 {
            if toSpeaker { router.setSpeakerOverride(false) }
            listener.setMuted(false)
        }
    }

    /// 设置里的「试听外放」：从手机扬声器播一句，确认外放有没有声音。
    func testSpeaker() async {
        prepare()
        let sample = mine.speechID.hasPrefix("zh") ? "你好，这是酷天同声的外放测试。" : "Hello, this is a speaker test."
        router.setSpeakerOverride(true)
        await speaker.speak(sample, language: mine.speechID, id: UUID())
        router.setSpeakerOverride(false)
    }

    func clear(_ origin: Origin? = nil) {
        if let origin { items.removeAll { $0.origin == origin } } else { items.removeAll() }
    }

    var transcript: String {
        items.map { u in
            let who = u.side == .me ? "我" : "对方"
            return "\(who)：\(u.source)\n→ \(u.translation ?? "")"
        }.joined(separator: "\n\n")
    }
}
