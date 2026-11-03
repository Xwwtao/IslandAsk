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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownBlock.parse(markdown).enumerated(), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
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
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
