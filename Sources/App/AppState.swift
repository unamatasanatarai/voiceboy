import Cocoa
import SwiftUI

public class AppState: ObservableObject {
    public static let shared = AppState()
    
    @Published public var isRecording: Bool = false
    @Published public var liveText: String = ""
    @Published public var lastTranscript: String = ""
    @Published public var selectedModel: String = "voice-input-english-74.bin" {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: AppState.selectedModelDefaultsKey)
        }
    }
    @Published public var selectedLanguage: String = "en" {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: AppState.selectedLanguageDefaultsKey)
        }
    }
    
    private static let selectedModelDefaultsKey = "VoiceBoy_SelectedModel"
    private static let selectedLanguageDefaultsKey = "VoiceBoy_SelectedLanguage"
    private static let finalizingDefaultsKey = "VoiceBoy_EnableFinalizing"
    private static let recordingsDirDefaultsKey = "VoiceBoy_RecordingsDirectory"
    private static let showDockIconDefaultsKey = "VoiceBoy_ShowDockIcon"
    private static let copyToClipboardDefaultsKey = "VoiceBoy_CopyToClipboard"
    
    // User-Defined Hotkey (Managed via KeyboardShortcuts, Default: Alt + [)
    @Published public var currentHotkey: HotkeyCombination {
        didSet {
            KeyboardShortcuts.setShortcut(currentHotkey, for: .toggleDictation)
            GlobalHotkeyManager.shared.register(combination: currentHotkey)
            updateStatusPrompt()
        }
    }
    
    // Custom Recordings Directory
    @Published public var recordingsDirectory: URL {
        didSet {
            UserDefaults.standard.set(recordingsDirectory.path, forKey: AppState.recordingsDirDefaultsKey)
        }
    }
    
    // Optional Finalizing step (skip to paste live transcript immediately with zero latency)
    @Published public var enableFinalizing: Bool {
        didSet {
            UserDefaults.standard.set(enableFinalizing, forKey: AppState.finalizingDefaultsKey)
        }
    }
    
    // Optional Dock Icon (setting at bottom of window: uncheck to hide from Dock)
    @Published public var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: AppState.showDockIconDefaultsKey)
            let newPolicy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
            guard NSApp.activationPolicy() != newPolicy else { return }
            
            NSApp.setActivationPolicy(newPolicy)
            if showDockIcon {
                if let appIcon = Bundle.main.image(forResource: "AppIconMaster") ?? NSImage(contentsOfFile: "Resources/AppIconMaster.png") ?? Bundle.main.image(forResource: "AppIcon") {
                    NSApp.applicationIconImage = appIcon
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.shared?.window?.makeKeyAndOrderFront(nil)
        }
    }
    
    // Optional Copy to Clipboard (whether to keep transcript on clipboard after dictation)
    @Published public var copyToClipboard: Bool {
        didSet {
            UserDefaults.standard.set(copyToClipboard, forKey: AppState.copyToClipboardDefaultsKey)
        }
    }
    
    @Published public var statusMessage: String = "Press ⌥[ to dictate"
    @Published public var showQuitToast: Bool = false
    
    private let streamer = LiveAudioStreamer()
    private var liveTimer: Timer?
    private var isTranscribingChunk: Bool = false
    
    private init() {
        let initialHotkey = KeyboardShortcuts.getShortcut(for: .toggleDictation) ?? .default
        self.currentHotkey = initialHotkey
        
        let musicURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")
        let defaultVaultBoyDir = musicURL.appendingPathComponent("VaultBoy-Recordings")
        
        if let savedDir = UserDefaults.standard.string(forKey: AppState.recordingsDirDefaultsKey) {
            self.recordingsDirectory = URL(fileURLWithPath: savedDir)
        } else {
            self.recordingsDirectory = defaultVaultBoyDir
        }
        
        if UserDefaults.standard.object(forKey: AppState.finalizingDefaultsKey) != nil {
            self.enableFinalizing = UserDefaults.standard.bool(forKey: AppState.finalizingDefaultsKey)
        } else {
            self.enableFinalizing = false
        }
        
        if UserDefaults.standard.object(forKey: AppState.showDockIconDefaultsKey) != nil {
            self.showDockIcon = UserDefaults.standard.bool(forKey: AppState.showDockIconDefaultsKey)
        } else {
            self.showDockIcon = false
        }
        
        if let savedModel = UserDefaults.standard.string(forKey: AppState.selectedModelDefaultsKey) {
            self.selectedModel = savedModel
        } else {
            self.selectedModel = "voice-input-english-74.bin"
        }
        if let savedLang = UserDefaults.standard.string(forKey: AppState.selectedLanguageDefaultsKey) {
            self.selectedLanguage = savedLang
        } else {
            self.selectedLanguage = "en"
        }
        if UserDefaults.standard.object(forKey: AppState.copyToClipboardDefaultsKey) != nil {
            self.copyToClipboard = UserDefaults.standard.bool(forKey: AppState.copyToClipboardDefaultsKey)
        } else {
            self.copyToClipboard = true
        }
        
        GlobalHotkeyManager.shared.onHotkeyPressed = { [weak self] in
            self?.toggleRecording()
        }
        GlobalHotkeyManager.shared.onCancelPressed = { [weak self] in
            self?.cancelRecording()
        }
        GlobalHotkeyManager.shared.register(combination: currentHotkey)
        updateStatusPrompt()
    }
    
    public func changeRecordingsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.directoryURL = recordingsDirectory
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            self.recordingsDirectory = selectedURL
            try? FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: true)
        }
    }
    
    public func openRecordingsDirectory() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDirectory)
    }
    
    public func updateStatusPrompt() {
        statusMessage = "Press \(currentHotkey.displayString) to dictate"
    }
    
    public func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    public func startRecording() {
        LiveAudioStreamer.requestPermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.statusMessage = "Microphone access denied"
                return
            }
            
            do {
                self.liveText = ""
                self.statusMessage = "Recording..."
                self.isRecording = true
                
                // Monitor Escape key to allow instant dictation cancellation
                GlobalHotkeyManager.shared.startEscapeMonitoring()
                
                self.streamer.onVolumeChanged = { [weak self] level in
                    DispatchQueue.main.async {
                        guard let self = self, self.isRecording else { return }
                        ToastWindowController.shared.showToast(
                            status: "Dictating (\(self.currentHotkey.displayString) finish • Esc cancel)",
                            text: self.liveText,
                            audioLevel: level
                        )
                    }
                }
                
                try self.streamer.start()
                
                // Show initial toast top-center
                ToastWindowController.shared.showToast(
                    status: "Dictating (\(self.currentHotkey.displayString) finish • Esc cancel)",
                    text: "",
                    audioLevel: 0.1
                )
                
                // Start incremental live transcription timer
                self.liveTimer?.invalidate()
                self.liveTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                    self?.runLiveCycle()
                }
            } catch {
                self.statusMessage = "Microphone error: \(error.localizedDescription)"
                self.isRecording = false
            }
        }
    }
    
    private func runLiveCycle() {
        guard isRecording, !isTranscribingChunk else { return }
        
        let samples = streamer.getSamplesSnapshot()
        guard Double(samples.count) / 16000.0 >= 0.5 else { return }
        
        isTranscribingChunk = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let modelPath = AudioTranscriber.resolveModelPath(named: self.selectedModel) else {
                DispatchQueue.main.async { self.isTranscribingChunk = false }
                return
            }
            
            let dur = Double(samples.count) / 16000.0
            let (trimmed, trimmedDur) = AudioLoader.stripLeadingAndTrailingSilence(samples: samples, sampleRate: 16000)
            let audio = AudioData(
                samples: trimmed.isEmpty ? samples : trimmed,
                originalDurationSec: dur,
                trimmedDurationSec: trimmed.isEmpty ? dur : trimmedDur,
                sampleRate: 16000
            )
            
            do {
                let result = try AudioTranscriber.shared.transcribe(
                    audioData: audio,
                    modelPath: modelPath,
                    useDynamicContext: true,
                    language: self.selectedLanguage
                )
                
                DispatchQueue.main.async {
                    if self.isRecording {
                        self.liveText = result.text
                        ToastWindowController.shared.showToast(
                            status: "Dictating (\(self.currentHotkey.displayString) finish • Esc cancel)",
                            text: result.text,
                            audioLevel: 0.2
                        )
                    }
                    self.isTranscribingChunk = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isTranscribingChunk = false
                }
            }
        }
    }
    
    public func cancelRecording() {
        guard isRecording else { return }
        
        GlobalHotkeyManager.shared.stopEscapeMonitoring()
        liveTimer?.invalidate()
        liveTimer = nil
        streamer.stop()
        isRecording = false
        isTranscribingChunk = false
        liveText = ""
        
        statusMessage = "Dictation cancelled (Esc)"
        ToastWindowController.shared.showToast(status: "Cancelled", text: "", audioLevel: 0.0)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            ToastWindowController.shared.hideToast()
        }
    }
    
    public func stopRecording() {
        GlobalHotkeyManager.shared.stopEscapeMonitoring()
        liveTimer?.invalidate()
        liveTimer = nil
        streamer.stop()
        isRecording = false
        isTranscribingChunk = false
        
        let samples = streamer.getSamplesSnapshot()
        
        // Save recording in chosen recordings directory
        if !samples.isEmpty {
            _ = streamer.saveWav(samples: samples, to: self.recordingsDirectory)
        }
        
        let currentLive = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Optional Finalizing step: If disabled and we already have live text, paste immediately!
        if !enableFinalizing && !currentLive.isEmpty {
            self.lastTranscript = currentLive
            self.statusMessage = "Pasted live transcript"
            ToastWindowController.shared.hideToast {
                TextPaster.paste(text: currentLive, copyToClipboard: self.copyToClipboard)
            }
            return
        }
        
        // If finalizing is enabled (or live text was empty), run full high-accuracy finalizing pass:
        guard !samples.isEmpty else {
            ToastWindowController.shared.hideToast()
            statusMessage = "No audio detected"
            return
        }
        
        statusMessage = "Processing final transcript..."
        ToastWindowController.shared.showToast(status: "Finalizing...", text: liveText, audioLevel: 0.0)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let modelPath = AudioTranscriber.resolveModelPath(named: self.selectedModel) else {
                DispatchQueue.main.async {
                    ToastWindowController.shared.hideToast()
                    self.statusMessage = "Model error"
                }
                return
            }
            
            let dur = Double(samples.count) / 16000.0
            let (trimmed, trimmedDur) = AudioLoader.stripLeadingAndTrailingSilence(samples: samples, sampleRate: 16000)
            let audio = AudioData(
                samples: trimmed.isEmpty ? samples : trimmed,
                originalDurationSec: dur,
                trimmedDurationSec: trimmed.isEmpty ? dur : trimmedDur,
                sampleRate: 16000
            )
            
            do {
                let result = try AudioTranscriber.shared.transcribe(
                    audioData: audio,
                    modelPath: modelPath,
                    useDynamicContext: true,
                    language: self.selectedLanguage
                )
                
                let finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                DispatchQueue.main.async {
                    self.lastTranscript = finalText
                    self.statusMessage = "Done • \(result.humanReadableLatency) (\(result.humanReadableDuration))"
                    
                    // Close the toast BEFORE typing/pasting text into the active app
                    ToastWindowController.shared.hideToast {
                        TextPaster.paste(text: finalText, copyToClipboard: self.copyToClipboard)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    ToastWindowController.shared.hideToast()
                    self.statusMessage = "Transcription failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
