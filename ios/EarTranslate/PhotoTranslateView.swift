import SwiftUI
import PhotosUI
import Vision
import Translation

/// 图片里识别出的一行文字和它的译文。
struct PhotoLine: Identifiable {
    let id = UUID()
    let text: String
    var translation: String?
}

/// 3. 图片翻译：从相册选图或拍照，在手机上离线识别文字（Vision），再离线翻译。
struct PhotoTranslateView: View {
    @EnvironmentObject var vm: Interpreter
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var lines: [PhotoLine] = []
    @State private var status = ""
    @State private var showCamera = false
    @State private var showActions = false
    @State private var toMine = true                     // 翻译成我的语言（否则翻译成对方语言）
    @State private var config: TranslationSession.Configuration?

    private var target: Lang { toMine ? vm.mine : vm.theirs }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "图片翻译") {
                Button { showActions = true } label: { CircleIcon(system: "ellipsis") }
                    .disabled(lines.isEmpty && image == nil)
                    .accessibilityLabel("更多")
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    BigChoice(icon: "photo.on.rectangle", title: "手机图片", subtitle: "从相册选择")
                }
                .buttonStyle(.plain)
                Button { showCamera = true } label: {
                    BigChoice(icon: "camera.fill", title: "拍照翻译", subtitle: "对准文字拍一张")
                }
                .buttonStyle(.plain)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            }
            .padding(.horizontal, 14)

            CapsuleSwitch(value: $toMine, options: [(true, "翻译成 \(vm.mine.name)"), (false, "翻译成 \(vm.theirs.name)")])
                .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let image {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .frame(maxWidth: .infinity)
                    }
                    if !status.isEmpty {
                        Text(status).font(.footnote.weight(.semibold)).foregroundStyle(Theme.mute)
                    }
                    if lines.isEmpty && image == nil {
                        VStack(spacing: 10) {
                            Image(systemName: "text.viewfinder").font(.system(size: 54)).foregroundStyle(Theme.me)
                            Text("拍菜单、路牌、说明书，或者从相册选一张图").font(.headline)
                            Text("文字识别和翻译都在手机上离线完成，图片不会上传。")
                                .font(.subheadline).foregroundStyle(Theme.mute).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    ForEach(lines) { l in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l.text).font(.footnote).foregroundStyle(Theme.mute)
                            Text(l.translation ?? "翻译中…")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(l.translation == nil ? Theme.mute : Theme.ink)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                    }
                }
                .padding(14)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .confirmationDialog("图片翻译", isPresented: $showActions, titleVisibility: .hidden) {
            Button("复制全部译文") {
                UIPasteboard.general.string = lines.map { $0.translation ?? $0.text }.joined(separator: "\n")
                status = "已复制全部译文"
            }
            Button("复制原文和译文") {
                UIPasteboard.general.string = lines.map { "\($0.text)\n→ \($0.translation ?? "")" }.joined(separator: "\n\n")
                status = "已复制原文和译文"
            }
            Button("清空记录", role: .destructive) {
                lines = []; image = nil; status = ""; pickerItem = nil
            }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: pickerItem) {
            guard let item = pickerItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    await process(img)
                } else {
                    status = "这张图片读取失败，请换一张试试"
                }
                pickerItem = nil
            }
        }
        .onChange(of: toMine) { retranslate() }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in Task { await process(img) } }
                .ignoresSafeArea()
        }
        .translationTask(config) { session in await translateAll(session) }
    }

    // MARK: - 识别和翻译

    private func process(_ img: UIImage) async {
        image = img
        lines = []
        status = "正在识别文字…"
        let texts = await Self.recognize(img)
        if texts.isEmpty {
            status = "没有在图片里找到文字，请拍得更清楚一些"
            return
        }
        lines = texts.map { PhotoLine(text: $0) }
        status = "识别到 \(texts.count) 行文字，正在翻译…"
        retranslate()
    }

    /// 重新触发翻译会话（源语言自动识别，目标语言按选择）。
    private func retranslate() {
        guard !lines.isEmpty else { return }
        for i in lines.indices { lines[i].translation = nil }
        if config?.target == target.language {
            config?.invalidate()
        } else {
            config = TranslationSession.Configuration(source: nil, target: target.language)
        }
    }

    private func translateAll(_ session: TranslationSession) async {
        let snapshot = lines
        let requests = snapshot.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
        do {
            let responses = try await session.translations(from: requests)
            for r in responses {
                if let id = r.clientIdentifier, let i = lines.firstIndex(where: { $0.id.uuidString == id }) {
                    lines[i].translation = r.targetText
                }
            }
            status = "共 \(lines.count) 行"
        } catch {
            // 整批失败（比如一张图里混了好几种语言）：逐行再试
            for l in snapshot {
                let out = try? await session.translate(l.text)
                if let i = lines.firstIndex(where: { $0.id == l.id }) {
                    lines[i].translation = out?.targetText ?? l.text
                }
            }
            status = "共 \(lines.count) 行（部分文字可能已经是\(target.name)，保留原文）"
        }
    }

    /// 用 Vision 在手机上离线识别图片里的文字，按从上到下的顺序返回每一行。
    static func recognize(_ img: UIImage) async -> [String] {
        guard let cg = img.cgImage else { return [] }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            let obs = try await request.perform(on: cg, orientation: CGImagePropertyOrientation(img.imageOrientation))
            return obs                                   // Vision 已按阅读顺序返回
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } catch {
            return []
        }
    }
}

struct BigChoice: View {
    let icon: String
    let title: String
    let subtitle: String
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title)
            Text(title).font(.headline.weight(.heavy))
            Text(subtitle).font(.caption).opacity(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 108)
        .foregroundStyle(Theme.bg)
        .background(RoundedRectangle(cornerRadius: 20).fill(icon.hasPrefix("camera") ? Theme.them : Theme.me))
        .opacity(enabled ? 1 : 0.4)
    }
}

/// 调用系统相机拍照。
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
