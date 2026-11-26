import SwiftUI
import Translation
import AVKit

/// 和网页版一致的配色：深蓝底，我 = 青色，对方 = 黄色，录音中 = 红色。
enum Theme {
    static let bg    = Color(red: 11/255,  green: 20/255,  blue: 51/255)    // #0b1433
    static let panel = Color(red: 20/255,  green: 30/255,  blue: 74/255)    // #141e4a
    static let line  = Color(red: 38/255,  green: 50/255,  blue: 110/255)   // #26326e
    static let ink   = Color(red: 238/255, green: 241/255, blue: 255/255)   // #eef1ff
    static let mute  = Color(red: 156/255, green: 168/255, blue: 216/255)   // #9ca8d8
    static let me    = Color(red: 79/255,  green: 193/255, blue: 198/255)   // #4fc1c6
    static let them  = Color(red: 247/255, green: 228/255, blue: 99/255)    // #f7e463
    static let rec   = Color(red: 232/255, green: 69/255,  blue: 44/255)    // #e8452c
    static func side(_ s: Side) -> Color { s == .me ? me : them }
}

struct ContentView: View {
    @EnvironmentObject var vm: Interpreter
    @State private var showSettings = false
    @State private var showCaptions = false
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            RouteBanner(router: vm.router)
            languageBar
            modePicker
            Transcript(listener: vm.listener, speaker: vm.speaker)
            if vm.mode == .live {
                LiveStage(listener: vm.listener) { showCaptions = true }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            controls
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .tint(Theme.me)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(vm) }
        .fullScreenCover(item: $vm.bigText) { u in BigTextView(text: u.translation ?? u.source) }
        .fullScreenCover(isPresented: $showCaptions) { LiveCaptionView(listener: vm.listener).environmentObject(vm) }
        .alert("提示", isPresented: Binding(get: { vm.errorMessage != nil },
                                          set: { if !$0 { vm.errorMessage = nil } })) {
            Button("好") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
        .onChange(of: vm.mode) { vm.stopListening() }
        .onReceive(vm.speaker.$problem) { p in
            if let p { vm.errorMessage = p; vm.speaker.problem = nil }
        }
        .translationTask(vm.configMeToThem) { session in await vm.serve(session, side: .me) }
        .translationTask(vm.configThemToMe) { session in await vm.serve(session, side: .them) }
        .onAppear { vm.prepare() }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Text("酷天同声").font(.system(size: 26, weight: .heavy))
            Spacer()
            Menu {
                Button("复制全部记录", systemImage: "doc.on.doc") { UIPasteboard.general.string = vm.transcript }
                Button("清空记录", systemImage: "trash", role: .destructive) { vm.clear() }
            } label: { CircleIcon(system: "ellipsis") }
            .disabled(vm.items.isEmpty)
            Button { vm.allSpeaker.toggle() } label: {
                CircleIcon(system: "speaker.wave.3.fill", on: vm.allSpeaker)
            }
            .accessibilityLabel(vm.allSpeaker ? "手机外放：开" : "手机外放：关")
            Button { showSettings = true } label: { CircleIcon(system: "gearshape") }
                .accessibilityLabel("设置")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            LangPicker(title: "我", color: Theme.me, selection: $vm.mine)
            Button { vm.swapLanguages() } label: { CircleIcon(system: "arrow.left.arrow.right") }
                .accessibilityLabel("交换语言")
            LangPicker(title: "对方", color: Theme.them, selection: $vm.theirs)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { m in
                Button { vm.mode = m } label: {
                    Text(m.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .foregroundStyle(vm.mode == m ? Theme.bg : Theme.mute)
                        .background(Capsule().fill(vm.mode == m ? Theme.ink : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().strokeBorder(Theme.line))
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: - 底部按钮

    @ViewBuilder private var controls: some View {
        VStack(spacing: 10) {
            if vm.mode == .talk {
                HStack(spacing: 12) {
                    TalkButton(title: vm.listeningSide == .me ? "说完了" : "我说",
                               subtitle: "\(vm.mine.name) → \(vm.theirs.name)",
                               color: Theme.me,
                               active: vm.listeningSide == .me) { Task { await vm.toggle(.me) } }
                        .disabled(vm.listeningSide == .them)
                    TalkButton(title: vm.listeningSide == .them ? "说完了" : "对方说",
                               subtitle: "\(vm.theirs.name) → \(vm.mine.name)",
                               color: Theme.them,
                               active: vm.listeningSide == .them) { Task { await vm.toggle(.them) } }
                        .disabled(vm.listeningSide == .me)
                }
            } else {
                TalkButton(title: vm.listeningSide == nil ? "开始同传" : "停止同传",
                           subtitle: "自动识别 \(vm.mine.name) ⇄ \(vm.theirs.name)，\(vm.allSpeaker ? "外放" : "耳机里播")译文",
                           color: Theme.ink,
                           active: vm.listeningSide != nil) { Task { await vm.toggle(.them) } }
            }
            HStack(spacing: 8) {
                TextField("", text: $typed, prompt: Text("也可以打字翻译…").foregroundStyle(Theme.mute))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                Button(action: sendTyped) {
                    Text("翻译").font(.body.weight(.semibold))
                        .padding(.horizontal, 16).frame(minHeight: 46)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func sendTyped() {
        vm.translateTyped(typed)
        typed = ""
    }
}

// MARK: - 组件

struct CircleIcon: View {
    let system: String
    var on = false
    var body: some View {
        Image(systemName: system)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .foregroundStyle(on ? Theme.bg : Theme.ink)
            .background(Circle().fill(on ? Theme.them : Theme.panel))
            .overlay(Circle().strokeBorder(on ? Theme.them : Theme.line))
    }
}

struct RouteBanner: View {
    @ObservedObject var router: AudioRouter
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: router.isBluetooth ? "airpodspro" : "exclamationmark.triangle.fill")
                .foregroundStyle(router.isBluetooth ? Theme.me : Theme.them)
            VStack(alignment: .leading, spacing: 0) {
                Text(router.isBluetooth ? "已连接：\(router.outputName)" : "未检测到蓝牙耳机")
                    .font(.subheadline.weight(.semibold))
                Text("麦克风：\(router.inputName)").font(.caption).foregroundStyle(Theme.mute)
            }
            Spacer()
            RoutePicker().frame(width: 36, height: 36)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .padding(.horizontal, 14)
    }
}

/// 系统的 AirPlay / 蓝牙输出选择按钮。
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = UIColor(Theme.ink)
        v.activeTintColor = UIColor(Theme.me)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct LangPicker: View {
    let title: String
    let color: Color
    @Binding var selection: Lang
    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(Lang.all) { Text($0.name).tag($0) }
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.caption2).foregroundStyle(Theme.mute)
                    Text(selection.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Theme.mute)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        }
        .foregroundStyle(Theme.ink)
    }
}

struct Transcript: View {
    @EnvironmentObject var vm: Interpreter
    @ObservedObject var listener: SpeechListener
    @ObservedObject var speaker: Speaker

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if vm.items.isEmpty && listener.partial.isEmpty {
                        EmptyHint(live: vm.mode == .live).padding(.top, 30)
                    }
                    ForEach(vm.items) { u in
                        Bubble(u: u, speaking: speaker.speakingID == u.id,
                               onPlay: { Task { await vm.speak(u) } },
                               onBig: { vm.bigText = u })
                            .id(u.id)
                    }
                    // 面对面：正在说的话显示在气泡下面（同传的实时文字在下方字幕区）
                    if vm.mode == .talk, !listener.partial.isEmpty {
                        Text(listener.partial)
                            .italic()
                            .foregroundStyle(Theme.mute)
                            .frame(maxWidth: .infinity, alignment: vm.listeningSide == .them ? .leading : .trailing)
                            .id("partial")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.items.count) {
                if let last = vm.items.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: listener.partial) {
                if vm.mode == .talk { proxy.scrollTo("partial", anchor: .bottom) }
            }
        }
    }
}

struct EmptyHint: View {
    let live: Bool
    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "headphones").font(.system(size: 60, weight: .semibold)).foregroundStyle(Theme.me)
                Image(systemName: "waveform").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.bg)
                    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Theme.them))
                    .offset(x: 22, y: -12)
            }
            .padding(.bottom, 6)
            Text("连好蓝牙耳机，按下方按钮说话").font(.headline)
            Text(live ? "同传：中文、英文直接说，不用切换。\n每句说完稍微停顿，屏幕上会显示翻译，并在耳机里播报。"
                      : "面对面：轮到谁说就按谁的按钮，说完再按一次。")
                .font(.subheadline).foregroundStyle(Theme.mute).multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct Bubble: View {
    let u: Utterance
    let speaking: Bool
    let onPlay: () -> Void
    let onBig: () -> Void

    private var color: Color { Theme.side(u.side) }

    var body: some View {
        HStack {
            if u.side == .me { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(u.source).font(.footnote).foregroundStyle(Theme.mute)
                if let t = u.translation {
                    Text(t).font(.title3.weight(.medium))
                        .foregroundStyle(speaking ? color : Theme.ink)
                } else if let f = u.failed {
                    Text(f).foregroundStyle(Theme.rec)
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.small).tint(Theme.mute); Text("翻译中…").foregroundStyle(Theme.mute) }
                }
                if u.translation != nil {
                    HStack(spacing: 18) {
                        Button(action: onPlay) { Label("播放", systemImage: speaking ? "speaker.wave.3.fill" : "play.fill") }
                        Button(action: onBig) { Label("大字", systemImage: "textformat.size") }
                        Button { UIPasteboard.general.string = u.translation } label: { Label("复制", systemImage: "doc.on.doc") }
                    }
                    .labelStyle(.iconOnly)
                    .font(.subheadline)
                    .foregroundStyle(Theme.mute)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
            .overlay(alignment: u.side == .me ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4).padding(.vertical, 12)
            }
            if u.side == .them { Spacer(minLength: 40) }
        }
    }
}

struct TalkButton: View {
    let title: String
    let subtitle: String
    let color: Color
    let active: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: active ? "waveform" : "mic.fill")
                    .font(.title2)
                    .symbolEffect(.variableColor.iterative, isActive: active)
                Text(title).font(.headline.weight(.heavy))
                Text(subtitle).font(.caption2).lineLimit(1).minimumScaleFactor(0.7).opacity(0.8)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 88)
            .foregroundStyle(active ? .white : Theme.bg)
            .background(RoundedRectangle(cornerRadius: 22).fill(active ? Theme.rec : color))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact, trigger: active)
    }
}

/// 同传字幕区：一直显示在屏幕上。上面是两种语言正在识别的文字，下面是最新一句的译文。
struct LiveStage: View {
    @EnvironmentObject var vm: Interpreter
    @ObservedObject var listener: SpeechListener
    let onFull: () -> Void

    private var status: String {
        if vm.listeningSide == nil { return vm.items.isEmpty ? "点下方「开始同传」" : "已停止" }
        if !listener.partial.isEmpty { return "🎙 正在识别…" }
        if let last = vm.items.last, last.translation == nil, last.failed == nil { return "翻译中…" }
        return "正在听…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status).font(.footnote.weight(.semibold)).foregroundStyle(Theme.mute)
                Spacer()
                Button(action: onFull) {
                    Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right").font(.footnote)
                }
                .foregroundStyle(Theme.mute)
            }
            if !listener.partial.isEmpty {
                LivePartials(names: [vm.mine.name, vm.theirs.name], texts: listener.partials, big: false)
            }
            if let u = vm.items.last {
                Text(u.source).font(.subheadline).foregroundStyle(Theme.mute).lineLimit(2)
                Text(u.translation ?? u.failed ?? "翻译中…")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(u.failed != nil ? Theme.rec : Theme.side(u.side))
                    .lineLimit(4)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if listener.partial.isEmpty {
                Text("说话后，翻译会显示在这里")
                    .font(.title3.weight(.semibold)).foregroundStyle(Theme.mute)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
        .animation(.easeOut(duration: 0.2), value: vm.items.last?.translation)
    }
}

/// 两种语言正在识别的文字（各一行）。
struct LivePartials: View {
    let names: [String]
    let texts: [String]
    var big = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(texts.enumerated()), id: \.offset) { i, t in
                if !t.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(i < names.count ? names[i] : "")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(i == 0 ? Theme.me : Theme.them)
                            .lineLimit(1)
                            .frame(width: 64, alignment: .leading)
                        Text(t).font(big ? .title2 : .body).italic().foregroundStyle(Theme.ink)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 全屏同传字幕：一直跟着最新一句，同时显示正在识别的文字。
struct LiveCaptionView: View {
    @EnvironmentObject var vm: Interpreter
    @ObservedObject var listener: SpeechListener
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            if let u = vm.items.last {
                Text(u.source).font(.title3).foregroundStyle(Theme.mute).multilineTextAlignment(.center)
                Text(u.translation ?? "翻译中…")
                    .font(.system(size: 46, weight: .bold))
                    .minimumScaleFactor(0.3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.side(u.side))
            } else {
                Text("等待说话…").font(.title).foregroundStyle(Theme.mute)
            }
            Spacer()
            if !listener.partial.isEmpty {
                LivePartials(names: [vm.mine.name, vm.theirs.name], texts: listener.partials, big: true)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            }
            Button { dismiss() } label: {
                Text("关闭").font(.headline).padding(.horizontal, 28).frame(minHeight: 46)
                    .background(Capsule().fill(Theme.panel))
                    .overlay(Capsule().strokeBorder(Theme.line))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.dark)
        .animation(.default, value: vm.items.last?.translation)
    }
}

/// 全屏大字，可以翻转 180° 直接给对面的人看。
struct BigTextView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var flipped = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            Text(text)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.bg)
                .minimumScaleFactor(0.3)
                .multilineTextAlignment(.center)
                .padding(32)
                .rotationEffect(.degrees(flipped ? 180 : 0))
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 24) {
                Button { flipped.toggle() } label: { Label("翻转", systemImage: "arrow.up.arrow.down") }
                Button("关闭") { dismiss() }
            }
            .buttonStyle(.bordered)
            .tint(Theme.bg)
            .padding()
        }
        .preferredColorScheme(.light)
        .onTapGesture { dismiss() }
    }
}
