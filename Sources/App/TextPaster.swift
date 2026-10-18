import Cocoa
import ApplicationServices

public final class TextPaster {
    public static func paste(text: String, copyToClipboard: Bool = AppState.shared.copyToClipboard) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // 1. Prepare pasteboard
        let pasteboard = NSPasteboard.general
        
        // Backup previous clipboard contents with full fidelity if copyToClipboard is false
        var savedItems: [[(NSPasteboard.PasteboardType, Data)]] = []
        if !copyToClipboard, let items = pasteboard.pasteboardItems {
            for item in items {
                var itemData: [(NSPasteboard.PasteboardType, Data)] = []
                for type in item.types {
                    if let data = item.data(forType: type) {
                        itemData.append((type, data))
                    }
                }
                if !itemData.isEmpty {
                    savedItems.append(itemData)
                }
            }
        }
        
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        
        // 3. Ensure accessibility permission is active
        if !AXIsProcessTrusted() {
            let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            let options = [checkOptPrompt: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        
        // 4. Perform synthetic paste with adequate delay for modifier release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            simulatePaste()
            
            // 5. If user disabled "copy to clipboard", restore previous clipboard contents after paste completes
            if !copyToClipboard {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    pasteboard.clearContents()
                    for itemData in savedItems {
                        let newItem = NSPasteboardItem()
                        for (type, data) in itemData {
                            newItem.setData(data, forType: type)
                        }
                        pasteboard.writeObjects([newItem])
                    }
                }
            }
        }
    }
    
    public static func simulatePaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        
        // Virtual key codes:
        // Left Option: 58 (0x3A), Right Option: 61 (0x3D)
        // Command: 55 (0x37)
        // 'v': 9 (0x09)
        
        // Step 1: Release physical Option/Alt keys in case still held from hotkey press (⌥[)
        if let optUpLeft = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: false) {
            optUpLeft.flags = []
            optUpLeft.post(tap: .cghidEventTap)
            optUpLeft.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let optUpRight = CGEvent(keyboardEventSource: src, virtualKey: 61, keyDown: false) {
            optUpRight.flags = []
            optUpRight.post(tap: .cghidEventTap)
            optUpRight.post(tap: .cgAnnotatedSessionEventTap)
        }
        
        // Step 2: Post Command DOWN
        if let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true) {
            cmdDown.flags = .maskCommand
            cmdDown.post(tap: .cghidEventTap)
            cmdDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        
        // Step 3: Post 'v' DOWN with Command flag
        if let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
            vDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        
        // Step 4: Post 'v' UP with Command flag
        if let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: .cghidEventTap)
            vUp.post(tap: .cgAnnotatedSessionEventTap)
        }
        
        // Step 5: Post Command UP with empty flags
        if let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false) {
            cmdUp.flags = []
            cmdUp.post(tap: .cghidEventTap)
            cmdUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
