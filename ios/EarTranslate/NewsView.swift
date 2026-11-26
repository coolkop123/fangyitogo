import SwiftUI
import AVKit

/// 4. 酷天新闻：原生新闻列表，内容和 coolnews.ca 一致（来自 CoolTok 新闻版块）。
struct NewsView: View {
    enum NewsSection: Hashable { case articles, videos }
    @StateObject private var store = NewsStore()
    @State private var section: NewsSection = .articles
    @State private var category = "全部"
    @State private var query = ""
    @State private var playing: NewsItem?
    @State private var path: [NewsItem] = []

    private var filtered: [NewsItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.articles.filter {
            (category == "全部" || $0.category == category) &&
            (q.isEmpty || ($0.title + $0.body.joined()).lowercased().contains(q))
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                CapsuleSwitch(value: $section, options: [(.articles, "图文新闻"), (.videos, "视频新闻")])
                content
            }
            .background(Theme.bg.ignoresSafeArea())
            .foregroundStyle(Theme.ink)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: NewsItem.self) { ArticleReader(item: $0) }
            .fullScreenCover(item: $playing) { VideoPlayerScreen(item: $0) }
            .task { if store.syncedAt == nil { await store.refresh() } }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("CoolNewsLogo")
                .resizable().scaledToFit()
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("酷天新闻 Cool News")
            VStack(alignment: .leading, spacing: 2) {
                Text("温哥华 · 加拿大 · 全球华人资讯").font(.caption).foregroundStyle(Theme.mute)
                Text(store.syncedAt.map { "已同步 \(NewsTime.full($0))" } ?? (store.loading ? "正在同步…" : " "))
                    .font(.caption2).foregroundStyle(Theme.mute)
            }
            Spacer()
            Button { Task { await store.refresh() } } label: { CircleIcon(system: "arrow.clockwise") }
                .disabled(store.loading)
                .accessibilityLabel("同步最新")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if let err = store.error, store.articles.isEmpty && store.videos.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 44)).foregroundStyle(Theme.them)
                Text("新闻加载失败").font(.headline)
                Text(err).font(.footnote).foregroundStyle(Theme.mute).multilineTextAlignment(.center)
                Button("重试") { Task { await store.refresh() } }.buttonStyle(.borderedProminent).tint(Theme.me)
                Link("在网页上看 coolnews.ca", destination: URL(string: "https://coolnews.ca")!).font(.footnote)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.loading && store.articles.isEmpty && store.videos.isEmpty {
            ProgressView("正在加载新闻…").tint(Theme.mute).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if section == .articles {
            articleList
        } else {
            videoList
        }
    }

    private var articleList: some View {
        List {
            Group {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(NewsStore.categories, id: \.self) { c in
                            Button { category = c } label: {
                                Text(c).font(.subheadline.weight(category == c ? .bold : .regular))
                                    .padding(.horizontal, 14).frame(minHeight: 34)
                                    .foregroundStyle(category == c ? Theme.bg : Theme.mute)
                                    .background(Capsule().fill(category == c ? Theme.ink : Theme.panel))
                                    .overlay(Capsule().strokeBorder(Theme.line))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.mute)
                    TextField("", text: $query, prompt: Text("搜索新闻标题或正文…").foregroundStyle(Theme.mute))
                        .submitLabel(.search)
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))

                if filtered.isEmpty {
                    Text("没有找到符合条件的新闻，换个关键词试试。")
                        .font(.subheadline).foregroundStyle(Theme.mute)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(filtered) { a in
                    Button { path.append(a) } label: { NewsRow(item: a) }
                        .buttonStyle(.plain)
                }
                if category == "全部", query.isEmpty, store.canLoadMore {
                    Button {
                        Task { await store.loadMore() }
                    } label: {
                        Text(store.loadingMore ? "加载中…" : "加载更多新闻")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.loadingMore)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await store.refresh() }
    }

    private var videoList: some View {
        List {
            Group {
                if store.videos.isEmpty {
                    Text("暂无视频新闻").foregroundStyle(Theme.mute).frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(store.videos) { v in
                    Button { playing = v } label: { NewsRow(item: v) }
                        .buttonStyle(.plain)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
    }
}

/// 列表里的一行：左图右文。
struct NewsRow: View {
    let item: NewsItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: item.image) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Theme.line)
                }
                .frame(width: 118, height: item.kind == .video ? 66 : 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if item.kind == .video {
                    Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white)
                        .padding(5).background(Circle().fill(.black.opacity(0.55))).padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 16, weight: .semibold)).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.kind == .video ? "\(item.author) · \(NewsTime.relative(item.time))"
                                         : "\(item.category) · \(NewsTime.relative(item.time))")
                    .font(.caption).foregroundStyle(Theme.mute)
            }
            ShareLink(item: item.shareURL, subject: Text(item.title), message: Text(item.title)) {
                Image(systemName: "arrowshape.turn.up.right").font(.footnote).foregroundStyle(Theme.mute)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("转发")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .contentShape(Rectangle())
    }
}

/// 图文新闻全文。
struct ArticleReader: View {
    let item: NewsItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("图文新闻 · \(item.category)").font(.caption.weight(.bold)).foregroundStyle(Theme.them)
                Text(item.title).font(.system(size: 26, weight: .heavy)).lineSpacing(4)
                Text("\(NewsTime.full(item.time))（温哥华时间）\(item.views > 0 ? " · 阅读 \(item.views)" : "")")
                    .font(.footnote).foregroundStyle(Theme.mute)
                if let img = item.image {
                    VStack(alignment: .leading, spacing: 6) {
                        AsyncImage(url: img) { $0.resizable().scaledToFit() } placeholder: {
                            Rectangle().fill(Theme.line).frame(height: 200)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        if !item.imgSource.isEmpty {
                            Text(item.imgSource).font(.caption).foregroundStyle(Theme.mute)
                        }
                    }
                }
                ForEach(Array(item.body.enumerated()), id: \.offset) { _, p in
                    Text("\u{3000}\u{3000}" + p).font(.system(size: 18)).lineSpacing(8)
                        .textSelection(.enabled)
                }
                if !item.source.isEmpty {
                    Divider().overlay(Theme.line)
                    Text(item.source).font(.footnote).foregroundStyle(Theme.mute)
                }
            }
            .padding(18)
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: item.shareURL, subject: Text(item.title), message: Text(item.title))
            }
        }
    }
}

/// 视频新闻播放（全屏）。
struct VideoPlayerScreen: View {
    let item: NewsItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { dismiss() } label: { CircleIcon(system: "xmark") }
                Spacer()
                ShareLink(item: item.shareURL, subject: Text(item.title), message: Text(item.title)) {
                    CircleIcon(system: "square.and.arrow.up")
                }
            }
            Spacer(minLength: 0)
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.title).font(.title3.weight(.bold))
            if !item.sub.isEmpty { Text(item.sub).font(.subheadline).foregroundStyle(Theme.mute) }
            Text("\(item.author) · \(NewsTime.full(item.time))").font(.footnote).foregroundStyle(Theme.mute)
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.ink)
        .onAppear {
            guard let url = item.video else { return }
            // 播新闻视频时用普通播放模式（不录音），声音走扬声器或耳机
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            // 恢复翻译用的音频设置
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
        }
    }
}
