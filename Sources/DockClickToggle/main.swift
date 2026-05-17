import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

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
    private var pendingClick: PendingClick?
    private var dockItemCache: [DockItem] = []
    private var lastDockCacheRefresh = Date.distantPast
    private var lastActionAt = Date.distantPast
    private var consecutiveTimeouts = 0
    private let statusStore = StatusStore()
    private let maxConsecutiveTimeouts = 5
    private let maxClickMovement: CGFloat = 5
    private let maxClickDuration: TimeInterval = 0.35
    private let dockCacheTTL: TimeInterval = 0.5

    func start() {
        requestAccessibilityIfNeeded()
        requestInputMonitoringIfNeeded()
        writeStatus(state: "STARTING", eventTapCreated: false, lastError: nil)

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

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                consecutiveTimeouts += 1
                if consecutiveTimeouts > maxConsecutiveTimeouts {
                    fputs("DockClickToggle: event tap disabled \(consecutiveTimeouts) times. Re-enabling after 2s.\n", stderr)
                    consecutiveTimeouts = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self, let eventTap = self.eventTap else { return }
                        CGEvent.tapEnable(tap: eventTap, enable: true)
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
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func requestInputMonitoringIfNeeded() {
        guard !CGPreflightListenEventAccess() else {
            return
        }

        let granted = CGRequestListenEventAccess()
        if !granted {
            fputs("DockClickToggle: Input Monitoring is not granted yet. Enable Dock Click Toggle in System Settings > Privacy & Security > Input Monitoring.\n", stderr)
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
            return nil
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

    private func startHeartbeat() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.writeStatus(
                state: self.eventTap == nil ? "FAIL" : "OK",
                eventTapCreated: self.eventTap != nil,
                lastError: self.eventTap == nil ? "event_tap_missing" : nil
            )
        }
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

    private func collectDockItems(from element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 6 else {
            return []
        }

        if axString(element, kAXSubroleAttribute) == kAXApplicationDockItemSubrole as String {
            return [element]
        }

        guard let children = axArray(element, kAXChildrenAttribute) else {
            return []
        }

        return children.flatMap { collectDockItems(from: $0, depth: depth + 1) }
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
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DockClickToggle().start()
