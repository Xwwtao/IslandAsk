//
//  MarkdownText.swift
//  IslandAsk
//
//  轻量 Markdown 渲染（SPEC 第 6.12 节：完整回答 Markdown 渲染）。
//  SwiftUI 的 Text 只支持行内语法，标题、列表会原样显示 # 和 -；这里按行拆成块，
//  块内再交给 AttributedString(markdown:) 处理粗体、斜体、行内代码、链接。
//  支持：标题、无序/有序列表、引用、代码块、分隔线、表格（等宽原样显示）。
//

import SwiftUI

struct MarkdownText: View {

    let markdown: String
    /// 流式中：按最后一个空行切成「稳定前缀 + 尾部」，前缀只在跨过新段落时才重新解析和排版；
    /// 同时关掉文字选择（大量可选中 Text 的排版开销很大），流结束后再打开。
    var isStreaming = false

    var body: some View {
        if isStreaming {
            let split = MarkdownBlock.streamingSplit(markdown)
            VStack(alignment: .leading, spacing: 8) {
                if !split.stable.isEmpty {
                    MarkdownBlocksView(markdown: split.stable)
                        .equatable()
                }
                if !split.tail.isEmpty {
                    MarkdownBlocksView(markdown: split.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownBlocksView(markdown: markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

/// 解析并渲染一段 Markdown。Equatable：内容没变时 SwiftUI 跳过 body，不重新解析。
private struct MarkdownBlocksView: View, Equatable {

    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownBlock.parse(markdown).enumerated(), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tint.opacity(0.5))
                        .frame(width: 3)
                }
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.footnote.monospaced())
                    .padding(12)
            }
            .scrollIndicators(.hidden)
            .background(.fill.tertiary, in: .rect(cornerRadius: Theme.Radius.inner))
        case .rule:
            Divider()
        }
    }

    /// 行内语法；解析失败就原样显示。
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        return sanitizedLinks(parsed)
    }

    /// 回答来自大模型，截图里的文字可能诱导它输出钓鱼链接或唤起其他 App 的 URL Scheme：
    /// 只保留 http/https 链接，其余去掉链接只留文字；链接文字里看不出真实域名时，在后面标出域名。
    private static func sanitizedLinks(_ parsed: AttributedString) -> AttributedString {
        var result = AttributedString()
        var currentLink: URL?
        var currentText = ""

        func closeLink() {
            defer {
                currentLink = nil
                currentText = ""
            }
            guard let host = currentLink?.host(), !LinkSafety.linkTextShowsHost(currentText, host: host) else { return }
            var label = AttributedString("（\(host)）")
            label.foregroundColor = Color.secondary
            result.append(label)
        }

        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            var safeLink: URL?
            if let url = run.link {
                let scheme = url.scheme?.lowercased()
                if (scheme == "https" || scheme == "http") && url.host() != nil {
                    safeLink = url
                } else {
                    piece.link = nil
                }
            }
            if safeLink != currentLink, currentLink != nil {
                closeLink()
            }
            currentLink = safeLink
            if safeLink != nil {
                currentText += String(piece.characters)
            }
            result.append(piece)
        }
        closeLink()
        return result
    }
}

// MARK: - 块解析

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, indent: Int, text: String)
    case quote(String)
    case code(String)
    case rule

    /// 流式切分：在最后一个不处于代码块内的空行处切开。空行之前的块已经写完，之后不会再变。
    static func streamingSplit(_ markdown: String) -> (stable: String, tail: String) {
        var inFence = false
        var lastSplit: String.Index?
        var lineStart = markdown.startIndex
        while lineStart < markdown.endIndex {
            let lineEnd = markdown[lineStart...].firstIndex(of: "\n") ?? markdown.endIndex
            let line = markdown[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
            } else if line.isEmpty, !inFence, lineEnd < markdown.endIndex {
                lastSplit = markdown.index(after: lineEnd)
            }
            guard lineEnd < markdown.endIndex else { break }
            lineStart = markdown.index(after: lineEnd)
        }
        guard let lastSplit else { return ("", markdown) }
        return (String(markdown[..<lastSplit]), String(markdown[lastSplit...]))
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?
        var table: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushTable() {
            if !table.isEmpty {
                blocks.append(.code(table.joined(separator: "\n")))
                table = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushTable()
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // 代码块：``` 之间原样保留。
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushAll()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                continue
            }

            if trimmed.hasPrefix("|") {
                flushParagraph()
                flushQuote()
                table.append(trimmed)
                continue
            }
            flushTable()

            if let heading = headingLevel(trimmed) {
                flushAll()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let item = listItem(rawLine) {
                flushAll()
                blocks.append(item)
            } else {
                flushQuote()
                paragraph.append(trimmed)
            }
        }

        if let lines = code {
            blocks.append(.code(lines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ rawLine: String) -> MarkdownBlock? {
        let leadingSpaces = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let indent = min(leadingSpaces / 2, 3)
        let line = rawLine.dropFirst(leadingSpaces)

        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return .listItem(marker: "•", indent: indent, text: line.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }

        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return .listItem(
            marker: "\(digits).",
            indent: indent,
            text: afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        )
    }
}

// MARK: - 链接安全

nonisolated enum LinkSafety {

    /// 链接文字本身就是这个域名（或以它为主机的网址）时才不标域名。不能用「文字包含域名」判断：
    /// 文字 bank.com、真实地址 ank.com 也算包含，用户会被误导。
    static func linkTextShowsHost(_ text: String, host: String) -> Bool {
        func normalized(_ value: String) -> String {
            let lowered = value.lowercased()
            return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        let textHost = URL(string: trimmed)?.host() ?? URL(string: "https://\(trimmed)")?.host()
        guard let textHost else { return false }
        return normalized(textHost) == normalized(host)
    }
}
