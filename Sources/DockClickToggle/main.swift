import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ServiceManagement

struct DockItem {
    let title: String
    let url: URL
    let frame: CGRect
}

struct PendingClick {
    let bundleIdentifier: String
    let appName: String
    let downPoint: CGPoint
    let downAt: Date
}

struct StatusPayload: Codable {
    let state: String
    let pid: Int32
    let version: String
    let accessibilityTrusted: Bool
    let inputMonitoringGranted: Bool
    let eventTapCreated: Bool
    let lastStartedAt: String
    let lastUpdatedAt: String
    let lastUpdatedUnix: Int
    let lastError: String?
}

final class StatusStore {
    private let startedAt = ISO8601DateFormatter().string(from: Date())
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DockClickToggle", isDirectory: true)
    }

    var statusURL: URL {
        supportDirectory.appendingPathComponent("status.json")
    }

    func write(
        state: String,
        accessibilityTrusted: Bool,
        inputMonitoringGranted: Bool,
        eventTapCreated: Bool,
        lastError: String?
    ) {
        let now = Date()
        let payload = StatusPayload(
            state: state,
            pid: getpid(),
            version: "1.0",
            accessibilityTrusted: accessibilityTrusted,
            inputMonitoringGranted: inputMonitoringGranted,
            eventTapCreated: eventTapCreated,
            lastStartedAt: startedAt,
            lastUpdatedAt: ISO8601DateFormatter().string(from: now),
            lastUpdatedUnix: Int(now.timeIntervalSince1970),
            lastError: lastError
        )

        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(payload)
            try data.write(to: statusURL, options: .atomic)
        } catch {
            fputs("DockClickToggle: failed to write status: \(error)\n", stderr)
        }

        try? state.write(toFile: "/tmp/dock-click-toggle.status", atomically: true, encoding: .utf8)
    }
}

final class DockClickToggle {
    private var eventTap: CFMachPort?
    private var heartbeatTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var pendingClick: PendingClick?
    private var dockItemCache: [DockItem] = []
    private var lastDockCacheRefresh = Date.distantPast
    private var lastActionAt = Date.distantPast
    private var lastAXPermissionLogAt = Date.distantPast
    private var consecutiveTimeouts = 0
    private var isRecoveringEventTap = false
    private var isTearingDown = false
    private let statusStore = StatusStore()
    private let maxConsecutiveTimeouts = 5
    private let maxClickMovement: CGFloat = 5
    private let maxClickDuration: TimeInterval = 0.50
    private let dockCacheTTL: TimeInterval = 2.0
    private let axPermissionLogInterval: TimeInterval = 30

    func start() {
        installSignalHandlers()
        writeStatus(state: "STARTING", eventTapCreated: false, lastError: nil)

        guard checkRequiredPermissions() else {
            Darwin.exit(1)
        }

        let mask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let instance = Unmanaged<DockClickToggle>.fromOpaque(userInfo).takeUnretainedValue()
            return instance.handle(type: type, event: event)
        }

        for attempt in 0..<3 {
            eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            if eventTap != nil { break }
            fputs("DockClickToggle: event tap attempt \(attempt + 1) failed, retrying in 2s...\n", stderr)
            Thread.sleep(forTimeInterval: 2)
        }

        guard let eventTap else {
            writeStatus(
                state: "FAIL",
                eventTapCreated: false,
                lastError: "event_tap_create_failed"
            )
            fputs("DockClickToggle: failed to create event tap after 3 attempts. Grant Input Monitoring permission.\n", stderr)
            Darwin.exit(1)
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        writeStatus(state: "OK", eventTapCreated: true, lastError: nil)
        startHeartbeat()
        fputs("DockClickToggle: running.\n", stderr)
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                consecutiveTimeouts += 1
                if consecutiveTimeouts > maxConsecutiveTimeouts {
                    fputs("DockClickToggle: event tap disabled \(consecutiveTimeouts) times. Re-enabling after 2s.\n", stderr)
                    consecutiveTimeouts = 0
                    isRecoveringEventTap = true
                    writeStatus(
                        state: "RECOVERING",
                        eventTapCreated: false,
                        lastError: "event_tap_reenable"
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self, let eventTap = self.eventTap else { return }
                        CGEvent.tapEnable(tap: eventTap, enable: true)
                        self.isRecoveringEventTap = false
                        self.writeStatus(state: "OK", eventTapCreated: true, lastError: nil)
                    }
                    return Unmanaged.passUnretained(event)
                }
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        consecutiveTimeouts = 0

        switch type {
        case .leftMouseDown:
            return handleMouseDown(event)
        case .leftMouseUp:
            return handleMouseUp(event)
        case .leftMouseDragged:
            if pendingClick != nil {
                pendingClick = nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        pendingClick = nil

        guard !hasModifierKeys(event) else {
            return Unmanaged.passUnretained(event)
        }

        let point = event.location
        guard let item = dockItem(at: point),
              let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontmost.bundleIdentifier,
              let bundleURL = frontmost.bundleURL,
              sameFileURL(item.url, bundleURL),
              hasUnminimizedWindow(bundleIdentifier: bundleIdentifier),
              Date().timeIntervalSince(lastActionAt) > 0.18 else {
            return Unmanaged.passUnretained(event)
        }

        pendingClick = PendingClick(
            bundleIdentifier: bundleIdentifier,
            appName: item.title,
            downPoint: point,
            downAt: Date()
        )
        return nil
    }

    private func handleMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let pending = pendingClick else {
            return Unmanaged.passUnretained(event)
        }
        pendingClick = nil

        let upPoint = event.location
        let duration = Date().timeIntervalSince(pending.downAt)
        guard distance(pending.downPoint, upPoint) <= maxClickMovement,
              duration <= maxClickDuration,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == pending.bundleIdentifier else {
            return Unmanaged.passUnretained(event)
        }

        lastActionAt = Date()
        minimizeWindows(bundleIdentifier: pending.bundleIdentifier)
        return nil
    }

    private func writeStatus(state: String, eventTapCreated: Bool, lastError: String?) {
        statusStore.write(
            state: state,
            accessibilityTrusted: AXIsProcessTrusted(),
            inputMonitoringGranted: CGPreflightListenEventAccess(),
            eventTapCreated: eventTapCreated,
            lastError: lastError
        )
    }

    private func checkRequiredPermissions() -> Bool {
        let accessibilityTrusted = AXIsProcessTrusted()
        let inputMonitoringGranted = CGPreflightListenEventAccess()
        guard accessibilityTrusted && inputMonitoringGranted else {
            var missing: [String] = []
            if !accessibilityTrusted {
                missing.append("Accessibility")
            }
            if !inputMonitoringGranted {
                missing.append("Input Monitoring")
            }

            let lastError = missing
                .map { $0.lowercased().replacingOccurrences(of: " ", with: "_") + "_not_granted" }
                .joined(separator: "+")

            writeStatus(state: "FAIL", eventTapCreated: false, lastError: lastError)
            fputs(
                "DockClickToggle: missing permission(s): \(missing.joined(separator: ", ")). Enable them in System Settings, or run DockClickToggle --request-permissions manually.\n",
                stderr
            )
            return false
        }

        return true
    }

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isRecoveringEventTap {
                self.writeStatus(
                    state: "RECOVERING",
                    eventTapCreated: false,
                    lastError: "event_tap_reenable"
                )
                return
            }

            self.writeStatus(
                state: self.eventTap == nil ? "FAIL" : "OK",
                eventTapCreated: self.eventTap != nil,
                lastError: self.eventTap == nil ? "event_tap_missing" : nil
            )
        }
    }

    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.teardown()
        }
        term.resume()

        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { [weak self] in
            self?.teardown()
        }
        interrupt.resume()

        signalSources = [term, interrupt]
    }

    private func teardown() {
        guard !isTearingDown else {
            return
        }

        isTearingDown = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        writeStatus(state: "STOPPED", eventTapCreated: false, lastError: nil)
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        CFRunLoopStop(CFRunLoopGetMain())
    }

    private func hasModifierKeys(_ event: CGEvent) -> Bool {
        let flags = event.flags
        return flags.contains(.maskCommand) ||
            flags.contains(.maskAlternate) ||
            flags.contains(.maskControl) ||
            flags.contains(.maskShift)
    }

    private func dockItem(at point: CGPoint) -> DockItem? {
        refreshDockItemCacheIfNeeded()

        return dockItemCache.first {
            $0.frame.insetBy(dx: -3, dy: -3).contains(point)
        }
    }

    private func refreshDockItemCacheIfNeeded() {
        guard Date().timeIntervalSince(lastDockCacheRefresh) > dockCacheTTL else {
            return
        }

        dockItemCache = loadDockItems()
        lastDockCacheRefresh = Date()
    }

    private func loadDockItems() -> [DockItem] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return []
        }

        let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
        let items = collectDockItems(from: dockAX)

        return items.compactMap { element in
            guard axString(element, kAXSubroleAttribute) == kAXApplicationDockItemSubrole as String,
                  let title = axString(element, kAXTitleAttribute),
                  let url = axURL(element, "AXURL"),
                  let frame = axFrame(element) else {
                return nil
            }
            return DockItem(title: title, url: url, frame: frame)
        }
    }

    private func collectDockItems(from root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [AXUIElement] = [root]
        var index = 0

        while index < queue.count {
            let element = queue[index]
            index += 1

            if axString(element, kAXSubroleAttribute) == kAXApplicationDockItemSubrole as String {
                result.append(element)
                continue
            }

            if let children = axArray(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children)
            }
        }

        return result
    }

    private func hasUnminimizedWindow(bundleIdentifier: String) -> Bool {
        guard let app = runningApplication(bundleIdentifier: bundleIdentifier),
              !app.isHidden,
              let windows = appWindows(app) else {
            return false
        }

        return windows.contains { window in
            axBool(window, kAXMinimizedAttribute) == false
        }
    }

    private func minimizeWindows(bundleIdentifier: String) {
        guard let app = runningApplication(bundleIdentifier: bundleIdentifier),
              let windows = appWindows(app) else {
            return
        }

        var minimized = 0
        var failed = 0
        for window in windows where axBool(window, kAXMinimizedAttribute) == false {
            let result = AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanTrue
            )
            if result == .success {
                minimized += 1
            } else {
                failed += 1
            }
        }

        if minimized == 0 && failed > 0 {
            fputs("DockClickToggle: failed to minimize visible windows for \(bundleIdentifier); not hiding app.\n", stderr)
        }
    }

    private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }
    }

    private func appWindows(_ app: NSRunningApplication) -> [AXUIElement]? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        return axArray(axApp, kAXWindowsAttribute)
    }

    private func sameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path ==
            rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return sqrt(dx * dx + dy * dy)
    }

    private func axArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            if result == .apiDisabled {
                logAXPermissionIssue(attribute: attribute, result: result)
            }
            return nil
        }
        return value as? [AXUIElement]
    }

    private func logAXPermissionIssue(attribute: String, result: AXError) {
        let now = Date()
        guard now.timeIntervalSince(lastAXPermissionLogAt) > axPermissionLogInterval else {
            return
        }

        lastAXPermissionLogAt = now
        fputs(
            "DockClickToggle: Accessibility API error \(result.rawValue) while reading \(attribute). Check System Settings > Privacy & Security > Accessibility.\n",
            stderr
        )
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func axURL(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? URL
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero

        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              let positionValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) else {
            return nil
        }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let sizeValue,
              CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }
}

enum LoginItemCommand {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let command = arguments.dropFirst().first else {
            return false
        }

        switch command {
        case "--register-login-item":
            register()
            return true
        case "--unregister-login-item":
            unregister()
            return true
        case "--login-item-status":
            printStatus()
            return true
        case "--register-agent-login-item":
            registerAgent()
            return true
        case "--unregister-agent-login-item":
            unregisterAgent()
            return true
        case "--agent-login-item-status":
            printAgentStatus()
            return true
        case "--open-login-items-settings":
            openSystemSettings()
            return true
        case "--request-permissions":
            requestPermissions()
            return true
        case "--permission-status":
            printPermissionStatus()
            return true
        default:
            return false
        }
    }

    private static func register() {
        guard #available(macOS 13.0, *) else {
            fputs("DockClickToggle: SMAppService requires macOS 13 or later.\n", stderr)
            Darwin.exit(2)
        }

        do {
            if SMAppService.mainApp.status == .enabled {
                print("loginItemStatus=\(statusString(SMAppService.mainApp.status))")
                return
            }

            try SMAppService.mainApp.register()
            print("loginItemStatus=\(statusString(SMAppService.mainApp.status))")
        } catch {
            fputs("DockClickToggle: failed to register login item: \(error)\n", stderr)
            print("loginItemStatus=\(statusString(SMAppService.mainApp.status))")
            Darwin.exit(1)
        }
    }

    private static func unregister() {
        guard #available(macOS 13.0, *) else {
            fputs("DockClickToggle: SMAppService requires macOS 13 or later.\n", stderr)
            Darwin.exit(2)
        }

        do {
            let status = SMAppService.mainApp.status
            if status == .notRegistered || status == .notFound {
                print("loginItemStatus=\(statusString(SMAppService.mainApp.status))")
                return
            }

            try SMAppService.mainApp.unregister()
            print("loginItemStatus=\(statusString(SMAppService.mainApp.status))")
        } catch {
            fputs("DockClickToggle: failed to unregister login item: \(error)\n", stderr)
            print("loginItemStatus=\(statusString(SMAppService.mainApp.status))")
            Darwin.exit(1)
        }
    }

    private static func printStatus() {
        guard #available(macOS 13.0, *) else {
            print("loginItemStatus=unavailable")
            return
        }

        print("loginItemStatus=\(statusString(SMAppService.mainApp.status))")
    }

    private static func registerAgent() {
        guard #available(macOS 13.0, *) else {
            fputs("DockClickToggle: SMAppService requires macOS 13 or later.\n", stderr)
            Darwin.exit(2)
        }

        let service = SMAppService.loginItem(identifier: "local.dock-click-toggle.agent")
        do {
            if service.status == .enabled {
                print("agentLoginItemStatus=\(statusString(service.status))")
                return
            }

            try service.register()
            print("agentLoginItemStatus=\(statusString(service.status))")
        } catch {
            fputs("DockClickToggle: failed to register agent login item: \(error)\n", stderr)
            print("agentLoginItemStatus=\(statusString(service.status))")
            Darwin.exit(1)
        }
    }

    private static func unregisterAgent() {
        guard #available(macOS 13.0, *) else {
            fputs("DockClickToggle: SMAppService requires macOS 13 or later.\n", stderr)
            Darwin.exit(2)
        }

        let service = SMAppService.loginItem(identifier: "local.dock-click-toggle.agent")
        do {
            let status = service.status
            if status == .notRegistered || status == .notFound {
                print("agentLoginItemStatus=\(statusString(service.status))")
                return
            }

            try service.unregister()
            print("agentLoginItemStatus=\(statusString(service.status))")
        } catch {
            fputs("DockClickToggle: failed to unregister agent login item: \(error)\n", stderr)
            print("agentLoginItemStatus=\(statusString(service.status))")
            Darwin.exit(1)
        }
    }

    private static func printAgentStatus() {
        guard #available(macOS 13.0, *) else {
            print("agentLoginItemStatus=unavailable")
            return
        }

        let service = SMAppService.loginItem(identifier: "local.dock-click-toggle.agent")
        print("agentLoginItemStatus=\(statusString(service.status))")
    }

    private static func openSystemSettings() {
        guard #available(macOS 13.0, *) else {
            fputs("DockClickToggle: SMAppService requires macOS 13 or later.\n", stderr)
            Darwin.exit(2)
        }

        SMAppService.openSystemSettingsLoginItems()
    }

    private static func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        let inputMonitoringGranted = CGPreflightListenEventAccess() || CGRequestListenEventAccess()

        print("accessibilityTrusted=\(accessibilityTrusted)")
        print("inputMonitoringGranted=\(inputMonitoringGranted)")

        if !accessibilityTrusted || !inputMonitoringGranted {
            fputs("DockClickToggle: permissions are still incomplete. Enable Accessibility and Input Monitoring in System Settings, then restart DockClickToggle.\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func printPermissionStatus() {
        print("accessibilityTrusted=\(AXIsProcessTrusted())")
        print("inputMonitoringGranted=\(CGPreflightListenEventAccess())")
    }

    @available(macOS 13.0, *)
    private static func statusString(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            return "notRegistered"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requiresApproval"
        case .notFound:
            return "notFound"
        @unknown default:
            return "unknown"
        }
    }
}

#if DOCK_CLICK_TOGGLE_AGENT
if CommandLine.arguments.count > 1, LoginItemCommand.runIfRequested() {
    Darwin.exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DockClickToggle().start()
#else
if LoginItemCommand.runIfRequested() {
    Darwin.exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DockClickToggle().start()
#endif
