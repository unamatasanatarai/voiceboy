import Cocoa
import ApplicationServices
import Carbon

public final class TextPaster {
    private static var lastPasteTimestamp: TimeInterval = 0
    private static var lastPastedText: String = ""
    private static let lock = NSLock()
    
    public static func resetDebounceForTesting() {
        lock.lock()
        lastPasteTimestamp = 0
        lastPastedText = ""
        lock.unlock()
    }
    
    public enum SecureInputReason {
        /// The focused element is an AXSecureTextField.
        case passwordField
        /// Some process holds macOS Secure Event Input; the target cannot be inspected and may be a password field.
        case globalSecureEventInput
    }

    /// Test hook to force a secure-input verdict; nil uses live system state.
    public static var secureInputOverrideForTesting: SecureInputReason?

    /// Returns why pasting should be blocked, preferring the precise AX verdict over the system-wide flag.
    public static func secureInputBlockReason() -> SecureInputReason? {
        if let forced = secureInputOverrideForTesting {
            return forced
        }
        if AXIsProcessTrusted() {
            let systemWide = AXUIElementCreateSystemWide()
            var focusedElement: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
            if status == .success, let element = focusedElement {
                var subrole: CFTypeRef?
                if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSubroleAttribute as CFString, &subrole) == .success,
                   let subroleStr = subrole as? String,
                   subroleStr == "AXSecureTextField" {
                    return .passwordField
                }
            }
        }
        if IsSecureEventInputEnabled() {
            return .globalSecureEventInput
        }
        return nil
    }

    /// Checks if macOS Secure Event Input is active or the frontmost focused UI element is a password field.
    public static func isTargetSecureInput() -> Bool {
        return secureInputBlockReason() != nil
    }
    
    public static func paste(text: String, copyToClipboard: Bool = AppState.shared.copyToClipboard) {
        // Issue 19: Canonical Unicode NFC normalization ensures combining marks, accented Latin, and emoji sequences render consistently
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !trimmed.isEmpty else { return }
        
        // Security check (Scenario 10): Block injection into password / secure-entry fields
        if let reason = secureInputBlockReason() {
            // Never type into a secure target, but don't silently lose the dictation either: if the user opted into
            // clipboard copies, leave the text there so they can paste it themselves.
            if copyToClipboard {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(trimmed, forType: .string)
            }
            let what = reason == .passwordField ? "Password field detected" : "Secure input is active (another app)"
            let detail = copyToClipboard ? "\(what) — text copied to clipboard" : what
            DispatchQueue.main.async {
                AppState.shared.statusMessage = "Dictation blocked: \(detail)"
                ToastWindowController.shared.showToast(status: "Blocked", text: detail, audioLevel: 0.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    ToastWindowController.shared.hideToast()
                }
            }
            return
        }
        
        let axTrusted = AXIsProcessTrusted()
        if !axTrusted {
            let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            let options = [checkOptPrompt: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            if !copyToClipboard {
                DispatchQueue.main.async {
                    AppState.shared.statusMessage = "Accessibility permission required to auto-paste"
                }
                return
            }
        }
        
        // Debounce protection: prevent duplicate paste calls within a 300ms window
        lock.lock()
        let now = Date().timeIntervalSince1970
        if trimmed == lastPastedText && (now - lastPasteTimestamp) < 0.3 {
            lock.unlock()
            return
        }
        lastPasteTimestamp = now
        lastPastedText = trimmed
        lock.unlock()
        
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
        let expectedChangeCount = pasteboard.changeCount
        
        guard axTrusted else { return }
        
        // 4. Perform synthetic paste with adequate delay for modifier release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            simulatePaste()
            
            // 5. If user disabled "copy to clipboard", restore previous clipboard contents after paste completes,
            // but ONLY if the user or another app has not copied new content in the interim (Scenario 11)
            if !copyToClipboard {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard pasteboard.changeCount == expectedChangeCount else {
                        return // User or external clipboard manager modified clipboard; do not overwrite
                    }
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
    
    // MARK: - Modifier Key Management (Issue 12)
    /// Virtual key codes for all macOS modifier keys (Left/Right Option, Shift, Control, Command)
    public static let allModifierKeyCodes: [CGKeyCode] = [
        58, 61, // Option (Left, Right)
        56, 60, // Shift (Left, Right)
        59, 62, // Control (Left, Right)
        55, 54  // Command (Left, Right)
    ]
    
    /// Synthesizes key-up events for all modifier keys to prevent hotkey modifiers (e.g. ⇧⌥K or ⌃⌥Space)
    /// from corrupting the subsequent ⌘V keystroke into ⇧⌘V or ⌃⌘V.
    public static func releaseAllModifiers(source: CGEventSource?) {
        for keyCode in allModifierKeyCodes {
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
                keyUp.flags = []
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }
    
    public static func simulatePaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        
        // Step 1: Release all physical modifier keys in case any are still held from hotkey triggers
        releaseAllModifiers(source: src)
        
        // Step 2: Post Command DOWN with strict .maskCommand
        if let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true) {
            cmdDown.flags = .maskCommand
            cmdDown.post(tap: .cghidEventTap)
        }
        
        // Step 3: Post 'v' DOWN with strict .maskCommand
        if let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
        }
        
        // Step 4: Post 'v' UP with strict .maskCommand
        if let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: .cghidEventTap)
        }
        
        // Step 5: Post Command UP with empty flags
        if let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false) {
            cmdUp.flags = []
            cmdUp.post(tap: .cghidEventTap)
        }
    }
}
