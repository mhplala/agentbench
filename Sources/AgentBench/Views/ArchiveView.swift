import SwiftUI

// Read-only view of a finished (archived) session.
struct ArchiveView: View {
    @EnvironmentObject var app: AppState
    let session: Session

    private func w(_ x: String) -> String { x == "tie" ? "平局" : "Agent \(x)" }

    var body: some View {
        VStack(spacing: 0) {
            // workbar
            HStack(spacing: 18) {
                Text(session.task).font(Theme.ui(15, .semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 9) {
                            ForEach(session.configs.indices, id: \.self) { i in
                                if i > 0 { Text("vs").font(Theme.mono(11)).foregroundStyle(Theme.ink3) }
                                AgentTag(agentId: session.configs[i].agentId, model: session.configs[i].model, lane: i)
                            }
                        }
                    }.frame(maxWidth: 380)
                    Button { Exporter.exportWithPanel(session) } label: {
                        HStack(spacing: 7) { SFIcon(name: "send", size: 15); Text("导出").font(Theme.ui(13, .semibold)) }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.panel)
                            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                    }.buttonStyle(.plain).help("导出整个 trace 与 log 到文件夹")
                    Button { app.rerun(from: session) } label: {
                        HStack(spacing: 7) { SFIcon(name: "refresh", size: 15); Text("以此重跑").font(Theme.ui(13, .semibold)) }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.panel)
                            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22).frame(height: 58)
            .padding(.top, 28)   // clear the titlebar / traffic-light strip
            .background(Theme.panel.opacity(0.95))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        SFIcon(name: "history", size: 14).foregroundStyle(Theme.ink3)
                        Text("存档会话 · 只读 · 完整对话、产出物与原始日志已保留，可「导出」继续分析")
                            .font(Theme.ui(12.5)).foregroundStyle(Theme.ink3)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel2)
                    .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))

                    // metrics strip (N lanes)
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(session.configs.indices, id: \.self) { i in
                            if i > 0 { Rectangle().frame(width: 1).foregroundStyle(Theme.line) }
                            metricCol(i, session.runs[i], session.configs[i], session.runs.map { $0.metrics })
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.r))
                    .cardShadow()

                    // verdict
                    if let v = session.verdict {
                        VStack(spacing: 0) {
                            HStack(spacing: 16) {
                                HStack(spacing: 7) {
                                    SFIcon(name: "trophy", size: 14)
                                    Text("裁判：\(w(v.winner))").font(Theme.ui(14, .bold))
                                }
                                .foregroundStyle(.white).padding(.horizontal, 13).padding(.vertical, 6)
                                .background(app.accentColor).clipShape(Capsule())
                                Text(v.scores.indices.map { "\(Lane.label($0)) \(String(format: "%.1f", v.scores[$0]))" }.joined(separator: " · "))
                                    .font(Theme.mono(13)).foregroundStyle(Theme.ink2)
                                Spacer()
                                if let vote = session.vote {
                                    Text("你的票：\(w(vote))").font(Theme.ui(13)).foregroundStyle(Theme.ink3)
                                }
                            }
                            .padding(.horizontal, 22).padding(.vertical, 15)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)
                            Text(v.rationale).font(Theme.ui(14)).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 22).padding(.vertical, 16)
                        }
                        .background(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
                        .cardShadow()

                        JudgeCard(v: v, accent: app.accentColor)
                    } else if let vote = session.vote {
                        Text("你的票：\(w(vote))").font(Theme.ui(14)).foregroundStyle(Theme.ink2)
                    }

                    // full read-only transcript (turns / tools / answers / artifacts)
                    HStack(spacing: 8) {
                        SFIcon(name: "read", size: 13).foregroundStyle(Theme.ink3)
                        Text("对话转录").font(Theme.ui(11, .bold)).tracking(1.2).foregroundStyle(Theme.ink3)
                    }
                    .padding(.top, 6)
                    ArchiveTranscript(session: session)
                }
                .frame(maxWidth: 1100).frame(maxWidth: .infinity)
                .padding(.horizontal, 22).padding(.vertical, 24)
            }
            .background(Theme.bg)
        }
    }

    private func metricCol(_ lane: Int, _ run: RunResult, _ cfg: AgentConfig, _ peers: [Metrics]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentTag(agentId: cfg.agentId, model: cfg.model, lane: lane)
            MetricChips(m: run.metrics, peers: peers)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
