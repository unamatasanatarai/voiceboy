import Cocoa
import SwiftUI

public class AppDelegate: NSObject, NSApplicationDelegate {
    public static var shared: AppDelegate?
    
    var window: NSWindow?
    private var lastQuitAttemptTime: Date?
    private let quitIntervalThreshold: TimeInterval = 2.0
    private var keyMonitor: Any?
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        let contentView = MinimalMainView()
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.minSize = NSSize(width: 460, height: 470)
        win.maxSize = NSSize(width: 460, height: 470)
        win.level = .normal
        win.title = "VoiceBoy"
        win.titleVisibility = .visible
        win.center()
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.contentViewController = NSHostingController(rootView: contentView)
        win.setContentSize(NSSize(width: 460, height: 470))
        win.makeKeyAndOrderFront(nil)
        
        self.window = win
        
        // Activation policy: regular shows dock icon, accessory hides dock icon
        let policy: NSApplication.ActivationPolicy = AppState.shared.showDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
        if let appIcon = Bundle.main.image(forResource: "AppIconMaster") ?? NSImage(contentsOfFile: "Resources/AppIconMaster.png") ?? Bundle.main.image(forResource: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        
        // Initialize Status Bar controller
        StatusBarController.shared.setup()
        
        // Set up standard Main Menu (Edit menu for cut/copy/paste responder chain)
        setupMainMenu()
        
        // Intercept Cmd+Q for "double cmd+q to quit"
        setupDoubleCmdQInterceptor()
        
        // Immediately request Microphone and Accessibility permissions on launch
        checkAndRequestPermissions()
    }
    
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About VoiceBoy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit VoiceBoy", action: #selector(directQuit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        // Edit Menu (Enables standard responder chain for Cut, Copy, Paste, Select All)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSStandardKeyBindingResponding.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        // Window Menu (Enables standard responder chain for Cmd+W / Close Window)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(closeItem)
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
    
    public func showMainWindow() {
        guard let win = self.window else { return }
        if win.isMiniaturized {
            win.deminiaturize(nil)
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }
    
    private func setupDoubleCmdQInterceptor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // Check for Command+Q
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == [.command], let chars = event.charactersIgnoringModifiers, chars.lowercased() == "q" {
                if self.handleQuitRequest() {
                    self.directQuit()
                }
                return nil // Consume event to prevent default immediate termination
            }
            return event
        }
    }
    
    @objc public func directQuit() {
        NSApp.terminate(nil)
    }
    
    @discardableResult
    public func handleQuitRequest() -> Bool {
        let now = Date()
        if let last = lastQuitAttemptTime, now.timeIntervalSince(last) <= quitIntervalThreshold {
            lastQuitAttemptTime = nil
            AppState.shared.showQuitToast = false
            return true
        }
        
        lastQuitAttemptTime = now
        showMainWindow()
        
        withAnimation(.easeInOut(duration: 0.15)) {
            AppState.shared.showQuitToast = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + quitIntervalThreshold) { [weak self] in
            guard let self = self else { return }
            if let last = self.lastQuitAttemptTime, Date().timeIntervalSince(last) >= self.quitIntervalThreshold {
                self.lastQuitAttemptTime = nil
                withAnimation(.easeInOut(duration: 0.15)) {
                    AppState.shared.showQuitToast = false
                }
            }
        }
        return false
    }
    
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return .terminateNow
    }
    
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // App continues running in status bar (and dock if enabled) when window is closed
        return false
    }
    
    private func checkAndRequestPermissions() {
        // 1. Microphone Permission
        LiveAudioStreamer.requestPermission { granted in
            if !granted {
                print("Warning: Microphone access was not granted.")
            }
        }
        
        // 2. Accessibility Permission (Required for typing text into active input boxes)
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options = [checkOptPrompt: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        if !isTrusted {
            print("Note: Prompting user for Accessibility permissions to enable auto-typing.")
        }
    }
    
    deinit {
        if let mon = keyMonitor {
            NSEvent.removeMonitor(mon)
        }
    }
}
