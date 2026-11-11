import Cocoa
import SwiftUI

public class AppState: ObservableObject {
    public static let shared = AppState()
    
    @Published public var isRecording: Bool = false
    @Published public var liveText: String = ""
    @Published public var lastTranscript: String = ""
    @Published public var selectedModel: String = "asr4all-s" {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: AppState.selectedModelDefaultsKey)
        }
    }
    
    private static let selectedModelDefaultsKey = "VoiceBoy_SelectedModel"
    private static let finalizingDefaultsKey = "VoiceBoy_EnableFinalizing"
    private static let recordingsDirDefaultsKey = "VoiceBoy_RecordingsDirectory"
    private static let showDockIconDefaultsKey = "VoiceBoy_ShowDockIcon"
    private static let copyToClipboardDefaultsKey = "VoiceBoy_CopyToClipboard"
    private static let saveRecordingsToDiskDefaultsKey = "VoiceBoy_SaveRecordingsToDisk"
    
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
    
    // Optional Save Recordings to Disk (Default: false for user privacy)
    @Published public var saveRecordingsToDisk: Bool {
        didSet {
            UserDefaults.standard.set(saveRecordingsToDisk, forKey: AppState.saveRecordingsToDiskDefaultsKey)
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
    private(set) public var activeSessionID: UUID?
    
    // Sliding Window & Tail Audio Tracking state (Issues 7 & 9)
    private var committedPrefixText: String = ""
    private var committedSampleOffset: Int = 0
    private var lastTranscribedSampleCount: Int = 0
    private var liveSessionGeneration: UInt64 = 0
    private var usingIncrementalAsr4allStream: Bool = false
    private var asr4allStreamStartedForSession: Bool = false
    private var asr4allLiveStreamDisabled: Bool = false

    /// Whether stopRecording may paste the live text directly instead of running a final pass.
    /// ASR4ALL streams always need finish(): the engine holds up to one window of unprocessed audio
    /// (plus the PCEC end-of-utterance flush) that is never reflected in the live preview.
    static func shouldPasteLivePreviewOnStop(
        enableFinalizing: Bool,
        usingIncrementalAsr4allStream: Bool,
        totalSamples: Int,
        lastTranscribedSampleCount: Int,
        liveText: String
    ) -> Bool {
        guard !enableFinalizing, !usingIncrementalAsr4allStream else { return false }
        let liveCoversAllAudio = totalSamples - lastTranscribedSampleCount < 16000 / 10
        return liveCoversAllAudio && !liveText.isEmpty && liveText != "[Silence / No speech detected]"
    }

    /// Errors that will recur on every live tick (model missing, integrity/load failure) and should stop
    /// further live steps for the session instead of being retried every 0.7 s.
    static func isFatalLiveStreamError(_ error: Error) -> Bool {
        if case TranscriberError.transcriptionCancelled = error { return false }
        return true
    }

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
        
        let storedModel = UserDefaults.standard.string(forKey: AppState.selectedModelDefaultsKey)
        let validStoredModel = storedModel.flatMap { name in
            AudioTranscriber.knownModels.contains(where: { $0.filename == name }) ? name : nil
        }
        let initialModel = validStoredModel ?? "asr4all-s"
        if let resolved = AudioTranscriber.resolveModelPath(named: initialModel) {
            let actualName = URL(fileURLWithPath: resolved).lastPathComponent
            self.selectedModel = actualName
        } else {
            self.selectedModel = initialModel
        }
        
        if UserDefaults.standard.object(forKey: AppState.copyToClipboardDefaultsKey) != nil {
            self.copyToClipboard = UserDefaults.standard.bool(forKey: AppState.copyToClipboardDefaultsKey)
        } else {
            self.copyToClipboard = true
        }
        
        if UserDefaults.standard.object(forKey: AppState.saveRecordingsToDiskDefaultsKey) != nil {
            self.saveRecordingsToDisk = UserDefaults.standard.bool(forKey: AppState.saveRecordingsToDiskDefaultsKey)
        } else {
            self.saveRecordingsToDisk = false
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
                ToastWindowController.shared.showToast(status: "Microphone Access Denied", text: "Please enable microphone permission in System Settings.", audioLevel: 0.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { ToastWindowController.shared.hideToast() }
                return
            }
            
            guard let resolvedModel = AudioTranscriber.resolveModelPath(named: self.selectedModel) else {
                self.statusMessage = "No speech model found"
                ToastWindowController.shared.showToast(status: "No speech model installed", text: "Open VoiceBoy settings to download a speech model.", audioLevel: 0.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { ToastWindowController.shared.hideToast() }
                return
            }
            
            let actualModelName = URL(fileURLWithPath: resolvedModel).lastPathComponent
            if self.selectedModel != actualModelName {
                self.selectedModel = actualModelName
            }
            
            do {
                let sessionID = UUID()
                self.activeSessionID = sessionID
                let sessionGen = AudioTranscriber.shared.abortAndAdvanceGeneration()
                _ = AudioTranscriber.shared.resetAbort(ifMatchingGeneration: sessionGen)
                self.liveSessionGeneration = sessionGen
                self.usingIncrementalAsr4allStream = AudioTranscriber.isAsr4allBundle(at: resolvedModel)
                self.asr4allStreamStartedForSession = false
                self.asr4allLiveStreamDisabled = false
                self.liveText = ""
                self.statusMessage = "Recording..."
                self.isRecording = true
                
                // Monitor Escape key to allow instant dictation cancellation
                GlobalHotkeyManager.shared.startEscapeMonitoring()
                
                self.streamer.onVolumeChanged = { [weak self] level in
                    DispatchQueue.main.async {
                        guard let self = self, self.activeSessionID == sessionID, self.isRecording else { return }
                        ToastWindowController.shared.showToast(
                            status: "Dictating (\(self.currentHotkey.displayString) finish • Esc cancel)",
                            text: self.liveText,
                            audioLevel: level
                        )
                    }
                }
                
                self.streamer.onConfigurationChange = { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self = self, self.activeSessionID == sessionID, self.isRecording else { return }
                        if let err = error {
                            self.statusMessage = "Audio device disconnected: \(err.localizedDescription)"
                            self.cancelRecording()
                        } else {
                            self.statusMessage = "Audio device changed, recovered"
                        }
                    }
                }
                
                try self.streamer.start()
                
                self.committedPrefixText = ""
                self.committedSampleOffset = 0
                self.lastTranscribedSampleCount = 0
                
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
                self.activeSessionID = nil
            }
        }
    }
    
    private func runLiveCycle() {
        guard isRecording, !isTranscribingChunk else { return }
        guard let sessionID = self.activeSessionID else { return }
        let sessionGen = self.liveSessionGeneration
        
        if usingIncrementalAsr4allStream {
            guard !asr4allLiveStreamDisabled else { return }
            let (_, totalCount) = streamer.drainSamples(since: Int.max)
            guard Double(totalCount - lastTranscribedSampleCount) / 16000.0 >= 0.5 else { return }
            
            let needsRestart = !asr4allStreamStartedForSession
            asr4allStreamStartedForSession = true
            isTranscribingChunk = true
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                guard let modelPath = AudioTranscriber.resolveModelPath(named: self.selectedModel) else {
                    DispatchQueue.main.async { self.isTranscribingChunk = false }
                    return
                }
                do {
                    let (fullText, _) = try AudioTranscriber.shared.stepAsr4allStream(
                        modelPath: modelPath,
                        tierName: "stream_c16r4",
                        restartStream: needsRestart,
                        expectedGeneration: sessionGen,
                        sampleSliceProvider: { [weak self] fromOffset in
                            guard let self = self else { return [] }
                            return self.streamer.drainSamples(since: fromOffset).chunk
                        }
                    )
                    DispatchQueue.main.async {
                        guard self.activeSessionID == sessionID, self.isRecording else {
                            self.isTranscribingChunk = false
                            return
                        }
                        self.liveText = fullText
                        self.lastTranscribedSampleCount = self.streamer.drainSamples(since: Int.max).totalCount
                        ToastWindowController.shared.showToast(
                            status: "Dictating (\(self.currentHotkey.displayString) finish • Esc cancel)",
                            text: fullText,
                            audioLevel: 0.2
                        )
                        self.isTranscribingChunk = false
                    }
                } catch {
                    let fatal = AppState.isFatalLiveStreamError(error)
                    DispatchQueue.main.async {
                        self.isTranscribingChunk = false
                        guard fatal, self.activeSessionID == sessionID, self.isRecording else { return }
                        // Stop retrying (each retry re-runs model load + integrity hashing); stop() reports via finish.
                        self.asr4allLiveStreamDisabled = true
                        self.statusMessage = "Live preview unavailable: \(error.localizedDescription)"
                    }
                }
            }
            return
        }
        
        let samples = streamer.getSamplesSnapshot()
        let totalCount = samples.count
        let uncommittedCount = totalCount - committedSampleOffset
        guard Double(uncommittedCount) / 16000.0 >= 0.5 else { return }

        // Track the active window start locally: the prefix commit below updates
        // committedSampleOffset asynchronously on main, so reading it back here would
        // re-transcribe (and duplicate) the just-committed prefix.
        var activeStart = committedSampleOffset

        isTranscribingChunk = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let modelPath = AudioTranscriber.resolveModelPath(named: self.selectedModel) else {
                DispatchQueue.main.async { self.isTranscribingChunk = false }
                return
            }
            
            // Issue 9: Sliding window & prefix stabilization ($O(1)$ computation per tick)
            // If active uncommitted audio exceeds ~6 seconds, find a natural pause and commit prefix
            if uncommittedCount >= 16000 * 6 {
                let searchStart = activeStart + 16000 * 3
                let searchEnd = activeStart + 16000 * 5
                if let splitPoint = AudioLoader.findSilenceSplitPoint(samples: samples, sampleRate: 16000, searchStart: searchStart, searchEnd: searchEnd) {
                    let prefixSlice = Array(samples[activeStart..<splitPoint])
                    let prefixDur = Double(prefixSlice.count) / 16000.0
                    let prefixAudio = AudioData(samples: prefixSlice, originalDurationSec: prefixDur, trimmedDurationSec: prefixDur, sampleRate: 16000)
                    if let prefixRes = try? AudioTranscriber.shared.transcribe(audioData: prefixAudio, modelPath: modelPath, useDynamicContext: true, language: "auto", expectedGeneration: sessionGen) {
                        let trimmedPrefix = prefixRes.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedPrefix.isEmpty {
                            activeStart = splitPoint
                            DispatchQueue.main.async {
                                guard self.activeSessionID == sessionID, self.isRecording else { return }
                                self.committedPrefixText = self.committedPrefixText.isEmpty ? trimmedPrefix : "\(self.committedPrefixText) \(trimmedPrefix)"
                                self.committedSampleOffset = splitPoint
                            }
                        }
                    }
                }
            }
            
            // Transcribe active slice from committedSampleOffset to totalCount
            let activeSlice = Array(samples[activeStart..<totalCount])
            let dur = Double(activeSlice.count) / 16000.0
            let (trimmed, trimmedDur) = AudioLoader.stripLeadingAndTrailingSilence(samples: activeSlice, sampleRate: 16000)
            let audio = AudioData(
                samples: trimmed.isEmpty ? activeSlice : trimmed,
                originalDurationSec: dur,
                trimmedDurationSec: trimmed.isEmpty ? dur : trimmedDur,
                sampleRate: 16000
            )
            
            do {
                let result = try AudioTranscriber.shared.transcribe(
                    audioData: audio,
                    modelPath: modelPath,
                    useDynamicContext: true,
                    language: "auto",
                    expectedGeneration: sessionGen
                )
                
                DispatchQueue.main.async {
                    guard self.activeSessionID == sessionID, self.isRecording else {
                        self.isTranscribingChunk = false
                        return
                    }
                    let activeText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fullText: String
                    if self.committedPrefixText.isEmpty {
                        fullText = activeText
                    } else if activeText.isEmpty {
                        fullText = self.committedPrefixText
                    } else {
                        fullText = "\(self.committedPrefixText) \(activeText)"
                    }
                    
                    self.liveText = fullText
                    self.lastTranscribedSampleCount = totalCount
                    
                    ToastWindowController.shared.showToast(
                        status: "Dictating (\(self.currentHotkey.displayString) finish • Esc cancel)",
                        text: fullText,
                        audioLevel: 0.2
                    )
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
        guard isRecording || activeSessionID != nil else { return }
        self.activeSessionID = nil
        self.liveSessionGeneration = AudioTranscriber.shared.abortAndAdvanceGeneration()
        AudioTranscriber.shared.cancelAsr4allStreamAsync()
        
        GlobalHotkeyManager.shared.stopEscapeMonitoring()
        liveTimer?.invalidate()
        liveTimer = nil
        streamer.stop()
        isRecording = false
        isTranscribingChunk = false
        liveText = ""
        committedPrefixText = ""
        committedSampleOffset = 0
        lastTranscribedSampleCount = 0
        usingIncrementalAsr4allStream = false
        asr4allStreamStartedForSession = false
        asr4allLiveStreamDisabled = false

        statusMessage = "Dictation cancelled (Esc)"
        ToastWindowController.shared.showToast(status: "Cancelled", text: "", audioLevel: 0.0)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            ToastWindowController.shared.hideToast()
        }
    }
    
    public func stopRecording() {
        guard isRecording, let sessionID = self.activeSessionID else { return }
        
        GlobalHotkeyManager.shared.stopEscapeMonitoring()
        liveTimer?.invalidate()
        liveTimer = nil
        streamer.stop()
        isRecording = false
        
        // Advance generation token so stale queued live chunks reject themselves cleanly inside queue.sync.
        // ASR4ALL streams must NOT abort an in-flight step: aborting discards the incremental stream and forces
        // finish() to re-feed the whole recording (O(N)); letting the step complete keeps finish() O(tail).
        // Whisper live chunks are independent batch passes, so aborting them frees the queue for the final pass.
        let finalizeGen = usingIncrementalAsr4allStream
            ? AudioTranscriber.shared.advanceGenerationWithoutAbort()
            : AudioTranscriber.shared.abortAndAdvanceGeneration()
        self.liveSessionGeneration = finalizeGen
        isTranscribingChunk = false
        
        let samples = streamer.getSamplesSnapshot()
        
        // Save recording in chosen recordings directory only if explicitly enabled (Issue 10)
        if saveRecordingsToDisk && !samples.isEmpty {
            _ = streamer.saveWav(samples: samples, to: self.recordingsDirectory)
        }
        
        // Guard against zero recorded audio
        guard !samples.isEmpty else {
            self.activeSessionID = nil
            AudioTranscriber.shared.cancelAsr4allStreamAsync()
            ToastWindowController.shared.hideToast()
            statusMessage = "No audio detected"
            return
        }
        
        let currentLive = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // When Post-processing is OFF (!enableFinalizing):
        // Paste the live transcript instantly only if it already covers all recorded audio.
        // Otherwise the words spoken after the last live cycle would be dropped, so flush the
        // uncommitted tail below (fast: at most a few seconds of audio) without the "Finalizing..." UI.
        if !enableFinalizing {
            if AppState.shouldPasteLivePreviewOnStop(
                enableFinalizing: enableFinalizing,
                usingIncrementalAsr4allStream: usingIncrementalAsr4allStream,
                totalSamples: samples.count,
                lastTranscribedSampleCount: lastTranscribedSampleCount,
                liveText: currentLive
            ) {
                self.activeSessionID = nil
                AudioTranscriber.shared.cancelAsr4allStreamAsync()
                self.lastTranscript = currentLive
                self.statusMessage = "Pasted live transcript"
                ToastWindowController.shared.hideToast {
                    TextPaster.paste(text: currentLive, copyToClipboard: self.copyToClipboard)
                }
                return
            }
        } else {
            // When Post-processing is ON (enableFinalizing == true):
            // Run full post-processing / finalizing pass for maximum accuracy:
            statusMessage = "Processing final transcript..."
            ToastWindowController.shared.showToast(status: "Finalizing...", text: liveText, audioLevel: 0.0)
        }
        
        // Run finalizing/flush pass asynchronously; expectedGeneration: finalizeGen safely resets abort inside queue.sync.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let modelPath = AudioTranscriber.resolveModelPath(named: self.selectedModel) else {
                DispatchQueue.main.async {
                    guard self.activeSessionID == sessionID else { return }
                    self.activeSessionID = nil
                    self.statusMessage = "No speech model found"
                    ToastWindowController.shared.showToast(status: "No speech model found", text: "Download a model in settings to enable dictation.", audioLevel: 0.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { ToastWindowController.shared.hideToast() }
                }
                return
            }
            
            do {
                let finalText: String
                let result: TranscriptionResult
                if AudioTranscriber.isAsr4allBundle(at: modelPath) {
                    let dur = Double(samples.count) / 16000.0
                    result = try AudioTranscriber.shared.finishAsr4allStream(
                        modelPath: modelPath,
                        tierName: "stream_c16r4",
                        originalDurationSec: dur,
                        trimmedDurationSec: dur,
                        expectedGeneration: finalizeGen,
                        sampleSliceProvider: { fromOffset in
                            guard fromOffset < samples.count else { return [] }
                            return Array(samples[fromOffset..<samples.count])
                        }
                    )
                    finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    // If we have a committed prefix, only transcribe the remaining uncommitted tail audio
                    let samplesToTranscribe: [Float]
                    let prefixToPrepend: String
                    if self.committedSampleOffset > 0 && !self.committedPrefixText.isEmpty && self.committedSampleOffset < samples.count {
                        samplesToTranscribe = Array(samples[self.committedSampleOffset..<samples.count])
                        prefixToPrepend = self.committedPrefixText
                    } else {
                        samplesToTranscribe = samples
                        prefixToPrepend = ""
                    }
                    
                    let dur = Double(samplesToTranscribe.count) / 16000.0
                    let (trimmed, trimmedDur) = AudioLoader.stripLeadingAndTrailingSilence(samples: samplesToTranscribe, sampleRate: 16000)
                    let audio = AudioData(
                        samples: trimmed.isEmpty ? samplesToTranscribe : trimmed,
                        originalDurationSec: dur,
                        trimmedDurationSec: trimmed.isEmpty ? dur : trimmedDur,
                        sampleRate: 16000
                    )
                    
                    result = try AudioTranscriber.shared.transcribe(
                        audioData: audio,
                        modelPath: modelPath,
                        useDynamicContext: true,
                        language: "auto",
                        expectedGeneration: finalizeGen
                    )
                    
                    let activeText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if prefixToPrepend.isEmpty {
                        finalText = activeText
                    } else if activeText.isEmpty {
                        finalText = prefixToPrepend
                    } else {
                        finalText = "\(prefixToPrepend) \(activeText)"
                    }
                }
                
                DispatchQueue.main.async {
                    guard self.activeSessionID == sessionID else { return }
                    self.activeSessionID = nil
                    self.lastTranscript = finalText
                    
                    if !finalText.isEmpty && finalText != "[Silence / No speech detected]" {
                        self.statusMessage = "Done • \(result.humanReadableLatency) (\(result.humanReadableDuration))"
                        // Close the toast BEFORE typing/pasting text into the active app
                        ToastWindowController.shared.hideToast {
                            TextPaster.paste(text: finalText, copyToClipboard: self.copyToClipboard)
                        }
                    } else {
                        self.statusMessage = "No speech detected"
                        ToastWindowController.shared.showToast(status: "No speech detected", text: "", audioLevel: 0.0)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            ToastWindowController.shared.hideToast()
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.activeSessionID == sessionID else { return }
                    self.activeSessionID = nil
                    ToastWindowController.shared.hideToast()
                    if case TranscriberError.transcriptionCancelled = error {
                        self.statusMessage = "Transcription cancelled"
                    } else {
                        self.statusMessage = "Transcription failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
