import Cocoa
import SwiftUI
import Combine

public class StatusBarController: NSObject, NSMenuDelegate {
    public static let shared = StatusBarController()
    
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    
    public func setup() {
        if statusItem != nil { return }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        
        button.toolTip = "VoiceBoy — Live Dictation"
        updateIcon(isRecording: AppState.shared.isRecording)
        
        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        
        // Listen to recording state changes to update the status bar icon
        AppState.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                self?.updateIcon(isRecording: recording)
            }
            .store(in: &cancellables)
    }
    
    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            AppDelegate.shared?.showMainWindow()
            return
        }
        
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // Right-click: display contextual menu
            let menu = buildContextMenu()
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            // Reset menu so future left clicks trigger button.action directly
            DispatchQueue.main.async { [weak self] in
                self?.statusItem?.menu = nil
            }
        } else {
            // Left-click: toggle/open main window
            AppDelegate.shared?.showMainWindow()
        }
    }
    
    public func updateIcon(isRecording: Bool) {
        guard let button = statusItem?.button else { return }
        let icon = loadVoiceBoyIcon(isRecording: isRecording)
        button.image = icon
        button.contentTintColor = isRecording ? .systemRed : nil
    }
    
    private func loadVoiceBoyIcon(isRecording: Bool) -> NSImage {
        let name = isRecording ? "StatusBarIcon-Recording" : "StatusBarIcon"
        
        // 1. Try from Bundle Resources (automatically pairs 1x and @2x representations)
        if let img = Bundle.main.image(forResource: NSImage.Name(name)) ?? NSImage(named: NSImage.Name(name)) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = !isRecording
            return img
        }
        
        // 2. Fallback to local Resources/ folder (for CLI / dev)
        let localPath = "Resources/\(name).png"
        let localPath2x = "Resources/\(name)@2x.png"
        if FileManager.default.fileExists(atPath: localPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)),
           let img = NSImage(data: data) {
            if FileManager.default.fileExists(atPath: localPath2x),
               let data2x = try? Data(contentsOf: URL(fileURLWithPath: localPath2x)),
               let rep2x = NSBitmapImageRep(data: data2x) {
                rep2x.size = NSSize(width: 18, height: 18)
                img.addRepresentation(rep2x)
            }
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = !isRecording
            return img
        }
        
        // 3. Fallback to system symbol
        let fallbackName = isRecording ? "record.circle.fill" : "waveform"
        let fallback = NSImage(systemSymbolName: fallbackName, accessibilityDescription: "VoiceBoy") ?? NSImage()
        fallback.isTemplate = !isRecording
        return fallback
    }
    
    public func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        
        // Open / Show window
        let showItem = NSMenuItem(title: "Open VoiceBoy", action: #selector(openMainWindow), keyEquivalent: "o")
        showItem.target = self
        menu.addItem(showItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit item
        let quitItem = NSMenuItem(title: "Quit VoiceBoy", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        return menu
    }
    
    @objc private func openMainWindow() {
        AppDelegate.shared?.showMainWindow()
    }
    
    @objc private func quitApp() {
        if let delegate = AppDelegate.shared {
            delegate.directQuit()
        } else {
            NSApp.terminate(nil)
        }
    }
}
