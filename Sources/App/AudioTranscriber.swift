import Foundation

public struct TranscriptionResult {
    public let text: String
    public let originalDurationSec: Double
    public let processedDurationSec: Double
    public let inferenceDurationMs: Double
    public let realTimeFactor: Double
    public let audioContextSize: Int
    public let modelPath: String
    public let modelName: String
    public let isSilence: Bool
    
    /// Formats seconds into human-readable text (e.g. "14.2s", "1m 24s", "2h 15m")
    public static func formatHumanDuration(seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "0s" }
        if seconds < 1.0 {
            return String(format: "%dms", Int(round(seconds * 1000.0)))
        } else if seconds < 60.0 {
            return String(format: "%.1fs", seconds)
        } else if seconds < 3600.0 {
            let mins = Int(seconds) / 60
            let remSecs = Int(seconds) % 60
            return remSecs > 0 ? "\(mins)m \(remSecs)s" : "\(mins)m"
        } else {
            let hours = Int(seconds) / 3600
            let mins = (Int(seconds) % 3600) / 60
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
    }
    
    /// Formats latency milliseconds into human-readable text (e.g. "142ms", "1.24s", "3.5s")
    public static func formatHumanLatency(ms: Double) -> String {
        guard !ms.isNaN && !ms.isInfinite && ms >= 0 else { return "0ms" }
        if ms < 1000.0 {
            return String(format: "%.0fms", ms)
        } else {
            return String(format: "%.2fs", ms / 1000.0)
        }
    }
    
    public var humanReadableDuration: String {
        Self.formatHumanDuration(seconds: originalDurationSec)
    }
    
    public var humanReadableProcessedDuration: String {
        Self.formatHumanDuration(seconds: processedDurationSec)
    }
    
    public var humanReadableLatency: String {
        Self.formatHumanLatency(ms: inferenceDurationMs)
    }
    
    public var summary: String {
        let speedup = realTimeFactor > 0 ? String(format: "%.1fx faster than real-time", 1.0 / realTimeFactor) : "N/A"
        return "[\(humanReadableLatency) (\(String(format: "%.1f", inferenceDurationMs))ms) | Duration: \(humanReadableDuration) | RTF: \(String(format: "%.3f", realTimeFactor)) (\(speedup)) | Context: \(audioContextSize)]"
    }
}

public enum TranscriberError: LocalizedError {
    case modelNotFound(String)
    case contextInitializationFailed(String)
    case transcriptionFailed(Int32)
    case transcriptionCancelled
    case emptyAudio
    
    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Whisper model not found at: \(path)"
        case .contextInitializationFailed(let msg):
            return "Failed to initialize Whisper engine context: \(msg)"
        case .transcriptionFailed(let code):
            return "Transcription engine returned error code \(code)"
        case .transcriptionCancelled:
            return "Transcription was cancelled by user"
        case .emptyAudio:
            return "Provided audio stream contains no valid samples"
        }
    }
}

public final class AudioTranscriber {
    private var context: OpaquePointer?
    private var currentModelPath: String?
    private let queue = DispatchQueue(label: "org.futo.voiceboy.transcriber", qos: .userInitiated)
    
    // Issue 5 Fix: Atomic abort flag for native ggml_abort_callback
    private var abortFlag: Int32 = 0
    
    public static let shared = AudioTranscriber()
    
    public init() {}
    
    deinit {
        if let ctx = context {
            whisper_free(ctx)
        }
    }
    
    /// Requests immediate cancellation of any active in-flight whisper_full inference call.
    public func abortCurrentTranscription() {
        abortFlag = 1
    }
    
    /// Clears any pending cancellation request before starting a new dictation session.
    public func resetAbort() {
        abortFlag = 0
    }
    
    public struct ModelInfo: Identifiable, Hashable {
        public var id: String { filename }
        public let filename: String
        public let displayName: String
        public let category: String
        public let parameterCount: String
        public let bestFor: String
        public let recommendation: String
        public let downloadURL: String
        public let expectedSizeBytes: Int64
        public let sha256: String
        
        public init(
            filename: String,
            displayName: String,
            category: String,
            parameterCount: String,
            bestFor: String,
            recommendation: String,
            downloadURL: String,
            expectedSizeBytes: Int64,
            sha256: String
        ) {
            self.filename = filename
            self.displayName = displayName
            self.category = category
            self.parameterCount = parameterCount
            self.bestFor = bestFor
            self.recommendation = recommendation
            self.downloadURL = downloadURL
            self.expectedSizeBytes = expectedSizeBytes
            self.sha256 = sha256
        }
    }
    
    public static let knownModels: [ModelInfo] = [
        // English Models
        ModelInfo(
            filename: "futo-english-39.bin",
            displayName: "English-39",
            category: "English",
            parameterCount: "39M params (~43 MB)",
            bestFor: "Default, best for quick processing - fastest",
            recommendation: "Ideal for real-time live dictation and streaming with ultra-low latency.",
            downloadURL: "https://keyboard.futo.org/voice-input-english-39.bin",
            expectedSizeBytes: 43550795,
            sha256: "4b5480aa1b14a7efc5b578ef176510970a898049671c3cd237285b3e3f6bfbfc"
        ),
        ModelInfo(
            filename: "voice-input-english-74.bin",
            displayName: "English-74",
            category: "English",
            parameterCount: "74M params (~82 MB)",
            bestFor: "Balance between speed and accuracy - fast",
            recommendation: "Great for everyday dictation where you want improved accuracy on uncommon words.",
            downloadURL: "https://keyboard.futo.org/voice-input-english-74.bin",
            expectedSizeBytes: 81781811,
            sha256: "e9b4b7b81b8a28769e8aa9962aa39bb9f21b622cf6a63982e93f065ed5caf1c8"
        ),
        ModelInfo(
            filename: "voice-input-english-244.bin",
            displayName: "English-244",
            category: "English",
            parameterCount: "244M params (~264 MB)",
            bestFor: "Most accurate results - slow",
            recommendation: "Recommended for complex audio, heavy accents, noisy environments, or technical jargon.",
            downloadURL: "https://keyboard.futo.org/voice-input-english-244.bin",
            expectedSizeBytes: 264477561,
            sha256: "58fbe949992dafed917590d58bc12ca577b08b9957f0b3e0d7ee71b64bed3aa8"
        ),
        // Multilingual Models
        ModelInfo(
            filename: "voice-input-multilingual-74.bin",
            displayName: "Multilingual-74",
            category: "Multilingual",
            parameterCount: "74M params (~82 MB)",
            bestFor: "Balance between speed and accuracy - fast",
            recommendation: "Recommended for Chinese, German, Spanish, Russian, French, Portuguese, Korean, and Japanese.",
            downloadURL: "https://keyboard.futo.org/voice-input-multilingual-74.bin",
            expectedSizeBytes: 81768602,
            sha256: "e44f352c9aa2c3609dece20c733c4ad4a75c28cd9ab07d005383df55fa96efc4"
        ),
        ModelInfo(
            filename: "voice-input-multilingual-244.bin",
            displayName: "Multilingual-244",
            category: "Multilingual",
            parameterCount: "244M params (~264 MB)",
            bestFor: "Most accurate results - slow",
            recommendation: "Recommended for all other supported languages and nuanced multilingual speech.",
            downloadURL: "https://keyboard.futo.org/voice-input-multilingual-244.bin",
            expectedSizeBytes: 264464624,
            sha256: "15ef255465a6dc582ecf1ec651a4618c7ee2c18c05570bbe46493d248d465ac4"
        )
    ]
    
    /// XDG-compliant base models directory: ${XDG_DATA_HOME:-$HOME/.local/share}/voiceboy/models
    public static var xdgModelsDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let baseURL: URL
        if let xdgData = env["XDG_DATA_HOME"], !xdgData.trimmingCharacters(in: .whitespaces).isEmpty {
            baseURL = URL(fileURLWithPath: xdgData)
        } else {
            baseURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local")
                .appendingPathComponent("share")
        }
        let dir = baseURL.appendingPathComponent("voiceboy").appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// Physical core count on macOS (Intel & Apple Silicon), preventing hyperthreading contention
    public static var physicalCoreCount: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &count, &size, nil, 0) == 0 && count > 0 {
            return Int(count)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
    
    /// Resolves the absolute path for a model file name or returns a standard fallback.
    public static func resolveModelPath(named name: String = "futo-english-39.bin") -> String? {
        let requestedCandidates = [name] + (name == "futo-english-39.bin" ? knownModels.map { $0.filename } : [])
        
        for candidateName in requestedCandidates {
            // Absolute path check
            if candidateName.hasPrefix("/") && FileManager.default.fileExists(atPath: candidateName) {
                return candidateName
            }
            
            // Path traversal sanitization (Section 9)
            let safeName = URL(fileURLWithPath: candidateName).lastPathComponent
            guard !safeName.isEmpty && safeName != "." && safeName != ".." else { continue }
            
            let candidates = [
                // 1. XDG Models Directory (~/.local/share/voiceboy/models)
                xdgModelsDirectory.appendingPathComponent(safeName).path,
                // 2. Bundle Resources
                Bundle.main.path(forResource: (safeName as NSString).deletingPathExtension, ofType: (safeName as NSString).pathExtension),
                Bundle.main.resourceURL?.appendingPathComponent(safeName).path,
                Bundle.main.resourceURL?.appendingPathComponent("models/\(safeName)").path,
                // 3. Fallback for CLI development in repo
                URL(fileURLWithPath: "models/\(safeName)").path,
                URL(fileURLWithPath: safeName).path,
                // 4. Relative to binary
                Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("models/\(safeName)").path,
                Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("../Resources/models/\(safeName)").path
            ].compactMap { $0 }
            
            for candidate in candidates {
                if FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
    
    private func _loadModelUnlocked(at path: String) throws {
        if context != nil && currentModelPath == path {
            return // Already loaded
        }
        if let ctx = context {
            whisper_free(ctx)
            context = nil
        }
        
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriberError.modelNotFound(path)
        }
        
        var cparams = whisper_context_default_params()
        cparams.use_gpu = false
        cparams.flash_attn = false
        
        guard let newCtx = whisper_init_from_file_with_params(path, cparams) else {
            throw TranscriberError.contextInitializationFailed("whisper_init_from_file_with_params returned null for \(path)")
        }
        self.context = newCtx
        self.currentModelPath = path
    }
    
    /// Transcribes audio samples using FUTO ACFT optimizations without translation.
    public func transcribe(audioData: AudioData,
                           modelPath: String? = nil,
                           useDynamicContext: Bool = true,
                           language: String = "auto") throws -> TranscriptionResult {
        return try queue.sync {
            let activeModelPath: String
            if let customPath = modelPath {
                activeModelPath = customPath
            } else if let cached = currentModelPath {
                activeModelPath = cached
            } else if let detected = AudioTranscriber.resolveModelPath() {
                activeModelPath = detected
            } else {
                throw TranscriberError.modelNotFound("No FUTO model found. Please verify models/futo-english-39.bin exists.")
            }
            
            if context == nil || currentModelPath != activeModelPath {
                try self._loadModelUnlocked(at: activeModelPath)
            }
            guard let ctx = context else {
                throw TranscriberError.contextInitializationFailed("No active context")
            }
            
            let samples = audioData.samples
            guard !samples.isEmpty else {
                throw TranscriberError.emptyAudio
            }
            
            // Subsystem E: Bind thread count to physical cores on Intel to prevent hyperthreading cache thrashing
            let threads = Int32(min(8, max(1, AudioTranscriber.physicalCoreCount)))
            
            let dur = audioData.trimmedDurationSec
            let isLongAudio = dur > 30.0
            
            // Issue 6 Fix:
            // For utterances <= 30s, dynamic audio context shrinks the encoder compute window to match actual duration.
            // For continuous utterances > 30s, targetCtx is set to 0 (full 30s context) and single_segment is false,
            // enabling whisper.cpp standard multi-segment sliding window processing so trailing audio is not truncated.
            let targetCtx: Int32
            if useDynamicContext && !isLongAudio {
                targetCtx = Int32(min(1500, max(64, Int(dur * 50.0))))
            } else {
                targetCtx = 0 // whisper.cpp default: standard 30s context window
            }
            
            var wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            wparams.print_realtime = false
            wparams.print_progress = false
            wparams.print_timestamps = false
            wparams.print_special = false
            wparams.translate = false
            wparams.n_threads = threads
            wparams.no_context = true
            wparams.single_segment = !isLongAudio
            wparams.audio_ctx = targetCtx
            
            // Issue 5 Fix: Hook ggml_abort_callback to enable instant cancellation mid-inference
            if self.abortFlag != 0 {
                throw TranscriberError.transcriptionCancelled
            }
            wparams.abort_callback = { userData in
                guard let ptr = userData?.assumingMemoryBound(to: Int32.self) else { return false }
                return ptr.pointee != 0
            }
            
            let resolvedLang: String? = (language.isEmpty || language.lowercased() == "auto") ? nil : language
            
            let start = DispatchTime.now()
            var status: Int32 = 0
            
            withUnsafeMutablePointer(to: &self.abortFlag) { flagPtr in
                wparams.abort_callback_user_data = UnsafeMutableRawPointer(flagPtr)
                
                if let lang = resolvedLang {
                    status = lang.withCString { langPtr in
                        wparams.language = langPtr
                        return samples.withUnsafeBufferPointer { buf in
                            whisper_full(ctx, wparams, buf.baseAddress, Int32(buf.count))
                        }
                    }
                } else {
                    status = "auto".withCString { autoPtr in
                        wparams.language = autoPtr
                        return samples.withUnsafeBufferPointer { buf in
                            whisper_full(ctx, wparams, buf.baseAddress, Int32(buf.count))
                        }
                    }
                }
            }
            
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            
            if self.abortFlag != 0 || status != 0 {
                if self.abortFlag != 0 {
                    throw TranscriberError.transcriptionCancelled
                }
                // Free corrupted context so subsequent calls re-initialize cleanly
                if let ctx = self.context {
                    whisper_free(ctx)
                    self.context = nil
                }
                throw TranscriberError.transcriptionFailed(status)
            }
            
            let nSegments = whisper_full_n_segments(ctx)
            var recognized = ""
            for i in 0..<nSegments {
                if let segPtr = whisper_full_get_segment_text(ctx, i) {
                    recognized += String(cString: segPtr)
                }
            }
            
            // Issue 8 Fix: Strip [BLANK_AUDIO] artifacts and do NOT inject diagnostic messages
            // into recognized output text. Silent audio returns empty text so it never pastes into apps.
            let cleanText = recognized
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            let isSilence = cleanText.isEmpty
            let audioDur = audioData.originalDurationSec
            let rtf = audioDur > 0 ? (elapsedMs / 1000.0) / audioDur : 0.0
            let modelName = URL(fileURLWithPath: activeModelPath).lastPathComponent
            
            return TranscriptionResult(
                text: cleanText,
                originalDurationSec: audioDur,
                processedDurationSec: audioData.trimmedDurationSec,
                inferenceDurationMs: elapsedMs,
                realTimeFactor: rtf,
                audioContextSize: Int(targetCtx),
                modelPath: activeModelPath,
                modelName: modelName,
                isSilence: isSilence
            )
        }
    }
}
