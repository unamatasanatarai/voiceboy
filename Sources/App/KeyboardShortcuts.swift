import Cocoa
import Carbon
import SwiftUI

// MARK: - Hotkey Validation (Rule: Must use modifier; Shift alone forbidden)
public enum HotkeyValidationError: LocalizedError {
    case noModifier
    case shiftOnly
    case noKey
    
    public var errorDescription: String? {
        switch self {
        case .noModifier:
            return "Must use a modifier key (⌘ Command, ⌃ Control, or ⌥ Option)."
        case .shiftOnly:
            return "Shift (⇧) alone is not allowed. Shift must be accompanied by another modifier key (⌘, ⌃, or ⌥)."
        case .noKey:
            return "Please press a key together with your modifier."
        }
    }
}

public struct HotkeyValidator {
    public static func validateAndBuild(event: NSEvent) -> Result<HotkeyCombination, HotkeyValidationError> {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        
        let hasCmd = flags.contains(.command)
        let hasCtrl = flags.contains(.control)
        let hasAlt = flags.contains(.option)
        let hasShift = flags.contains(.shift)
        
        // Rule: Must use a modifier key
        if !hasCmd && !hasCtrl && !hasAlt && !hasShift {
            return .failure(.noModifier)
        }
        
        // Rule: Shift alone is forbidden! Shift must be accompanied by another modifier (Cmd, Ctrl, or Alt)
        if hasShift && !hasCmd && !hasCtrl && !hasAlt {
            return .failure(.shiftOnly)
        }
        
        let keyCode = UInt32(event.keyCode)
        
        var carbonMods: UInt32 = 0
        var displayMods = ""
        
        if hasCtrl {
            carbonMods |= UInt32(controlKey)
            displayMods += "⌃"
        }
        if hasAlt {
            carbonMods |= UInt32(optionKey)
            displayMods += "⌥"
        }
        if hasCmd {
            carbonMods |= UInt32(cmdKey)
            displayMods += "⌘"
        }
        if hasShift {
            carbonMods |= UInt32(shiftKey)
            displayMods += "⇧"
        }
        
        let keyChar = keycodeToString(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        guard !keyChar.isEmpty else {
            return .failure(.noKey)
        }
        
        let formattedKey = (keyChar.count == 1) ? keyChar.uppercased() : keyChar
        let combo = HotkeyCombination(
            keyCode: keyCode,
            carbonModifiers: carbonMods,
            characters: "\(displayMods)\(formattedKey)"
        )
        return .success(combo)
    }
    
    private static func keycodeToString(keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Grave: return "`"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "FwdDel"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            if let chars = characters, !chars.isEmpty {
                return chars
            }
            return "Key(\(keyCode))"
        }
    }
}

// MARK: - KeyboardShortcuts API & Architecture (Matching sindresorhus/KeyboardShortcuts style)
public enum KeyboardShortcuts {
    public struct Name: RawRepresentable, Hashable, Equatable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }
    
    public typealias Shortcut = HotkeyCombination
    
    public static func getShortcut(for name: Name) -> Shortcut? {
        let key = "KeyboardShortcut_\(name.rawValue)"
        if let data = UserDefaults.standard.data(forKey: key),
           let combo = try? JSONDecoder().decode(Shortcut.self, from: data) {
            return combo
        }
        return .default
    }
    
    public static func setShortcut(_ shortcut: Shortcut?, for name: Name) {
        let key = "KeyboardShortcut_\(name.rawValue)"
        if let shortcut = shortcut {
            if let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: key)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .keyboardShortcutDidChange, object: name)
    }
    
    public static func reset(name: Name) {
        setShortcut(.default, for: name)
    }
}

extension Notification.Name {
    static let keyboardShortcutDidChange = Notification.Name("KeyboardShortcuts.shortcutDidChange")
}

extension KeyboardShortcuts.Name {
    public static let toggleDictation = Self("toggleDictation")
}

// MARK: - KeyboardShortcuts.RecorderCocoa (Native NSSearchField subclass in style of KeyboardShortcuts)
extension KeyboardShortcuts {
    public final class RecorderCocoa: NSSearchField, NSSearchFieldDelegate {
        public var shortcutName: Name?
        public var onChange: ((Shortcut?) -> Void)?
        
        public var defaultShortcut: Shortcut = .default
        public private(set) var currentShortcut: Shortcut?
        public private(set) var isRecording = false
        
        private var localMonitor: Any?
        private var notificationObserver: NSObjectProtocol?
        
        public init(for name: Name, defaultShortcut: Shortcut = .default, onChange: ((Shortcut?) -> Void)? = nil) {
            self.shortcutName = name
            self.defaultShortcut = defaultShortcut
            self.onChange = onChange
            super.init(frame: NSRect(x: 0, y: 0, width: 72, height: 19))
            commonInit()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            commonInit()
        }
        
        deinit {
            stopRecording(restore: true)
            if let obs = notificationObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
        
        private func commonInit() {
            delegate = self
            isEditable = false
            isSelectable = false
            alignment = .center
            font = .systemFont(ofSize: 11, weight: .medium)
            focusRingType = .none
            isBordered = false
            drawsBackground = false
            bezelStyle = .roundedBezel
            textColor = NSColor(white: 0.60, alpha: 1.0)
            
            // In the style of sindresorhus/KeyboardShortcuts: Remove search and cancel buttons
            if let searchCell = cell as? NSSearchFieldCell {
                searchCell.searchButtonCell = nil
                searchCell.cancelButtonCell = nil
                searchCell.isBordered = false
                searchCell.backgroundColor = .clear
            }
            
            if let name = shortcutName {
                currentShortcut = KeyboardShortcuts.getShortcut(for: name) ?? defaultShortcut
                notificationObserver = NotificationCenter.default.addObserver(
                    forName: .keyboardShortcutDidChange,
                    object: nil,
                    queue: .main
                ) { [weak self] notif in
                    guard let self = self, let changedName = notif.object as? Name, changedName == name else { return }
                    self.currentShortcut = KeyboardShortcuts.getShortcut(for: name)
                    self.updateUI()
                }
            }
            
            updateUI()
        }
        
        override public var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 18)
        }
        
        private var showsCancelButton: Bool {
            get { false }
            set {}
        }
        
        private func updateUI() {
            textColor = NSColor(white: 0.60, alpha: 1.0)
            if isRecording {
                stringValue = ""
                placeholderString = "Press shortcut…"
                showsCancelButton = false
            } else if let shortcut = currentShortcut {
                stringValue = shortcut.displayString
                placeholderString = ""
                showsCancelButton = false
            } else {
                stringValue = defaultShortcut.displayString
                placeholderString = ""
                showsCancelButton = false
            }
        }
        
        override public func mouseDown(with event: NSEvent) {
            // Check if user clicked the cancel (x) button to reset
            if let searchCell = cell as? NSSearchFieldCell, showsCancelButton, let cancelCell = searchCell.cancelButtonCell {
                let cancelRect = cancelCell.drawingRect(forBounds: bounds)
                let clickPoint = convert(event.locationInWindow, from: nil)
                if cancelRect.contains(clickPoint) {
                    resetToDefault()
                    return
                }
            }
            
            if !isRecording {
                window?.makeFirstResponder(self)
                startRecording()
            }
        }
        
        override public func cancelOperation(_ sender: Any?) {
            if isRecording {
                stopRecording(restore: true)
            } else {
                resetToDefault()
            }
        }
        
        public func resetToDefault() {
            applyShortcut(defaultShortcut)
        }
        
        public func startRecording() {
            guard !isRecording else { return }
            isRecording = true
            updateUI()
            
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self = self, self.isRecording else { return event }
                
                if event.type == .keyDown {
                    // Escape cancels recording
                    if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                        self.stopRecording(restore: true)
                        return nil
                    }
                    
                    // Delete or Backspace resets to default
                    if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                        self.resetToDefault()
                        self.stopRecording()
                        return nil
                    }
                    
                    // Validate shortcut
                    switch HotkeyValidator.validateAndBuild(event: event) {
                    case .success(let combination):
                        self.applyShortcut(combination)
                        self.stopRecording()
                        return nil
                    case .failure:
                        NSSound.beep()
                        return nil
                    }
                }
                return event
            }
        }
        
        public func stopRecording(restore: Bool = false) {
            guard isRecording else { return }
            isRecording = false
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
            updateUI()
            window?.makeFirstResponder(nil)
        }
        
        private func applyShortcut(_ shortcut: Shortcut) {
            currentShortcut = shortcut
            if let name = shortcutName {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
            }
            updateUI()
            onChange?(shortcut)
        }
    }
}

// MARK: - KeyboardShortcuts.Recorder (SwiftUI View in style of KeyboardShortcuts)
extension KeyboardShortcuts {
    public struct Recorder: View {
        private let title: String?
        private let name: Name
        private let onChange: ((Shortcut?) -> Void)?
        
        public init(_ title: String? = nil, name: Name, onChange: ((Shortcut?) -> Void)? = nil) {
            self.title = title
            self.name = name
            self.onChange = onChange
        }
        
        public init(for name: Name, onChange: ((Shortcut?) -> Void)? = nil) {
            self.init(nil, name: name, onChange: onChange)
        }
        
        public var body: some View {
            HStack(spacing: 8) {
                if let title = title {
                    Text(title)
                }
                RecorderRepresentable(name: name, onChange: onChange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    public struct RecorderRepresentable: NSViewRepresentable {
        let name: Name
        let onChange: ((Shortcut?) -> Void)?
        
        public func makeNSView(context: Context) -> RecorderCocoa {
            RecorderCocoa(for: name, defaultShortcut: .default, onChange: onChange)
        }
        
        public func updateNSView(_ nsView: RecorderCocoa, context: Context) {
            nsView.shortcutName = name
            nsView.onChange = onChange
        }
    }
}
