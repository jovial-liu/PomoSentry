import AppKit
import SwiftUI

PomoSentryApp.main()

struct ContentView: View {
    @ObservedObject var store: TimerStore
    @State private var selectedSection = "今天"
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LiquidBackdrop()
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                Sidebar(store: store, selectedSection: $selectedSection)
                    .padding(12)
                Group {
                    if selectedSection == "学霸白名单" {
                        GuardPanel(store: store, focusGuard: store.focusGuard)
                    } else if selectedSection == "全部任务" {
                        AllTasksPanel(store: store)
                    } else {
                        MainPanel(store: store)
                    }
                }
                .id(selectedSection)
                .transition(.opacity.combined(with: .scale(scale: 0.995, anchor: .center)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.18, extraBounce: 0), value: selectedSection)
        .preferredColorScheme(.light)
        .onReceive(timer) { _ in store.tick() }
        .sheet(isPresented: Binding(get: { !didCompleteOnboarding }, set: { if !$0 { didCompleteOnboarding = true } })) {
            OnboardingView(store: store) { didCompleteOnboarding = true }
                .interactiveDismissDisabled()
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var store: TimerStore
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"
    let complete: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 7) {
                Text("欢迎使用 PomoSentry")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("计时、任务和严格白名单，帮助你把注意力留给真正重要的事。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ink.opacity(0.58))
                    .multilineTextAlignment(.center)
            }

            Picker("语言", selection: $appLanguage) {
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            VStack(alignment: .leading, spacing: 12) {
                OnboardingPoint(icon: "timer", title: "原生番茄计时", detail: "专注、短休息和长休息自动衔接。")
                OnboardingPoint(icon: "checklist", title: "任务与进度", detail: "选择当前任务，记录每个任务投入的番茄数。")
                OnboardingPoint(icon: "lock.shield.fill", title: "严格白名单", detail: "非白名单 App 无法切到前台，但可以继续在后台运行。")
            }
            .padding(18)
            .liquidGlass(cornerRadius: 16, tint: Color.mint.opacity(0.16))

            Button("开始使用") { complete() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(34)
        .frame(width: 500)
        .environment(\.locale, Locale(identifier: appLanguage))
    }
}

struct OnboardingPoint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(Color.tomato)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(detail)).font(.system(size: 11)).foregroundStyle(Color.ink.opacity(0.5))
            }
        }
    }
}

struct Sidebar: View {
    @ObservedObject var store: TimerStore
    @Binding var selectedSection: String
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.tomato)
                    Image(systemName: "timer")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PomoSentry")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("学霸番茄 · 专注守卫")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ink.opacity(0.55))
                }
            }
            .padding(.bottom, 30)

            Text("工作台")
                .sectionLabel()
                .padding(.bottom, 9)
            SidebarItem(title: "今天", icon: "sun.max.fill", count: store.tasks.filter { !$0.isDone }.count, selected: selectedSection == "今天") {
                selectSection("今天")
            }
            SidebarItem(title: "全部任务", icon: "checklist", selected: selectedSection == "全部任务") {
                selectSection("全部任务")
            }
            SidebarItem(title: "应用与网站", icon: "lock.shield.fill", count: store.focusGuard.displayedApps.count, selected: selectedSection == "学霸白名单") {
                selectSection("学霸白名单")
            }

            Spacer()

            Picker("语言", selection: $appLanguage) {
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
            .pickerStyle(.menu)
            .font(.system(size: 11))
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 13) {
                Text("今日进度")
                    .sectionLabel()
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(store.completedPomodoros)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("个番茄")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ink.opacity(0.55))
                }
                ProgressView(value: min(Double(store.completedPomodoros) / 8.0, 1))
                    .tint(Color.tomato)
                Text("目标 8 个 · 慢慢来就很好")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink.opacity(0.48))
            }
            .padding(16)
            .liquidGlass(cornerRadius: 16, tint: Color.mint.opacity(0.2))
        }
        .padding(24)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .liquidGlass(cornerRadius: 26, tint: Color.mint.opacity(0.16))
    }

    private func selectSection(_ section: String) {
        guard selectedSection != section else { return }
        withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
            selectedSection = section
        }
    }
}

struct GuardPanel: View {
    @ObservedObject var store: TimerStore
    @ObservedObject var focusGuard: FocusGuard
    @State private var showEmergencyEnd = false
    @State private var confirmationText = ""
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("应用与网站")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("浏览器可以加入 App 黑白名单；指定域名可单独拦截，浏览器仍在后台运行。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ink.opacity(0.56))
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(focusGuard.isEnabled ? Color.mint : Color.peach)
                            Image(systemName: focusGuard.isEnabled ? "lock.fill" : "lock.open.fill")
                                .foregroundStyle(Color.ink)
                        }
                        .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("严格专注模式")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            Text(focusGuard.statusText)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ink.opacity(0.52))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { focusGuard.isEnabled }, set: { focusGuard.setEnabled($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(store.isRunning)
                    }

                    if !focusGuard.lastBlockedApp.isEmpty {
                        Label("已拦截：\(focusGuard.lastBlockedApp)（本轮 \(focusGuard.blockedCount) 次）", systemImage: "hand.raised.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.tomato)
                    }

                    HStack {
                        Text("开始专注时自动执行")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("仅在计时器运行期间生效")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ink.opacity(0.42))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("名单策略")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.ink.opacity(0.5))
                        Picker("名单策略", selection: Binding(get: { focusGuard.listPolicy }, set: { focusGuard.setListPolicy($0) })) {
                            Text("白名单 · 只允许名单内").tag(AppListPolicy.allowlist)
                            Text("黑名单 · 只拦截名单内").tag(AppListPolicy.blocklist)
                        }
                        .pickerStyle(.segmented)
                    }
                    .disabled(store.isRunning)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("拦截方式")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.ink.opacity(0.5))
                        Picker("拦截方式", selection: Binding(get: { focusGuard.blockingBehavior }, set: { focusGuard.setBlockingBehavior($0) })) {
                            Text("保留后台运行").tag(BlockingBehavior.keepRunning)
                            Text("强制退出").tag(BlockingBehavior.forceQuit)
                        }
                        .pickerStyle(.segmented)
                    }
                    .disabled(store.isRunning)
                    Text(focusGuard.blockingBehavior == .keepRunning
                         ? "被拦截的 App 会继续在后台运行和联网，但无法切换到前台使用。"
                         : "强制退出可能导致其他 App 中未保存的内容丢失，请在开始专注前保存工作。")
                        .font(.system(size: 10))
                        .foregroundStyle(focusGuard.blockingBehavior == .keepRunning ? Color.ink.opacity(0.5) : Color.orange)

                    Label("会话会在重新打开后恢复；但电脑所有者始终可以强制结束普通用户 App。", systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.ink.opacity(0.48))

                    if focusGuard.listPolicy == .blocklist {
                        Label("Safari、Chrome、Edge、Arc 等浏览器都可以直接加入黑名单。", systemImage: "globe")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.ink.opacity(0.58))
                    }

                    if store.isStrictlyLocked {
                        Button("紧急结束严格专注") { showEmergencyEnd = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.tomato)
                    }
                }
                .padding(22)
                .liquidGlass(cornerRadius: 20, tint: focusGuard.isEnabled ? Color.mint.opacity(0.18) : nil)

                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(localized(focusGuard.listPolicy == .allowlist ? "允许使用的 App" : "禁止使用的 App",
                                           focusGuard.listPolicy == .allowlist ? "Allowed Apps" : "Blocked Apps",
                                           language: appLanguage))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text(localized(focusGuard.listPolicy == .allowlist ? "专注时只有这些 App 可以切到前台" : "专注时这些 App 无法切到前台，但仍可在后台运行",
                                           focusGuard.listPolicy == .allowlist ? "Only these apps can come to the foreground during focus." : "These apps cannot come to the foreground, but keep running in the background.",
                                           language: appLanguage))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ink.opacity(0.48))
                        }
                        Spacer()
                        Button { focusGuard.addApplication() } label: {
                            Label("添加 App", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.tomato)
                        .disabled(store.isRunning)
                    }

                    VStack(spacing: 0) {
                        if focusGuard.displayedApps.isEmpty {
                            Text("名单为空，点击右上角添加 App")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ink.opacity(0.42))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 14)
                        }
                        ForEach(focusGuard.displayedApps) { app in
                            AllowedAppRow(app: app, canRemove: !store.isRunning && (focusGuard.listPolicy == .blocklist || app.bundleID != "app.pomosentry.mac"), focusGuard: focusGuard)
                            if app.id != focusGuard.displayedApps.last?.id { Divider().padding(.leading, 38) }
                        }
                    }
                }
                .padding(22)
                .liquidGlass(cornerRadius: 20)

                WebsiteRulesCard(store: store, focusGuard: focusGuard)

                VStack(alignment: .leading, spacing: 8) {
                    Label("正式版网络过滤", systemImage: "network.badge.shield.half.filled")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("当前版本按精确域名拦截，并在启用和清除时分别请求管理员确认。子域名需要单独添加；正式的全域名后缀过滤需要 Apple Network Extension 授权。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .liquidGlass(cornerRadius: 16, tint: Color.lavender.opacity(0.24))
            }
            .padding(34)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showEmergencyEnd) {
            VStack(alignment: .leading, spacing: 16) {
                Text("确定结束严格专注？")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("为了避免冲动退出，请输入下面的确认文字。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink.opacity(0.55))
                TextField(localized("结束专注", "END FOCUS", language: appLanguage), text: $confirmationText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("继续专注") {
                        confirmationText = ""
                        showEmergencyEnd = false
                    }
                    Spacer()
                    Button("确认结束") {
                        store.emergencyEndStrictSession()
                        confirmationText = ""
                        showEmergencyEnd = false
                    }
                    .disabled(confirmationText != localized("结束专注", "END FOCUS", language: appLanguage))
                }
            }
            .padding(24)
            .frame(width: 390)
        }
    }
}

struct WebsiteRulesCard: View {
    @ObservedObject var store: TimerStore
    @ObservedObject var focusGuard: FocusGuard
    @State private var domainInput = ""
    @State private var invalidInput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.lavender.opacity(0.55))
                    Image(systemName: "globe.badge.chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.ink.opacity(0.78))
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("网站域名黑名单")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("浏览器保持后台运行，只拦截已添加的精确域名")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink.opacity(0.48))
                }
                Spacer()
                Toggle("", isOn: Binding(get: { focusGuard.websiteBlockingEnabled }, set: { focusGuard.setWebsiteBlockingEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(store.isRunning || store.isPreparing)
            }

            HStack(spacing: 9) {
                Image(systemName: "link")
                    .foregroundStyle(Color.ink.opacity(0.42))
                TextField("例如 youtube.com 或 m.youtube.com", text: $domainInput)
                    .textFieldStyle(.plain)
                    .onSubmit(addDomain)
                Button("添加网址", action: addDomain)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tomato)
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
            .liquidGlass(cornerRadius: 12, tint: invalidInput ? Color.red.opacity(0.16) : Color.white.opacity(0.12), interactive: true)
            .disabled(store.isRunning || store.isPreparing)

            if invalidInput {
                Text("请输入有效域名。网页路径会自动提取主机名；不同子域名请分别添加。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red.opacity(0.75))
            }

            if focusGuard.blockedWebsites.isEmpty {
                Text("尚未添加网站。你可以加入视频网站、社交媒体或新闻站点。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink.opacity(0.42))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(focusGuard.blockedWebsites, id: \.self) { domain in
                        HStack(spacing: 7) {
                            Image(systemName: "nosign")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.tomato)
                            Text(domain)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button { focusGuard.removeWebsite(domain) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.ink.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isRunning || store.isPreparing)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.46), in: Capsule())
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: focusGuard.websiteRulesActive ? "checkmark.shield.fill" : "info.circle.fill")
                    .foregroundStyle(focusGuard.websiteRulesActive ? Color.green : Color.orange)
                Text(focusGuard.websiteStatus.isEmpty
                     ? "开始和结束时 macOS 会分别请求管理员确认；每次操作后都会验证真实系统状态。"
                     : focusGuard.websiteStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ink.opacity(0.52))
                Spacer()
                if focusGuard.websiteRulesActive {
                    Button("立即清除") { Task { await focusGuard.clearWebsiteRules() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.tomato)
                        .disabled(focusGuard.isWebsiteOperationInProgress)
                }
            }
        }
        .padding(22)
        .liquidGlass(cornerRadius: 20, tint: Color.lavender.opacity(0.14))
    }

    private func addDomain() {
        if focusGuard.addWebsite(domainInput) {
            domainInput = ""
            invalidInput = false
        } else {
            invalidInput = true
        }
    }
}

struct AllowedAppRow: View {
    let app: AllowedApplication
    let canRemove: Bool
    @ObservedObject var focusGuard: FocusGuard

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(app.name))
                    .font(.system(size: 13, weight: .medium))
                Text(app.bundleID)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ink.opacity(0.38))
            }
            Spacer()
            if !canRemove {
                Text("必需")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.ink.opacity(0.4))
            } else {
                Button { focusGuard.removeApplication(app) } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(Color.ink.opacity(0.28))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
    }
}

struct SidebarItem: View {
    let title: String
    let icon: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Capsule()
                    .fill(selected ? Color.tomato : Color.clear)
                    .frame(width: 3, height: 18)
                Image(systemName: icon)
                    .frame(width: 17)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.ink.opacity(0.45)) }
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
            .background(
                selected ? Color.white.opacity(0.92) : (isHovering ? Color.white.opacity(0.48) : Color.clear),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in isHovering = hovering }
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .animation(.easeOut(duration: 0.14), value: selected)
    }
}

struct MainPanel: View {
    @ObservedObject var store: TimerStore
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("FOCUS STUDIO", systemImage: "sparkles")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(Color.tomato)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Color.tomato.opacity(0.10), in: Capsule())
                        Text(greeting)
                            .font(.system(size: 31, weight: .bold, design: .rounded))
                        Text("准备好把今天过得更专注一点了吗？")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.ink.opacity(0.56))
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        StatPill(value: "\(store.completedPomodoros)", label: "已完成", icon: "checkmark.seal.fill", color: .mint)
                        StatPill(value: "\(store.tasks.filter { !$0.isDone }.count)", label: "待处理", icon: "circle.dotted", color: .peach)
                    }
                }

                TimerCard(store: store)
                TaskCard(store: store)
            }
            .padding(34)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return localized("早上好，今天也要稳稳地来", "Good morning. Start steady.", language: appLanguage) }
        if hour < 18 { return localized("下午好，给自己一个专注时段", "Good afternoon. Make room for deep focus.", language: appLanguage) }
        return localized("晚上好，收好今天的最后一点能量", "Good evening. Finish the day with intention.", language: appLanguage)
    }
}

struct AllTasksPanel: View {
    @ObservedObject var store: TimerStore
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(localized("任务资料库", "TASK LIBRARY", language: appLanguage), systemImage: "tray.full.fill")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Color.tomato)
                    Text(localized("全部任务", "All Tasks", language: appLanguage))
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                    Text(localized("集中查看所有任务；“今天”只显示今天和未安排日期的任务。", "Review every task in one place; Today shows today's and unscheduled tasks.", language: appLanguage))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ink.opacity(0.56))
                }
                TaskCard(store: store, showsAll: true)
            }
            .padding(34)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatPill: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color == .mint ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 15, weight: .bold, design: .rounded))
                Text(LocalizedStringKey(label)).font(.system(size: 10)).foregroundStyle(Color.ink.opacity(0.48))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 12, tint: color.opacity(0.32), interactive: true)
    }
}

struct TimerCard: View {
    @ObservedObject var store: TimerStore
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"

    var body: some View {
        VStack(spacing: 24) {
            Picker("计时模式", selection: Binding(get: { store.mode }, set: { store.selectMode($0) })) {
                ForEach(TimerMode.allCases, id: \.self) { mode in Text(LocalizedStringKey(mode.rawValue)).tag(mode) }
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
            .disabled(store.isRunning || store.isPreparing)

            if store.mode == .focus {
                HStack(spacing: 8) {
                    Label("专注时长", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ink.opacity(0.62))
                    ForEach([25, 45, 60, 90], id: \.self) { minutes in
                        Button("\(minutes)") { store.setFocusMinutes(minutes) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(store.focusMinutes == minutes ? Color.tomato.opacity(0.18) : Color.white.opacity(0.42), in: Capsule())
                    }
                    Divider().frame(height: 20)
                    Stepper(value: Binding(get: { store.focusMinutes }, set: { store.setFocusMinutes($0) }), in: 1...240) {
                        Text(localized("\(store.focusMinutes) 分钟", "\(store.focusMinutes) min", language: appLanguage))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 66, alignment: .trailing)
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .liquidGlass(cornerRadius: 13, tint: Color.white.opacity(0.12), interactive: true)
                .disabled(store.isRunning || store.isPreparing)
                .help("自由调节 1–240 分钟")
            }

            HStack(spacing: 50) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.22))
                    Circle().stroke(Color.white.opacity(0.90), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: max(store.progress, 0.001))
                        .stroke(store.mode.tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.25), value: store.progress)
                        .shadow(color: store.mode.tint.opacity(0.38), radius: 10)
                    VStack(spacing: 5) {
                        Text(store.timeString)
                            .font(.system(size: 59, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.ink)
                        Text(LocalizedStringKey(store.isRunning ? "进行中" : "准备开始"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.ink.opacity(0.48))
                    }
                }
                .frame(width: 220, height: 220)
                .shadow(color: Color.ink.opacity(0.09), radius: 24, y: 12)

                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringKey(store.mode.rawValue))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(LocalizedStringKey(store.mode.subtitle))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.ink.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                    if let task = store.tasks.first(where: { $0.id == store.selectedTaskID }) {
                        Label(task.title, systemImage: "link")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.ink.opacity(0.7))
                            .lineLimit(2)
                    } else {
                        Text("从下方选择一个任务开始")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ink.opacity(0.42))
                    }
                    HStack(spacing: 10) {
                        Button { store.toggleTimer() } label: {
                            Text(LocalizedStringKey(store.isPreparing ? "正在准备" : (store.isStrictlyLocked ? "严格专注中" : (store.isRunning ? "暂停" : "开始"))))
                        }
                        .buttonStyle(PrimaryButtonStyle())
                            .disabled(store.isStrictlyLocked || store.isPreparing)
                        Button { store.resetTimer() } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("重置本轮")
                        .disabled(store.isStrictlyLocked || store.isPreparing)
                    }
                }
                .frame(maxWidth: 230, alignment: .leading)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [store.mode.tint.opacity(0.16), Color.white.opacity(0.16), Color.lavender.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .liquidGlass(cornerRadius: 24, tint: store.mode.tint.opacity(0.2))
    }
}

struct TaskCard: View {
    @ObservedObject var store: TimerStore
    var showsAll = false
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"

    private var visibleTasks: [PomodoroTask] { showsAll ? store.tasks : store.todayTasks }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(showsAll ? "全部任务" : "今天的任务"))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("选一个小目标，专注完成它")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ink.opacity(0.48))
                }
                Spacer()
                Text(localized("\(visibleTasks.filter { $0.isDone }.count)/\(visibleTasks.count) 完成", "\(visibleTasks.filter { $0.isDone }.count)/\(visibleTasks.count) complete", language: appLanguage))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ink.opacity(0.5))
            }

            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .foregroundStyle(Color.ink.opacity(0.42))
                TextField("添加一个任务…", text: $store.newTaskTitle)
                    .textFieldStyle(.plain)
                    .onSubmit { store.addTask() }
                Button("添加") { store.addTask() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tomato)
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .liquidGlass(cornerRadius: 10, interactive: true)

            VStack(spacing: 0) {
                ForEach(visibleTasks) { task in
                    TaskRow(task: task, selected: task.id == store.selectedTaskID, store: store)
                    if task.id != visibleTasks.last?.id { Divider().padding(.leading, 38) }
                }
            }
        }
        .padding(22)
        .liquidGlass(cornerRadius: 20, tint: Color.white.opacity(0.10))
    }
}

struct TaskRow: View {
    let task: PomodoroTask
    let selected: Bool
    @ObservedObject var store: TimerStore

    var body: some View {
        HStack(spacing: 10) {
            Button { store.toggleTask(task) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(task.isDone ? Color.green : Color.ink.opacity(0.28))
            }
            .buttonStyle(.plain)
            Text(task.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .strikethrough(task.isDone)
                .foregroundStyle(task.isDone ? Color.ink.opacity(0.38) : Color.ink)
                .lineLimit(1)
            Spacer()
            if task.pomodoros > 0 {
                Label("\(task.pomodoros)", systemImage: "timer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.tomato.opacity(0.75))
            }
            if selected {
                Text("当前")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.tomato)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.peach, in: Capsule())
            }
            Button { store.deleteTask(task) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink.opacity(0.28))
            }
            .buttonStyle(.plain)
            .help("删除任务")
        }
        .contentShape(Rectangle())
        .onTapGesture { store.selectTask(task.id) }
        .padding(.vertical, 11)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .frame(height: 37)
            .liquidGlass(cornerRadius: 999, tint: Color.tomato.opacity(configuration.isPressed ? 0.55 : 0.82), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.ink.opacity(0.7))
            .frame(width: 37, height: 37)
            .liquidGlass(cornerRadius: 999, tint: Color.white.opacity(configuration.isPressed ? 0.2 : 0.38), interactive: true)
    }
}

extension View {
    func sectionLabel() -> some View {
        self.font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Color.ink.opacity(0.42))
    }

    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(interactive), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background((tint ?? Color.white.opacity(0.12)), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.38), lineWidth: 1))
                .shadow(color: Color.ink.opacity(0.07), radius: 16, x: 0, y: 8)
        }
    }
}

struct LiquidBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.91, green: 0.97, blue: 0.94),
                    Color(red: 1.00, green: 0.93, blue: 0.88),
                    Color(red: 0.92, green: 0.92, blue: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.tomato.opacity(0.16))
                .frame(width: 440, height: 440)
                .blur(radius: 90)
                .offset(x: 300, y: -250)
            Circle()
                .fill(Color.mint.opacity(0.28))
                .frame(width: 520, height: 520)
                .blur(radius: 110)
                .offset(x: -380, y: 260)
            Circle()
                .fill(Color.lavender.opacity(0.22))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: 330, y: 330)
        }
        .ignoresSafeArea()
    }
}

extension Color {
    static let ink = Color(red: 0.08, green: 0.16, blue: 0.17)
    static let tomato = Color(red: 0.94, green: 0.35, blue: 0.25)
    static let mint = Color(red: 0.69, green: 0.88, blue: 0.78)
    static let lavender = Color(red: 0.76, green: 0.74, blue: 0.96)
    static let peach = Color(red: 1.0, green: 0.84, blue: 0.73)
    static let appBackground = Color(red: 0.95, green: 0.97, blue: 0.94)
    static let sidebarBackground = Color(red: 0.89, green: 0.95, blue: 0.90)
}
