import SwiftUI

// MARK: formatters

enum Fmt {
    static func sec(_ ms: Int) -> String { String(format: "%.1fs", Double(ms) / 1000) }
    static func tok(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
    static func usd(_ n: Double) -> String { String(format: n < 0.1 ? "$%.3f" : "$%.2f", n) }
}

// MARK: icons (SF Symbols mapping of the prototype's stroke set)

enum Sym {
    static let map: [String: String] = [
        "search": "magnifyingglass", "play": "play.fill", "history": "clock.arrow.circlepath",
        "plus": "plus", "check": "checkmark", "x": "xmark", "clock": "clock",
        "coin": "dollarsign.circle", "bolt": "bolt.fill", "ruler": "ruler",
        "gavel": "hammer.fill", "read": "doc.text", "edit": "pencil", "terminal": "terminal",
        "chevron": "chevron.right", "chevronD": "chevron.down", "trophy": "trophy.fill",
        "refresh": "arrow.clockwise", "gear": "gearshape", "sidebar": "sidebar.left",
        "brain": "brain", "expand": "arrow.up.left.and.arrow.down.right",
        "info": "circle", "send": "arrow.right", "spark": "sparkles", "warn": "exclamationmark.triangle",
        "browser": "safari", "globe": "globe",
    ]
}

struct SFIcon: View {
    let name: String
    var size: CGFloat = 14
    var weight: Font.Weight = .medium
    var body: some View {
        Image(systemName: Sym.map[name] ?? name)
            .font(.system(size: size, weight: weight))
    }
}

// MARK: agent identity

struct AgentGlyph: View {
    let agentId: String
    let lane: Int
    var box: CGFloat = 25
    private var primary: Bool { lane == 0 }   // lane 0 filled, others outlined
    var body: some View {
        let spec = AgentCatalog.spec(agentId)
        Text(spec.glyph)
            .font(.system(size: box * 0.56))
            .frame(width: box, height: box)
            .background(primary ? Theme.ink : Theme.panel)
            .foregroundStyle(primary ? .white : Theme.ink)
            .overlay(RoundedRectangle(cornerRadius: box * 0.28)
                .stroke(primary ? .clear : Theme.ink, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: box * 0.28))
    }
}

struct AgentTag: View {
    let agentId: String
    let model: String
    let lane: Int
    var body: some View {
        HStack(spacing: 9) {
            AgentGlyph(agentId: agentId, lane: lane)
            Text(AgentCatalog.spec(agentId).name)
                .font(Theme.ui(14, .bold))
                .foregroundStyle(Theme.ink)
                .fixedSize()
            if !model.isEmpty {
                Text(model)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.panel2)
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }
        }
    }
}

// MARK: metric chips

struct MetricChips: View {
    let m: Metrics
    var peers: [Metrics] = []   // all lanes' metrics; the best per metric is greened

    private struct Item { let icon, key, value: String; let raw: Double; let lowerBetter: Bool }

    private var items: [Item] {
        let costVal = m.costKnown ? Fmt.usd(m.costUsd) : "—"
        let tokPrefix = m.tokensEstimated ? "≈" : ""
        return [
            Item(icon: "clock", key: "延迟", value: Fmt.sec(m.latencyMs), raw: Double(m.latencyMs), lowerBetter: true),
            Item(icon: "coin", key: "成本", value: costVal, raw: m.costUsd, lowerBetter: true),
            Item(icon: "bolt", key: "Tokens", value: tokPrefix + Fmt.tok(m.tokensTotal), raw: Double(m.tokensTotal), lowerBetter: true),
            Item(icon: "ruler", key: "行数", value: "\(m.lines)", raw: Double(m.lines), lowerBetter: false),
        ]
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                let best = isBest(it)
                HStack(spacing: 6) {
                    SFIcon(name: it.icon, size: 11).foregroundStyle(Theme.ink3)
                    Text(it.key).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
                    Text(it.value).font(Theme.mono(12, .semibold)).foregroundStyle(best ? Theme.good : Theme.ink)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.panel2)
                .overlay(Capsule().stroke(Theme.line2, lineWidth: 1))
                .clipShape(Capsule())
            }
        }
    }

    // green when this lane is uniquely the best among peers for the metric
    private func isBest(_ it: Item) -> Bool {
        guard peers.count >= 2 else { return false }
        let vals: [Double] = peers.map {
            switch it.key {
            case "延迟": return Double($0.latencyMs)
            case "成本": return $0.costUsd
            case "Tokens": return Double($0.tokensTotal)
            default: return Double($0.lines)
            }
        }
        guard let target = it.lowerBetter ? vals.min() : vals.max() else { return false }
        if vals.filter({ $0 == target }).count > 1 { return false }   // tie → no highlight
        return it.raw == target
    }
}

// Tiny flow layout for wrapping chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

struct Spinner: View {
    @State private var spin = false
    var size: CGFloat = 12
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.7).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

// Small uppercase section label.
struct BlockLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.ui(11, .bold))
            .tracking(1.4)
            .foregroundStyle(Theme.ink3)
    }
}

// MARK: - Unified status vocabulary
//
// One icon size / background / layout for every "this lane is doing X" state, so
// the workspace doesn't read as several UI kits stitched together.

enum StatusKind {
    case running, done, failed, idle, warn
    var color: Color {
        switch self {
        case .running: return Theme.ink2
        case .done:    return Theme.good
        case .failed:  return Theme.bad
        case .idle:    return Theme.ink3
        case .warn:    return Theme.bad
        }
    }
    var icon: String {
        switch self {
        case .running: return "clock"
        case .done:    return "check"
        case .failed:  return "warn"
        case .idle:    return "clock"
        case .warn:    return "warn"
        }
    }
}

struct StatusPill: View {
    let kind: StatusKind
    let text: String
    var spinning: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            if spinning { Spinner(size: 11) } else { SFIcon(name: kind.icon, size: 11) }
            Text(text).font(Theme.mono(11.5, .semibold))
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(kind.color.opacity(0.08))
        .clipShape(Capsule())
    }
}

// Unified empty state — same icon size, spacing, copy length everywhere.
struct EmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil
    var body: some View {
        VStack(spacing: 7) {
            SFIcon(name: icon, size: 20, weight: .regular).foregroundStyle(Theme.ink3)
            Text(title).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink2)
            if let message {
                Text(message).font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// Unified warning / call-to-action banner (untrusted preview, judge failure, …).
struct WarningBanner: View {
    let text: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil
    var accent: Color = Theme.ink
    var body: some View {
        HStack(spacing: 8) {
            SFIcon(name: "warn", size: 12).foregroundStyle(Theme.bad)
            Text(text).font(Theme.ui(11.5)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel).font(Theme.ui(11.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(accent).clipShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Color(hex: 0xB42318, alpha: 0.06))
    }
}

// Dropdown styled to match the app's custom fields (ModelField / TextField) so
// selectors don't mix the native macOS pop-up bezel with the custom field look.
// Same padding/height/stroke as ModelField → controls line up when placed in a row.
struct MenuField<MenuContent: View>: View {
    let label: String
    var width: CGFloat? = nil
    var mono: Bool = false
    var help: String? = nil
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(mono ? Theme.mono(12.5) : Theme.ui(13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SFIcon(name: "chevronD", size: 11).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(width: width)
            .background(Theme.panel2)
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(help ?? "")
    }
}

// Icon-only command button with a tooltip — the desktop-app idiom the toolbar
// leaned away from with text pills.
struct IconButton: View {
    let icon: String
    let help: String
    var size: CGFloat = 14
    var prominent: Bool = false
    var tint: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            SFIcon(name: icon, size: size, weight: .semibold)
                .foregroundStyle(prominent ? .white : (tint ?? Theme.ink2))
                .frame(width: 30, height: 28)
                .background(prominent ? (tint ?? Theme.ink) : Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm)
                    .stroke(prominent ? .clear : Theme.line3, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
