import SwiftUI

// Renders real brand marks for the agent CLIs instead of generic unicode glyphs.
// Logos are embedded as single-path SVG `d` strings (24×24 viewBox) and drawn as
// vector Paths — no binary assets, fully scalable, tinted with brand colors.
// Agents without an embedded mark fall back to their `glyph` on a brand-colored tile.

// MARK: - brand registry

struct BrandInfo {
    var d: String? = nil            // SVG path (24-box); nil → glyph fallback
    var mark: Color = .white        // mark / glyph color
    var tile: Color = Color(hex: 0x14141A)   // tile background
    var gradient: [Color]? = nil    // if set, the mark is filled with this gradient
    var inset: CGFloat = 0.60       // mark size as a fraction of the tile
}

enum BrandIcons {
    // Simple Icons path data (CC0); brand colors are the vendors' marks.
    private static let anthropic = "M17.3041 3.541h-3.6718l6.696 16.918H24Zm-10.6082 0L0 20.459h3.7442l1.3693-3.5527h7.0052l1.3693 3.5528h3.7442L10.5363 3.5409Zm-.3712 10.2232 2.2914-5.9456 2.2914 5.9456Z"
    private static let gemini = "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"
    private static let cursor = "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"

    // Match by family so custom agents (e.g. a "claude-doubao" relay, or a codex/
    // gemini variant defined in agents.json) still get the right brand mark. We look
    // at both the agent id and its CLI bin.
    static func info(_ agentId: String) -> BrandInfo {
        let id = agentId.lowercased()
        let bin = AgentCatalog.spec(agentId).bin.lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { id.contains($0) || bin == $0 } }

        if has("claude", "anthropic") {            // white Anthropic mark on Claude clay
            return BrandInfo(d: anthropic, mark: .white, tile: Color(hex: 0xD97757), inset: 0.56)
        }
        if has("gemini") {                          // Gemini spark, blue→purple→pink on white
            return BrandInfo(d: gemini, mark: .black, tile: .white,
                             gradient: [Color(hex: 0x4285F4), Color(hex: 0x9B72CB), Color(hex: 0xD96570)],
                             inset: 0.62)
        }
        if has("cursor") {
            return BrandInfo(d: cursor, mark: .white, tile: Color(hex: 0x111114), inset: 0.58)
        }
        if has("codex", "openai", "chatgpt", "gpt") {
            return BrandInfo(mark: .white, tile: Color(hex: 0x0D0D0D))            // OpenAI black
        }
        if has("opencode") {
            return BrandInfo(mark: .white, tile: Color(hex: 0x1F1F23))
        }
        if has("aider") {
            return BrandInfo(mark: .white, tile: Color(hex: 0x14794A))           // aider green
        }
        return BrandInfo(mark: .white, tile: Color(hex: 0x14141A))
    }
}

// MARK: - icon view

struct BrandIcon: View {
    let agentId: String
    var box: CGFloat = 25

    var body: some View {
        let info = BrandIcons.info(agentId)
        let radius = box * 0.28
        let light = info.tile == .white
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(info.tile)
            if let d = info.d {
                let shape = BrandShape(d: d)
                Group {
                    if let g = info.gradient {
                        shape.fill(LinearGradient(colors: g, startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        shape.fill(info.mark)
                    }
                }
                .frame(width: box * info.inset, height: box * info.inset)
            } else {
                Text(AgentCatalog.spec(agentId).glyph)
                    .font(.system(size: box * 0.5, weight: .medium))
                    .foregroundStyle(info.mark)
            }
        }
        .frame(width: box, height: box)
        .overlay(RoundedRectangle(cornerRadius: radius)
            .stroke(Theme.line2, lineWidth: light ? 1 : 0))
    }
}

// MARK: - SVG path → Shape

struct BrandShape: Shape {
    let d: String
    var box: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let cg = SVGPath.cgPath(d)
        let scale = min(rect.width, rect.height) / box
        let tx = rect.midX - box * scale / 2
        let ty = rect.midY - box * scale / 2
        var t = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        return Path(cg.copy(using: &t) ?? cg)
    }
}

// MARK: - minimal SVG path (d) parser → CGPath

enum SVGPath {
    private enum Tok { case cmd(Character); case num(CGFloat) }

    static func cgPath(_ d: String) -> CGPath {
        let toks = tokenize(d)
        let p = CGMutablePath()
        var i = 0
        var cur = CGPoint.zero, sub = CGPoint.zero
        var prevCtrl: CGPoint? = nil
        var prevCmd: Character = " "

        func peekNum() -> Bool {
            guard i < toks.count else { return false }
            if case .num = toks[i] { return true }
            return false
        }
        func n() -> CGFloat {
            guard i < toks.count, case let .num(v) = toks[i] else { return 0 }
            i += 1; return v
        }
        func pt(_ rel: Bool) -> CGPoint {
            let x = n(), y = n()
            return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }
        func reflect(cubic: Bool) -> CGPoint {
            let pl = Character(prevCmd.lowercased())
            let ok = cubic ? (pl == "c" || pl == "s") : (pl == "q" || pl == "t")
            if let c = prevCtrl, ok { return CGPoint(x: 2 * cur.x - c.x, y: 2 * cur.y - c.y) }
            return cur
        }

        while i < toks.count {
            guard case let .cmd(raw) = toks[i] else { i += 1; continue }
            i += 1
            var cmd = raw
            repeat {
                let rel = cmd.isLowercase
                switch Character(cmd.lowercased()) {
                case "m":
                    cur = pt(rel); sub = cur; p.move(to: cur)
                    cmd = rel ? "l" : "L"     // extra pairs after M are implicit line-to
                case "l":
                    cur = pt(rel); p.addLine(to: cur)
                case "h":
                    var x = n(); if rel { x += cur.x }; cur.x = x; p.addLine(to: cur)
                case "v":
                    var y = n(); if rel { y += cur.y }; cur.y = y; p.addLine(to: cur)
                case "c":
                    let c1 = pt(rel), c2 = pt(rel), e = pt(rel)
                    p.addCurve(to: e, control1: c1, control2: c2); prevCtrl = c2; cur = e
                case "s":
                    let c1 = reflect(cubic: true), c2 = pt(rel), e = pt(rel)
                    p.addCurve(to: e, control1: c1, control2: c2); prevCtrl = c2; cur = e
                case "q":
                    let c = pt(rel), e = pt(rel)
                    p.addQuadCurve(to: e, control: c); prevCtrl = c; cur = e
                case "t":
                    let c = reflect(cubic: false), e = pt(rel)
                    p.addQuadCurve(to: e, control: c); prevCtrl = c; cur = e
                case "a":
                    let rx = n(), ry = n(), rot = n(), large = n() != 0, sweep = n() != 0
                    let e = pt(rel)
                    arc(p, from: cur, to: e, rx: rx, ry: ry, rotDeg: rot, large: large, sweep: sweep)
                    cur = e; prevCtrl = nil
                case "z":
                    p.closeSubpath(); cur = sub
                default: break
                }
                prevCmd = cmd
            } while peekNum() && Character(cmd.lowercased()) != "z"
        }
        return p
    }

    private static func tokenize(_ s: String) -> [Tok] {
        var toks: [Tok] = []
        let chars = Array(s)
        let cmds = Set("MmLlHhVvCcSsQqTtAaZz")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1; continue }
            if cmds.contains(c) { toks.append(.cmd(c)); i += 1; continue }
            var j = i
            if chars[j] == "+" || chars[j] == "-" { j += 1 }
            var sawDot = false, sawExp = false
            while j < chars.count {
                let d = chars[j]
                if d.isNumber { j += 1 }
                else if d == "." && !sawDot && !sawExp { sawDot = true; j += 1 }
                else if (d == "e" || d == "E") && !sawExp {
                    sawExp = true; j += 1
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                } else { break }
            }
            if j > i, let v = Double(String(chars[i..<j])) { toks.append(.num(CGFloat(v))); i = j }
            else { i += 1 }   // skip anything unparseable
        }
        return toks
    }

    // SVG elliptical arc → cubic bezier segments appended to the path.
    private static func arc(_ p: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                            rx rxIn: CGFloat, ry ryIn: CGFloat, rotDeg: CGFloat,
                            large: Bool, sweep: Bool) {
        if rxIn == 0 || ryIn == 0 { p.addLine(to: p1); return }
        var rx = abs(rxIn), ry = abs(ryIn)
        let phi = rotDeg * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        let sign: CGFloat = (large != sweep) ? 1 : -1
        let num = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let co = den == 0 ? 0 : sign * sqrt(num / den)
        let cxp = co * rx * y1p / ry
        let cyp = -co * ry * x1p / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = len == 0 ? 0 : acos(min(1, max(-1, (ux * vx + uy * vy) / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        let segs = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segs)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var a0 = theta1
        func map(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
            let x = rx * ex, y = ry * ey
            return CGPoint(x: cosP * x - sinP * y + cx, y: sinP * x + cosP * y + cy)
        }
        for _ in 0..<segs {
            let a1 = a0, a2 = a0 + delta
            let c1a = cos(a1), s1a = sin(a1), c2a = cos(a2), s2a = sin(a2)
            let cp1 = map(c1a - t * s1a, s1a + t * c1a)
            let cp2 = map(c2a + t * s2a, s2a - t * c2a)
            p.addCurve(to: map(c2a, s2a), control1: cp1, control2: cp2)
            a0 = a2
        }
    }
}
