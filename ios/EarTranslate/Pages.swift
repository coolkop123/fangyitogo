import SwiftUI
import Translation

/// 底部五个标签页。
enum AppTab: Hashable { case home, talk, photo, news, me }

struct RootView: View {
    @EnvironmentObject var vm: Interpreter
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("首页", systemImage: "waveform.circle.fill", value: AppTab.home) { HomeView() }
            Tab("对话翻译", systemImage: "bubble.left.and.bubble.right.fill", value: AppTab.talk) { ConversationView() }
            Tab("图片翻译", systemImage: "camera.viewfinder", value: AppTab.photo) { PhotoTranslateView() }
            Tab("酷天新闻", systemImage: "newspaper.fill", value: AppTab.news) { NewsView() }
            Tab("我的", systemImage: "person.crop.circle.fill", value: AppTab.me) { MeView() }
        }
        .tint(Theme.me)
        .preferredColorScheme(.dark)
        .onChange(of: tab) {
            // 换页时停止收音，并切换同传 / 对话模式
            vm.stopListening()
            vm.mode = tab == .talk ? .talk : .live
        }
        .fullScreenCover(item: $vm.bigText) { u in BigTextView(text: u.translation ?? u.source) }
        .alert("提示", isPresented: Binding(get: { vm.errorMessage != nil },
                                          set: { if !$0 { vm.errorMessage = nil } })) {
            Button("好") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
        .onReceive(vm.speaker.$problem) { p in
            if let p { vm.errorMessage = p; vm.speaker.problem = nil }
        }
        // 两个方向的翻译会话一直保持，所有页面共用
        .translationTask(vm.configMeToThem) { session in await vm.serve(session, side: .me) }
        .translationTask(vm.configThemToMe) { session in await vm.serve(session, side: .them) }
        .onAppear { vm.prepare() }
    }
}

// MARK: - 共用的页面头部和语言栏

struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 26, weight: .heavy))
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

struct LanguageBar: View {
    @EnvironmentObject var vm: Interpreter
    var body: some View {
        HStack(spacing: 8) {
            LangPicker(title: "我", color: Theme.me, selection: $vm.mine)
            Button { vm.swapLanguages() } label: { CircleIcon(system: "arrow.left.arrow.right") }
                .accessibilityLabel("交换语言")
            LangPicker(title: "对方", color: Theme.them, selection: $vm.theirs)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct SpeakerToggle: View {
    @EnvironmentObject var vm: Interpreter
    var body: some View {
        Button { vm.allSpeaker.toggle() } label: {
            CircleIcon(system: "speaker.wave.3.fill", on: vm.allSpeaker)
        }
        .accessibilityLabel(vm.allSpeaker ? "手机外放：开" : "手机外放：关")
    }
}

struct ClearMenu: View {
    @EnvironmentObject var vm: Interpreter
    let origin: Origin
    var body: some View {
        Menu {
            Button("复制全部记录", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = vm.items(origin).map { "\($0.source)\n→ \($0.translation ?? "")" }.joined(separator: "\n\n")
            }
            Button("清空记录", systemImage: "trash", role: .destructive) { vm.clear(origin) }
        } label: { CircleIcon(system: "ellipsis") }
        .disabled(vm.items(origin).isEmpty)
    }
}

/// 两个选项的胶囊切换。
struct CapsuleSwitch<T: Hashable>: View {
    @Binding var value: T
    let options: [(T, String)]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { opt in
                Button { value = opt.0 } label: {
                    Text(opt.1)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .foregroundStyle(value == opt.0 ? Theme.bg : Theme.mute)
                        .background(Capsule().fill(value == opt.0 ? Theme.ink : .clear))
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
}

// MARK: - 1. 首页：同声翻译、打字翻译

struct HomeView: View {
    enum HomeSection: Hashable { case live, typing }
    @EnvironmentObject var vm: Interpreter
    @State private var section: HomeSection = .live
    @State private var showCaptions = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "酷天同声") {
                ClearMenu(origin: section == .live ? .live : .typed)
                SpeakerToggle()
            }
            CapsuleSwitch(value: $section, options: [(.live, "同声翻译"), (.typing, "打字翻译")])
            LanguageBar()
            if section == .live {
                RouteBanner(router: vm.router)
                Transcript(listener: vm.listener, speaker: vm.speaker, origin: .live)
                LiveStage(listener: vm.listener) { showCaptions = true }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                TalkButton(title: vm.listeningSide == nil ? "开始同传" : "停止同传",
                           subtitle: "自动识别 \(vm.mine.name) ⇄ \(vm.theirs.name)，\(vm.allSpeaker ? "外放" : "耳机里播")译文",
                           color: Theme.ink,
                           active: vm.listeningSide != nil) { Task { await vm.toggle(.them) } }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                TypingView()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .onChange(of: section) { vm.stopListening() }
        .fullScreenCover(isPresented: $showCaptions) { LiveCaptionView(listener: vm.listener).environmentObject(vm) }
    }
}

struct TypingView: View {
    @EnvironmentObject var vm: Interpreter
    @State private var text = ""
    @State private var side: Side = .me      // .me：我的语言 → 对方语言
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(side == .me ? vm.mine.name : vm.theirs.name)  →  \(side == .me ? vm.theirs.name : vm.mine.name)")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.mute)
                    Spacer()
                    Button { side = side == .me ? .them : .me } label: {
                        Label("换方向", systemImage: "arrow.up.arrow.down").font(.footnote)
                    }
                    .foregroundStyle(Theme.me)
                }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("输入要翻译的文字…").foregroundStyle(Theme.mute).padding(.top, 8).padding(.leading, 5)
                    }
                    TextEditor(text: $text)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90, maxHeight: 150)
                }
                HStack {
                    if !text.isEmpty {
                        Button("清除") { text = "" }.foregroundStyle(Theme.mute)
                    }
                    Spacer()
                    Button {
                        vm.translateTyped(text, side: side)
                        text = ""
                        focused = false
                    } label: {
                        Text("翻译").font(.headline).foregroundStyle(Theme.bg)
                            .padding(.horizontal, 24).frame(minHeight: 42)
                            .background(Capsule().fill(Theme.me))
                    }
                    .buttonStyle(.plain)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
            .padding(.horizontal, 14)

            Transcript(listener: vm.listener, speaker: vm.speaker, origin: .typed)
        }
    }
}

// MARK: - 2. 对话翻译（面对面）

struct ConversationView: View {
    @EnvironmentObject var vm: Interpreter
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "对话翻译") {
                ClearMenu(origin: .talk)
                SpeakerToggle()
            }
            RouteBanner(router: vm.router)
            LanguageBar()
            Transcript(listener: vm.listener, speaker: vm.speaker, origin: .talk)
            if vm.listeningSide != nil {
                ListenStatus(listener: vm.listener)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
    }
}

// MARK: - 5. 我的

struct MeView: View {
    var body: some View {
        SettingsView(embedded: true)
    }
}
