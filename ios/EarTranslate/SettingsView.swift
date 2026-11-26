import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var vm: Interpreter
    @Environment(\.dismiss) private var dismiss
    /// 放在「我的」标签页里时为 true（不显示「完成」按钮，多一个「关于」）。
    var embedded = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v)（\(b)）"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("语言") {
                    Picker("我的语言", selection: $vm.mine) {
                        ForEach(Lang.all) { Text($0.name).tag($0) }
                    }
                    Picker("对方语言", selection: $vm.theirs) {
                        ForEach(Lang.all) { Text($0.name).tag($0) }
                    }
                }
                Section("播报") {
                    Button {
                        Task { await vm.testSpeaker() }
                    } label: {
                        Label("试听外放（从手机扬声器播一句）", systemImage: "speaker.wave.2.fill")
                    }
                    Toggle("译文自动播报", isOn: $vm.autoSpeak)
                    Toggle(isOn: $vm.allSpeaker) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("全部用手机外放")
                            Text("连着耳机也从手机扬声器大声播放；播放时暂停收音，防止回声")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("我说的译文", selection: $vm.myOutput) {
                        ForEach(MyOutput.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(vm.allSpeaker)
                    VStack(alignment: .leading) {
                        Text("语速")
                        Slider(value: $vm.speechRate, in: 0.35...0.62) {
                            Text("语速")
                        } minimumValueLabel: { Image(systemName: "tortoise") }
                          maximumValueLabel: { Image(systemName: "hare") }
                    }
                }
                Section {
                    Picker("收音灵敏度", selection: $vm.sensitivity) {
                        Text("标准").tag(1.0)
                        Text("高（推荐）").tag(4.0)
                        Text("很高").tag(10.0)
                    }
                } header: { Text("收音") } footer: {
                    Text("小声说话识别不出来时调高。周围很吵时，灵敏度太高可能把旁边的人声也识别进来。")
                }
                Section {
                    VStack(alignment: .leading) {
                        Text("停顿 \(vm.silenceTimeout, specifier: "%.1f") 秒算一句")
                        Slider(value: $vm.silenceTimeout, in: 0.6...2.5, step: 0.1)
                    }
                } header: { Text("同传收听") } footer: {
                    Text("数值越小出字越快，但长句可能被切断。")
                }
                if embedded {
                    Section("关于") {
                        LabeledContent("版本", value: version)
                        Link(destination: URL(string: "https://coolnews.ca")!) { Label("酷天新闻网站", systemImage: "newspaper") }
                        Link(destination: URL(string: "https://fangyitogo-app.pages.dev/support.html")!) { Label("技术支持", systemImage: "questionmark.circle") }
                        Link(destination: URL(string: "https://fangyitogo-app.pages.dev/privacy.html")!) { Label("隐私政策", systemImage: "hand.raised") }
                    }
                }
                Section("耳机使用说明") {
                    Label("在 设置 › 蓝牙 中连接耳机，任何蓝牙耳机都可以。", systemImage: "1.circle")
                    Label("App 会优先用耳机麦克风收音，译文从耳机播出。", systemImage: "2.circle")
                    Label("面对面时，我说的译文默认从手机外放给对方听；对方说的译文只在我的耳机里播。", systemImage: "3.circle")
                    Label("想要更自然的声音：设置 › 辅助功能 › 朗读内容 › 声音，下载「增强」或「高级」语音。", systemImage: "4.circle")
                    Label("第一次用某种语言时，系统会提示下载离线翻译包，之后不联网也能翻译。", systemImage: "5.circle")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(embedded ? "我的" : "设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            }
            .tint(Theme.me)
            .preferredColorScheme(.dark)
        }
    }
}
