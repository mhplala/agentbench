import SwiftUI

struct JudgeCard: View {
    let v: Verdict
    var accent: Color

    var body: some View {
        VStack(spacing: 0) {
            // top
            HStack(spacing: 10) {
                SFIcon(name: "gavel", size: 15).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("自动裁判").font(Theme.ui(14.5, .bold)).foregroundStyle(Theme.ink)
                Text(v.judge).font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.panel2).overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                    .clipShape(Capsule())
                Spacer()
                HStack(spacing: 6) {
                    SFIcon(name: "trophy", size: 13)
                    Text(v.winner == "tie" ? "平局" : "Agent \(v.winner) 更优").font(Theme.ui(12.5, .bold))
                }
                .foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 5)
                .background(accent).clipShape(Capsule())
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

            // score bars (per lane)
            VStack(spacing: 9) {
                ForEach(v.scores.indices, id: \.self) { i in
                    scoreBar("Agent \(Lane.label(i))", v.scores[i], win: v.winner == Lane.label(i))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)

            // criteria (per lane scores)
            VStack(spacing: 0) {
                ForEach(v.criteria) { c in
                    HStack(alignment: .top, spacing: 12) {
                        Text(c.name).font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 64, alignment: .leading)
                        HStack(spacing: 4) {
                            ForEach(c.scores.indices, id: \.self) { i in
                                if i > 0 { Text("/").foregroundStyle(Theme.ink3) }
                                Text("\(c.scores[i])").font(Theme.mono(12.5, .semibold))
                                    .foregroundStyle(c.scores[i] == (c.scores.max() ?? 0) ? Theme.ink : Theme.ink3)
                            }
                        }
                        .frame(width: 78, alignment: .leading)
                        Text(c.note).font(Theme.ui(12)).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 16)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)
                }
            }

            // rationale
            Text(v.rationale)
                .font(Theme.ui(13.5)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(Theme.panel2)
        }
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
    }

    private func scoreBar(_ label: String, _ score: Double, win: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Theme.ui(12.5, .semibold))
                .foregroundStyle(win ? Theme.ink : Theme.ink2)
                .frame(width: 58, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panel2).overlay(Capsule().stroke(Theme.line2, lineWidth: 1))
                    Capsule().fill(win ? accent : Theme.line3)
                        .frame(width: max(0, geo.size.width * score / 10))
                }
            }
            .frame(height: 8)
            Text(String(format: "%.1f", score)).font(Theme.mono(13, .semibold))
                .foregroundStyle(Theme.ink).frame(width: 32, alignment: .trailing)
        }
    }
}

// Right-side judge drawer (slides over the workspace).
struct JudgeDrawer: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        ZStack(alignment: .trailing) {
            if app.judgeOpen {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { app.judgeOpen = false }
                    .transition(.opacity)
                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        SFIcon(name: "gavel", size: 16).foregroundStyle(Theme.ink)
                        Text("自动裁判").font(Theme.ui(15, .bold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Button { app.judgeOpen = false } label: { SFIcon(name: "x", size: 16).foregroundStyle(Theme.ink3) }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

                    ScrollView {
                        Group {
                            if app.judging {
                                HStack(spacing: 8) { Spinner(size: 14); Text("裁判评分中…").foregroundStyle(Theme.ink2) }
                                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                            } else if let v = app.live.verdict {
                                JudgeCard(v: v, accent: app.accentColor)
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 6) {
                                        SFIcon(name: "warn", size: 13).foregroundStyle(Theme.bad)
                                        Text("裁判未产出结果").font(Theme.ui(13.5, .semibold)).foregroundStyle(Theme.ink)
                                    }
                                    if let err = app.live.judgeError {
                                        Text(err).font(Theme.mono(11.5)).foregroundStyle(Theme.ink2)
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(10).background(Theme.delBG)
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                                    }
                                    Button { app.retryJudge() } label: {
                                        HStack(spacing: 6) { SFIcon(name: "refresh", size: 13); Text("重试裁判").font(Theme.ui(13, .semibold)) }
                                            .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 9)
                                            .background(app.accentColor).clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                                    }.buttonStyle(.plain)
                                    Text("提示：裁判用「元 Agent」(设置里配)。若一直失败，检查元 Agent 的身份/模型/provider 是否可用。")
                                        .font(Theme.ui(11.5)).foregroundStyle(Theme.ink3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                            }
                        }
                        .padding(16)
                    }
                }
                .frame(width: 360)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(Theme.panel)
                .overlay(Rectangle().frame(width: 1).foregroundStyle(Theme.line), alignment: .leading)
                .shadow(color: .black.opacity(0.12), radius: 30, x: -8, y: 0)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.26), value: app.judgeOpen)
    }
}
