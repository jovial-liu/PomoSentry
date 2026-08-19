import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

struct PomoSentryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TimerStore()
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .environment(\.locale, Locale(identifier: appLanguage))
                .background(WindowConfigurator())
                .onAppear { appDelegate.store = store }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            Button(store.isRunning ? localized("暂停计时", "Pause", language: appLanguage) : localized("开始专注", "Start Focus", language: appLanguage)) {
                store.toggleTimer()
            }
            .disabled(store.isBusyOrLocked)
            Button(localized("重置本轮", "Reset Round", language: appLanguage)) { store.resetTimer() }
                .disabled(store.isBusyOrLocked)
            Divider()
            Text(store.statusText)
            Divider()
            Button(localized("退出 PomoSentry", "Quit PomoSentry", language: appLanguage)) {
                NSApplication.shared.terminate(nil)
            }
            .disabled(store.isStrictlyLocked)
        } label: {
            Label(store.menuBarTitle, systemImage: "timer")
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 18
        window.contentView?.layer?.cornerCurve = .continuous
        window.contentView?.layer?.masksToBounds = true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: TimerStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.isStrictlyLocked {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        if store.requiresTerminationCleanup {
            Task {
                let clean = await store.prepareForTermination()
                sender.reply(toApplicationShouldTerminate: clean)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

func localized(_ chinese: String, _ english: String, language: String? = nil) -> String {
    let code = language ?? UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans"
    return code.hasPrefix("en") ? english : chinese
}

enum TimerMode: String, CaseIterable, Codable, Sendable {
    case focus = "专注"
    case shortBreak = "短休息"
    case longBreak = "长休息"

    var duration: Int {
        switch self {
        case .focus: 25 * 60
        case .shortBreak: 5 * 60
        case .longBreak: 15 * 60
        }
    }

    var tint: Color {
        switch self {
        case .focus: .tomato
        case .shortBreak: .mint
        case .longBreak: .lavender
        }
    }

    var subtitle: String {
        switch self {
        case .focus: "把注意力交给眼前这一件事"
        case .shortBreak: "起来走走，给大脑一点空间"
        case .longBreak: "你已经完成了几轮，值得好好休息"
        }
    }
}

struct PomodoroTask: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var isDone: Bool
    var pomodoros: Int
    var dueDate: Date?

    init(id: UUID = UUID(), title: String, isDone: Bool = false, pomodoros: Int = 0, dueDate: Date? = Date()) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.pomodoros = pomodoros
        self.dueDate = dueDate
    }
}

struct AllowedApplication: Identifiable, Codable, Equatable, Sendable {
    var id: String { path }
    let bundleID: String
    let name: String
    let path: String
    let signingIdentifier: String?
    let teamIdentifier: String?
    let executableHash: String?

    init(bundleID: String, name: String, path: String, signingIdentifier: String? = nil, teamIdentifier: String? = nil, executableHash: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.executableHash = executableHash
    }
}

enum AppListPolicy: String, CaseIterable, Codable, Sendable {
    case allowlist
    case blocklist
}

enum BlockingBehavior: String, CaseIterable, Codable, Sendable {
    case keepRunning
    case forceQuit
}

enum WebsiteRulesError: LocalizedError, Equatable {
    case unreadable
    case malformedMarkers
    case invalidDomain(String)
    case changedConcurrently
    case authorization(String)
    case postcondition

    var errorDescription: String? {
        switch self {
        case .unreadable: localized("无法读取 /etc/hosts", "Could not read /etc/hosts")
        case .malformedMarkers: localized("检测到不完整或重复的 PomoSentry 标记，已停止操作以保护其他配置", "Malformed or duplicate PomoSentry markers were found; the operation was stopped to protect unrelated entries")
        case .invalidDomain(let value): localized("无效域名：\(value)", "Invalid domain: \(value)")
        case .changedConcurrently: localized("系统 hosts 文件刚刚被其他程序修改，请重试", "The hosts file changed during the operation; try again")
        case .authorization(let message): message
        case .postcondition: localized("系统文件的最终状态与请求不一致，已停止继续操作", "The final system-file state did not match the request")
        }
    }
}

enum WebsiteRulesFile {
    static let beginMarker = "# BEGIN POMOSENTRY"
    static let endMarker = "# END POMOSENTRY"

    static func normalizedDomain(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("://"), let host = URL(string: value)?.host {
            value = host
        } else {
            value = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
            if value.filter({ $0 == ":" }).count == 1 {
                value = value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? value
            }
        }
        while value.hasPrefix("www.") { value.removeFirst(4) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard value.count >= 3, value.count <= 253, value.contains(".") else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return nil }
        return value
    }

    static func replacement(existing: String, domains: [String]) throws -> String {
        let cleanDomains = try domains.map { value -> String in
            guard let domain = normalizedDomain(value), domain == value else { throw WebsiteRulesError.invalidDomain(value) }
            return domain
        }
        let lines = existing.components(separatedBy: .newlines)
        let begins = lines.indices.filter { lines[$0] == beginMarker }
        let ends = lines.indices.filter { lines[$0] == endMarker }
        guard begins.count == ends.count, begins.count <= 1 else { throw WebsiteRulesError.malformedMarkers }

        var retained = lines
        if let begin = begins.first, let end = ends.first {
            guard begin < end else { throw WebsiteRulesError.malformedMarkers }
            retained.removeSubrange(begin...end)
        }
        while retained.last?.isEmpty == true { retained.removeLast() }
        var result = retained.joined(separator: "\n")
        guard !cleanDomains.isEmpty else { return result + "\n" }

        if !result.isEmpty { result += "\n\n" }
        result += beginMarker + "\n"
        for domain in cleanDomains.sorted() {
            result += "0.0.0.0 \(domain)\n0.0.0.0 www.\(domain)\n"
            result += "::1 \(domain)\n::1 www.\(domain)\n"
        }
        result += endMarker + "\n"
        return result
    }

    static func hasValidRules(in hosts: String) -> Bool {
        let lines = hosts.components(separatedBy: .newlines)
        let begins = lines.indices.filter { lines[$0] == beginMarker }
        let ends = lines.indices.filter { lines[$0] == endMarker }
        return begins.count == 1 && ends.count == 1 && begins[0] < ends[0]
    }

    static func containsAnyMarker(in hosts: String) -> Bool {
        hosts.components(separatedBy: .newlines).contains { $0 == beginMarker || $0 == endMarker }
    }
}

enum ApplicationIdentity {
    static func enrolledApplication(at url: URL) -> AllowedApplication? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let signing = signingInfo(at: url)
        return AllowedApplication(
            bundleID: bundleID,
            name: name,
            path: canonicalPath(url),
            signingIdentifier: signing.identifier,
            teamIdentifier: signing.team,
            executableHash: executableHash(for: bundle)
        )
    }

    static func matches(_ running: NSRunningApplication, enrolled: AllowedApplication) -> Bool {
        guard let url = running.bundleURL,
              running.bundleIdentifier == enrolled.bundleID,
              canonicalPath(url) == canonicalPath(URL(fileURLWithPath: enrolled.path)) else { return false }
        let current = signingInfo(at: url)
        guard current.isValid else { return false }
        if let expectedTeam = enrolled.teamIdentifier {
            guard current.team == expectedTeam, current.identifier == (enrolled.signingIdentifier ?? enrolled.bundleID) else { return false }
            return true
        }
        if let expectedHash = enrolled.executableHash, let bundle = Bundle(url: url) {
            return executableHash(for: bundle) == expectedHash
        }
        return current.identifier == (enrolled.signingIdentifier ?? enrolled.bundleID)
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func signingInfo(at url: URL) -> (identifier: String?, team: String?, isValid: Bool) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, nil, false) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [CFString: Any] else { return (nil, nil, false) }
        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        return (dictionary[kSecCodeInfoIdentifier] as? String, dictionary[kSecCodeInfoTeamIdentifier] as? String, valid)
    }

    private static func executableHash(for bundle: Bundle) -> String? {
        guard let url = bundle.executableURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class FocusGuard: ObservableObject {
    @Published var isEnabled = false
    @Published private(set) var isMonitoring = false
    @Published var listPolicy: AppListPolicy = .allowlist
    @Published var blockingBehavior: BlockingBehavior = .keepRunning
    @Published private(set) var allowedApps: [AllowedApplication] = []
    @Published private(set) var blockedApps: [AllowedApplication] = []
    @Published private(set) var blockedWebsites: [String] = []
    @Published var websiteBlockingEnabled = false
    @Published private(set) var websiteRulesActive = false
    @Published var websiteStatus = ""
    @Published private(set) var lastBlockedApp = ""
    @Published private(set) var blockedCount = 0

    private let workspace = NSWorkspace.shared
    private let defaults = UserDefaults.standard
    private let mainBundleID = "app.pomosentry.mac"
    private var observers: [NSObjectProtocol] = []
    private var reconciliationTask: Task<Void, Never>?
    private var lastAllowedPID: pid_t?
    private var websiteOperationInProgress = false

    init() {
        loadConfiguration()
        reconcileWebsiteState()
    }

    var displayedApps: [AllowedApplication] { listPolicy == .allowlist ? allowedApps : blockedApps }
    var isWebsiteOperationInProgress: Bool { websiteOperationInProgress }
    var requiresWebsiteCleanup: Bool { websiteOperationInProgress || websiteRulesActive || Self.hostsFileContainsAnyMarker() }
    var statusText: String {
        if isMonitoring {
            return listPolicy == .allowlist
                ? localized("严格模式运行中 · 只允许已验证的白名单 App", "Strict mode active · Verified allowlist only")
                : localized("严格模式运行中 · 正在拦截黑名单 App", "Strict mode active · Blocklist enforced")
        }
        return isEnabled
            ? localized("严格模式已准备，将在专注开始时生效", "Strict mode is armed and starts with focus")
            : localized("学霸模式未开启", "Strict mode is off")
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "strictModeEnabled")
        if !enabled { stopMonitoring() }
    }

    @discardableResult
    func startMonitoring() -> Bool {
        guard !isMonitoring else { return true }
        blockedCount = 0
        lastAllowedPID = ProcessInfo.processInfo.processIdentifier
        isMonitoring = true
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in self?.enforce(application) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enforceCurrentApplication() }
            })
        }
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { break }
                self?.enforceCurrentApplication()
            }
        }
        enforceCurrentApplication()
        return true
    }

    func stopMonitoring() {
        observers.forEach { workspace.notificationCenter.removeObserver($0) }
        observers.removeAll()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        isMonitoring = false
        lastBlockedApp = ""
    }

    func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let application = ApplicationIdentity.enrolledApplication(at: url) else { return }
        if listPolicy == .allowlist {
            guard !allowedApps.contains(where: { $0.path == application.path }) else { return }
            allowedApps.append(application)
        } else {
            guard application.bundleID != mainBundleID, !blockedApps.contains(where: { $0.path == application.path }) else { return }
            blockedApps.append(application)
        }
        saveApplications()
    }

    func removeApplication(_ app: AllowedApplication) {
        if listPolicy == .allowlist {
            guard app.bundleID != mainBundleID else { return }
            allowedApps.removeAll { $0.path == app.path }
        } else {
            blockedApps.removeAll { $0.path == app.path }
        }
        saveApplications()
    }

    func setListPolicy(_ policy: AppListPolicy) {
        listPolicy = policy
        defaults.set(policy.rawValue, forKey: "appListPolicy")
    }

    func setBlockingBehavior(_ behavior: BlockingBehavior) {
        blockingBehavior = behavior
        defaults.set(behavior.rawValue, forKey: "blockingBehavior")
    }

    func setWebsiteBlockingEnabled(_ enabled: Bool) {
        websiteBlockingEnabled = enabled
        defaults.set(enabled, forKey: "websiteBlockingEnabled")
    }

    @discardableResult
    func addWebsite(_ input: String) -> Bool {
        guard let domain = WebsiteRulesFile.normalizedDomain(input), !blockedWebsites.contains(domain) else { return false }
        blockedWebsites.append(domain)
        blockedWebsites.sort()
        defaults.set(blockedWebsites, forKey: "blockedWebsites")
        websiteStatus = ""
        return true
    }

    func removeWebsite(_ domain: String) {
        blockedWebsites.removeAll { $0 == domain }
        defaults.set(blockedWebsites, forKey: "blockedWebsites")
    }

    @discardableResult
    func applyWebsiteRules() async -> Bool {
        guard websiteBlockingEnabled, !blockedWebsites.isEmpty else { return true }
        return await updateWebsiteRules(domains: blockedWebsites, applying: true)
    }

    @discardableResult
    func clearWebsiteRules() async -> Bool {
        reconcileWebsiteState()
        guard requiresWebsiteCleanup else { return true }
        return await updateWebsiteRules(domains: [], applying: false)
    }

    func reconcileWebsiteState() {
        guard let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
            websiteRulesActive = false
            websiteStatus = WebsiteRulesError.unreadable.localizedDescription
            return
        }
        websiteRulesActive = WebsiteRulesFile.hasValidRules(in: hosts)
        if WebsiteRulesFile.containsAnyMarker(in: hosts), !websiteRulesActive {
            websiteStatus = WebsiteRulesError.malformedMarkers.localizedDescription
        }
    }

    private func loadConfiguration() {
        if let data = defaults.data(forKey: "allowedApps"), let decoded = try? JSONDecoder().decode([AllowedApplication].self, from: data) { allowedApps = decoded }
        if let data = defaults.data(forKey: "blockedApps"), let decoded = try? JSONDecoder().decode([AllowedApplication].self, from: data) { blockedApps = decoded.filter { $0.bundleID != mainBundleID } }

        let sanitized = Set((defaults.stringArray(forKey: "blockedWebsites") ?? []).compactMap(WebsiteRulesFile.normalizedDomain)).sorted()
        blockedWebsites = sanitized
        defaults.set(sanitized, forKey: "blockedWebsites")
        websiteBlockingEnabled = defaults.bool(forKey: "websiteBlockingEnabled")
        isEnabled = defaults.bool(forKey: "strictModeEnabled")
        if let raw = defaults.string(forKey: "appListPolicy"), let value = AppListPolicy(rawValue: raw) { listPolicy = value }
        if let raw = defaults.string(forKey: "blockingBehavior"), let value = BlockingBehavior(rawValue: raw) { blockingBehavior = value }

        allowedApps.removeAll { $0.bundleID == "com.fanqiezhong.mac" || $0.bundleID == mainBundleID }
        if let selfApp = ApplicationIdentity.enrolledApplication(at: Bundle.main.bundleURL) {
            allowedApps.insert(selfApp, at: 0)
        } else {
            allowedApps.insert(AllowedApplication(bundleID: mainBundleID, name: "PomoSentry", path: Bundle.main.bundlePath), at: 0)
        }
        if allowedApps.count == 1 {
            for path in ["/System/Library/CoreServices/Finder.app", "/System/Applications/System Settings.app"] {
                if let application = ApplicationIdentity.enrolledApplication(at: URL(fileURLWithPath: path)) {
                    allowedApps.append(application)
                }
            }
        }
        saveApplications()
    }

    private func saveApplications() {
        defaults.set(try? JSONEncoder().encode(allowedApps), forKey: "allowedApps")
        defaults.set(try? JSONEncoder().encode(blockedApps), forKey: "blockedApps")
    }

    private func enforceCurrentApplication() { enforce(workspace.frontmostApplication) }

    private func enforce(_ application: NSRunningApplication?) {
        guard isMonitoring, let application, !application.isTerminated else { return }
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            lastAllowedPID = application.processIdentifier
            return
        }
        let list = listPolicy == .allowlist ? allowedApps : blockedApps
        let isListed = list.contains { ApplicationIdentity.matches(application, enrolled: $0) }
        let shouldBlock = listPolicy == .allowlist ? !isListed : isListed
        guard shouldBlock else {
            lastAllowedPID = application.processIdentifier
            return
        }
        lastBlockedApp = application.localizedName ?? application.bundleIdentifier ?? localized("未知应用", "Unknown app")
        blockedCount += 1
        if blockingBehavior == .forceQuit { _ = application.forceTerminate() }
        reactivateLastAllowedApp()
    }

    private func reactivateLastAllowedApp() {
        if let pid = lastAllowedPID,
           let application = workspace.runningApplications.first(where: { $0.processIdentifier == pid && !$0.isTerminated }),
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            _ = application.activate(options: [.activateAllWindows])
        } else {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    private func updateWebsiteRules(domains: [String], applying: Bool) async -> Bool {
        guard !websiteOperationInProgress else {
            websiteStatus = localized("已有网站规则操作正在进行", "A website-rule operation is already in progress")
            return false
        }
        websiteOperationInProgress = true
        defer { websiteOperationInProgress = false }
        websiteStatus = applying
            ? localized("正在请求管理员授权…", "Requesting administrator authorization…")
            : localized("正在请求管理员授权以清除规则…", "Requesting authorization to remove rules…")

        do {
            let existing = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
            let replacement = try WebsiteRulesFile.replacement(existing: existing, domains: domains)
            let expectedHash = Self.sha256(existing)
            let command = Self.atomicHostsUpdateCommand(replacement: replacement, expectedHash: expectedHash)
            let result = await Task.detached(priority: .userInitiated) { Self.runAdministratorCommand(command) }.value
            let current = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
            websiteRulesActive = WebsiteRulesFile.hasValidRules(in: current)
            let postconditionOK = domains.isEmpty ? !WebsiteRulesFile.containsAnyMarker(in: current) : websiteRulesActive
            guard result.success else {
                if applying && websiteRulesActive {
                    if let rollback = try? WebsiteRulesFile.replacement(existing: current, domains: []) {
                        let rollbackCommand = Self.atomicHostsUpdateCommand(replacement: rollback, expectedHash: Self.sha256(current))
                        _ = await Task.detached(priority: .userInitiated) { Self.runAdministratorCommand(rollbackCommand) }.value
                        reconcileWebsiteState()
                    }
                }
                websiteStatus = result.exitCode == 74
                    ? WebsiteRulesError.changedConcurrently.localizedDescription
                    : WebsiteRulesError.authorization(result.message).localizedDescription
                return false
            }
            guard postconditionOK else { throw WebsiteRulesError.postcondition }
            websiteStatus = applying
                ? localized("网站域名拦截已生效", "Website-domain blocking is active")
                : localized("网站规则已安全清除", "Website rules were removed safely")
            return true
        } catch {
            reconcileWebsiteState()
            websiteStatus = error.localizedDescription
            return false
        }
    }

    nonisolated private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func hostsFileContainsAnyMarker() -> Bool {
        guard let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else { return false }
        return WebsiteRulesFile.containsAnyMarker(in: hosts)
    }

    nonisolated private static func atomicHostsUpdateCommand(replacement: String, expectedHash: String) -> String {
        let encoded = Data(replacement.utf8).base64EncodedString()
        return "lock=/var/run/pomosentry-hosts.lock; if ! /bin/mkdir \"$lock\" 2>/dev/null; then oldpid=$(/bin/cat \"$lock/pid\" 2>/dev/null || true); if [ -n \"$oldpid\" ] && ! /bin/kill -0 \"$oldpid\" 2>/dev/null; then /bin/rm -rf \"$lock\" && /bin/mkdir \"$lock\" || exit 75; else exit 75; fi; fi; /bin/echo $$ > \"$lock/pid\"; tmp=''; cleanup() { [ -n \"$tmp\" ] && /bin/rm -f \"$tmp\"; /bin/rm -rf \"$lock\"; }; trap cleanup EXIT HUP INT TERM; current=$(/usr/bin/shasum -a 256 /etc/hosts | /usr/bin/awk '{print $1}'); [ \"$current\" = '\(expectedHash)' ] || exit 74; tmp=$(/usr/bin/mktemp /etc/hosts.pomosentry.XXXXXX) || exit 73; /bin/cp -p /etc/hosts \"$tmp\" || exit 73; /bin/echo '\(encoded)' | /usr/bin/base64 -D > \"$tmp\" || exit 73; /usr/bin/shasum -a 256 \"$tmp\" >/dev/null || exit 73; /bin/mv -f \"$tmp\" /etc/hosts || exit 73; tmp=''; /usr/bin/dscacheutil -flushcache || true; /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true"
    }

    nonisolated private static func runAdministratorCommand(_ command: String) -> (success: Bool, message: String, exitCode: Int32) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus == 0, message.isEmpty ? localized("操作被取消或失败", "Operation was cancelled or failed") : message, process.terminationStatus)
        } catch {
            return (false, error.localizedDescription, -1)
        }
    }
}

enum SessionPhase: String, Codable, Sendable {
    case idle
    case preparing
    case running
    case cleaning
}

struct SessionJournal: Codable, Sendable {
    let id: UUID
    let mode: TimerMode
    let plannedSeconds: Int
    let deadline: Date?
    let selectedTaskID: UUID?
    let strictApps: Bool
    let strictWebsites: Bool
}

enum Countdown {
    static func remaining(deadline: Date, now: Date = Date()) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }
}

@MainActor
final class TimerStore: ObservableObject {
    @Published var mode: TimerMode = .focus
    @Published private(set) var secondsRemaining = TimerMode.focus.duration
    @Published var focusMinutes = 25
    @Published private(set) var phase: SessionPhase = .idle
    @Published var completedPomodoros = 0
    @Published var tasks: [PomodoroTask] = []
    @Published var selectedTaskID: UUID?
    @Published var newTaskTitle = ""
    @Published var soundEnabled = true
    let focusGuard = FocusGuard()

    private let defaults = UserDefaults.standard
    private var session: SessionJournal?
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleGeneration = UUID()
    private var completionInProgress = false

    init() {
        load()
        Task { await restoreSessionIfNeeded() }
    }

    var isRunning: Bool { phase == .running }
    var isPreparing: Bool { phase == .preparing || phase == .cleaning }
    var isBusyOrLocked: Bool { isPreparing || isStrictlyLocked }
    var totalSeconds: Int { session?.plannedSeconds ?? duration(for: mode) }
    var progress: Double { totalSeconds > 0 ? min(max(1 - Double(secondsRemaining) / Double(totalSeconds), 0), 1) : 0 }
    var timeString: String { String(format: "%02d:%02d", secondsRemaining / 60, secondsRemaining % 60) }
    var menuBarTitle: String { isRunning ? timeString : "PomoSentry" }
    var isStrictlyLocked: Bool {
        guard mode == .focus, session?.strictApps == true || session?.strictWebsites == true else { return false }
        return phase != .idle
    }
    var requiresTerminationCleanup: Bool { isPreparing || session != nil || focusGuard.requiresWebsiteCleanup }

    var statusText: String {
        let english = (defaults.string(forKey: "appLanguage") ?? "zh-Hans").hasPrefix("en")
        let name: String
        switch mode {
        case .focus: name = english ? "Focus" : "专注"
        case .shortBreak: name = english ? "Short Break" : "短休息"
        case .longBreak: name = english ? "Long Break" : "长休息"
        }
        if phase == .preparing { return english ? "Preparing protections…" : "正在准备保护规则…" }
        if phase == .cleaning { return english ? "Cleaning protections…" : "正在清理保护规则…" }
        return isRunning ? (english ? "\(name) · \(timeString)" : "正在\(name) · \(timeString)") : (english ? "Ready for \(name) · \(timeString)" : "准备\(name) · \(timeString)")
    }

    var todayTasks: [PomodoroTask] {
        tasks.filter { task in
            guard let date = task.dueDate else { return true }
            return Calendar.current.isDateInToday(date)
        }
    }

    func tick(now: Date = Date()) {
        guard phase == .running, let deadline = session?.deadline else { return }
        let remaining = Countdown.remaining(deadline: deadline, now: now)
        secondsRemaining = remaining
        if remaining == 0, !completionInProgress {
            completionInProgress = true
            Task { await completeCurrentRound() }
        }
    }

    func toggleTimer() {
        guard !isBusyOrLocked else { return }
        if isRunning {
            lifecycleTask = Task { await transitionToIdle(resetClock: false) }
        } else {
            lifecycleTask = Task { await startCurrentRound() }
        }
    }

    func resetTimer() {
        guard !isBusyOrLocked else { return }
        lifecycleTask = Task { await transitionToIdle(resetClock: true) }
    }

    func selectMode(_ newMode: TimerMode) {
        guard phase == .idle else { return }
        mode = newMode
        secondsRemaining = duration(for: newMode)
        saveGeneralState()
    }

    func setFocusMinutes(_ minutes: Int) {
        guard phase == .idle else { return }
        focusMinutes = min(max(minutes, 1), 240)
        defaults.set(focusMinutes, forKey: "focusMinutes")
        if mode == .focus { secondsRemaining = focusMinutes * 60 }
    }

    func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = PomodoroTask(title: title)
        tasks.append(task)
        selectedTaskID = task.id
        newTaskTitle = ""
        saveGeneralState()
    }

    func selectTask(_ id: UUID?) {
        selectedTaskID = id
        saveGeneralState()
    }

    func toggleTask(_ task: PomodoroTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].isDone.toggle()
        saveGeneralState()
    }

    func deleteTask(_ task: PomodoroTask) {
        tasks.removeAll { $0.id == task.id }
        if selectedTaskID == task.id { selectedTaskID = nil }
        saveGeneralState()
    }

    func finishCurrentRound() {
        guard phase == .running, !completionInProgress else { return }
        completionInProgress = true
        Task { await completeCurrentRound() }
    }

    func emergencyEndStrictSession() {
        lifecycleTask = Task { await transitionToIdle(resetClock: true, allowLocked: true) }
    }

    func prepareForTermination() async -> Bool {
        lifecycleGeneration = UUID()
        let pending = lifecycleTask
        pending?.cancel()
        await pending?.value
        phase = .cleaning
        focusGuard.stopMonitoring()
        let cleaned = await focusGuard.clearWebsiteRules()
        if cleaned {
            clearSession()
            phase = .idle
        }
        return cleaned
    }

    private func startCurrentRound() async {
        guard phase == .idle else { return }
        let generation = UUID()
        lifecycleGeneration = generation
        let planned = duration(for: mode)
        let strictApps = mode == .focus && focusGuard.isEnabled
        let strictWebsites = mode == .focus && focusGuard.websiteBlockingEnabled && !focusGuard.blockedWebsites.isEmpty
        phase = .preparing
        session = SessionJournal(id: generation, mode: mode, plannedSeconds: planned, deadline: nil, selectedTaskID: selectedTaskID, strictApps: strictApps, strictWebsites: strictWebsites)
        saveSession()

        if strictApps { _ = focusGuard.startMonitoring() }
        if strictWebsites {
            let success = await focusGuard.applyWebsiteRules()
            guard lifecycleGeneration == generation, !Task.isCancelled else {
                _ = await focusGuard.clearWebsiteRules()
                return
            }
            guard success else {
                focusGuard.stopMonitoring()
                clearSession()
                phase = .idle
                return
            }
        }

        let deadline = Date().addingTimeInterval(TimeInterval(planned))
        session = SessionJournal(id: generation, mode: mode, plannedSeconds: planned, deadline: deadline, selectedTaskID: selectedTaskID, strictApps: strictApps, strictWebsites: strictWebsites)
        secondsRemaining = planned
        phase = .running
        saveSession()
    }

    private func transitionToIdle(resetClock: Bool, allowLocked: Bool = false) async {
        guard allowLocked || !isStrictlyLocked else { return }
        lifecycleGeneration = UUID()
        phase = .cleaning
        focusGuard.stopMonitoring()
        let cleaned = await focusGuard.clearWebsiteRules()
        guard cleaned else {
            phase = .cleaning
            return
        }
        clearSession()
        phase = .idle
        if resetClock { secondsRemaining = duration(for: mode) }
        saveGeneralState()
    }

    private func completeCurrentRound() async {
        guard let completedMode = session?.mode ?? (phase == .running ? mode : nil) else {
            completionInProgress = false
            return
        }
        phase = .cleaning
        focusGuard.stopMonitoring()
        let cleaned = await focusGuard.clearWebsiteRules()
        guard cleaned else {
            completionInProgress = false
            phase = .cleaning
            return
        }
        clearSession()
        if completedMode == .focus {
            completedPomodoros += 1
            if let id = selectedTaskID, let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].pomodoros += 1 }
            mode = completedPomodoros.isMultiple(of: 4) ? .longBreak : .shortBreak
        } else {
            mode = .focus
        }
        secondsRemaining = duration(for: mode)
        phase = .idle
        completionInProgress = false
        if soundEnabled { NSSound(named: "Glass")?.play() }
        saveGeneralState()
    }

    private func restoreSessionIfNeeded() async {
        guard let saved = session else { return }
        mode = saved.mode
        selectedTaskID = saved.selectedTaskID.flatMap { id in tasks.contains(where: { $0.id == id }) ? id : nil }
        guard let deadline = saved.deadline else {
            _ = await focusGuard.clearWebsiteRules()
            clearSession()
            phase = .idle
            secondsRemaining = duration(for: mode)
            return
        }
        if deadline <= Date() {
            secondsRemaining = 0
            phase = .running
            completionInProgress = true
            await completeCurrentRound()
            return
        }
        if saved.strictApps { _ = focusGuard.startMonitoring() }
        if saved.strictWebsites {
            focusGuard.reconcileWebsiteState()
            if !focusGuard.websiteRulesActive {
                phase = .preparing
                guard await focusGuard.applyWebsiteRules() else {
                    focusGuard.stopMonitoring()
                    clearSession()
                    phase = .idle
                    return
                }
            }
        }
        phase = .running
        tick()
    }

    private func saveGeneralState() {
        defaults.set(try? JSONEncoder().encode(tasks), forKey: "tasks")
        defaults.set(completedPomodoros, forKey: "completedPomodoros")
        defaults.set(selectedTaskID?.uuidString, forKey: "selectedTaskID")
        defaults.set(mode.rawValue, forKey: "timerMode")
    }

    private func saveSession() {
        defaults.set(try? JSONEncoder().encode(session), forKey: "activeSession")
        saveGeneralState()
    }

    private func clearSession() {
        session = nil
        defaults.removeObject(forKey: "activeSession")
    }

    private func load() {
        let savedMinutes = defaults.integer(forKey: "focusMinutes")
        focusMinutes = savedMinutes > 0 ? min(max(savedMinutes, 1), 240) : 25
        if let raw = defaults.string(forKey: "timerMode"), let savedMode = TimerMode(rawValue: raw) { mode = savedMode }
        if let data = defaults.data(forKey: "tasks"), let decoded = try? JSONDecoder().decode([PomodoroTask].self, from: data) { tasks = decoded }
        completedPomodoros = defaults.integer(forKey: "completedPomodoros")
        if let value = defaults.string(forKey: "selectedTaskID"), let id = UUID(uuidString: value), tasks.contains(where: { $0.id == id }) { selectedTaskID = id }
        if let data = defaults.data(forKey: "activeSession"), let decoded = try? JSONDecoder().decode(SessionJournal.self, from: data) { session = decoded }
        secondsRemaining = duration(for: mode)
    }

    private func duration(for mode: TimerMode) -> Int { mode == .focus ? focusMinutes * 60 : mode.duration }
}
