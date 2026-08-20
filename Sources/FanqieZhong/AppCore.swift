import AppKit
import ApplicationServices
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
            Button(store.primaryActionTitle(language: appLanguage)) {
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
        window.titlebarSeparatorStyle = .none
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView?.layer?.cornerRadius = 18
        window.contentView?.layer?.cornerCurve = .continuous
        window.contentView?.layer?.masksToBounds = true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: TimerStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else {
            NSApp.activate(ignoringOtherApps: true)
            return .terminateCancel
        }
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

enum TaskDueChoice: String, CaseIterable, Codable, Sendable {
    case today
    case tomorrow
    case unscheduled
}

enum TaskVisibility {
    static func belongsInToday(_ task: PomodoroTask, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let date = task.dueDate else { return true }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date.distantFuture
        if date < startOfToday { return !task.isDone }
        return date < startOfTomorrow
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

    func shouldBlock(isListed: Bool) -> Bool {
        self == .allowlist ? !isListed : isListed
    }
}

enum BlockingBehavior: String, CaseIterable, Codable, Sendable {
    case keepRunning
    case forceQuit
}

enum PomodoroSequence {
    static func nextMode(after completedCycleCount: Int) -> TimerMode {
        completedCycleCount > 0 && completedCycleCount.isMultiple(of: 4) ? .longBreak : .shortBreak
    }
}

struct StrictAppConfiguration: Codable, Equatable, Sendable {
    let policy: AppListPolicy
    let blockingBehavior: BlockingBehavior
    let applications: [AllowedApplication]
}

enum StrictInputDecision {
    static func shouldBlock(
        active: Bool,
        policy: AppListPolicy,
        listedPIDs: Set<pid_t>,
        navigationPIDs: Set<pid_t>,
        ownPID: pid_t,
        targetPID: pid_t?,
        authorizationPIDs: Set<pid_t> = []
    ) -> Bool {
        guard active else { return false }
        guard let targetPID else { return true }
        if targetPID == ownPID || navigationPIDs.contains(targetPID) || authorizationPIDs.contains(targetPID) { return false }
        return policy.shouldBlock(isListed: listedPIDs.contains(targetPID))
    }
}

enum SystemNavigationSurface {
    static let bundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.Spotlight"
    ]

    static func contains(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(bundleIdentifiers.contains) ?? false
    }
}

enum SystemAuthorizationSurface {
    static let bundleIdentifiers: Set<String> = [
        "com.apple.SecurityAgent"
    ]
    static let processNames: Set<String> = [
        "SecurityAgent",
        "SecurityAgentUI"
    ]

    static func contains(bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(bundleIdentifiers.contains) ?? false
    }

    static func contains(processName: String?) -> Bool {
        processName.map(processNames.contains) ?? false
    }

    static func visibleWindowPIDs() -> Set<pid_t> {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(windows.compactMap { window -> pid_t? in
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  contains(processName: ownerName),
                  let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
            return pid_t(ownerPID.int32Value)
        })
    }
}

private final class FocusShieldPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct FocusShieldView: View {
    let applicationName: String

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 14) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Color(red: 0.94, green: 0.35, blue: 0.25))
                Text(localized("专注模式已拦截", "Focus mode blocked this app"))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(applicationName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Text(localized("它仍在后台运行，但专注结束前无法操作。", "It is still running in the background, but cannot be used until focus ends."))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
    }
}

private final class StrictInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var policy = AppListPolicy.allowlist
    private var listedPIDs: Set<pid_t> = []
    private var navigationPIDs: Set<pid_t> = []
    private var authorizationPIDs: Set<pid_t> = []
    private var frontmostPID: pid_t?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func configure(policy: AppListPolicy, listedPIDs: Set<pid_t>, navigationPIDs: Set<pid_t>, authorizationPIDs: Set<pid_t> = [], frontmostPID: pid_t?) {
        lock.lock()
        self.policy = policy
        self.listedPIDs = listedPIDs
        self.navigationPIDs = navigationPIDs
        self.authorizationPIDs = authorizationPIDs
        self.frontmostPID = frontmostPID
        active = true
        lock.unlock()
    }

    func update(policy: AppListPolicy, listedPIDs: Set<pid_t>, navigationPIDs: Set<pid_t>, authorizationPIDs: Set<pid_t> = [], frontmostPID: pid_t?) {
        lock.lock()
        self.policy = policy
        self.listedPIDs = listedPIDs
        self.navigationPIDs = navigationPIDs
        self.authorizationPIDs = authorizationPIDs
        self.frontmostPID = frontmostPID
        lock.unlock()
    }

    func updateFrontmostPID(_ processIdentifier: pid_t?) {
        lock.lock()
        frontmostPID = processIdentifier
        lock.unlock()
    }

    func stop() {
        lock.lock()
        active = false
        listedPIDs.removeAll()
        navigationPIDs.removeAll()
        authorizationPIDs.removeAll()
        frontmostPID = nil
        lock.unlock()
    }

    func shouldBlock(processIdentifier: pid_t?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return StrictInputDecision.shouldBlock(
            active: active,
            policy: policy,
            listedPIDs: listedPIDs,
            navigationPIDs: navigationPIDs,
            ownPID: ownPID,
            targetPID: processIdentifier,
            authorizationPIDs: authorizationPIDs
        )
    }

    func shouldBlockFrontmostApplication() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return StrictInputDecision.shouldBlock(
            active: active,
            policy: policy,
            listedPIDs: listedPIDs,
            navigationPIDs: navigationPIDs,
            ownPID: ownPID,
            targetPID: frontmostPID,
            authorizationPIDs: authorizationPIDs
        )
    }

    func currentFrontmostPID() -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return frontmostPID
    }
}

private final class StrictInputTap {
    private let gate: StrictInputGate
    private let onDisabled: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastMouseTargetPID: pid_t?

    init(gate: StrictInputGate, onDisabled: @escaping () -> Void) {
        self.gate = gate
        self.onDisabled = onDisabled
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }
        let eventTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<StrictInputTap>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = controller.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    controller.onDisabled()
                    return Unmanaged.passUnretained(event)
                }
                return controller.shouldSuppress(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        lastMouseTargetPID = nil
    }

    private func shouldSuppress(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            let targetPID = Self.targetPID(for: event, resolveWindowOwner: true)
                ?? lastMouseTargetPID
                ?? gate.currentFrontmostPID()
            if let targetPID { lastMouseTargetPID = targetPID }
            return gate.shouldBlock(processIdentifier: targetPID)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            let targetPID = Self.targetPID(for: event, resolveWindowOwner: false)
                ?? gate.currentFrontmostPID()
                ?? lastMouseTargetPID
            if let targetPID { lastMouseTargetPID = targetPID }
            return gate.shouldBlock(processIdentifier: targetPID)
        case .keyDown, .keyUp, .flagsChanged:
            return gate.shouldBlockFrontmostApplication()
        default:
            return false
        }
    }

    private static func targetPID(for event: CGEvent, resolveWindowOwner: Bool) -> pid_t? {
        let eventTargetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        if eventTargetPID > 0 { return pid_t(eventTargetPID) }
        return resolveWindowOwner ? windowOwner(at: event.location) : nil
    }

    private static func windowOwner(at point: CGPoint) -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            if let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { continue }
            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.contains(point),
                  let owner = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            return pid_t(owner.int32Value)
        }
        return nil
    }
}

@MainActor
private final class FocusShieldController {
    private var panels: [FocusShieldPanel] = []
    private var blockedPID: pid_t?

    func show(applicationName: String, processIdentifier: pid_t) {
        guard blockedPID != processIdentifier || panels.isEmpty else { return }
        dismiss()
        blockedPID = processIdentifier

        for screen in NSScreen.screens {
            let panel = FocusShieldPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.contentView = NSHostingView(rootView: FocusShieldView(applicationName: applicationName))
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func dismiss() {
        panels.forEach { panel in
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        blockedPID = nil
    }
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

    static func hasExactRules(in hosts: String, domains: [String]) -> Bool {
        guard !domains.isEmpty,
              let expected = try? replacement(existing: "", domains: domains),
              let actualBlock = managedBlock(in: hosts),
              let expectedBlock = managedBlock(in: expected) else { return false }
        return actualBlock == expectedBlock
    }

    static func containsAnyMarker(in hosts: String) -> Bool {
        hosts.components(separatedBy: .newlines).contains { $0 == beginMarker || $0 == endMarker }
    }

    private static func managedBlock(in hosts: String) -> [String]? {
        let lines = hosts.components(separatedBy: .newlines)
        let begins = lines.indices.filter { lines[$0] == beginMarker }
        let ends = lines.indices.filter { lines[$0] == endMarker }
        guard begins.count == 1, ends.count == 1, begins[0] < ends[0] else { return nil }
        return Array(lines[begins[0]...ends[0]])
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
    @Published private(set) var inputPermissionRequired = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var configurationLocked = false
    @Published private(set) var applicationStatus = ""
    @Published private(set) var lastProtectionError = ""
    @Published private(set) var inputProtectionWarning = ""
    @Published private(set) var inputProtectionHealthy = true

    private let workspace = NSWorkspace.shared
    private let defaults = UserDefaults.standard
    private let mainBundleID = "app.pomosentry.mac"
    private var observers: [NSObjectProtocol] = []
    private var reconciliationTask: Task<Void, Never>?
    private var permissionPollingTask: Task<Void, Never>?
    private var lastAllowedPID: pid_t?
    private var activeBlockedPID: pid_t?
    private var hiddenByGuardPIDs: Set<pid_t> = []
    private var activeListedPIDs: Set<pid_t> = []
    private var identityCache: [pid_t: Bool] = [:]
    @Published private var websiteOperationInProgress = false
    private var activeConfiguration: StrictAppConfiguration?
    private var administratorAuthorizationAllowed = false
    private var activeAuthorizationPIDs: Set<pid_t> = []
    private var websiteStateReadable = true
    private let shieldController = FocusShieldController()
    private let inputGate = StrictInputGate()
    private lazy var inputTap = StrictInputTap(gate: inputGate) { [weak self] in
        Task { @MainActor in self?.handleInputTapDisabled() }
    }

    init() {
        loadConfiguration()
        accessibilityGranted = Self.accessibilityPermission()
        inputPermissionRequired = isEnabled && !accessibilityGranted
        inputProtectionHealthy = !inputPermissionRequired
        if inputPermissionRequired {
            lastProtectionError = localized("辅助功能权限已失效，严格专注暂时无法启动", "Accessibility permission is unavailable; strict focus cannot start")
        }
        if inputPermissionRequired { beginPermissionPolling() }
        reconcileWebsiteState()
    }

    var displayedApps: [AllowedApplication] { listPolicy == .allowlist ? allowedApps : blockedApps }
    var currentConfiguration: StrictAppConfiguration {
        StrictAppConfiguration(
            policy: listPolicy,
            blockingBehavior: blockingBehavior,
            applications: listPolicy == .allowlist ? allowedApps : blockedApps
        )
    }
    var isWebsiteOperationInProgress: Bool { websiteOperationInProgress }
    var requiresWebsiteCleanup: Bool {
        websiteOperationInProgress || !websiteStateReadable || websiteRulesActive || Self.hostsFileContainsAnyMarker()
    }
    func websiteRulesMatch(domains: [String]) -> Bool {
        guard let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else { return false }
        return WebsiteRulesFile.hasExactRules(in: hosts, domains: domains)
    }
    var statusText: String {
        if isEnabled && (!accessibilityGranted || inputPermissionRequired) {
            return localized("需要辅助功能权限，严格专注尚未启动", "Accessibility permission is required; strict focus did not start")
        }
        if isMonitoring && !inputProtectionHealthy {
            return localized("严格模式运行中 · 输入保护正在恢复", "Strict mode active · Restoring input protection")
        }
        if isMonitoring {
            return (activeConfiguration?.policy ?? listPolicy) == .allowlist
                ? localized("严格模式运行中 · 只允许已验证的白名单 App", "Strict mode active · Verified allowlist only")
                : localized("严格模式运行中 · 正在拦截黑名单 App", "Strict mode active · Blocklist enforced")
        }
        return isEnabled
            ? localized("严格模式已准备，将在专注开始时生效", "Strict mode is armed and starts with focus")
            : localized("学霸模式未开启", "Strict mode is off")
    }

    func setEnabled(_ enabled: Bool) {
        guard !configurationLocked, !isMonitoring else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: "strictModeEnabled")
        if enabled {
            refreshAccessibilityPermission()
            if !accessibilityGranted { beginPermissionPolling() }
        } else {
            stopMonitoring()
            permissionPollingTask?.cancel()
            permissionPollingTask = nil
            inputPermissionRequired = false
        }
    }

    @discardableResult
    func startMonitoring(configuration: StrictAppConfiguration? = nil, allowAdministratorAuthorization: Bool = false) -> Bool {
        if isMonitoring {
            administratorAuthorizationAllowed = allowAdministratorAuthorization
            refreshInputGate(frontmostApplication: workspace.frontmostApplication)
            inputProtectionHealthy = inputTap.start()
            return inputProtectionHealthy
        }
        guard validateAccessibilityPermission() else { return false }
        administratorAuthorizationAllowed = allowAdministratorAuthorization
        activeConfiguration = configuration ?? currentConfiguration
        permissionPollingTask?.cancel()
        permissionPollingTask = nil
        inputPermissionRequired = false
        blockedCount = 0
        activeBlockedPID = nil
        inputProtectionWarning = ""
        inputProtectionHealthy = false
        activeListedPIDs.removeAll()
        identityCache.removeAll()
        lastAllowedPID = ProcessInfo.processInfo.processIdentifier
        refreshInputGate(frontmostApplication: workspace.frontmostApplication, configure: true)
        guard inputTap.start() else {
            inputGate.stop()
            activeConfiguration = nil
            inputPermissionRequired = true
            inputProtectionHealthy = false
            lastBlockedApp = localized("无法建立全局输入拦截，请检查辅助功能权限", "Could not create the global input blocker; check Accessibility permission")
            lastProtectionError = lastBlockedApp
            return false
        }
        inputProtectionHealthy = true
        isMonitoring = true
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    if name == NSWorkspace.didLaunchApplicationNotification, let application {
                        self?.identityCache.removeValue(forKey: application.processIdentifier)
                    }
                    self?.refreshInputGate(frontmostApplication: application)
                    self?.enforce(application)
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enforceCurrentApplication() }
            })
        }
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { break }
                if self?.administratorAuthorizationAllowed == true {
                    self?.refreshInputGate(frontmostApplication: self?.workspace.frontmostApplication)
                }
                self?.enforceCurrentApplication()
            }
        }
        terminateDisallowedApplications()
        hideDisallowedApplications()
        enforceCurrentApplication()
        return true
    }

    @discardableResult
    func validateAccessibilityPermission() -> Bool {
        refreshAccessibilityPermission()
        guard accessibilityGranted else {
            inputPermissionRequired = true
            lastBlockedApp = localized("请允许 PomoSentry 使用辅助功能后重新开始", "Allow PomoSentry in Accessibility, then start again")
            lastProtectionError = lastBlockedApp
            beginPermissionPolling()
            return false
        }
        return true
    }

    func stopMonitoring() {
        observers.forEach { workspace.notificationCenter.removeObserver($0) }
        observers.removeAll()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        inputTap.stop()
        inputGate.stop()
        activeConfiguration = nil
        administratorAuthorizationAllowed = false
        activeAuthorizationPIDs.removeAll()
        activeListedPIDs.removeAll()
        identityCache.removeAll()
        shieldController.dismiss()
        activeBlockedPID = nil
        isMonitoring = false
        inputProtectionHealthy = true
        lastBlockedApp = ""
        inputProtectionWarning = ""
        restoreApplicationsHiddenByGuard()
    }

    func setAdministratorAuthorizationAllowed(_ allowed: Bool) {
        administratorAuthorizationAllowed = allowed
        guard isMonitoring else { return }
        refreshInputGate(frontmostApplication: workspace.frontmostApplication)
    }

    @discardableResult
    func addApplication() -> Bool {
        guard !configurationLocked, !isMonitoring else { return false }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return false }
        guard let url = panel.url, let application = ApplicationIdentity.enrolledApplication(at: url) else {
            applicationStatus = localized("无法验证这个 App 的签名或应用包", "This app could not be verified")
            return false
        }
        if listPolicy == .allowlist {
            guard !allowedApps.contains(where: { $0.path == application.path }) else {
                applicationStatus = localized("这个 App 已经在白名单中", "This app is already on the allowlist")
                return false
            }
            allowedApps.append(application)
        } else {
            guard application.bundleID != mainBundleID else {
                applicationStatus = localized("PomoSentry 不能加入自己的黑名单", "PomoSentry cannot be added to its own blocklist")
                return false
            }
            guard !blockedApps.contains(where: { $0.path == application.path }) else {
                applicationStatus = localized("这个 App 已经在黑名单中", "This app is already on the blocklist")
                return false
            }
            blockedApps.append(application)
        }
        saveApplications()
        applicationStatus = localized("已添加：\(application.name)", "Added: \(application.name)")
        return true
    }

    func removeApplication(_ app: AllowedApplication) {
        guard !configurationLocked, !isMonitoring else { return }
        if listPolicy == .allowlist {
            guard app.bundleID != mainBundleID else { return }
            allowedApps.removeAll { $0.path == app.path }
        } else {
            blockedApps.removeAll { $0.path == app.path }
        }
        saveApplications()
        applicationStatus = localized("已移除：\(app.name)", "Removed: \(app.name)")
    }

    func setListPolicy(_ policy: AppListPolicy) {
        guard !configurationLocked, !isMonitoring else { return }
        listPolicy = policy
        defaults.set(policy.rawValue, forKey: "appListPolicy")
    }

    func setBlockingBehavior(_ behavior: BlockingBehavior) {
        guard !configurationLocked, !isMonitoring else { return }
        blockingBehavior = behavior
        defaults.set(behavior.rawValue, forKey: "blockingBehavior")
    }

    func setWebsiteBlockingEnabled(_ enabled: Bool) {
        guard !configurationLocked else { return }
        websiteBlockingEnabled = enabled
        defaults.set(enabled, forKey: "websiteBlockingEnabled")
        if !enabled, requiresWebsiteCleanup {
            Task { [weak self] in
                _ = await self?.clearWebsiteRules()
            }
        }
    }

    @discardableResult
    func addWebsite(_ input: String) -> Bool {
        guard !configurationLocked else { return false }
        guard let domain = WebsiteRulesFile.normalizedDomain(input), !blockedWebsites.contains(domain) else { return false }
        blockedWebsites.append(domain)
        blockedWebsites.sort()
        defaults.set(blockedWebsites, forKey: "blockedWebsites")
        websiteStatus = ""
        return true
    }

    func removeWebsite(_ domain: String) {
        guard !configurationLocked else { return }
        blockedWebsites.removeAll { $0 == domain }
        defaults.set(blockedWebsites, forKey: "blockedWebsites")
    }

    @discardableResult
    func applyWebsiteRules(domains: [String]? = nil) async -> Bool {
        let requestedDomains = domains ?? blockedWebsites
        guard !requestedDomains.isEmpty else { return false }
        return await updateWebsiteRules(domains: requestedDomains, applying: true)
    }

    @discardableResult
    func clearWebsiteRules() async -> Bool {
        reconcileWebsiteState()
        guard requiresWebsiteCleanup else { return true }
        return await updateWebsiteRules(domains: [], applying: false)
    }

    func reconcileWebsiteState() {
        guard let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
            websiteStateReadable = false
            websiteRulesActive = false
            websiteStatus = WebsiteRulesError.unreadable.localizedDescription
            lastProtectionError = websiteStatus
            return
        }
        websiteStateReadable = true
        websiteRulesActive = WebsiteRulesFile.hasValidRules(in: hosts)
        if websiteRulesActive,
           websiteBlockingEnabled,
           !blockedWebsites.isEmpty,
           !WebsiteRulesFile.hasExactRules(in: hosts, domains: blockedWebsites) {
            websiteStatus = localized("系统网站规则与当前名单不一致，请重新开始专注或清除规则",
                                     "The system website rules do not match the current list. Start focus again or remove the rules.")
            lastProtectionError = websiteStatus
        } else if WebsiteRulesFile.containsAnyMarker(in: hosts), !websiteRulesActive {
            websiteStatus = WebsiteRulesError.malformedMarkers.localizedDescription
            lastProtectionError = websiteStatus
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        beginPermissionPolling()
        workspace.open(url)
    }

    func setConfigurationLocked(_ locked: Bool) {
        configurationLocked = locked
    }

    func refreshAccessibilityPermission() {
        accessibilityGranted = Self.accessibilityPermission()
        if accessibilityGranted {
            inputPermissionRequired = false
            if isMonitoring, !inputProtectionHealthy {
                inputProtectionHealthy = inputTap.start()
                if inputProtectionHealthy, inputProtectionWarning.hasPrefix(localized("系统暂时暂停", "The system briefly paused")) {
                    inputProtectionWarning = ""
                }
            }
            let permissionError = localized("请允许 PomoSentry 使用辅助功能后重新开始", "Allow PomoSentry in Accessibility, then start again")
            if lastProtectionError == permissionError { lastProtectionError = "" }
        } else if isEnabled {
            inputPermissionRequired = true
            if isMonitoring {
                inputProtectionHealthy = false
                inputProtectionWarning = localized("辅助功能权限已失效，输入保护正在等待恢复。", "Accessibility permission was revoked; input protection is waiting to recover.")
                lastProtectionError = inputProtectionWarning
            }
        }
    }

    func reportProtectionError(_ message: String) {
        lastProtectionError = message
    }

    func revealCurrentApplication() {
        workspace.activateFileViewerSelecting([Bundle.main.bundleURL])
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

        if !defaults.bool(forKey: "didRemoveLegacyDefaultAllowlistApps") {
            let legacyDefaults = Set(["com.apple.finder", "com.apple.systempreferences"])
            allowedApps.removeAll { legacyDefaults.contains($0.bundleID) }
            defaults.set(true, forKey: "didRemoveLegacyDefaultAllowlistApps")
        }
        allowedApps.removeAll { $0.bundleID == "com.fanqiezhong.mac" || $0.bundleID == mainBundleID }
        if let selfApp = ApplicationIdentity.enrolledApplication(at: Bundle.main.bundleURL) {
            allowedApps.insert(selfApp, at: 0)
        } else {
            allowedApps.insert(AllowedApplication(bundleID: mainBundleID, name: "PomoSentry", path: Bundle.main.bundlePath), at: 0)
        }
        saveApplications()
    }

    private func saveApplications() {
        defaults.set(try? JSONEncoder().encode(allowedApps), forKey: "allowedApps")
        defaults.set(try? JSONEncoder().encode(blockedApps), forKey: "blockedApps")
    }

    private func enforceCurrentApplication() {
        let application = workspace.frontmostApplication
        inputGate.updateFrontmostPID(application?.processIdentifier)
        enforce(application)
    }

    private func handleInputTapDisabled() {
        guard isMonitoring else { return }
        inputProtectionHealthy = false
        inputProtectionWarning = localized("系统暂时暂停了全局输入拦截，PomoSentry 已立即尝试恢复。",
                                           "The system briefly paused global input blocking; PomoSentry immediately attempted to restore it.")
        lastProtectionError = inputProtectionWarning
        if !Self.accessibilityPermission() {
            inputProtectionHealthy = false
            inputPermissionRequired = true
            beginPermissionPolling()
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                guard let self, self.isMonitoring, Self.accessibilityPermission() else { return }
                self.inputProtectionHealthy = self.inputTap.start()
            }
        }
    }

    private func refreshInputGate(frontmostApplication: NSRunningApplication?, configure: Bool = false) {
        guard let configuration = activeConfiguration else { return }
        let list = configuration.applications
        let listedPIDs = Set(workspace.runningApplications.compactMap { application -> pid_t? in
            guard !application.isTerminated,
                  isListed(application, in: list) else { return nil }
            return application.processIdentifier
        })
        activeListedPIDs = listedPIDs
        let navigationPIDs = Set(workspace.runningApplications.compactMap { application -> pid_t? in
            guard let bundleIdentifier = application.bundleIdentifier,
                  SystemNavigationSurface.bundleIdentifiers.contains(bundleIdentifier) else { return nil }
            return application.processIdentifier
        })
        let authorizationPIDs = administratorAuthorizationAllowed
            ? Set(workspace.runningApplications.compactMap { application -> pid_t? in
                guard let bundleIdentifier = application.bundleIdentifier,
                      SystemAuthorizationSurface.contains(bundleIdentifier: bundleIdentifier) else { return nil }
                return application.processIdentifier
            }).union(SystemAuthorizationSurface.visibleWindowPIDs())
            : []
        activeAuthorizationPIDs = authorizationPIDs
        if configure {
            inputGate.configure(policy: configuration.policy, listedPIDs: listedPIDs, navigationPIDs: navigationPIDs, authorizationPIDs: authorizationPIDs, frontmostPID: frontmostApplication?.processIdentifier)
        } else {
            inputGate.update(policy: configuration.policy, listedPIDs: listedPIDs, navigationPIDs: navigationPIDs, authorizationPIDs: authorizationPIDs, frontmostPID: frontmostApplication?.processIdentifier)
        }
    }

    private func beginPermissionPolling() {
        guard permissionPollingTask == nil else { return }
        permissionPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshAccessibilityPermission()
                if self?.accessibilityGranted == true {
                    if self?.lastBlockedApp == localized("请允许 PomoSentry 使用辅助功能后重新开始", "Allow PomoSentry in Accessibility, then start again") {
                        self?.lastBlockedApp = ""
                    }
                    self?.permissionPollingTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func accessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func enforce(_ application: NSRunningApplication?) {
        guard isMonitoring, let configuration = activeConfiguration, let application, !application.isTerminated else { return }
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            lastAllowedPID = application.processIdentifier
            activeBlockedPID = nil
            shieldController.dismiss()
            return
        }
        if SystemNavigationSurface.contains(bundleIdentifier: application.bundleIdentifier) {
            activeBlockedPID = nil
            shieldController.dismiss()
            return
        }
        if administratorAuthorizationAllowed,
           (SystemAuthorizationSurface.contains(bundleIdentifier: application.bundleIdentifier)
            || activeAuthorizationPIDs.contains(application.processIdentifier)) {
            activeBlockedPID = nil
            shieldController.dismiss()
            return
        }
        let isListed = activeListedPIDs.contains(application.processIdentifier)
        let shouldBlock = configuration.policy.shouldBlock(isListed: isListed)
        guard shouldBlock else {
            lastAllowedPID = application.processIdentifier
            activeBlockedPID = nil
            shieldController.dismiss()
            return
        }
        let applicationName = application.localizedName ?? application.bundleIdentifier ?? localized("未知应用", "Unknown app")
        lastBlockedApp = applicationName
        if activeBlockedPID != application.processIdentifier {
            activeBlockedPID = application.processIdentifier
            blockedCount += 1
        }
        shieldController.show(applicationName: applicationName, processIdentifier: application.processIdentifier)
        if configuration.blockingBehavior == .forceQuit {
            _ = application.forceTerminate()
        } else {
            hideForFocus(application)
        }
        reactivateLastAllowedApp()
    }

    private func hideDisallowedApplications() {
        guard let configuration = activeConfiguration, configuration.blockingBehavior == .keepRunning else { return }
        for application in workspace.runningApplications where !application.isTerminated {
            guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            guard !SystemNavigationSurface.contains(bundleIdentifier: application.bundleIdentifier) else { continue }
            guard !(administratorAuthorizationAllowed
                     && (SystemAuthorizationSurface.contains(bundleIdentifier: application.bundleIdentifier)
                         || activeAuthorizationPIDs.contains(application.processIdentifier))) else { continue }
            let isListed = activeListedPIDs.contains(application.processIdentifier)
            if configuration.policy.shouldBlock(isListed: isListed) {
                hideForFocus(application)
            }
        }
    }

    private func terminateDisallowedApplications() {
        guard let configuration = activeConfiguration, configuration.blockingBehavior == .forceQuit else { return }
        for application in workspace.runningApplications where !application.isTerminated {
            guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            guard !SystemNavigationSurface.contains(bundleIdentifier: application.bundleIdentifier) else { continue }
            guard !(administratorAuthorizationAllowed
                     && (SystemAuthorizationSurface.contains(bundleIdentifier: application.bundleIdentifier)
                         || activeAuthorizationPIDs.contains(application.processIdentifier))) else { continue }
            let isListed = activeListedPIDs.contains(application.processIdentifier)
            if configuration.policy.shouldBlock(isListed: isListed) {
                _ = application.forceTerminate()
            }
        }
    }

    private func hideForFocus(_ application: NSRunningApplication) {
        let wasHidden = application.isHidden
        if application.hide(), !wasHidden {
            hiddenByGuardPIDs.insert(application.processIdentifier)
        }
    }

    private func isListed(_ application: NSRunningApplication, in applications: [AllowedApplication]) -> Bool {
        if let cached = identityCache[application.processIdentifier] { return cached }
        let result = applications.contains { ApplicationIdentity.matches(application, enrolled: $0) }
        identityCache[application.processIdentifier] = result
        return result
    }

    private func restoreApplicationsHiddenByGuard() {
        let applications = workspace.runningApplications.filter { hiddenByGuardPIDs.contains($0.processIdentifier) && !$0.isTerminated }
        hiddenByGuardPIDs.removeAll()
        applications.forEach { _ = $0.unhide() }
    }

    private func reactivateLastAllowedApp() {
        if let pid = lastAllowedPID,
           let application = workspace.runningApplications.first(where: { $0.processIdentifier == pid && !$0.isTerminated }),
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            _ = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        } else {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { !($0 is FocusShieldPanel) && $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        }
    }

    private func updateWebsiteRules(domains: [String], applying: Bool) async -> Bool {
        guard !websiteOperationInProgress else {
            websiteStatus = localized("已有网站规则操作正在进行", "A website-rule operation is already in progress")
            lastProtectionError = websiteStatus
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
            guard let current = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else {
                websiteStateReadable = false
                throw WebsiteRulesError.unreadable
            }
            websiteStateReadable = true
            websiteRulesActive = WebsiteRulesFile.hasValidRules(in: current)
            let postconditionOK = domains.isEmpty
                ? !WebsiteRulesFile.containsAnyMarker(in: current)
                : WebsiteRulesFile.hasExactRules(in: current, domains: domains)
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
                lastProtectionError = websiteStatus
                return false
            }
            guard postconditionOK else { throw WebsiteRulesError.postcondition }
            websiteStatus = applying
                ? localized("网站域名拦截已生效", "Website-domain blocking is active")
                : localized("网站规则已安全清除", "Website rules were removed safely")
            lastProtectionError = ""
            return true
        } catch {
            reconcileWebsiteState()
            websiteStatus = error.localizedDescription
            lastProtectionError = websiteStatus
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
    case paused
    case cleaning
}

private enum CleanupRecovery {
    case failedStart
    case completedRound
    case reset
}

struct SessionJournal: Codable, Sendable {
    let id: UUID
    let mode: TimerMode
    let plannedSeconds: Int
    let deadline: Date?
    let selectedTaskID: UUID?
    let strictApps: Bool
    let strictWebsites: Bool
    let remainingSeconds: Int?
    let strictAppConfiguration: StrictAppConfiguration?
    let websiteDomains: [String]?

    init(
        id: UUID,
        mode: TimerMode,
        plannedSeconds: Int,
        deadline: Date?,
        selectedTaskID: UUID?,
        strictApps: Bool,
        strictWebsites: Bool,
        remainingSeconds: Int? = nil,
        strictAppConfiguration: StrictAppConfiguration? = nil,
        websiteDomains: [String]? = nil
    ) {
        self.id = id
        self.mode = mode
        self.plannedSeconds = plannedSeconds
        self.deadline = deadline
        self.selectedTaskID = selectedTaskID
        self.strictApps = strictApps
        self.strictWebsites = strictWebsites
        self.remainingSeconds = remainingSeconds
        self.strictAppConfiguration = strictAppConfiguration
        self.websiteDomains = websiteDomains
    }
}

enum Countdown {
    static func remaining(deadline: Date, now: Date = Date()) -> Int {
        max(0, Int(ceil(deadline.timeIntervalSince(now))))
    }
}

enum CalendarDayStamp {
    static func value(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(components.era ?? 0)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}

@MainActor
final class TimerStore: ObservableObject {
    @Published var mode: TimerMode = .focus
    @Published private(set) var secondsRemaining = TimerMode.focus.duration
    @Published var focusMinutes = 25
    @Published var shortBreakMinutes = 5
    @Published var longBreakMinutes = 15
    @Published private(set) var phase: SessionPhase = .idle
    @Published var completedPomodoros = 0
    @Published var dailyGoal = 8
    @Published var tasks: [PomodoroTask] = []
    @Published var selectedTaskID: UUID?
    @Published var newTaskTitle = ""
    @Published var newTaskDueChoice: TaskDueChoice = .today
    @Published var soundEnabled = true
    let focusGuard = FocusGuard()

    private let defaults = UserDefaults.standard
    private var session: SessionJournal?
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleGeneration = UUID()
    private var completionInProgress = false
    private var cleanupRecovery: CleanupRecovery?
    private var pomodoroCycleCount = 0
    private var lastFinalizedSessionID: UUID?

    init() {
        load()
        if let savedSession = session {
            phase = .preparing
            focusGuard.setConfigurationLocked(savedSession.strictApps || savedSession.strictWebsites)
        }
        Task { await restoreSessionIfNeeded() }
    }

    var isRunning: Bool { phase == .running }
    var isPaused: Bool { phase == .paused }
    var isPreparing: Bool { phase == .preparing || phase == .cleaning }
    var isBusyOrLocked: Bool { isPreparing || isStrictlyLocked }
    var canRetryProtection: Bool {
        if phase == .cleaning {
            return cleanupRecovery != nil && !focusGuard.isWebsiteOperationInProgress
        }
        return phase == .preparing
            && (session?.deadline != nil || session?.strictWebsites == true)
            && !focusGuard.isWebsiteOperationInProgress
            && !(session?.strictApps == true && !focusGuard.accessibilityGranted)
    }
    var totalSeconds: Int { session?.plannedSeconds ?? duration(for: mode) }
    var progress: Double { totalSeconds > 0 ? min(max(1 - Double(secondsRemaining) / Double(totalSeconds), 0), 1) : 0 }
    var timeString: String { String(format: "%02d:%02d", secondsRemaining / 60, secondsRemaining % 60) }
    var menuBarTitle: String { isRunning || isPaused ? timeString : "PomoSentry" }
    func primaryActionTitle(language: String? = nil) -> String {
        if isPreparing { return localized("正在准备", "Preparing", language: language) }
        if isStrictlyLocked { return localized("严格专注中", "Focus Locked", language: language) }
        if isRunning { return localized("暂停", "Pause", language: language) }
        if isPaused { return localized("继续", "Resume", language: language) }
        return localized("开始", "Start", language: language)
    }

    func timerStateTitle(language: String? = nil) -> String {
        if isRunning { return localized("进行中", "In Progress", language: language) }
        if isPaused { return localized("已暂停", "Paused", language: language) }
        return localized("准备开始", "Ready", language: language)
    }
    var isStrictlyLocked: Bool {
        guard mode == .focus, session?.strictApps == true || session?.strictWebsites == true else { return false }
        return phase != .idle
    }
    var requiresTerminationCleanup: Bool {
        isPreparing || session?.strictWebsites == true || focusGuard.requiresWebsiteCleanup
    }
    func isTaskLockedToCurrentSession(_ id: UUID) -> Bool {
        phase != .idle && session?.selectedTaskID == id
    }

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
        if phase == .paused { return english ? "Paused · \(name) · \(timeString)" : "已暂停 · \(name) · \(timeString)" }
        return isRunning ? (english ? "\(name) · \(timeString)" : "正在\(name) · \(timeString)") : (english ? "Ready for \(name) · \(timeString)" : "准备\(name) · \(timeString)")
    }

    var todayTasks: [PomodoroTask] {
        tasks.filter { TaskVisibility.belongsInToday($0) }
    }

    func tick(now: Date = Date()) {
        rolloverDailyProgressIfNeeded(now: now)
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
            pauseCurrentRound()
        } else if isPaused {
            resumePausedRound()
        } else {
            lifecycleTask = Task { await startCurrentRound() }
        }
    }

    func resetTimer() {
        guard !isBusyOrLocked else { return }
        lifecycleTask = Task { await transitionToIdle(resetClock: true) }
    }

    func retryProtectionSetup() {
        guard canRetryProtection else { return }
        if phase == .cleaning {
            lifecycleTask = Task { await retryCleanup() }
        } else {
            lifecycleTask = Task { await restoreSessionIfNeeded() }
        }
    }

    func selectMode(_ newMode: TimerMode) {
        guard phase == .idle else { return }
        mode = newMode
        secondsRemaining = duration(for: newMode)
        saveGeneralState()
    }

    func setFocusMinutes(_ minutes: Int) {
        setMinutes(minutes, for: .focus)
    }

    func setMinutes(_ minutes: Int, for timerMode: TimerMode) {
        guard phase == .idle else { return }
        switch timerMode {
        case .focus:
            focusMinutes = min(max(minutes, 1), 240)
            defaults.set(focusMinutes, forKey: "focusMinutes")
        case .shortBreak:
            shortBreakMinutes = min(max(minutes, 1), 60)
            defaults.set(shortBreakMinutes, forKey: "shortBreakMinutes")
        case .longBreak:
            longBreakMinutes = min(max(minutes, 1), 120)
            defaults.set(longBreakMinutes, forKey: "longBreakMinutes")
        }
        if mode == timerMode { secondsRemaining = duration(for: timerMode) }
    }

    func setDailyGoal(_ goal: Int) {
        dailyGoal = min(max(goal, 1), 24)
        defaults.set(dailyGoal, forKey: "dailyGoal")
    }

    func setSoundEnabled(_ enabled: Bool) {
        soundEnabled = enabled
        defaults.set(enabled, forKey: "soundEnabled")
    }

    func addTask() {
        guard phase == .idle else { return }
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = PomodoroTask(title: title, dueDate: dueDate(for: newTaskDueChoice))
        tasks.append(task)
        selectedTaskID = task.id
        newTaskTitle = ""
        saveGeneralState()
    }

    func selectTask(_ id: UUID?) {
        guard phase == .idle else { return }
        selectedTaskID = id
        saveGeneralState()
    }

    func setTaskDueChoice(_ choice: TaskDueChoice, for task: PomodoroTask) {
        guard !isTaskLockedToCurrentSession(task.id),
              let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].dueDate = dueDate(for: choice)
        saveGeneralState()
    }

    func taskDueChoice(for task: PomodoroTask) -> TaskDueChoice {
        guard let date = task.dueDate else { return .unscheduled }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInTomorrow(date) { return .tomorrow }
        return .unscheduled
    }

    func toggleTask(_ task: PomodoroTask) {
        guard phase == .idle else { return }
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].isDone.toggle()
        saveGeneralState()
    }

    func deleteTask(_ task: PomodoroTask) {
        guard !isTaskLockedToCurrentSession(task.id) else { return }
        tasks.removeAll { $0.id == task.id }
        if selectedTaskID == task.id { selectedTaskID = nil }
        saveGeneralState()
    }

    func prepareForTermination() async -> Bool {
        lifecycleGeneration = UUID()
        let pending = lifecycleTask
        pending?.cancel()
        await pending?.value
        phase = .cleaning
        cleanupRecovery = .reset
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
        let strictAppConfiguration = strictApps ? focusGuard.currentConfiguration : nil
        let websiteDomains = strictWebsites ? focusGuard.blockedWebsites : nil
        focusGuard.setConfigurationLocked(strictApps || strictWebsites)
        phase = .preparing
        session = SessionJournal(
            id: generation,
            mode: mode,
            plannedSeconds: planned,
            deadline: nil,
            selectedTaskID: selectedTaskID,
            strictApps: strictApps,
            strictWebsites: strictWebsites,
            strictAppConfiguration: strictAppConfiguration,
            websiteDomains: websiteDomains
        )
        saveSession()

        if strictApps, !focusGuard.validateAccessibilityPermission() {
            clearSession()
            phase = .idle
            return
        }
        if strictApps, !focusGuard.startMonitoring(
            configuration: strictAppConfiguration,
            allowAdministratorAuthorization: strictWebsites
        ) {
            clearSession()
            phase = .idle
            return
        }
        if strictWebsites {
            let success = await focusGuard.applyWebsiteRules(domains: websiteDomains)
            guard lifecycleGeneration == generation, !Task.isCancelled else {
                focusGuard.stopMonitoring()
                _ = await focusGuard.clearWebsiteRules()
                return
            }
            guard success else {
                focusGuard.stopMonitoring()
                let cleaned = await focusGuard.clearWebsiteRules()
                if cleaned {
                    clearSession()
                    phase = .idle
                } else {
                    cleanupRecovery = .failedStart
                    phase = .cleaning
                }
                return
            }
            if strictApps {
                focusGuard.setAdministratorAuthorizationAllowed(false)
            }
        }

        let deadline = Date().addingTimeInterval(TimeInterval(planned))
        session = SessionJournal(
            id: generation,
            mode: mode,
            plannedSeconds: planned,
            deadline: deadline,
            selectedTaskID: selectedTaskID,
            strictApps: strictApps,
            strictWebsites: strictWebsites,
            strictAppConfiguration: strictAppConfiguration,
            websiteDomains: websiteDomains
        )
        secondsRemaining = planned
        phase = .running
        saveSession()
    }

    private func pauseCurrentRound(now: Date = Date()) {
        guard phase == .running, !isStrictlyLocked, let current = session, let deadline = current.deadline else { return }
        let remaining = Countdown.remaining(deadline: deadline, now: now)
        guard remaining > 0 else {
            tick(now: now)
            return
        }
        secondsRemaining = remaining
        session = SessionJournal(
            id: current.id,
            mode: current.mode,
            plannedSeconds: current.plannedSeconds,
            deadline: nil,
            selectedTaskID: current.selectedTaskID,
            strictApps: false,
            strictWebsites: false,
            remainingSeconds: remaining
        )
        phase = .paused
        saveSession()
    }

    private func resumePausedRound() {
        guard phase == .paused, let current = session, let remaining = current.remainingSeconds, remaining > 0 else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(remaining))
        session = SessionJournal(
            id: current.id,
            mode: current.mode,
            plannedSeconds: current.plannedSeconds,
            deadline: deadline,
            selectedTaskID: current.selectedTaskID,
            strictApps: false,
            strictWebsites: false
        )
        secondsRemaining = remaining
        phase = .running
        saveSession()
    }

    private func transitionToIdle(resetClock: Bool) async {
        guard !isStrictlyLocked else { return }
        lifecycleGeneration = UUID()
        phase = .cleaning
        cleanupRecovery = .reset
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
        guard let completedSession = session else {
            completionInProgress = false
            return
        }
        let completedMode = completedSession.mode
        let completedTaskID = completedSession.selectedTaskID
        phase = .cleaning
        cleanupRecovery = .completedRound
        let cleaned = await focusGuard.clearWebsiteRules()
        guard cleaned else {
            phase = .cleaning
            return
        }
        focusGuard.stopMonitoring()
        if lastFinalizedSessionID != completedSession.id {
            if completedMode == .focus {
                completedPomodoros += 1
                pomodoroCycleCount += 1
                if let id = completedTaskID, let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].pomodoros += 1 }
                mode = PomodoroSequence.nextMode(after: pomodoroCycleCount)
            } else {
                mode = .focus
            }
            lastFinalizedSessionID = completedSession.id
            saveGeneralState()
        }
        clearSession()
        secondsRemaining = duration(for: mode)
        phase = .idle
        completionInProgress = false
        if soundEnabled { NSSound(named: "Glass")?.play() }
        saveGeneralState()
    }

    private func retryCleanup() async {
        guard phase == .cleaning, let recovery = cleanupRecovery else { return }
        let cleaned = await focusGuard.clearWebsiteRules()
        guard cleaned else { return }
        switch recovery {
        case .completedRound:
            await completeCurrentRound()
        case .failedStart, .reset:
            focusGuard.stopMonitoring()
            clearSession()
            phase = .idle
            secondsRemaining = duration(for: mode)
            saveGeneralState()
        }
    }

    private func restoreSessionIfNeeded() async {
        guard let saved = session else { return }
        mode = saved.mode
        focusGuard.setConfigurationLocked(saved.strictApps || saved.strictWebsites)
        selectedTaskID = saved.selectedTaskID.flatMap { id in tasks.contains(where: { $0.id == id }) ? id : nil }
        guard let deadline = saved.deadline else {
            if let remaining = saved.remainingSeconds,
               remaining > 0,
               !saved.strictApps,
               !saved.strictWebsites {
                secondsRemaining = min(remaining, saved.plannedSeconds)
                phase = .paused
                return
            }
            focusGuard.stopMonitoring()
            let cleaned = await focusGuard.clearWebsiteRules()
            guard cleaned else {
                cleanupRecovery = .reset
                phase = .cleaning
                secondsRemaining = duration(for: mode)
                return
            }
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
        if (saved.strictApps && saved.strictAppConfiguration == nil)
            || (saved.strictWebsites && saved.websiteDomains == nil) {
            focusGuard.stopMonitoring()
            focusGuard.reportProtectionError(localized(
                "检测到旧版本严格会话，原保护名单无法验证；会话已安全结束，请重新开始。",
                "This strict session was created by an older version and its original protection list cannot be verified. The session was safely ended; start a new one."
            ))
            let cleaned = await focusGuard.clearWebsiteRules()
            guard cleaned else {
                cleanupRecovery = .reset
                phase = .cleaning
                secondsRemaining = duration(for: mode)
                return
            }
            clearSession()
            phase = .idle
            secondsRemaining = duration(for: mode)
            return
        }
        if saved.strictApps {
            while !focusGuard.validateAccessibilityPermission() {
                phase = .preparing
                secondsRemaining = Countdown.remaining(deadline: deadline)
                if secondsRemaining == 0 {
                    phase = .running
                    completionInProgress = true
                    await completeCurrentRound()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let restoredWebsiteDomains = saved.websiteDomains ?? focusGuard.blockedWebsites
        if saved.strictWebsites {
            guard !restoredWebsiteDomains.isEmpty else {
                focusGuard.stopMonitoring()
                let cleaned = await focusGuard.clearWebsiteRules()
                guard cleaned else {
                    cleanupRecovery = .reset
                    phase = .cleaning
                    secondsRemaining = duration(for: mode)
                    return
                }
                clearSession()
                phase = .idle
                secondsRemaining = duration(for: mode)
                return
            }
            focusGuard.reconcileWebsiteState()
        }
        let websiteNeedsApply = saved.strictWebsites && !focusGuard.websiteRulesMatch(domains: restoredWebsiteDomains)
        if saved.strictApps {
            while !focusGuard.startMonitoring(
                configuration: saved.strictAppConfiguration,
                allowAdministratorAuthorization: websiteNeedsApply
            ) {
                phase = .preparing
                secondsRemaining = Countdown.remaining(deadline: deadline)
                if secondsRemaining == 0 {
                    phase = .running
                    completionInProgress = true
                    await completeCurrentRound()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if saved.strictWebsites, websiteNeedsApply {
            phase = .preparing
            guard await focusGuard.applyWebsiteRules(domains: restoredWebsiteDomains) else {
                phase = .preparing
                secondsRemaining = Countdown.remaining(deadline: deadline)
                return
            }
            if saved.strictApps {
                focusGuard.setAdministratorAuthorizationAllowed(false)
            }
        }
        phase = .running
        tick()
    }

    private func saveGeneralState() {
        defaults.set(try? JSONEncoder().encode(tasks), forKey: "tasks")
        defaults.set(completedPomodoros, forKey: "completedPomodoros")
        defaults.set(pomodoroCycleCount, forKey: "pomodoroCycleCount")
        defaults.set(CalendarDayStamp.value(), forKey: "completedPomodorosDay")
        defaults.set(soundEnabled, forKey: "soundEnabled")
        defaults.set(selectedTaskID?.uuidString, forKey: "selectedTaskID")
        defaults.set(mode.rawValue, forKey: "timerMode")
        defaults.set(lastFinalizedSessionID?.uuidString, forKey: "lastFinalizedSessionID")
    }

    private func saveSession() {
        defaults.set(try? JSONEncoder().encode(session), forKey: "activeSession")
        saveGeneralState()
    }

    private func clearSession() {
        session = nil
        cleanupRecovery = nil
        defaults.removeObject(forKey: "activeSession")
        focusGuard.setConfigurationLocked(false)
    }

    private func load() {
        let savedMinutes = defaults.integer(forKey: "focusMinutes")
        focusMinutes = savedMinutes > 0 ? min(max(savedMinutes, 1), 240) : 25
        let savedShortBreak = defaults.integer(forKey: "shortBreakMinutes")
        shortBreakMinutes = savedShortBreak > 0 ? min(max(savedShortBreak, 1), 60) : 5
        let savedLongBreak = defaults.integer(forKey: "longBreakMinutes")
        longBreakMinutes = savedLongBreak > 0 ? min(max(savedLongBreak, 1), 120) : 15
        let savedGoal = defaults.integer(forKey: "dailyGoal")
        dailyGoal = savedGoal > 0 ? min(max(savedGoal, 1), 24) : 8
        if let raw = defaults.string(forKey: "timerMode"), let savedMode = TimerMode(rawValue: raw) { mode = savedMode }
        if let data = defaults.data(forKey: "tasks"), let decoded = try? JSONDecoder().decode([PomodoroTask].self, from: data) { tasks = decoded }
        completedPomodoros = defaults.integer(forKey: "completedPomodoros")
        pomodoroCycleCount = defaults.object(forKey: "pomodoroCycleCount") as? Int ?? completedPomodoros
        if let value = defaults.string(forKey: "lastFinalizedSessionID") { lastFinalizedSessionID = UUID(uuidString: value) }
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        rolloverDailyProgressIfNeeded()
        if let value = defaults.string(forKey: "selectedTaskID"), let id = UUID(uuidString: value), tasks.contains(where: { $0.id == id }) { selectedTaskID = id }
        if let data = defaults.data(forKey: "activeSession"), let decoded = try? JSONDecoder().decode(SessionJournal.self, from: data) { session = decoded }
        secondsRemaining = duration(for: mode)
    }

    private func rolloverDailyProgressIfNeeded(now: Date = Date()) {
        let today = CalendarDayStamp.value(for: now)
        guard let recordedDay = defaults.string(forKey: "completedPomodorosDay") else {
            completedPomodoros = 0
            defaults.set(0, forKey: "completedPomodoros")
            defaults.set(today, forKey: "completedPomodorosDay")
            return
        }
        guard recordedDay != today else { return }
        completedPomodoros = 0
        defaults.set(0, forKey: "completedPomodoros")
        defaults.set(today, forKey: "completedPomodorosDay")
    }

    private func duration(for mode: TimerMode) -> Int {
        switch mode {
        case .focus: focusMinutes * 60
        case .shortBreak: shortBreakMinutes * 60
        case .longBreak: longBreakMinutes * 60
        }
    }

    private func dueDate(for choice: TaskDueChoice) -> Date? {
        switch choice {
        case .today:
            Date()
        case .tomorrow:
            Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case .unscheduled:
            nil
        }
    }
}
