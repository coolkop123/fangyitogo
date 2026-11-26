import Foundation

/// 一条酷天新闻（图文或视频）。数据来自 CoolTok 公开新闻接口，和 coolnews.ca 网站一致。
struct NewsItem: Identifiable, Hashable {
    enum Kind: Hashable { case article, video }
    let id: String
    let kind: Kind
    let title: String
    let sub: String            // 视频的英文副标题
    let body: [String]         // 图文正文段落
    let imgSource: String      // 「图片来源：…」
    let source: String         // 「来源：…」
    let image: URL?            // 图文配图 / 视频封面
    let video: URL?
    let time: Date
    let author: String
    let likes: Int
    let views: Int
    let category: String

    var shareURL: URL { URL(string: "https://coolnews.ca/?news=\(id)")! }
}

@MainActor
final class NewsStore: ObservableObject {
    @Published private(set) var videos: [NewsItem] = []
    @Published private(set) var articles: [NewsItem] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var error: String?
    @Published private(set) var syncedAt: Date?
    private var articlePage = 0
    private var articleTotal = 0

    static let api = "https://api.coollive.net/app-api/moment/page"
    var canLoadMore: Bool { articles.count < articleTotal }

    /// 和网站一样：视频取前 2 页（每页 10 条），图文取前 3 页（每页 20 条）。
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        async let v1 = Self.fetch(type: 3, page: 1, size: 10)
        async let v2 = Self.fetch(type: 3, page: 2, size: 10)
        async let a1 = Self.fetch(type: 2, page: 1, size: 20)
        async let a2 = Self.fetch(type: 2, page: 2, size: 20)
        async let a3 = Self.fetch(type: 2, page: 3, size: 20)
        let (rv1, rv2, ra1, ra2, ra3) = await (v1, v2, a1, a2, a3)
        guard case .success(let pv1) = rv1, case .success(let pa1) = ra1 else {
            if case .failure(let e) = ra1 { error = e.localizedDescription }
            else if case .failure(let e) = rv1 { error = e.localizedDescription }
            return
        }
        let vids = pv1.list + ((try? rv2.get())?.list ?? [])
        videos = Self.unique(vids.compactMap { Self.parseVideo($0) })
        let arts = pa1.list + ((try? ra2.get())?.list ?? []) + ((try? ra3.get())?.list ?? [])
        articles = Self.unique(arts.compactMap { Self.parseArticle($0) })
        articleTotal = pa1.total
        articlePage = 3
        error = nil
        syncedAt = Date()
    }

    func loadMore() async {
        guard !loadingMore, canLoadMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if case .success(let p) = await Self.fetch(type: 2, page: articlePage + 1, size: 20) {
            articlePage += 1
            let seen = Set(articles.map(\.id))
            articles += p.list.compactMap { Self.parseArticle($0) }.filter { !seen.contains($0.id) }
        }
    }

    // MARK: - 网络

    struct Page { let list: [[String: Any]]; let total: Int }
    struct APIError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    nonisolated static func fetch(type: Int, page: Int, size: Int) async -> Result<Page, Error> {
        var c = URLComponents(string: api)!
        c.queryItems = [
            .init(name: "pageNo", value: "\(page)"), .init(name: "pageSize", value: "\(size)"),
            .init(name: "bizType", value: "2"), .init(name: "type", value: "\(type)"),
        ]
        var req = URLRequest(url: c.url!, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw APIError(msg: "服务器返回 \(h.statusCode)") }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  num(root["code"]) == 0, let d = root["data"] as? [String: Any] else {
                throw APIError(msg: "新闻数据格式不对")
            }
            return .success(Page(list: d["list"] as? [[String: Any]] ?? [], total: num(d["total"]) ?? 0))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 解析（和网站 index.html 里的逻辑一致）

    nonisolated static func num(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
    nonisolated static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let i = num(v) { return String(i) }
        return nil
    }
    nonisolated static func date(_ m: [String: Any]) -> Date {
        let raw = m["createTime"] ?? m["t"]
        var ms: Double = 0
        if let d = raw as? Double { ms = d } else if let i = raw as? Int { ms = Double(i) }
        else if let s = raw as? String { ms = Double(s) ?? 0 }
        return Date(timeIntervalSince1970: ms > 1e11 ? ms / 1000 : ms)
    }
    nonisolated static func url(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        return URL(string: s)
    }
    nonisolated static func unique(_ items: [NewsItem]) -> [NewsItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    nonisolated static func parseArticle(_ m: [String: Any]) -> NewsItem? {
        guard let id = str(m["momentId"]) ?? str(m["id"]) else { return nil }
        let lines = (m["content"] as? String ?? "").components(separatedBy: "\n")
        let title = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !title.isEmpty else { return nil }
        var body: [String] = [], imgSrc = "", src = ""
        for raw in lines.dropFirst() {
            let ln = raw.trimmingCharacters(in: .whitespaces)
            if ln.isEmpty { continue }
            if ln.hasPrefix("图片来源：") { imgSrc = ln; continue }
            if ln.hasPrefix("来源：") { src = ln; continue }
            body.append(ln.replacingOccurrences(of: "^\u{3000}+", with: "", options: .regularExpression))
        }
        let img = (m["img"] as? String) ?? ((m["imageList"] as? [[String: Any]])?.first?["imageUrl"] as? String)
        return NewsItem(id: id, kind: .article, title: title, sub: "", body: body, imgSource: imgSrc, source: src,
                        image: url(img), video: nil, time: date(m), author: "酷天新闻",
                        likes: num(m["likeCount"]) ?? num(m["likes"]) ?? 0,
                        views: num(m["viewCount"]) ?? num(m["views"]) ?? 0,
                        category: classify(title: title, firstPara: body.first ?? ""))
    }

    nonisolated static func parseVideo(_ m: [String: Any]) -> NewsItem? {
        guard let id = str(m["momentId"]) ?? str(m["id"]),
              let video = url((m["videoUrl"] as? String) ?? (m["video"] as? String)) else { return nil }
        let lines = (m["content"] as? String ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let raw = (lines.first ?? "").components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? ""
        var title = raw, sub = ""
        // 「中文标题 English Subtitle」拆成标题和英文副标题
        if let re = try? NSRegularExpression(pattern: "^([\\u4e00-\\u9fff0-9\\s，。、：；·—「」《》%％]+?)\\s*([A-Za-z][A-Za-z0-9\\s,.'&:/-]*)$"),
           let r = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let r1 = Range(r.range(at: 1), in: raw), let r2 = Range(r.range(at: 2), in: raw),
           raw[r2].filter({ !$0.isWhitespace }).count >= 8 {
            title = raw[r1].trimmingCharacters(in: .whitespaces)
            sub = raw[r2].trimmingCharacters(in: .whitespaces)
        }
        if sub.isEmpty, lines.count > 1, lines[1].range(of: "[A-Za-z]", options: .regularExpression) != nil, !lines[1].hasPrefix("#") {
            sub = lines[1].components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let nick = ((m["user"] as? [String: Any])?["nickname"] as? String)?.trimmingCharacters(in: .whitespaces)
        return NewsItem(id: id, kind: .video, title: title.isEmpty ? "视频新闻" : title, sub: sub, body: [],
                        imgSource: "", source: "",
                        image: url((m["videoThumbUrl"] as? String) ?? (m["thumb"] as? String)), video: video,
                        time: date(m), author: (m["author"] as? String) ?? (nick?.isEmpty == false ? nick! : "酷天新闻"),
                        likes: num(m["likeCount"]) ?? num(m["likes"]) ?? 0,
                        views: num(m["viewCount"]) ?? num(m["views"]) ?? 0,
                        category: "视频")
    }

    static let categories = ["全部", "本地", "加拿大", "美国", "中国", "港澳台", "国际", "体育", "财经"]
    nonisolated static let rules: [(String, [String])] = [
        ("本地", ["温哥华", "列治文", "本拿比", "素里", "高贵林", "大温", "卑诗", "BC省", "兰里", "白石", "新西敏", "北温", "西温", "三角洲", "枫树岭", "阿伯茨福德"]),
        ("加拿大", ["加拿大", "渥太华", "多伦多", "卡尔加里", "埃德蒙顿", "蒙特利尔", "安大略", "魁北克", "阿尔伯塔", "特鲁多", "卡尼", "联邦"]),
        ("美国", ["美国", "华盛顿", "纽约", "加州", "洛杉矶", "特朗普", "白宫", "美联储", "硅谷", "德州", "佛州"]),
        ("中国", ["中国", "北京", "上海", "广东", "深圳", "广州", "国务院", "外交部", "人民币", "A股", "港股"]),
        ("港澳台", ["香港", "澳门", "台湾", "台北", "港府"]),
        ("体育", ["足球", "篮球", "NBA", "世界杯", "奥运", "冰球", "Canucks", "联赛", "冠军"]),
        ("财经", ["股市", "油价", "金价", "利率", "通胀", "楼市", "房价", "经济", "财报", "股价", "汇率"]),
    ]
    nonisolated static func classifyIn(_ t: String) -> String? {
        for (cat, kws) in rules where kws.contains(where: { t.contains($0) }) { return cat }
        return nil
    }
    /// 先看标题；标题判断不了再看第一段（去掉「温哥华时间」这类日期行，避免误判）。
    nonisolated static func classify(title: String, firstPara: String) -> String {
        if let c = classifyIn(title) { return c }
        return classifyIn((title + " " + firstPara).replacingOccurrences(of: "温哥华时间", with: "")) ?? "国际"
    }
}

/// 时间显示（温哥华时间）。
enum NewsTime {
    static let vancouver = TimeZone(identifier: "America/Vancouver")!
    static func full(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN"); f.timeZone = vancouver
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60))) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        if s < 7 * 86400 { return "\(Int(s / 86400)) 天前" }
        return full(d)
    }
}
