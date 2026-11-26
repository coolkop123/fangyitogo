import AVFoundation

/// 用系统语音朗读译文，走当前音频线路（蓝牙耳机或扬声器）。
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speakingID: UUID?
    /// 播不出声音时的提示（由界面显示）。
    @Published var problem: String?
    /// AVSpeechUtterance 语速，0.5 为默认。
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    private let synth = AVSpeechSynthesizer()
    private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private var started: Set<ObjectIdentifier> = []

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    /// 朗读并等待读完（被打断、超时也会返回，不会一直卡住）。
    func speak(_ text: String, language: String, id: UUID) async {
        speakingID = id
        // 先用挑选的声音；2.5 秒还没开始出声，就换系统默认声音再试一次
        var ok = await speakOnce(text, voice: Self.bestVoice(for: language))
        if !ok {
            synth.stopSpeaking(at: .immediate)
            ok = await speakOnce(text, voice: AVSpeechSynthesisVoice(language: language))
            if !ok { problem = "没有播出声音：请检查手机音量和侧面静音键，或在 设置 › 辅助功能 › 朗读内容 › 声音 里下载该语言的声音。" }
        }
        if speakingID == id { speakingID = nil }
    }

    /// 播一次。返回是否真的开始出声。
    private func speakOnce(_ text: String, voice: AVSpeechSynthesisVoice?) async -> Bool {
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        u.volume = 1
        let key = ObjectIdentifier(u)
        // 最长等待：按字数估算，防止回调丢失时一直卡住
        let maxWait = max(8.0, Double(text.count) * 0.35)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiting[key] = c
            synth.speak(u)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(2500))
                guard let self, self.waiting[key] != nil, !self.started.contains(key) else { return }
                self.synth.stopSpeaking(at: .immediate)
                self.resume(key)                         // 2.5 秒没开始：放弃这次
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(maxWait))
                self?.resume(key)                        // 兜底：最长等待时间到了
            }
        }
        return started.remove(key) != nil
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    /// 选一个能正常发声的声音：语言匹配，排除「趣味声音」和「个人声音」，优先增强音质。
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let usable = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let exact = usable.filter { $0.language == language }
        let pool = exact.isEmpty ? usable.filter { $0.language.hasPrefix(prefix) } : exact
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u)
        Task { @MainActor in self.started.insert(key) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u)
        Task { @MainActor in self.resume(key) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u)
        Task { @MainActor in self.resume(key) }
    }

    private func resume(_ key: ObjectIdentifier) {
        waiting.removeValue(forKey: key)?.resume()
    }
}
