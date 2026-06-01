import SwiftUI

// Monospace code block with optional git-style diff coloring (red − / green +).
// Lines are split ONCE in init (not re-split every body pass), rendered with a
// LazyVStack, and capped so a huge artifact can't create tens of thousands of
// row views at once. The full content is always available via "导出".
struct CodeView: View {
    private let lines: [String]
    private let diffMap: [DiffMark]?
    private let fontSize: CGFloat
    private let truncated: Bool

    static let maxLines = 4000

    init(text: String, diffMap: [DiffMark]? = nil, fontSize: CGFloat = 11.5) {
        let all = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        let over = all.count > Self.maxLines
        self.truncated = over
        self.lines = over ? Array(all.prefix(Self.maxLines)) : all
        self.diffMap = diffMap
        self.fontSize = fontSize
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in
                    let mark = (diffMap != nil && i < diffMap!.count) ? diffMap![i] : DiffMark.same
                    HStack(alignment: .top, spacing: 0) {
                        Text(mark == .add ? "+" : mark == .del ? "−" : " ")
                            .font(Theme.mono(fontSize))
                            .foregroundStyle(mark == .add ? Theme.addFG : mark == .del ? Theme.delFG : Theme.ink3)
                            .frame(width: 14, alignment: .center)
                        Text(lines[i].isEmpty ? " " : lines[i])
                            .font(Theme.mono(fontSize))
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 0.5)
                    .background(mark == .add ? Theme.addBG : mark == .del ? Theme.delBG : .clear)
                }
                if truncated {
                    Text("… 已截断，仅渲染前 \(Self.maxLines) 行 · 完整内容请用「导出」")
                        .font(Theme.mono(fontSize)).foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(hex: 0xFBFBFC))
    }
}
