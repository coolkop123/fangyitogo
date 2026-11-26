import Foundation

/// 一种语言：语音识别 / 朗读用 `speechID`，翻译框架用 `translationID`。
struct Lang: Identifiable, Hashable {
    let speechID: String        // 例如 "zh-CN"，用于 SFSpeechRecognizer 与 AVSpeechSynthesisVoice
    let translationID: String   // 例如 "zh-Hans"，用于 Translation 框架
    let name: String

    var id: String { speechID }
    var locale: Locale { Locale(identifier: speechID) }
    var language: Locale.Language { Locale.Language(identifier: translationID) }

    static let all: [Lang] = [
        .init(speechID: "zh-CN", translationID: "zh-Hans", name: "中文（普通话）"),
        .init(speechID: "zh-TW", translationID: "zh-Hant", name: "中文（繁體）"),
        .init(speechID: "zh-HK", translationID: "zh-Hant", name: "粵語（香港）"),
        .init(speechID: "en-US", translationID: "en-US",   name: "English (US)"),
        .init(speechID: "en-GB", translationID: "en-GB",   name: "English (UK)"),
        .init(speechID: "ja-JP", translationID: "ja",      name: "日本語"),
        .init(speechID: "ko-KR", translationID: "ko",      name: "한국어"),
        .init(speechID: "fr-FR", translationID: "fr",      name: "Français"),
        .init(speechID: "de-DE", translationID: "de",      name: "Deutsch"),
        .init(speechID: "es-ES", translationID: "es",      name: "Español"),
        .init(speechID: "it-IT", translationID: "it",      name: "Italiano"),
        .init(speechID: "pt-BR", translationID: "pt-BR",   name: "Português (BR)"),
        .init(speechID: "ru-RU", translationID: "ru",      name: "Русский"),
        .init(speechID: "th-TH", translationID: "th",      name: "ไทย"),
        .init(speechID: "vi-VN", translationID: "vi",      name: "Tiếng Việt"),
        .init(speechID: "id-ID", translationID: "id",      name: "Bahasa Indonesia"),
        .init(speechID: "tr-TR", translationID: "tr",      name: "Türkçe"),
        .init(speechID: "ar-SA", translationID: "ar",      name: "العربية"),
    ]

    static func find(_ id: String?) -> Lang? { all.first { $0.speechID == id } }
}

/// 谁在说话：我（戴耳机的人）或对方。
enum Side: Sendable { case me, them }

enum Mode: String, CaseIterable, Identifiable {
    case talk = "面对面对话"
    case live = "同传收听"
    var id: String { rawValue }
}

/// 我说的话翻译后怎么给对方听。
enum MyOutput: String, CaseIterable, Identifiable {
    case speaker  = "手机外放给对方听"
    case earbuds  = "耳机播放（对方戴另一只）"
    case textOnly = "只显示大字给对方看"
    var id: String { rawValue }
}

/// 记录来自哪个页面：同声翻译、对话翻译、打字翻译。
enum Origin: String, Sendable { case live, talk, typed }

struct Utterance: Identifiable, Equatable {
    let id = UUID()
    let side: Side
    let source: String
    var origin: Origin = .live
    var translation: String?
    var failed: String?
}

struct TranslationJob: Sendable {
    let id: UUID
    let text: String
}
