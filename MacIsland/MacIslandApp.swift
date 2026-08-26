//
//  MacIslandApp.swift
//  MacIsland
//
//  Created by Adrien Martin on 25/08/26.
//

import SwiftUI
import ServiceManagement
import ApplicationServices

@main
struct MacIslandAppRunner {
    static var strongDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        strongDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static let showsDockIconKey = "showsDockIcon"
    private static var revealMenuBarWorkItem: DispatchWorkItem?
    private var islandPanel: IslandPanel?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.registerDefaults()
        Self.applyDockIconVisibility()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // We explicitly do NOT call activate() at all to prevent focus stealing.
        Self.enableLaunchAtLogin()

        DispatchQueue.main.async { [weak self] in
            self?.showIslandPanel()
        }
    }

    func showIslandPanel() {
        if let islandPanel {
            islandPanel.orderFrontRegardless()
            return
        }

        let panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: ContentView())

        Self.configureWindow(panel)
        panel.orderFrontRegardless()
        islandPanel = panel
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [showsDockIconKey: false])
    }

    static func applyDockIconVisibility() {
        setDockIconVisible(UserDefaults.standard.bool(forKey: showsDockIconKey))
    }

    static func setDockIconVisible(_ isVisible: Bool) {
        NSApplication.shared.setActivationPolicy(isVisible ? .regular : .accessory)
    }

    static func enableLaunchAtLogin() {
        guard #available(macOS 13.0, *) else {
            return
        }

        let service = SMAppService.mainApp
        guard service.status == .notRegistered else {
            return
        }

        do {
            try service.register()
        } catch {
            print("Unable to register MacIsland as a login item: \(error)")
        }
    }

    static func configureWindow(_ window: NSWindow) {
        window.setContentSize(NSSize(width: 500, height: 200))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Prevent the window from being dragged.
        window.isMovableByWindowBackground = false
        window.isMovable = false

        // Keep the window floating on top of other apps and menu bar, including in full screen mode.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Remove the standard window border and shadow, our view will provide it if needed.
        window.styleMask.insert(.borderless)
        window.styleMask.remove(.titled)
        window.styleMask.remove(.resizable)
        window.hasShadow = false

        centerAtStatusBar(window)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            centerAtStatusBar(window)
        }
    }

    static func centerAtStatusBar(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else {
            return
        }

        let screenFrame = screen.frame
        let windowFrame = window.frame
        let origin = NSPoint(
            x: screenFrame.midX - windowFrame.width / 2,
            y: screenFrame.maxY - windowFrame.height
        )
        window.setFrameOrigin(origin)
    }

    static func revealUnderlyingMenuBarItems(in window: NSWindow) {
        revealMenuBarWorkItem?.cancel()

        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 0.08
        }

        let workItem = DispatchWorkItem { [weak window] in
            guard let window else {
                return
            }

            window.ignoresMouseEvents = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().alphaValue = 1
            }
            centerAtStatusBar(window)
        }

        revealMenuBarWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    static func wouldBlockMenuBarItems(window: NSWindow, islandSize: CGSize) -> Bool {
        guard AXIsProcessTrusted(),
              let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != NSRunningApplication.current.processIdentifier,
              let screen = window.screen ?? NSScreen.main else {
            return false
        }

        let islandFrame = menuBarComparisonFrame(
            forWindow: window,
            islandSize: islandSize,
            screenFrame: screen.frame
        )

        return menuBarItemFrames(for: frontmostApplication)
            .contains { $0.intersects(islandFrame) }
    }

    private static func menuBarComparisonFrame(
        forWindow window: NSWindow,
        islandSize: CGSize,
        screenFrame: CGRect
    ) -> CGRect {
        let frame = window.frame
        let cocoaFrame = CGRect(
            x: frame.midX - islandSize.width / 2,
            y: frame.maxY - islandSize.height,
            width: islandSize.width,
            height: islandSize.height
        )

        return CGRect(
            x: cocoaFrame.minX,
            y: screenFrame.maxY - cocoaFrame.maxY,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    private static func menuBarItemFrames(for application: NSRunningApplication) -> [CGRect] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var menuBarValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = menuBarValue else {
            return []
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let menuItems = childrenValue as? [AXUIElement] else {
            return []
        }

        var frames: [CGRect] = []
        for menuItem in menuItems {
            if let frame = menuBarItemFrame(for: menuItem) {
                frames.append(frame)
            }
        }
        return frames
    }

    private static func menuBarItemFrame(for menuItem: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(menuItem, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(menuItem, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let position = positionValue,
              let size = sizeValue else {
            return nil
        }

        var point = CGPoint.zero
        var itemSize = CGSize.zero

        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &itemSize) else {
            return nil
        }

        return CGRect(origin: point, size: itemSize)
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
