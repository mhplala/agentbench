import SwiftUI

struct ComposeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("新建对比").font(Theme.ui(30, .bold)).tracking(-0.6).foregroundStyle(Theme.ink)
                Text("同一个任务，交给两个 agent 跑，并排看它们怎么干活。")
                    .font(Theme.ui(14.5)).foregroundStyle(Theme.ink3)
                    .padding(.top, 7).padding(.bottom, 22)

                EnvBar()
                    .padding(.bottom, 22)

                BlockLabel(text: "任务 / PROMPT").padding(.bottom, 9)
                TextEditor(text: $app.live.task)
                    .font(Theme.ui(16))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(12)
                    .panel(stroke: Theme.line3)
                    .overlay(alignment: .topLeading) {
                        if app.live.task.isEmpty {
                            Text("例如：为电商后台实现一个订单列表组件，支持搜索、分页、批量删除（React + TypeScript），并补充单元测试。")
                                .font(Theme.ui(16)).foregroundStyle(Theme.ink3)
                                .padding(.horizontal, 17).padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }

                // agent slots (2-4)
                HStack(spacing: 8) {
                    BlockLabel(text: "对比 \(app.live.laneCount) 个 AGENT")
                    Spacer()
                    Button { app.removeLane(app.live.configs.count - 1) } label: {
                        HStack(spacing: 4) { SFIcon(name: "x", size: 11); Text("减少").font(Theme.ui(12, .semibold)) }
                            .foregroundStyle(app.live.laneCount > Lane.minCount ? Theme.ink2 : Theme.ink3)
                    }.buttonStyle(.plain).disabled(app.live.laneCount <= Lane.minCount)
                    Button { app.addLane() } label: {
                        HStack(spacing: 4) { SFIcon(name: "plus", size: 11); Text("添加 agent").font(Theme.ui(12, .semibold)) }
                            .foregroundStyle(app.live.laneCount < Lane.maxCount ? Theme.ink : Theme.ink3)
                    }.buttonStyle(.plain).disabled(app.live.laneCount >= Lane.maxCount)
                }
                .padding(.top, 22).padding(.bottom, 10)

                // 2 lanes split evenly; 3-4 lanes fall into a stable 2-column grid so
                // each card keeps a comfortable min width instead of being crushed or
                // pushed off-screen behind a horizontal scrollbar.
                Group {
                    if app.live.laneCount <= 2 {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(app.live.configs.indices, id: \.self) { i in
                                AgentSlotView(lane: i, cfg: $app.live.configs[i])
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                            GridItem(.flexible(), spacing: 14)],
                                  alignment: .leading, spacing: 14) {
                            ForEach(app.live.configs.indices, id: \.self) { i in
                                AgentSlotView(lane: i, cfg: $app.live.configs[i])
                            }
                        }
                    }
                }
                .padding(.bottom, 22)

                // judge + run
                judgeBar
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 28).padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("新建对比")
    }

    private var judgeBar: some View {
        HStack(spacing: 16) {
            Button { app.live.judgeOn.toggle() } label: {
                HStack(spacing: 11) {
                    Toggle2(on: app.live.judgeOn)
                    SFIcon(name: "gavel", size: 15).foregroundStyle(Theme.ink2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("自动裁判").font(Theme.ui(14, .semibold)).foregroundStyle(Theme.ink)
                        Text("由「元 Agent」评判（与参赛 agent 独立，下方可配）").font(Theme.ui(13)).foregroundStyle(Theme.ink3)
                    }
                }
            }
            .buttonStyle(.plain)

            if app.live.judgeOn { MetaAgentPicker() }
            Spacer()
            Button { app.runComparison() } label: {
                HStack(spacing: 9) {
                    SFIcon(name: "play", size: 14)
                    Text("运行对比").font(Theme.ui(14.5, .semibold))
                    Text("⌘↵").font(Theme.mono(10)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.white.opacity(0.16)).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 11)
                .background(app.canRun() ? app.accentColor : Theme.ink3)
                .clipShape(RoundedRectangle(cornerRadius: Theme.r))
            }
            .buttonStyle(.plain)
            .disabled(!app.canRun())
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .panel()
    }
}

// Detected-agents strip.
struct EnvBar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SFIcon(name: app.scanned ? "check" : "search", size: 12).foregroundStyle(Theme.ink3)
                Text(app.scanned ? "已检测本机 agent CLI" : "正在检测环境…")
                    .font(Theme.ui(12)).foregroundStyle(Theme.ink3)
            }
            FlowLayout(spacing: 8) {
                ForEach(app.availabilities) { a in
                    HStack(spacing: 6) {
                        Text(a.spec.glyph).font(.system(size: 12))
                        Text(a.spec.name).font(Theme.ui(12, .medium))
                        if a.installed {
                            SFIcon(name: "check", size: 10).foregroundStyle(Theme.good)
                        } else {
                            Text("未安装").font(Theme.ui(10.5)).foregroundStyle(Theme.bad)
                        }
                    }
                    .foregroundStyle(a.installed ? Theme.ink : Theme.ink3)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.panel2)
                    .overlay(Capsule().stroke(Theme.line2, lineWidth: 1))
                    .clipShape(Capsule())
                    .help(a.installed ? (a.version ?? a.path ?? "") : "安装: \(a.spec.installHint)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel2)
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line2, lineWidth: 1, antialiased: true)
            .foregroundStyle(Theme.line3))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
    }
}

struct AgentSlotView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.density) private var density
    let lane: Int
    @Binding var cfg: AgentConfig

    @State private var testing = false
    @State private var testResult: String? = nil
    @State private var testPass = false

    private var spec: AgentSpec { AgentCatalog.spec(cfg.agentId) }
    private var installed: Bool { app.isInstalled(cfg.agentId) }

    private func runTest() {
        guard let p = app.provider(cfg.providerId) else {
            testResult = "默认配置 · 无需测试"; testPass = true; return
        }
        testing = true; testResult = nil
        Task {
            let r = await CCSwitch.test(p)
            testing = false; testResult = r.label; testPass = r.passed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Agent \(Lane.label(lane))")
                    .font(Theme.ui(13, .bold)).tracking(0.5)
                    .foregroundStyle(lane == 0 ? .white : Theme.ink)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(lane == 0 ? Theme.ink : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: Theme.rXs)
                        .stroke(lane == 0 ? .clear : Theme.ink, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
                Spacer()
                if app.live.laneCount > Lane.minCount {
                    Button { app.removeLane(lane) } label: { SFIcon(name: "x", size: 12).foregroundStyle(Theme.ink3) }
                        .buttonStyle(.plain).help("移除该 agent")
                }
                Text(spec.glyph).font(.system(size: 20)).foregroundStyle(Theme.ink2)
            }

            field("Agent") {
                MenuField(label: "\(spec.name) · \(spec.vendor)") {
                    ForEach(AgentCatalog.all) { a in
                        Button("\(a.name) · \(a.vendor)") {
                            cfg.agentId = a.id
                            cfg.model = ""        // reset to agent default; pick a real one from the menu
                            cfg.providerId = nil  // providers are per-agent
                            testResult = nil
                        }
                    }
                }
            }

            field("模型（留空 = agent 自带默认）") {
                ModelField(model: $cfg.model, suggestions: app.models(for: cfg.agentId))
            }

            // cc-switch providers for this agent (inject env per run; test connectivity)
            let provs = app.providers(for: cfg.agentId)
            if !provs.isEmpty {
                field("Provider · cc-switch") {
                    HStack(spacing: 8) {
                        MenuField(label: cfg.providerId.flatMap { id in provs.first { $0.id == id }?.name }
                                    ?? "默认（当前激活）") {
                            Button("默认（当前激活）") { cfg.providerId = nil; testResult = nil }
                            ForEach(provs) { p in
                                Button(p.name + (p.isDefault ? "（默认）" : "") + (p.healthy == false ? " ⚠︎" : "")) {
                                    cfg.providerId = p.id; testResult = nil
                                }
                            }
                        }

                        Button { runTest() } label: {
                            HStack(spacing: 5) {
                                if testing { Spinner(size: 11) } else { SFIcon(name: "bolt", size: 11) }
                                Text("测试").font(Theme.ui(11.5, .semibold))
                            }
                            .foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Theme.panel2)
                            .overlay(RoundedRectangle(cornerRadius: Theme.rXs).stroke(Theme.line3, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.rXs))
                        }
                        .buttonStyle(.plain).disabled(testing)
                    }
                    if let testResult {
                        HStack(spacing: 5) {
                            SFIcon(name: testPass ? "check" : "warn", size: 11)
                            Text(testResult).font(Theme.mono(11))
                        }
                        .foregroundStyle(testPass ? Theme.good : Theme.bad)
                        .padding(.top, 2)
                    }
                }
            }

            field("工作目录 / 仓库（留空 = 临时沙盒）") {
                TextField("~/code/shop-admin", text: $cfg.repo)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(13.5))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.panel2)
                    .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
            }

            if !installed {
                HStack(alignment: .top, spacing: 6) {
                    SFIcon(name: "warn", size: 11).foregroundStyle(Theme.bad)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(spec.bin) 未安装").font(Theme.ui(11.5, .semibold)).foregroundStyle(Theme.bad)
                        Text(spec.installHint).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.delBG).clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
            }
        }
        .padding(density.cardPad + 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()   // flat config panel, no shadow
    }

    @ViewBuilder private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.ink2)
            content()
        }
    }
}

// Meta-agent picker (judge + config assistant), bound to global prefs — kept
// separate from the benchmarked lanes so its identity/credits don't mix.
struct MetaAgentPicker: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var prefs = Prefs.shared
    var body: some View {
        HStack(spacing: 8) {
            MenuField(label: AgentCatalog.spec(prefs.metaAgentId).name
                        + (app.isInstalled(prefs.metaAgentId) ? "" : "（未装）"),
                      width: 150) {
                ForEach(AgentCatalog.all) { a in
                    Button(a.name + (app.isInstalled(a.id) ? "" : "（未装）")) {
                        prefs.metaAgentId = a.id; prefs.metaModel = ""; prefs.metaProviderId = ""
                    }
                }
            }
            ModelField(model: $prefs.metaModel, suggestions: app.models(for: prefs.metaAgentId)).frame(width: 150)
            let provs = app.providers(for: prefs.metaAgentId)
            if !provs.isEmpty {
                MenuField(label: provs.first(where: { $0.id == prefs.metaProviderId })?.name ?? "默认",
                          width: 130) {
                    Button("默认") { prefs.metaProviderId = "" }
                    ForEach(provs) { p in Button(p.name) { prefs.metaProviderId = p.id } }
                }
            }
        }
    }
}

// Editable model field: free text + a menu of REAL detected models. Empty = agent default.
struct ModelField: View {
    @Binding var model: String
    let suggestions: [String]

    var body: some View {
        HStack(spacing: 0) {
            TextField("默认（agent 自带）", text: $model)
                .textFieldStyle(.plain)
                .font(Theme.mono(12.5))
                .padding(.horizontal, 12).padding(.vertical, 9)
            if !suggestions.isEmpty {
                Menu {
                    Button("默认（agent 自带）") { model = "" }
                    Divider()
                    ForEach(suggestions, id: \.self) { m in
                        Button(m) { model = m }
                    }
                } label: {
                    SFIcon(name: "chevronD", size: 13).foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 10)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34)
                .help("从本机检测到的 \(suggestions.count) 个模型中选择")
            }
        }
        .background(Theme.panel2)
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.line3, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
    }
}

// On/off pill matching the prototype toggle.
struct Toggle2: View {
    let on: Bool
    @EnvironmentObject var app: AppState
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? app.accentColor : Theme.line3).frame(width: 38, height: 22)
            Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
        .frame(width: 38, height: 22)
        .animation(.easeInOut(duration: 0.18), value: on)
    }
}
