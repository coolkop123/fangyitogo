import SwiftUI
import Translation
import AVKit

private let meColor = Color.teal
private let themColor = Color.orange

struct ContentView: View {
    @EnvironmentObject var vm: Interpreter
    @State private var showSettings = false
    @State private var showCaptions = false
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RouteBanner(router: vm.router)
                languageBar
                Picker("模式", selection: $vm.mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)

                Transcript(listener: vm.listener, speaker: vm.speaker)
                if vm.mode == .live, let last = vm.items.last {
                    CaptionCard(u: last) { showCaptions = true }
                        .padding(.horizontal)
                }
                controls
            }
            .navigationTitle("酷天同声")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("复制全部记录", systemImage: "doc.on.doc") { UIPasteboard.general.string = vm.transcript }
                        Button("清空记录", systemImage: "trash", role: .destructive) { vm.clear() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(vm.items.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { vm.allSpeaker.toggle() } label: {
                        Image(systemName: vm.allSpeaker ? "speaker.wave.3.fill" : "speaker.wave.3")
                    }
                    .tint(vm.allSpeaker ? .orange : nil)
                    .accessibilityLabel(vm.allSpeaker ? "手机外放：开" : "手机外放：关")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(vm) }
            .fullScreenCover(item: $vm.bigText) { u in BigTextView(text: u.translation ?? u.source) }
            .fullScreenCover(isPresented: $showCaptions) { LiveCaptionView(listener: vm.listener).environmentObject(vm) }
            .alert("提示", isPresented: Binding(get: { vm.errorMessage != nil },
                                              set: { if !$0 { vm.errorMessage = nil } })) {
                Button("好") { vm.errorMessage = nil }
            } message: { Text(vm.errorMessage ?? "") }
            .onChange(of: vm.mode) { vm.stopListening() }
        }
        .translationTask(vm.configMeToThem) { session in await vm.serve(session, side: .me) }
        .translationTask(vm.configThemToMe) { session in await vm.serve(session, side: .them) }
        .onAppear { vm.prepare() }
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            LangPicker(title: "我", color: meColor, selection: $vm.mine)
            Button { vm.swapLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44)
            }
            .accessibilityLabel("交换语言")
            LangPicker(title: "对方", color: themColor, selection: $vm.theirs)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 10) {
            if vm.mode == .talk {
                HStack(spacing: 12) {
                    TalkButton(title: vm.listeningSide == .me ? "说完了" : "我说",
                               subtitle: "\(vm.mine.name) → \(vm.theirs.name)",
                               color: meColor,
                               active: vm.listeningSide == .me) { Task { await vm.toggle(.me) } }
                        .disabled(vm.listeningSide == .them)
                    TalkButton(title: vm.listeningSide == .them ? "说完了" : "对方说",
                               subtitle: "\(vm.theirs.name) → \(vm.mine.name)",
                               color: themColor,
                               active: vm.listeningSide == .them) { Task { await vm.toggle(.them) } }
                        .disabled(vm.listeningSide == .me)
                }
            } else {
                TalkButton(title: vm.listeningSide == nil ? "开始同传" : "停止同传",
                           subtitle: "自动识别 \(vm.mine.name) ⇄ \(vm.theirs.name)，\(vm.allSpeaker ? "外放" : "耳机里播")译文",
                           color: .indigo,
                           active: vm.listeningSide != nil) { Task { await vm.toggle(.them) } }
            }
            HStack {
                TextField("也可以打字翻译…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                Button("翻译", action: sendTyped).buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.bar)
    }

    private func sendTyped() {
        vm.translateTyped(typed)
        typed = ""
    }
}

// MARK: - 组件

struct RouteBanner: View {
    @ObservedObject var router: AudioRouter
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: router.isBluetooth ? "airpodspro" : "exclamationmark.triangle.fill")
                .foregroundStyle(router.isBluetooth ? .green : .yellow)
            VStack(alignment: .leading, spacing: 0) {
                Text(router.isBluetooth ? "已连接：\(router.outputName)" : "未检测到蓝牙耳机")
                    .font(.subheadline.weight(.semibold))
                Text("麦克风：\(router.inputName)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            RoutePicker().frame(width: 36, height: 36)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

/// 系统的 AirPlay / 蓝牙输出选择按钮。
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
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
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.caption2).foregroundStyle(.secondary)
                    Text(selection.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        }
        .foregroundStyle(.primary)
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
                        EmptyHint().padding(.top, 60)
                    }
                    ForEach(vm.items) { u in
                        Bubble(u: u, speaking: speaker.speakingID == u.id,
                               onPlay: { Task { await vm.speak(u) } },
                               onBig: { vm.bigText = u })
                            .id(u.id)
                    }
                    if !listener.partial.isEmpty {
                        if vm.mode == .live {
                            LivePartials(names: [vm.mine.name, vm.theirs.name], texts: listener.partials)
                                .id("partial")
                        } else {
                            Text(listener.partial)
                                .italic()
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: vm.listeningSide == .them ? .leading : .trailing)
                                .id("partial")
                        }
                    }
                }
                .padding()
            }
            .onChange(of: vm.items.count) {
                if let last = vm.items.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: listener.partial) {
                proxy.scrollTo("partial", anchor: .bottom)
            }
        }
    }
}

struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "earbuds").font(.system(size: 52)).foregroundStyle(meColor)
            Text("先连接蓝牙耳机，再按下方按钮说话").font(.headline)
            Text("面对面：轮到谁说就按谁的按钮，说完再按一次。\n同传：持续收听对方语言，译文在耳机里播报。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct Bubble: View {
    let u: Utterance
    let speaking: Bool
    let onPlay: () -> Void
    let onBig: () -> Void

    private var color: Color { u.side == .me ? meColor : themColor }

    var body: some View {
        HStack {
            if u.side == .me { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(u.source).font(.footnote).foregroundStyle(.secondary)
                if let t = u.translation {
                    Text(t).font(.title3.weight(.medium))
                        .foregroundStyle(speaking ? color : .primary)
                } else if let f = u.failed {
                    Text(f).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
                if u.translation != nil {
                    HStack(spacing: 16) {
                        Button(action: onPlay) { Label("播放", systemImage: speaking ? "speaker.wave.3.fill" : "play.fill") }
                        Button(action: onBig) { Label("大字", systemImage: "textformat.size") }
                        Button { UIPasteboard.general.string = u.translation } label: { Label("复制", systemImage: "doc.on.doc") }
                    }
                    .labelStyle(.iconOnly)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.14)))
            .overlay(alignment: u.side == .me ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4).padding(.vertical, 10)
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
                Text(title).font(.headline)
                Text(subtitle).font(.caption2).lineLimit(1).minimumScaleFactor(0.7).opacity(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 22).fill(active ? Color.red : color))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact, trigger: active)
    }
}

/// 全屏大字，可以翻转 180° 直接给对面的人看。
/// 同传时实时显示两种语言正在识别的文字。
struct LivePartials: View {
    let names: [String]
    let texts: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(texts.enumerated()), id: \.offset) { i, t in
                if !t.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(i < names.count ? names[i] : "").font(.caption2.weight(.semibold))
                            .foregroundStyle(i == 0 ? Color.teal : Color.orange)
                        Text(t).italic().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

/// 同传字幕卡片：最新一句的原文和译文，点一下全屏。
struct CaptionCard: View {
    let u: Utterance
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(u.source).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption2).foregroundStyle(.secondary)
                }
                Text(u.translation ?? u.failed ?? "翻译中…")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(u.side == .me ? Color.teal : Color.orange)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}

/// 全屏同传字幕：一直跟着最新一句，同时显示正在识别的文字。
struct LiveCaptionView: View {
    @EnvironmentObject var vm: Interpreter
    @ObservedObject var listener: SpeechListener
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if let u = vm.items.last {
                Text(u.source).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(u.translation ?? "翻译中…")
                    .font(.system(size: 44, weight: .bold))
                    .minimumScaleFactor(0.3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(u.side == .me ? Color.teal : Color.orange)
            } else {
                Text("等待说话…").font(.title).foregroundStyle(.secondary)
            }
            Spacer()
            if !listener.partial.isEmpty {
                LivePartials(names: [vm.mine.name, vm.theirs.name], texts: listener.partials)
            }
            Button("关闭") { dismiss() }.buttonStyle(.bordered)
        }
        .padding(24)
        .animation(.default, value: vm.items.last?.translation)
    }
}

struct BigTextView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var flipped = true

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Text(text)
                .font(.system(size: 44, weight: .semibold))
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
            .padding()
        }
        .onTapGesture { dismiss() }
    }
}
