import SwiftUI
import AppKit

// Fullscreen side-by-side artifact comparison (preview / code / diff on a big canvas).
struct CompareOverlay: View {
    @EnvironmentObject var app: AppState
    @State private var escMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            // head
            HStack(spacing: 12) {
                Text("产出物对比").font(Theme.ui(15, .bold)).foregroundStyle(Theme.ink)
                Segmented(view: $app.artifactView)
                DiffToggle()
                Spacer()
                Text("Esc 退出").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                Button { app.compareOpen = false } label: { SFIcon(name: "x", size: 18).foregroundStyle(Theme.ink3) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.panel)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .bottom)

            // grid (N panes)
            HStack(spacing: 0) {
                ForEach(app.live.laneIndices, id: \.self) { i in
                    if i > 0 { Rectangle().frame(width: 1).foregroundStyle(Theme.line) }
                    pane(lane: i)
                }
            }
        }
        .background(Theme.bg)
        .onExitCommand { app.compareOpen = false }
        // Esc must work even when the embedded WebView has captured keyboard focus.
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                if ev.keyCode == 53 { app.compareOpen = false; return nil }  // 53 = Esc
                return ev
            }
        }
        .onDisappear {
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        }
    }

    private func pane(lane: Int) -> some View {
        let run = app.live.runs[lane]
        let cfg = app.live.configs[lane]
        return VStack(spacing: 0) {
            HStack {
                AgentTag(agentId: cfg.agentId, model: cfg.model, lane: lane)
                if run.answer?.previewHTML != nil {
                    Button { app.openInBrowser(lane) } label: {
                        HStack(spacing: 5) { SFIcon(name: "browser", size: 12); Text("浏览器").font(Theme.ui(11.5, .semibold)) }
                            .foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Theme.panel)
                            .overlay(RoundedRectangle(cornerRadius: Theme.rXs).stroke(Theme.line3, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
                    }.buttonStyle(.plain).help("在系统浏览器打开")
                }
                Spacer(minLength: 8)
                MetricChips(m: run.metrics, peers: app.live.runs.map { $0.metrics })
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.panel2)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line2), alignment: .bottom)

            let turn = run.answer
            Group {
                if app.artifactView == "preview" {
                    if let html = turn?.previewHTML {
                        ZStack(alignment: .bottom) {
                            HTMLPreview(html: html, baseDir: run.previewBaseDir,
                                        fileURL: run.previewFileURL, readAccessDir: run.workdir,
                                        trusted: app.isTrusted(lane))
                            if !app.isTrusted(lane) { TrustBanner(lane: lane) }
                        }
                    } else if let s = turn?.summary, !s.isEmpty {
                        // no HTML → render the answer so the fullscreen compare is
                        // useful for text / non-HTML outputs too
                        ScrollView { MarkdownText(text: s).padding(18).frame(maxWidth: 760) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panel2)
                    } else {
                        VStack(spacing: 6) {
                            SFIcon(name: "info", size: 20).foregroundStyle(Theme.ink3)
                            Text("无产出可显示").foregroundStyle(Theme.ink3)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panel2)
                    }
                } else {
                    CodeView(text: turn?.code ?? "", diffMap: app.diffMap(lane), fontSize: 12.5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// shared segmented preview/code control
struct Segmented: View {
    @Binding var view: String
    var body: some View {
        HStack(spacing: 2) {
            seg("preview", "预览"); seg("code", "代码")
        }
        .padding(3).background(Theme.panel2)
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        .fixedSize()   // keep its natural size — never let a cramped header squish it
    }
    private func seg(_ key: String, _ label: String) -> some View {
        let on = view == key
        return Button { view = key } label: {
            Text(label).font(Theme.ui(12.5, .semibold)).fixedSize()
                .foregroundStyle(on ? Theme.ink : Theme.ink2)
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background(on ? Theme.panel : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
        }
        .buttonStyle(.plain)
    }
}

struct DiffToggle: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Button { app.diff.toggle() } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Theme.delFG, Theme.addFG],
                          startPoint: .leading, endPoint: .trailing))
                    .frame(width: 9, height: 9)
                Text("Diff").font(Theme.ui(12.5, .semibold))
            }
            .foregroundStyle(app.artifactView == "code" ? (app.diff ? Theme.ink : Theme.ink2) : Theme.ink3)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm)
                .stroke(app.diff ? app.accentColor : Theme.line3, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
        }
        .buttonStyle(.plain)
        .disabled(app.artifactView != "code")
    }
}
