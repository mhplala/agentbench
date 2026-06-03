import SwiftUI

// Lightweight Markdown renderer for agent answer text: headings, bold/italic/`code`
// (inline), bullet & ordered lists, blockquotes, fenced code blocks, tables, dividers.
//
// PERF: parsing + AttributedString(markdown:) is expensive and `body` is recomputed on
// every scroll frame, so the fully-parsed document (with inline AttributedStrings
// precomputed) is cached by text in an NSCache — body just renders the cached blocks.
struct MarkdownText: View {
    let text: String
    var base: CGFloat = 13.5

    var body: some View {
        let blocks = Self.cached(text)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(blocks.indices, id: \.self) { i in render(blocks[i]) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    enum Block {
        case heading(Int, AttributedString), bullet(AttributedString), ordered(String, AttributedString)
        case quote(AttributedString), code(String), rule, paragraph(AttributedString), blank
        case table([AttributedString], [[AttributedString]])
    }

    @ViewBuilder private func render(_ b: Block) -> some View {
        switch b {
        case .heading(let lvl, let s):
            Text(s).font(Theme.ui(lvl <= 1 ? 18 : lvl == 2 ? 16 : 14.5, .bold))
                .foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
        case .bullet(let s):
            HStack(alignment: .top, spacing: 7) {
                Text("•").font(Theme.ui(base)).foregroundStyle(Theme.ink3)
                Text(s).font(Theme.ui(base)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ordered(let m, let s):
            HStack(alignment: .top, spacing: 7) {
                Text(m).font(Theme.ui(base, .semibold)).foregroundStyle(Theme.ink3).monospacedDigit()
                Text(s).font(Theme.ui(base)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .quote(let s):
            Text(s).font(Theme.ui(base)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .overlay(Rectangle().frame(width: 2).foregroundStyle(Theme.line3), alignment: .leading)
        case .code(let s):
            Text(s).font(Theme.mono(12)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .padding(9).background(Theme.panel2).clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
        case .rule:
            Rectangle().frame(height: 1).foregroundStyle(Theme.line2).padding(.vertical, 2)
        case .table(let headers, let rows):
            let tf = base - 2
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { c in
                        Text(headers[c]).font(Theme.ui(tf, .bold)).foregroundStyle(Theme.ink)
                    }
                }
                Divider().gridCellColumns(max(1, headers.count))
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { c in
                            Text(c < rows[r].count ? rows[r][c] : AttributedString(""))
                                .font(Theme.ui(tf)).foregroundStyle(Theme.ink2)
                        }
                    }
                }
            }
            .padding(8).background(Theme.panel2)
            .overlay(RoundedRectangle(cornerRadius: Theme.rXs).stroke(Theme.line2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let s):
            Text(s).font(Theme.ui(base)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        case .blank:
            Color.clear.frame(height: 1)
        }
    }

    // MARK: parse (cached)

    private final class Box { let blocks: [Block]; init(_ b: [Block]) { blocks = b } }
    private static let cache = NSCache<NSString, Box>()

    static func cached(_ text: String) -> [Block] {
        let key = text as NSString
        if let b = cache.object(forKey: key) { return b.blocks }
        let blocks = parse(text)
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }

    private static func attr(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(s)
    }

    private static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var inCode = false
        var codeBuf: [String] = []
        while i < lines.count {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inCode { out.append(.code(codeBuf.joined(separator: "\n"))); codeBuf = []; inCode = false }
                else { inCode = true }
                i += 1; continue
            }
            if inCode { codeBuf.append(raw); i += 1; continue }
            if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let headers = tableCells(t).map(attr)
                var rows: [[AttributedString]] = []
                var j = i + 2
                while j < lines.count {
                    let rt = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !rt.isEmpty, rt.contains("|") else { break }
                    rows.append(tableCells(rt).map(attr)); j += 1
                }
                out.append(.table(headers, rows)); i = j; continue
            }
            if t.isEmpty { out.append(.blank); i += 1; continue }
            if t == "---" || t == "***" || t == "___" { out.append(.rule); i += 1; continue }
            if let h = heading(t) { out.append(.heading(h.0, attr(h.1))); i += 1; continue }
            if t.hasPrefix("> ") { out.append(.quote(attr(String(t.dropFirst(2))))); i += 1; continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                out.append(.bullet(attr(String(t.dropFirst(2))))); i += 1; continue
            }
            if let o = ordered(t) { out.append(.ordered(o.0, attr(o.1))); i += 1; continue }
            out.append(.paragraph(attr(t))); i += 1
        }
        if inCode, !codeBuf.isEmpty { out.append(.code(codeBuf.joined(separator: "\n"))) }
        return out
    }

    private static func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { c in
            let x = c.replacingOccurrences(of: ":", with: "")
            return !x.isEmpty && x.allSatisfy { $0 == "-" }
        }
    }
    private static func heading(_ t: String) -> (Int, String)? {
        var n = 0; var i = t.startIndex
        while i < t.endIndex, t[i] == "#" { n += 1; i = t.index(after: i) }
        guard n >= 1, n <= 6, i < t.endIndex, t[i] == " " else { return nil }
        return (n, String(t[t.index(after: i)...]))
    }
    private static func ordered(_ t: String) -> (String, String)? {
        let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let mark = parts.first, mark.count <= 4,
              (mark.hasSuffix(".") || mark.hasSuffix(")")), Int(mark.dropLast()) != nil
        else { return nil }
        return (mark, parts[1])
    }
}
