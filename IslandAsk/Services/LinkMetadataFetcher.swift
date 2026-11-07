//
//  LinkMetadataFetcher.swift
//  IslandAsk
//
//  链接收藏（M-C2，SPEC 第 6.13 节）：抓取网页标题和描述，供快速档整理链接卡片。
//  - 标题：LPMetadataProvider（LinkPresentation）优先，取不到时用页面里的 og:title，再退回 <title>。
//  - 描述：URLSession 读页面（最多 512KB），取 og:description，退回 meta description。
//  - M-C2 补充：正文摘录（最多 3000 字，微信公众号优先取 #js_content）、封面图（og:image / twitter:image）、
//    网站图标（apple-touch-icon / icon，没有时退回 /favicon.ico）。请求头用手机 Safari 的 User-Agent：
//    默认的 CFNetwork UA 会被部分网站当成爬虫，返回精简页或验证页。
//  - 两路并行，各自受同一个超时约束；任何一路失败都只是少了这一项，不抛错（抓不到时只用标题和附注整理）。
//  - 只抓 http / https，其他 scheme 不发请求。
//  - 分享内容只有文字时（微信常这样），用 NSDataDetector 找出第一个 http(s) 链接。
//  日志 category：link。
//

import Foundation
import LinkPresentation
import os

nonisolated struct LinkMetadata: Sendable, Equatable {
    var title: String?
    var description: String?
    /// M-C2 补充：正文摘录，最多 maxExcerptLength 字。
    var excerpt: String?
    /// 封面图、网站图标的绝对地址（已按页面最终地址解析相对路径）。
    var imageURL: URL?
    var iconURL: URL?
    /// 网站拦截了程序读取（403、567、访客验证页等），或者标题、描述、正文全都拿不到。
    var blocked = false

    static let empty = LinkMetadata()
}

nonisolated enum LinkMetadataFetcher {

    /// 页面最多读这么多字节（SPEC 6.13）。
    static let maxPageBytes = 512 * 1024
    /// 读到 maxPageBytes 还没看到正文容器时，最多继续读到这里（微信公众号正文常在 600KB 之后）。
    static let extendedPageBytes = 2 * 1024 * 1024
    /// 找到正文容器后再读这么多就停。
    static let bytesAfterArticleStart = 150 * 1024
    /// 正文容器的标记：读到上限还没出现时才多读。
    static let articleMarkers = [Data(#"id="js_content""#.utf8)]
    /// 网站拦截时返回的状态码：401/403 拒绝、412 前置条件（常见于反爬）、429 限流、451、567（酷安）。
    static let blockedStatusCodes: Set<Int> = [401, 403, 412, 429, 451, 567]
    /// 拦截页、验证页的标题和地址特征。
    static let blockedTitles: Set<String> = ["Sina Visitor System"]
    /// 只看主机名（如 visitor.passport.weibo.cn），路径里出现这些词可能是正常文章（如「护照办理 /passport」）。
    static let blockedHostKeywords = ["visitor", "captcha", "passport", "antispam"]
    /// 网页标题末尾的站名后缀，去掉后来源标题更干净。
    static let titleSiteSuffixes = [" - rednote", " - 小红书", " - 知乎", " - 微博", "_哔哩哔哩_bilibili", " - 哔哩哔哩"]
    /// 发给大模型的描述上限：og:description 偶尔是整段正文。
    static let maxDescriptionLength = 1000
    /// 发给大模型的正文摘录上限（M-C2 补充，用户确认 3000 字）。
    static let maxExcerptLength = 3000
    /// 手机 Safari 的 User-Agent（M-C2 补充，用户确认）。
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.wentao.IslandAsk",
        category: "link"
    )

    // MARK: - 链接识别

    /// 只接受带主机名的 http / https 链接。
    static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return false }
        return true
    }

    /// 文字里第一个 http(s) 链接，以及它在文字里的范围（调用方据此把链接从附注里去掉）。
    static func firstLink(in text: String) -> (url: URL, range: Range<String.Index>)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: nsRange) {
            guard let url = match.url, isFetchable(url), let range = Range(match.range, in: text) else { continue }
            return (url, range)
        }
        return nil
    }

    // MARK: - 抓取

    /// 并行取 LinkPresentation 标题和页面 meta，合并成一份。不抛错：取不到的项为 nil。
    @concurrent
    static func fetch(_ url: URL, timeout: Duration) async -> LinkMetadata {
        guard isFetchable(url) else {
            logger.notice("fetch skipped: unsupported url scheme=\(url.scheme ?? "nil", privacy: .public)")
            return .empty
        }
        let host = url.host() ?? ""
        let startedAt = ContinuousClock.now
        logger.info("fetch start host=\(host, privacy: .public) timeoutMs=\(milliseconds(timeout), privacy: .public)")

        async let presentationTitle = fetchPresentationTitle(url, timeout: timeout)
        async let page = fetchPageMeta(url, timeout: timeout)
        let lpTitle = await presentationTitle
        let pageMeta = await page

        // 被拦截时页面上的标题是拦截页自己的（如「Sina Visitor System」），不用。
        let pageTitle = pageMeta.blocked ? nil : (pageMeta.ogTitle ?? pageMeta.htmlTitle)
        let usableLPTitle = lpTitle.flatMap { blockedTitles.contains($0) ? nil : $0 }
        let title = (usableLPTitle ?? pageTitle).map(stripSiteSuffix)
        let description = pageMeta.description.map { text in
            text.count > maxDescriptionLength ? String(text.prefix(maxDescriptionLength - 1)) + "…" : text
        }
        // 没有声明图标的网站退回根目录的 /favicon.ico（下载失败只是没有图标）。
        let iconURL = pageMeta.blocked ? nil
            : (pageMeta.iconURL ?? pageMeta.finalURL.flatMap { URL(string: "/favicon.ico", relativeTo: $0)?.absoluteURL })
        let blocked = pageMeta.blocked || (title == nil && description == nil && pageMeta.excerpt == nil)
        logger.info(
            "fetch finished host=\(host, privacy: .public) lpTitle=\(lpTitle != nil, privacy: .public) ogTitle=\(pageMeta.ogTitle != nil, privacy: .public) htmlTitle=\(pageMeta.htmlTitle != nil, privacy: .public) descriptionChars=\(description?.count ?? 0, privacy: .public) excerptChars=\(pageMeta.excerpt?.count ?? 0, privacy: .public) hasImage=\(pageMeta.imageURL != nil, privacy: .public) hasIcon=\(pageMeta.iconURL != nil, privacy: .public) blocked=\(blocked, privacy: .public) pageBlocked=\(pageMeta.blocked, privacy: .public) elapsedMs=\(milliseconds(ContinuousClock.now - startedAt), privacy: .public)"
        )
        return LinkMetadata(
            title: title,
            description: description,
            excerpt: pageMeta.excerpt,
            imageURL: pageMeta.imageURL,
            iconURL: iconURL,
            blocked: blocked
        )
    }

    /// 去掉标题末尾的站名后缀（「上海！复联总部大楼已亮灯！！ - rednote」→「上海！复联总部大楼已亮灯！！」）。
    static func stripSiteSuffix(_ title: String) -> String {
        for suffix in titleSiteSuffixes where title.hasSuffix(suffix) && title.count > suffix.count {
            return String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    /// 拦截页判断：状态码，或跳转到了访客验证、验证码之类的地址。
    static func isBlocked(status: Int, finalURL: URL?) -> Bool {
        if blockedStatusCodes.contains(status) { return true }
        guard let host = finalURL?.host()?.lowercased() else { return false }
        return blockedHostKeywords.contains { host.contains($0) }
    }

    /// LPMetadataProvider 取标题。provider 每个实例只能用一次。
    // TODO: 核对官方文档：LPMetadataProvider 能否在后台 App Intent 里使用、是否要求在主线程调用（真机看日志 lpTitle 是否为 true）。
    private static func fetchPresentationTitle(_ url: URL, timeout: Duration) async -> String? {
        let provider = LPMetadataProvider()
        provider.timeout = TimeInterval(milliseconds(timeout)) / 1000
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            return clean(metadata.title)
        } catch {
            logger.notice("presentation title failed host=\(url.host() ?? "", privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    struct PageMeta: Sendable, Equatable {
        var ogTitle: String?
        var htmlTitle: String?
        var description: String?
        var excerpt: String?
        var imageURL: URL?
        var iconURL: URL?
        /// 跳转后的最终地址：解析相对路径、退回 /favicon.ico 用。
        var finalURL: URL?
        var blocked = false
    }

    /// 读页面开头，解析 meta。非 2xx、非 HTML、网络错误都返回空。
    private static func fetchPageMeta(_ url: URL, timeout: Duration) async -> PageMeta {
        let seconds = TimeInterval(milliseconds(timeout)) / 1000
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return PageMeta() }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let finalURL = http.url ?? url
            if isBlocked(status: http.statusCode, finalURL: finalURL) {
                logger.notice(
                    "page fetch blocked status=\(http.statusCode, privacy: .public) host=\(url.host() ?? "", privacy: .public) finalHost=\(finalURL.host() ?? "", privacy: .public)"
                )
                return PageMeta(finalURL: finalURL, blocked: true)
            }
            guard (200..<300).contains(http.statusCode) else {
                logger.notice("page fetch http status=\(http.statusCode, privacy: .public) host=\(url.host() ?? "", privacy: .public)")
                return PageMeta()
            }
            guard contentType.isEmpty || contentType.contains("html") else {
                logger.notice("page fetch skipped: not html contentType=\(contentType, privacy: .public)")
                return PageMeta()
            }
            // M-C2 补充：要读正文，不再在 </head> 处停。平时读到 512KB；到上限还没看到正文容器（微信公众号）
            // 就继续读，最多 2MB，找到容器后再读 150KB 就停。
            var data = Data()
            data.reserveCapacity(256 * 1024)
            var limit = maxPageBytes
            var articleStart: Int?
            var scannedUpTo = 0
            for try await byte in bytes {
                data.append(byte)
                guard data.count >= limit else { continue }
                if articleStart == nil {
                    let from = max(0, scannedUpTo - 32)
                    articleStart = articleMarkers.lazy.compactMap { data[from...].range(of: $0)?.lowerBound }.first
                    scannedUpTo = data.count
                }
                if let articleStart {
                    let stopAt = min(extendedPageBytes, articleStart + bytesAfterArticleStart)
                    if data.count >= stopAt { break }
                    limit = stopAt
                } else if data.count >= extendedPageBytes {
                    break
                } else {
                    // 还没找到：每多读 64KB 再找一次。
                    limit = min(extendedPageBytes, data.count + 64 * 1024)
                }
            }
            let html = String(decoding: data, as: UTF8.self)
            var meta = parsePageMeta(html, baseURL: finalURL)
            if let title = meta.htmlTitle, blockedTitles.contains(title) {
                meta.blocked = true
            }
            logger.info(
                "page fetch finished host=\(url.host() ?? "", privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) articleAt=\(articleStart ?? -1, privacy: .public) finalHost=\(finalURL.host() ?? "", privacy: .public)"
            )
            return meta
        } catch {
            logger.notice("page fetch failed host=\(url.host() ?? "", privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return PageMeta()
        }
    }

    // MARK: - HTML 解析（只做够用的正则，不引入解析库）

    static func parsePageMeta(_ html: String, baseURL: URL? = nil) -> PageMeta {
        var properties: [String: String] = [:]
        for tag in matches(of: #"<meta\b[^>]*>"#, in: html) {
            let attributes = parseAttributes(tag)
            guard let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
                  let content = attributes["content"], properties[key] == nil else { continue }
            properties[key] = content
        }
        let htmlTitle = firstCapture(of: #"<title[^>]*>([\s\S]*?)</title>"#, in: html)
        let imageRaw = properties["og:image"] ?? properties["og:image:url"] ?? properties["twitter:image"]
            ?? properties["image"] ?? wechatCoverURL(in: html)
        return PageMeta(
            ogTitle: clean(properties["og:title"].map(decodeEntities)),
            htmlTitle: clean(htmlTitle.map(decodeEntities)),
            description: clean(
                (properties["og:description"] ?? properties["description"] ?? properties["twitter:description"])
                    .map(decodeEntities)
            ),
            excerpt: extractExcerpt(from: html),
            imageURL: imageRaw.flatMap { resolveWebURL(decodeEntities($0), baseURL: baseURL) },
            iconURL: iconHref(in: html).flatMap { resolveWebURL(decodeEntities($0), baseURL: baseURL) },
            finalURL: baseURL
        )
    }

    // MARK: - 正文摘录

    /// 正文摘录：微信公众号取 id="js_content" 的容器，其次 <article>，再次 <main>，最后 <body>。
    /// 去掉 script / style / noscript / svg / 页眉页脚导航等块，再去标签、解码实体、合并空白，截到 maxExcerptLength。
    /// 太短（< 40 字）的当作没有，避免把「请在微信客户端打开」这类提示当正文。
    static func extractExcerpt(from html: String) -> String? {
        var cleaned = html
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "header", "footer", "nav"] {
            cleaned = cleaned.replacingOccurrences(
                of: "<\(tag)\\b[\\s\\S]*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        cleaned = cleaned.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: " ", options: .regularExpression)

        let container = section(of: cleaned, startPattern: #"<[a-z]+[^>]*\bid\s*=\s*["']js_content["'][^>]*>"#)
            ?? firstCapture(of: #"<article\b[^>]*>([\s\S]*?)</article>"#, in: cleaned)
            ?? firstCapture(of: #"<main\b[^>]*>([\s\S]*?)</main>"#, in: cleaned)
            ?? firstCapture(of: #"<body\b[^>]*>([\s\S]*)"#, in: cleaned)
        guard let container else { return nil }

        // 块级标签换成换行，保留段落感；其他标签直接去掉。
        var text = container.replacingOccurrences(
            of: #"</?(p|div|br|li|h[1-6]|section|tr|blockquote)\b[^>]*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text
            .components(separatedBy: .newlines)
            .compactMap { clean($0) }
        let joined = lines.joined(separator: "\n")
        guard joined.count >= 40 else { return nil }
        return joined.count > maxExcerptLength ? String(joined.prefix(maxExcerptLength - 1)) + "…" : joined
    }

    /// 从 startPattern 匹配处开始取到文本结尾（嵌套 div 无法用正则配对，截断交给长度上限）。
    private static func section(of text: String, startPattern: String) -> String? {
        guard let range = text.range(of: startPattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range.upperBound...])
    }

    // MARK: - 图片地址

    /// 微信公众号文章把封面写在脚本变量 msg_cdn_url 里（og:image 有时缺失）。
    private static func wechatCoverURL(in html: String) -> String? {
        firstCapture(of: #"msg_cdn_url\s*=\s*["']([^"']+)["']"#, in: html)
    }

    /// <link rel="apple-touch-icon"> 优先（尺寸大、清晰），其次 rel="icon" / "shortcut icon"。
    private static func iconHref(in html: String) -> String? {
        var touchIcon: String?
        var icon: String?
        for tag in matches(of: #"<link\b[^>]*>"#, in: html) {
            let attributes = parseAttributes(tag)
            guard let rel = attributes["rel"]?.lowercased(), let href = attributes["href"], !href.isEmpty else { continue }
            if rel.contains("apple-touch-icon"), touchIcon == nil {
                touchIcon = href
            } else if rel.split(separator: " ").contains("icon"), icon == nil {
                icon = href
            }
        }
        return touchIcon ?? icon
    }

    /// 把相对地址、协议相对地址（//cdn...）解析成 http(s) 绝对地址；data: 等其他 scheme 丢弃。
    static func resolveWebURL(_ raw: String, baseURL: URL?) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolved: URL?
        if trimmed.hasPrefix("//") {
            resolved = URL(string: "https:" + trimmed)
        } else if let absolute = URL(string: trimmed), absolute.scheme != nil {
            resolved = absolute
        } else {
            resolved = baseURL.flatMap { URL(string: trimmed, relativeTo: $0)?.absoluteURL }
        }
        guard let resolved, isFetchable(resolved) else { return nil }
        // 安全：图片、图标地址是网页自己声明的，不可信。指向局域网、本机等内网地址的一律丢弃，
        // 防止恶意网页借 App 向用户局域网里的设备发请求（SSRF）。和页面同一主机的除外（用户自己分享的就是内网地址）。
        if let host = resolved.host(), NetworkAddressPolicy.isPrivateHost(host),
           host.lowercased() != baseURL?.host()?.lowercased() {
            return nil
        }
        return resolved
    }

    private static func parseAttributes(_ tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        ) else { return [:] }
        var result: [String: String] = [:]
        let range = NSRange(tag.startIndex..., in: tag)
        for match in regex.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let valueRange = Range(match.range(at: 2), in: tag) ?? Range(match.range(at: 3), in: tag)
            guard let valueRange else { continue }
            let name = tag[nameRange].lowercased()
            if result[name] == nil {
                result[name] = String(tag[valueRange])
            }
        }
        return result
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    /// 常见实体：&amp; &lt; &gt; &quot; &#39; &apos; &nbsp; 以及数字实体 &#123; / &#x1F600;。
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        ]
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let entity = text[text.index(after: index)..<semicolon]
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[entity.lowercased()]
            }
            if let replacement {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    /// 去首尾空白、合并内部换行和连续空白；空串为 nil。
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - 内网地址判断（安全）

/// 判断主机名是不是内网 / 本机地址：IP 字面量在私有、回环、链路本地、CGNAT 等网段，或 localhost、.local 这类本地名字。
/// 只看字面量，不做 DNS 解析（解析到内网的公网域名防不住，属于已知局限）。
nonisolated enum NetworkAddressPolicy {

    static func isPrivateHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") {
            return true
        }
        if let octets = ipv4Octets(host) {
            return isPrivateIPv4(octets)
        }
        if host.contains(":") {
            return isPrivateIPv6(host)
        }
        // 不带点的单段名字（如 router）会按局域网搜索域解析。
        return !host.contains(".")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isPrivateIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (100, 64...127): return true          // CGNAT
        case (198, 18...19): return true           // 基准测试网段
        case (224...255, _): return true           // 组播、保留
        default: return false
        }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%").first.map(String.init) ?? host   // 去掉 zone id
        if address == "::" || address == "::1" { return true }
        if address.hasPrefix("fe8") || address.hasPrefix("fe9") || address.hasPrefix("fea") || address.hasPrefix("feb") {
            return true                             // fe80::/10 链路本地
        }
        if address.hasPrefix("fc") || address.hasPrefix("fd") { return true }   // fc00::/7 唯一本地
        if address.hasPrefix("ff") { return true }  // 组播
        // IPv4 映射地址 ::ffff:a.b.c.d
        if address.hasPrefix("::ffff:"), let octets = ipv4Octets(String(address.dropFirst(7))) {
            return isPrivateIPv4(octets)
        }
        return false
    }
}
