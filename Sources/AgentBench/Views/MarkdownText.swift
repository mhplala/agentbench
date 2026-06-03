import SwiftUI

// Lightweight Markdown renderer for agent answer text: headings (#..######),
// bold/italic/`code` (inline), bullet & ordered lists, blockquotes, fenced code
// blocks, and dividers. Good enough for typical agent output — not full CommonMark.
struct MarkdownText: View {
    let text: String
    var base: CGFloat = 13.5

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(parse().enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(Int, String), bullet(String), ordered(String, String)
        case quote(String), code(String), rule, paragraph(String), blank
        case table([String], [[String]])
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .heading(let lvl, let s):
            inline(s).font(Theme.ui(lvl <= 1 ? 18 : lvl == 2 ? 16 : 14.5, .bold))
                .foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
        case .bullet(let s):
            HStack(alignment: .top, spacing: 7) {
                Text("•").font(Theme.ui(base)).foregroundStyle(Theme.ink3)
                inline(s).font(Theme.ui(base)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ordered(let m, let s):
            HStack(alignment: .top, spacing: 7) {
                Text(m).font(Theme.ui(base, .semibold)).foregroundStyle(Theme.ink3).monospacedDigit()
                inline(s).font(Theme.ui(base)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .quote(let s):
            inline(s).font(Theme.ui(base)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .overlay(Rectangle().frame(width: 2).foregroundStyle(Theme.line3), alignment: .leading)
        case .code(let s):
            Text(s).font(Theme.mono(12)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9).background(Theme.panel2)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
        case .rule:
            Rectangle().frame(height: 1).foregroundStyle(Theme.line2).padding(.vertical, 2)
        case .table(let headers, let rows):
            let tf = base - 2   // tables render a notch smaller
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { c in
                        inline(headers[c]).font(Theme.ui(tf, .bold)).foregroundStyle(Theme.ink)
                    }
                }
                Divider().gridCellColumns(max(1, headers.count))
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { c in
                            inline(c < rows[r].count ? rows[r][c] : "")
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
            inline(s).font(Theme.ui(base)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .blank:
            Color.clear.frame(height: 1)
        }
    }

    // inline **bold** *italic* `code` [links] via AttributedString markdown
    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)) {
            return Text(a)
        }
        return Text(s)
    }

    private func parse() -> [Block] {
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
            // table: a "| … |" row immediately followed by a |---|---| separator
            if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let headers = tableCells(t)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let rt = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !rt.isEmpty, rt.contains("|") else { break }
                    rows.append(tableCells(rt)); j += 1
                }
                out.append(.table(headers, rows)); i = j; continue
            }
            if t.isEmpty { out.append(.blank); i += 1; continue }
            if t == "---" || t == "***" || t == "___" { out.append(.rule); i += 1; continue }
            if let h = heading(t) { out.append(.heading(h.0, h.1)); i += 1; continue }
            if t.hasPrefix("> ") { out.append(.quote(String(t.dropFirst(2)))); i += 1; continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                out.append(.bullet(String(t.dropFirst(2)))); i += 1; continue
            }
            if let o = ordered(t) { out.append(.ordered(o.0, o.1)); i += 1; continue }
            out.append(.paragraph(t)); i += 1
        }
        if inCode, !codeBuf.isEmpty { out.append(.code(codeBuf.joined(separator: "\n"))) }
        return out
    }

    private func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard cells.count >= 1, line.contains("|") else { return false }
        return cells.allSatisfy { c in
            let x = c.replacingOccurrences(of: ":", with: "")
            return !x.isEmpty && x.allSatisfy { $0 == "-" }
        }
    }

    private func heading(_ t: String) -> (Int, String)? {
        var n = 0; var i = t.startIndex
        while i < t.endIndex, t[i] == "#" { n += 1; i = t.index(after: i) }
        guard n >= 1, n <= 6, i < t.endIndex, t[i] == " " else { return nil }
        return (n, String(t[t.index(after: i)...]))
    }

    private func ordered(_ t: String) -> (String, String)? {
        let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let mark = parts.first, mark.count <= 4,
              (mark.hasSuffix(".") || mark.hasSuffix(")")), Int(mark.dropLast()) != nil
        else { return nil }
        return (mark, parts[1])
    }
}
