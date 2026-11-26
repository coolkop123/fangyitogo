import AVFoundation

/// 用系统语音朗读译文，走当前音频线路（蓝牙耳机或扬声器）。
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speakingID: UUID?
    /// AVSpeechUtterance 语速，0.5 为默认。
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    private let synth = AVSpeechSynthesizer()
    private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    /// 朗读并等待读完（被打断也会返回）。
    func speak(_ text: String, language: String, id: UUID) async {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice(for: language)
        u.rate = rate
        speakingID = id
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiting[ObjectIdentifier(u)] = c
            synth.speak(u)
        }
        if speakingID == id { speakingID = nil }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    /// 优先选增强 / 高级音质的声音（可在 设置 › 辅助功能 › 朗读内容 › 声音 下载）。
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let exact = voices.filter { $0.language == language }
        let loose = voices.filter { $0.language.hasPrefix(prefix) }
        let pool = exact.isEmpty ? loose : exact
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
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
