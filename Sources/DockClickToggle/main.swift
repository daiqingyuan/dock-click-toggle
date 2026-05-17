import AppKit
import ApplicationServices
import CoreGraphics
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
}

final class DockClickToggle {
    private var eventTap: CFMachPort?
    private var pendingClick: PendingClick?
    private var lastActionAt = Date.distantPast
    private var consecutiveTimeouts = 0
    private let maxConsecutiveTimeouts = 5

    func start() {
        requestAccessibilityIfNeeded()
        requestInputMonitoringIfNeeded()

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
            try? "FAIL".write(toFile: "/tmp/dock-click-toggle.status", atomically: true, encoding: .utf8)
            fputs("DockClickToggle: failed to create event tap after 3 attempts. Grant Input Monitoring permission.\n", stderr)
            CFRunLoopRun()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        try? "OK".write(toFile: "/tmp/dock-click-toggle.status", atomically: true, encoding: .utf8)
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
                    fputs("DockClickToggle: event tap disabled \(consecutiveTimeouts) times. Sleeping 2s before re-enable.\n", stderr)
                    Thread.sleep(forTimeInterval: 2)
                    consecutiveTimeouts = 0
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
            downPoint: point
        )
        return nil
    }

    private func handleMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let pending = pendingClick else {
            return Unmanaged.passUnretained(event)
        }
        pendingClick = nil

        let upPoint = event.location
        guard distance(pending.downPoint, upPoint) <= 8 else {
            return nil
        }

        lastActionAt = Date()
        minimizeWindows(bundleIdentifier: pending.bundleIdentifier)
        return nil
    }

    private func dockItem(at point: CGPoint) -> DockItem? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }

        let dockAX = AXUIElementCreateApplication(dock.processIdentifier)
        guard let topChildren = axArray(dockAX, kAXChildrenAttribute),
              let list = topChildren.first,
              let items = axArray(list, kAXChildrenAttribute) else {
            return nil
        }

        for element in items {
            guard axString(element, kAXSubroleAttribute) == kAXApplicationDockItemSubrole as String,
                  let title = axString(element, kAXTitleAttribute),
                  let url = axURL(element, "AXURL"),
                  let frame = axFrame(element),
                  frame.insetBy(dx: -3, dy: -3).contains(point) else {
                continue
            }
            return DockItem(title: title, url: url, frame: frame)
        }

        return nil
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
        for window in windows where axBool(window, kAXMinimizedAttribute) == false {
            let result = AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanTrue
            )
            if result == .success {
                minimized += 1
            }
        }

        if minimized == 0 {
            app.hide()
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
