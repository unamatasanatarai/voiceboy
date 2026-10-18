import Cocoa
import Carbon

public struct HotkeyCombination: Equatable, Codable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var characters: String
    
    // Default: Alt + [ (⌥[)
    public static let `default` = HotkeyCombination(
        keyCode: UInt32(kVK_ANSI_LeftBracket), // 33
        carbonModifiers: UInt32(optionKey),
        characters: "⌥["
    )
    
    public init(keyCode: UInt32, carbonModifiers: UInt32, characters: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.characters = characters
    }
    
    public var displayString: String {
        return characters
    }
}

public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager()
    
    public var onHotkeyPressed: (() -> Void)?
    public var onCancelPressed: (() -> Void)?
    
    private var hotKeyRef: EventHotKeyRef?
    private var escHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var localEscMonitor: Any?
    private var globalEscMonitor: Any?
    
    public private(set) var currentCombination: HotkeyCombination = .default
    
    private init() {}
    
    public func register(combination: HotkeyCombination = .default) {
        unregister()
        currentCombination = combination
        
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x54524258) // 'TRBX'
        hotKeyID.id = 1
        
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event = event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr {
                if hotKeyID.id == 1 {
                    DispatchQueue.main.async {
                        GlobalHotkeyManager.shared.onHotkeyPressed?()
                    }
                } else if hotKeyID.id == 2 {
                    DispatchQueue.main.async {
                        GlobalHotkeyManager.shared.onCancelPressed?()
                    }
                }
            }
            return noErr
        }
        
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &eventHandler)
        RegisterEventHotKey(combination.keyCode, combination.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
    
    public func startEscapeMonitoring() {
        stopEscapeMonitoring()
        
        // 1. Carbon Global Hotkey for Escape (ID: 2)
        var escID = EventHotKeyID()
        escID.signature = OSType(0x54524258) // 'TRBX'
        escID.id = 2
        RegisterEventHotKey(UInt32(kVK_Escape), 0, escID, GetApplicationEventTarget(), 0, &escHotKeyRef)
        
        // 2. Local monitor if VoiceBoy is the frontmost application
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                self?.onCancelPressed?()
                return nil
            }
            return event
        }
        
        // 3. Global monitor as an additional fallback
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                DispatchQueue.main.async {
                    self?.onCancelPressed?()
                }
            }
        }
    }
    
    public func stopEscapeMonitoring() {
        if let esc = escHotKeyRef {
            UnregisterEventHotKey(esc)
            escHotKeyRef = nil
        }
        if let monitor = localEscMonitor {
            NSEvent.removeMonitor(monitor)
            localEscMonitor = nil
        }
        if let monitor = globalEscMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscMonitor = nil
        }
    }
    
    public func unregister() {
        stopEscapeMonitoring()
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}
