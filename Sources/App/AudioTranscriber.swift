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
    private var asr4allContext: OpaquePointer?
    private var currentAsr4allPath: String?
    private let queue = DispatchQueue(label: "org.futo.voiceboy.transcriber", qos: .userInitiated)
    
    // Issue 5 Fix: Pinned heap pointer for native ggml_abort_callback, immune to Swift exclusivity and copy-in/out
    private let abortFlagPtr: UnsafeMutablePointer<Int32>
    
    public static let shared = AudioTranscriber()
    
    public init() {
        abortFlagPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        abortFlagPtr.initialize(to: 0)
    }
    
    deinit {
        abortFlagPtr.deallocate()
        if let ctx = context {
            whisper_free(ctx)
        }
        if let asrCtx = asr4allContext {
            asr4all_free(asrCtx)
        }
    }
    
    /// Requests immediate cancellation of any active in-flight whisper_full or ASR4ALL inference call.
    public func abortCurrentTranscription() {
        abortFlagPtr.pointee = 1
        if let asrCtx = asr4allContext {
            asr4all_abort(asrCtx)
        }
    }
    
    /// Clears any pending cancellation request before starting a new dictation session.
    public func resetAbort() {
        abortFlagPtr.pointee = 0
        if let asrCtx = asr4allContext {
            asr4all_reset_abort(asrCtx)
        }
    }
    
    public var isAborted: Bool {
        return abortFlagPtr.pointee != 0
    }
    
    public enum ModelEngine: String, Hashable {
        case whisper
        case asr4all
    }
    
    public struct BundleFile: Hashable {
        public let relativePath: String
        public let downloadURL: String
        public let expectedSizeBytes: Int64
        public let sha256: String
        
        public init(relativePath: String, downloadURL: String, expectedSizeBytes: Int64, sha256: String) {
            self.relativePath = relativePath
            self.downloadURL = downloadURL
            self.expectedSizeBytes = expectedSizeBytes
            self.sha256 = sha256
        }
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
        public let engine: ModelEngine
        public let bundleFiles: [BundleFile]
        
        public init(
            filename: String,
            displayName: String,
            category: String,
            parameterCount: String,
            bestFor: String,
            recommendation: String,
            downloadURL: String,
            expectedSizeBytes: Int64,
            sha256: String,
            engine: ModelEngine = .whisper,
            bundleFiles: [BundleFile] = []
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
            self.engine = engine
            self.bundleFiles = bundleFiles
        }
    }
    
    public static let knownModels: [ModelInfo] = [
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
        ),
        // English ASR4ALL Streaming Models (ONNX + PCEC)
        ModelInfo(
            filename: "asr4all-s",
            displayName: "ASR4ALL Small",
            category: "English (ASR4ALL)",
            parameterCount: "28M params (~106 MB)",
            bestFor: "Streaming CPU dictation - ultra fast",
            recommendation: "28M-param English streaming CTC + PCEC model.",
            downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/asr4all.onnx.data",
            expectedSizeBytes: 111226832,
            sha256: "9e6b8b118bbbc0139ecd788825c1d993d82653db4ab63467476606bd7dc271e0",
            engine: .asr4all,
            bundleFiles: [
                BundleFile(relativePath: "asr4all.onnx.data", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/asr4all.onnx.data", expectedSizeBytes: 108249312, sha256: "9e6b8b118bbbc0139ecd788825c1d993d82653db4ab63467476606bd7dc271e0"),
                BundleFile(relativePath: "metadata.json", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/metadata.json", expectedSizeBytes: 91004, sha256: "b73014a78a53883202752c6c451eb8aa4bd691e8eb96d7de083bb0c3b2894926"),
                BundleFile(relativePath: "pcec_c16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/pcec_c16.onnx", expectedSizeBytes: 138808, sha256: "b1a7c11bcdd123e87756e585f930f03fb9818f3569099e5b1e4d3a56ea25a04e"),
                BundleFile(relativePath: "pcec_c16_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/pcec_c16_flush.onnx", expectedSizeBytes: 135815, sha256: "a1a716ad9932fc6956e025589a0563c0546ec6691f302b336cb867d35c16071b"),
                BundleFile(relativePath: "pcec_c64.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/pcec_c64.onnx", expectedSizeBytes: 139657, sha256: "ecd0fe45a97df4d55cd93e8370aa7247c0f6624151e9bbf6a9354f43f26e3e96"),
                BundleFile(relativePath: "pcec_c64_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/pcec_c64_flush.onnx", expectedSizeBytes: 135923, sha256: "b6fe820e89d414c570db9b5c568915e5ae48961c205340617d54902fcc3388cd"),
                BundleFile(relativePath: "stream_c128r24.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/stream_c128r24.onnx", expectedSizeBytes: 388188, sha256: "594aa7b80ecb186e9dc612a2c58e4c6db6330bc3eee31c58d6085080757e77de"),
                BundleFile(relativePath: "stream_c16r4.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/stream_c16r4.onnx", expectedSizeBytes: 381779, sha256: "9e1fc04c729606231a3a3f6794c92f790ba04eef5cdbf65d09ea5c1cb4ea8821"),
                BundleFile(relativePath: "stream_c256r32.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/stream_c256r32.onnx", expectedSizeBytes: 388707, sha256: "2510876e2be3dda4ea654b88295ea607e87c4b1d6fa446d275340e599d766324"),
                BundleFile(relativePath: "stream_c32r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/stream_c32r8.onnx", expectedSizeBytes: 385402, sha256: "9075799dd97a16297f2948d460de2eefc248c793425de51aa220c7034be8fe21"),
                BundleFile(relativePath: "stream_c512r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/stream_c512r8.onnx", expectedSizeBytes: 389191, sha256: "fd53d23d2389d12fd0714cd4d131fd8aeb6308128f65c06fb636524b6e39b06f"),
                BundleFile(relativePath: "stream_c64r16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/stream_c64r16.onnx", expectedSizeBytes: 388229, sha256: "81eef9e892591a001b29e7a92e3b819fc6367a8a0d84c87632a3a930f05b80ba"),
                BundleFile(relativePath: "vad.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s/resolve/main/onnx/vad.onnx", expectedSizeBytes: 14817, sha256: "2f5d03c3bd904938fdb2917f37d78792572fc7188cefad3a20e7ab3c7c993d3e")
            ]
        ),
        ModelInfo(
            filename: "asr4all-m",
            displayName: "ASR4ALL Medium",
            category: "English (ASR4ALL)",
            parameterCount: "56M params (~208 MB)",
            bestFor: "Balanced streaming CPU speed & accuracy",
            recommendation: "56M-param English streaming CTC + PCEC model.",
            downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/asr4all.onnx.data",
            expectedSizeBytes: 217886952,
            sha256: "f915ab3cb21b0012b8c65214d8920b349ae8ddaa133511407b605dd8d6ae54a6",
            engine: .asr4all,
            bundleFiles: [
                BundleFile(relativePath: "asr4all.onnx.data", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/asr4all.onnx.data", expectedSizeBytes: 214322720, sha256: "f915ab3cb21b0012b8c65214d8920b349ae8ddaa133511407b605dd8d6ae54a6"),
                BundleFile(relativePath: "metadata.json", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/metadata.json", expectedSizeBytes: 91006, sha256: "e32f62550eaf2de70fadf7bd043ee96e1e34a9c3cb74ca968e5d5f258538edc5"),
                BundleFile(relativePath: "pcec_c16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/pcec_c16.onnx", expectedSizeBytes: 139240, sha256: "39180a8ac65c853aea126301fa6b5be4602ad1c968ba98517d60076f61e2292c"),
                BundleFile(relativePath: "pcec_c16_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/pcec_c16_flush.onnx", expectedSizeBytes: 136367, sha256: "7201783d866d306ca0a53616dc9800d2146c9bd6a4d4bd6557690b71da942582"),
                BundleFile(relativePath: "pcec_c64.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/pcec_c64.onnx", expectedSizeBytes: 140361, sha256: "5550c150a8935127c191d0ee3d65607c32fbd41b34ba10b9ad71d9189f56a35b"),
                BundleFile(relativePath: "pcec_c64_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/pcec_c64_flush.onnx", expectedSizeBytes: 136171, sha256: "85089b3f00e874766f56646aaba7d47f73f3529d2321e59313fc7fcef241356e"),
                BundleFile(relativePath: "stream_c128r24.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/stream_c128r24.onnx", expectedSizeBytes: 486573, sha256: "c5ab5fdc33be2fe281dfc32cb69f650ba7ba0a6d5d9ca4253ccb151e744e7d9b"),
                BundleFile(relativePath: "stream_c16r4.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/stream_c16r4.onnx", expectedSizeBytes: 478373, sha256: "a91550578e1f02f2e53a99a6102969b862bc142a88c5dbe89d8eb96dc4758b3c"),
                BundleFile(relativePath: "stream_c256r32.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/stream_c256r32.onnx", expectedSizeBytes: 486802, sha256: "046621e19dbf0a482b3a8ea17c8adfe760e6829de4b36fadb002300c1c4b3a05"),
                BundleFile(relativePath: "stream_c32r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/stream_c32r8.onnx", expectedSizeBytes: 482459, sha256: "0e462a809e254026385e6deca4677ed961278918b17c64384acd82d000a3d24d"),
                BundleFile(relativePath: "stream_c512r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/stream_c512r8.onnx", expectedSizeBytes: 486511, sha256: "60a31bad078718ca3f78f2d3b34a26da3706dd3d57a15d14d84ab8c89a22850a"),
                BundleFile(relativePath: "stream_c64r16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/stream_c64r16.onnx", expectedSizeBytes: 485549, sha256: "ff1d6c4431a7f62b02089d3fc35fefffc5edd5022974e4a891ed61ec363d927c"),
                BundleFile(relativePath: "vad.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m/resolve/main/onnx/vad.onnx", expectedSizeBytes: 14820, sha256: "22a811e376a988ff5a59ea77288bd07077a9d5f910378b4152237efa6efe5187")
            ]
        ),
        ModelInfo(
            filename: "asr4all-l",
            displayName: "ASR4ALL Large",
            category: "English (ASR4ALL)",
            parameterCount: "97M params (~361 MB)",
            bestFor: "High-accuracy English streaming & PCEC",
            recommendation: "97M-param English streaming CTC + PCEC model.",
            downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/asr4all.onnx.data",
            expectedSizeBytes: 377993607,
            sha256: "4d03c883a8947e70a55de6e56705b153639739ae6c22a2707193be995143c281",
            engine: .asr4all,
            bundleFiles: [
                BundleFile(relativePath: "asr4all.onnx.data", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/asr4all.onnx.data", expectedSizeBytes: 373837536, sha256: "4d03c883a8947e70a55de6e56705b153639739ae6c22a2707193be995143c281"),
                BundleFile(relativePath: "metadata.json", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/metadata.json", expectedSizeBytes: 91009, sha256: "63c6b2b00249d904e40092483626eb1e4578cea0753845a2c2a2fe9bb4ff7708"),
                BundleFile(relativePath: "pcec_c16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/pcec_c16.onnx", expectedSizeBytes: 139617, sha256: "df00b022d8ff1f60fa8bcb646f6a7acd693c0450f45d54d54d09e43cafeb6fc5"),
                BundleFile(relativePath: "pcec_c16_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/pcec_c16_flush.onnx", expectedSizeBytes: 136414, sha256: "17d492f0f639a339c9a1894efc64dab13234104924853ef93e80f7f875099059"),
                BundleFile(relativePath: "pcec_c64.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/pcec_c64.onnx", expectedSizeBytes: 140559, sha256: "2a8a312255ca284021b7a2d63907ea52668a8f4ecccbaeb17f1d3233e8812bd6"),
                BundleFile(relativePath: "pcec_c64_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/pcec_c64_flush.onnx", expectedSizeBytes: 136622, sha256: "25ef88e1370436874c7777c8a525e03690cdc7fc9527f10d975147cb7cfa7229"),
                BundleFile(relativePath: "stream_c128r24.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/stream_c128r24.onnx", expectedSizeBytes: 585337, sha256: "bafee8da9c5e056d36b57337f73459c043853d30e8d4d3ed4617738a3138c750"),
                BundleFile(relativePath: "stream_c16r4.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/stream_c16r4.onnx", expectedSizeBytes: 576247, sha256: "1c0d0e31a55a3284f9157a217ab45689a3bf01cae1d47fb0eb18b0e833976fc1"),
                BundleFile(relativePath: "stream_c256r32.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/stream_c256r32.onnx", expectedSizeBytes: 585566, sha256: "1e44a50a5b15ea0599e89c662eacb1aa40a4d91203e419b47aad01b33361d793"),
                BundleFile(relativePath: "stream_c32r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/stream_c32r8.onnx", expectedSizeBytes: 580674, sha256: "8efbd8a9342ea035f8db42fe88a5e59b7f4a35f253d7be38fd9d4cb9d49d6050"),
                BundleFile(relativePath: "stream_c512r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/stream_c512r8.onnx", expectedSizeBytes: 585753, sha256: "e669a94796cfdccbc4901b5ab74f157363b274659d1b3791c4dc1b9d42f9c872"),
                BundleFile(relativePath: "stream_c64r16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/stream_c64r16.onnx", expectedSizeBytes: 583423, sha256: "d1a4fc405c7772521b480829725616403c5590b1a5de303564034a0fd2ff73cb"),
                BundleFile(relativePath: "vad.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l/resolve/main/onnx/vad.onnx", expectedSizeBytes: 14850, sha256: "ea15b0b527b70c9e0dae6c9fa91a6381e7a6c8359fc5982be61ea8b344489eb0")
            ]
        ),
        ModelInfo(
            filename: "asr4all-s-plus",
            displayName: "ASR4ALL Small+",
            category: "English (ASR4ALL)",
            parameterCount: "33M params (~125 MB)",
            bestFor: "Fast streaming + speaker/diarization heads",
            recommendation: "33M-param English ASR4ALL Small bundle with speaker segmentation & verification.",
            downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/asr4all.onnx.data",
            expectedSizeBytes: 130683332,
            sha256: "1281c7e51d784dd40abed8703e982572b1267e601896f066c9f1ab72cdc6779c",
            engine: .asr4all,
            bundleFiles: [
                BundleFile(relativePath: "asr4all.onnx.data", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/asr4all.onnx.data", expectedSizeBytes: 127105152, sha256: "1281c7e51d784dd40abed8703e982572b1267e601896f066c9f1ab72cdc6779c"),
                BundleFile(relativePath: "metadata.json", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/metadata.json", expectedSizeBytes: 91190, sha256: "b01c050624398aef5a61a1f97b5faf201f0d3e0ed0277d45ef50a4fa5de20a76"),
                BundleFile(relativePath: "pcec_c16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/pcec_c16.onnx", expectedSizeBytes: 138808, sha256: "06055719448006a2f041b5cd97c74997d5f3b8700b79b0a630369a65219fc41f"),
                BundleFile(relativePath: "pcec_c16_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/pcec_c16_flush.onnx", expectedSizeBytes: 135815, sha256: "8d70b6f45cfcfd553b6fa00fd0756f4fd782715aedad215f85d24632a56af393"),
                BundleFile(relativePath: "pcec_c64.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/pcec_c64.onnx", expectedSizeBytes: 139657, sha256: "ebac73520641ff133de0d8ac87fa0bb4561e33c9781226304a8af19a5ea44f4f"),
                BundleFile(relativePath: "pcec_c64_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/pcec_c64_flush.onnx", expectedSizeBytes: 135923, sha256: "73069a2ace136b6235579bd618fbee96c019f236a78555b36d462521ebf97f4f"),
                BundleFile(relativePath: "seg.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/seg.onnx", expectedSizeBytes: 386292, sha256: "94991c941ec2e23782d5bfd2de4085a588a770d0542a3d3071062b9f98093b7a"),
                BundleFile(relativePath: "stream_c128r24.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/stream_c128r24.onnx", expectedSizeBytes: 365583, sha256: "d18550d081b4efcc94802730bf35a29580bab2270ab29a4f0fea55cc4c0aea85"),
                BundleFile(relativePath: "stream_c16r4.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/stream_c16r4.onnx", expectedSizeBytes: 359174, sha256: "791d442b0928b47d73bc4f0666c9f56d5dfffce9840a230c3122e9678dd93e0c"),
                BundleFile(relativePath: "stream_c256r32.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/stream_c256r32.onnx", expectedSizeBytes: 366102, sha256: "e5238e01fd58db631f8dd511b74d9b193cdf4cc21dc5f577296b7c2d45dcf988"),
                BundleFile(relativePath: "stream_c32r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/stream_c32r8.onnx", expectedSizeBytes: 362797, sha256: "c6c7dee4c96c8d636844c138606519d354065a26884731b22db73f78508ad6e8"),
                BundleFile(relativePath: "stream_c512r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/stream_c512r8.onnx", expectedSizeBytes: 366586, sha256: "65dcaa340d83fb7818e2032c836ce2c0ec44fce9f717f4dda25e79e8b48d5647"),
                BundleFile(relativePath: "stream_c64r16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/stream_c64r16.onnx", expectedSizeBytes: 365624, sha256: "00d26a0ea18398b310057996ef2c7ba248168dbf6eb371796f8462a6bfb8dd50"),
                BundleFile(relativePath: "sv.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/sv.onnx", expectedSizeBytes: 306782, sha256: "ea2192e0fc8c164b13629ba0ac4968799c5803c9380a34199e00ddee52b43307"),
                BundleFile(relativePath: "vad.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-s-plus/resolve/main/onnx/vad.onnx", expectedSizeBytes: 57847, sha256: "be5bfa256b6af354b08a451caaabc5ad20b8a225e7de8c31f596545f3c74b171")
            ]
        ),
        ModelInfo(
            filename: "asr4all-m-plus",
            displayName: "ASR4ALL Medium+",
            category: "English (ASR4ALL)",
            parameterCount: "61M params (~229 MB)",
            bestFor: "Balanced streaming + speaker/diarization heads",
            recommendation: "61M-param English ASR4ALL Medium bundle with speaker segmentation & verification.",
            downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/asr4all.onnx.data",
            expectedSizeBytes: 240349984,
            sha256: "04e8c6cf813a1ddef785ce1b4766431cc2407e9668e23011dac43fe68f6c55c3",
            engine: .asr4all,
            bundleFiles: [
                BundleFile(relativePath: "asr4all.onnx.data", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/asr4all.onnx.data", expectedSizeBytes: 236242368, sha256: "04e8c6cf813a1ddef785ce1b4766431cc2407e9668e23011dac43fe68f6c55c3"),
                BundleFile(relativePath: "metadata.json", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/metadata.json", expectedSizeBytes: 91192, sha256: "963ddff1540cb3ecf7c216a50e99ab349c145a84c37322cd067f3ce44028654d"),
                BundleFile(relativePath: "pcec_c16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/pcec_c16.onnx", expectedSizeBytes: 139240, sha256: "bb87c4793619b3ef4b47b51682092090365b2db4902557d7dfaf2433783ae916"),
                BundleFile(relativePath: "pcec_c16_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/pcec_c16_flush.onnx", expectedSizeBytes: 136367, sha256: "39602815718e4020df44cb8f72acf68ce690730ed8c1c725f92437bfa740b741"),
                BundleFile(relativePath: "pcec_c64.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/pcec_c64.onnx", expectedSizeBytes: 140361, sha256: "0b9d35e2d3a95c79c3d86325aa8992c3d4edfeae9e495a57d3aef99cf8ee0aaf"),
                BundleFile(relativePath: "pcec_c64_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/pcec_c64_flush.onnx", expectedSizeBytes: 136171, sha256: "7703c763d587ef883a6dcb4885a8af384faf944a1222a292fe0c64191c3b509c"),
                BundleFile(relativePath: "seg.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/seg.onnx", expectedSizeBytes: 294668, sha256: "b2e18abcb01ca9f31161af7bfd577ec917a82efae429aa0d3e04076116346a11"),
                BundleFile(relativePath: "stream_c128r24.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/stream_c128r24.onnx", expectedSizeBytes: 468574, sha256: "8811ba38a70fc52eb680362cc92baa81d794cfeeb37037bf8cf81cae6a68a291"),
                BundleFile(relativePath: "stream_c16r4.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/stream_c16r4.onnx", expectedSizeBytes: 460374, sha256: "ba83061f4b954a7f16e67ab47ce0a4bb891064c8ccfdd04c7e7a1816f2c3c696"),
                BundleFile(relativePath: "stream_c256r32.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/stream_c256r32.onnx", expectedSizeBytes: 468803, sha256: "43cf8d3e629199c2e663b02ac429db5bd84fa2d94df72911fc6d56b45e4e6397"),
                BundleFile(relativePath: "stream_c32r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/stream_c32r8.onnx", expectedSizeBytes: 464460, sha256: "052e44f7372bcf9f673c2ba1476dc757e199e04579da827be0ba04ddb13ace33"),
                BundleFile(relativePath: "stream_c512r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/stream_c512r8.onnx", expectedSizeBytes: 468512, sha256: "1a009e4c4d3862f943f905ee29ddfbe072db00ff09d595892cf8ea73ee397761"),
                BundleFile(relativePath: "stream_c64r16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/stream_c64r16.onnx", expectedSizeBytes: 467550, sha256: "8cc0aae3643274bab4fa3611dffa03d29b6b66e821e0550c4a9fb24f7e20adb9"),
                BundleFile(relativePath: "sv.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/sv.onnx", expectedSizeBytes: 313270, sha256: "ab7a81a26cc08a9ec821da83ca03edc423d969d666f0fb1339690c29cebc99e3"),
                BundleFile(relativePath: "vad.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-m-plus/resolve/main/onnx/vad.onnx", expectedSizeBytes: 58074, sha256: "a2ce6d0ee47115be4f0355fe6303567962ac453d3cba9ebc16d96e8a61f8df36")
            ]
        ),
        ModelInfo(
            filename: "asr4all-l-plus",
            displayName: "ASR4ALL Large+",
            category: "English (ASR4ALL)",
            parameterCount: "104M params (~386 MB)",
            bestFor: "Top ASR4ALL accuracy + speaker/diarization heads",
            recommendation: "104M-param English ASR4ALL Large bundle with speaker segmentation & verification.",
            downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/asr4all.onnx.data",
            expectedSizeBytes: 404899509,
            sha256: "6244044d75815baa5103014176f4d6126a5fdead9908c978fad0ef659e622841",
            engine: .asr4all,
            bundleFiles: [
                BundleFile(relativePath: "asr4all.onnx.data", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/asr4all.onnx.data", expectedSizeBytes: 400193664, sha256: "6244044d75815baa5103014176f4d6126a5fdead9908c978fad0ef659e622841"),
                BundleFile(relativePath: "metadata.json", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/metadata.json", expectedSizeBytes: 91195, sha256: "3b86876ea902f0f7d5dc306d2be8408087e2f200dbb3a3699f5779844ddb5cec"),
                BundleFile(relativePath: "pcec_c16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/pcec_c16.onnx", expectedSizeBytes: 139617, sha256: "bf673db58064ca7fb37a5e3cfe77e6063c732f4d937b1c4cf1cb107926ae5d86"),
                BundleFile(relativePath: "pcec_c16_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/pcec_c16_flush.onnx", expectedSizeBytes: 136414, sha256: "322f5dce66844c9c6b9e93d0f1dd1b35d2b208554c1ff0105cf7bdec350f4472"),
                BundleFile(relativePath: "pcec_c64.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/pcec_c64.onnx", expectedSizeBytes: 140559, sha256: "74d668866d983399665451a6328888f85f2fc8674ba6e0d89707dd8ad487767f"),
                BundleFile(relativePath: "pcec_c64_flush.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/pcec_c64_flush.onnx", expectedSizeBytes: 136622, sha256: "111c850112fab1c29d0e6b3a36afb16cf7c18bf80b1ae6639147c200ff6aef7c"),
                BundleFile(relativePath: "seg.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/seg.onnx", expectedSizeBytes: 298229, sha256: "5149aa43c3b968b8f54bef62e0125260cd8ea373dfa4c9f461caca368452e885"),
                BundleFile(relativePath: "stream_c128r24.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/stream_c128r24.onnx", expectedSizeBytes: 567284, sha256: "e7e4a3023a0ab62300936146684827c8dfadab3bc1c1d0f723e15cc9ac38e1d6"),
                BundleFile(relativePath: "stream_c16r4.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/stream_c16r4.onnx", expectedSizeBytes: 558194, sha256: "4ca24b8f075811929607f7ef49f1183b66aa7380b0823caaa6be6cea74888a3b"),
                BundleFile(relativePath: "stream_c256r32.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/stream_c256r32.onnx", expectedSizeBytes: 567513, sha256: "7b59d0b599b8e40521d9b24ad6c43c9eeaa657ca78412ea21535b44a4068a634"),
                BundleFile(relativePath: "stream_c32r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/stream_c32r8.onnx", expectedSizeBytes: 562621, sha256: "2292ee5c3d1569e50b29b8c3453e69397689f93a1cc1a93c5da6019b586c0952"),
                BundleFile(relativePath: "stream_c512r8.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/stream_c512r8.onnx", expectedSizeBytes: 567700, sha256: "5ab52c153b1022fbc966f08fd6a570925e7e3d648c656f8cd5c691220bf278f0"),
                BundleFile(relativePath: "stream_c64r16.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/stream_c64r16.onnx", expectedSizeBytes: 565370, sha256: "2c039064d43edbe9d917d4c2468e5713f64b04403eaf18bc18a7815b4447150d"),
                BundleFile(relativePath: "sv.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/sv.onnx", expectedSizeBytes: 316266, sha256: "bf4c1244ca405833ffe2fda4f6cde19fb95461fe108e7c40adba1057d8271ef9"),
                BundleFile(relativePath: "vad.onnx", downloadURL: "https://huggingface.co/futo-org/asr4all-l-plus/resolve/main/onnx/vad.onnx", expectedSizeBytes: 58261, sha256: "e54a906f9f55f33718e69bd6ff33617256546e59adb390ef82d0f06beecc6b7c")
            ]
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
    
    /// Returns true if the model supports English only (does not support Polish or other languages).
    public static func isEnglishOnlyModel(_ filename: String) -> Bool {
        if let info = knownModels.first(where: { $0.filename == filename }) {
            return info.category.localizedCaseInsensitiveContains("English")
        }
        return filename.contains("english") || filename.hasPrefix("asr4all-")
    }
    
    /// Returns true if `path` points to an ASR4ALL ONNX bundle directory.
    public static func isAsr4allBundle(at path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let meta = (path as NSString).appendingPathComponent("metadata.json")
        let weights = (path as NSString).appendingPathComponent("asr4all.onnx.data")
        return FileManager.default.fileExists(atPath: meta) && FileManager.default.fileExists(atPath: weights)
    }
    
    /// Checks whether a known model (single .bin or multi-file ASR4ALL bundle) is completely installed at `path`.
    public static func isModelInstalled(_ model: ModelInfo, at path: String) -> Bool {
        switch model.engine {
        case .whisper:
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        case .asr4all:
            guard isAsr4allBundle(at: path) else { return false }
            for file in model.bundleFiles {
                let filePath = (path as NSString).appendingPathComponent(file.relativePath)
                if !FileManager.default.fileExists(atPath: filePath) {
                    return false
                }
            }
            return true
        }
    }
    
    /// Resolves the absolute path for a model file name or returns a standard fallback.
    public static func resolveModelPath(named name: String = "asr4all-s", language: String? = nil) -> String? {
        // Path traversal sanitization: reject attempts containing relative dots or invalid paths
        let isPathTraversal = name.contains("..") || (name.contains("/") && !name.hasPrefix("/"))
        if isPathTraversal {
            return nil
        }
        
        // 1. Direct path or exact name lookup
        if name.hasPrefix("/") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: name, isDirectory: &isDir) {
                if !isDir.boolValue || isAsr4allBundle(at: name) {
                    return name
                }
            }
        }
        
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        if !safeName.isEmpty && safeName != "." && safeName != ".." {
            if let found = findModelOnDisk(named: safeName) {
                return found
            }
        }
        
        // 2. Intelligent fallback to available models if exact requested model is not downloaded
        let isNonEnglish = (language != nil && !language!.isEmpty && language!.lowercased() != "en" && language!.lowercased() != "auto")
        let fallbackOrder: [String]
        if isNonEnglish {
            fallbackOrder = [
                "voice-input-multilingual-74.bin",
                "voice-input-multilingual-244.bin",
                "asr4all-s",
                "asr4all-m",
                "asr4all-l"
            ]
        } else {
            fallbackOrder = [
                "asr4all-s",
                "asr4all-m",
                "asr4all-l",
                "asr4all-s-plus",
                "asr4all-m-plus",
                "asr4all-l-plus",
                "voice-input-multilingual-74.bin",
                "voice-input-multilingual-244.bin"
            ]
        }
        
        for candidate in fallbackOrder {
            if let found = findModelOnDisk(named: candidate) {
                return found
            }
        }
        
        // 3. Check for any valid .bin model or ASR4ALL bundle in xdgModelsDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: xdgModelsDirectory.path) {
            for file in contents.sorted() where !file.hasPrefix(".") {
                let fullPath = xdgModelsDirectory.appendingPathComponent(file).path
                if file.hasSuffix(".bin"), FileManager.default.fileExists(atPath: fullPath) {
                    return fullPath
                }
                if isAsr4allBundle(at: fullPath) {
                    return fullPath
                }
            }
        }
        
        return nil
    }
    
    public static func findModelOnDisk(named safeName: String) -> String? {
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
        
        let known = knownModels.first(where: { $0.filename == safeName })
        for candidate in candidates {
            if let known {
                if isModelInstalled(known, at: candidate) {
                    return candidate
                }
            } else {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir) {
                    if !isDir.boolValue || isAsr4allBundle(at: candidate) {
                        return candidate
                    }
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
            currentModelPath = nil
        }
        if let asrCtx = asr4allContext {
            asr4all_free(asrCtx)
            asr4allContext = nil
            currentAsr4allPath = nil
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
    
    private func _loadAsr4allUnlocked(at path: String, threads: Int32) throws {
        if asr4allContext != nil && currentAsr4allPath == path {
            return
        }
        if let asrCtx = asr4allContext {
            asr4all_free(asrCtx)
            asr4allContext = nil
            currentAsr4allPath = nil
        }
        if let ctx = context {
            whisper_free(ctx)
            context = nil
            currentModelPath = nil
        }
        
        var errBuf = [CChar](repeating: 0, count: 512)
        guard let newCtx = asr4all_init(path, threads, &errBuf, errBuf.count) else {
            let msg = String(cString: errBuf)
            throw TranscriberError.contextInitializationFailed(msg.isEmpty ? "asr4all_init failed for \(path)" : msg)
        }
        self.asr4allContext = newCtx
        self.currentAsr4allPath = path
    }
    
    /// Peak-normalizes quiet input so low-gain microphones produce usable log-mel features.
    /// Gain is capped to avoid amplifying pure background noise into phantom speech.
    static func normalizeGain(_ samples: [Float], targetPeak: Float = 0.9, maxGain: Float = 10.0) -> [Float] {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        guard peak > 0 else { return samples }
        let gain = min(maxGain, targetPeak / peak)
        guard gain > 1.05 else { return samples }
        return samples.map { $0 * gain }
    }

    /// Transcribes audio samples using FUTO Whisper ACFT or ASR4ALL ONNX models without translation.
    public func transcribe(audioData: AudioData,
                           modelPath: String? = nil,
                           useDynamicContext: Bool = true,
                           language: String = "en") throws -> TranscriptionResult {
        return try queue.sync {
            let activeModelPath: String
            if let customPath = modelPath {
                activeModelPath = customPath
            } else if let cached = currentModelPath ?? currentAsr4allPath {
                activeModelPath = cached
            } else if let detected = AudioTranscriber.resolveModelPath() {
                activeModelPath = detected
            } else {
                throw TranscriberError.modelNotFound("No FUTO model found. Please verify an ASR4ALL or multilingual model exists in models directory.")
            }
            
            guard !audioData.samples.isEmpty else {
                throw TranscriberError.emptyAudio
            }
            let samples = AudioTranscriber.normalizeGain(audioData.samples)
            
            // Subsystem E: Bind thread count to physical cores on Intel to prevent hyperthreading cache thrashing
            let threads = Int32(min(8, max(1, AudioTranscriber.physicalCoreCount)))
            
            if AudioTranscriber.isAsr4allBundle(at: activeModelPath) {
                return try self._transcribeAsr4allUnlocked(
                    samples: samples,
                    audioData: audioData,
                    modelPath: activeModelPath,
                    useDynamicContext: useDynamicContext,
                    threads: threads
                )
            }
            
            if context == nil || currentModelPath != activeModelPath {
                try self._loadModelUnlocked(at: activeModelPath)
            }
            guard let ctx = context else {
                throw TranscriberError.contextInitializationFailed("No active context")
            }
            
            let dur = Double(samples.count) / 16000.0
            let isLongAudio = dur > 30.0
            
            // Issue 6 Fix:
            // For utterances <= 30s, dynamic audio context shrinks the encoder compute window to match actual duration.
            // For continuous utterances > 30s, targetCtx is set to 0 (full 30s context) and single_segment is false,
            // enabling whisper.cpp standard multi-segment sliding window processing so trailing audio is not truncated.
            let targetCtx: Int32
            if useDynamicContext && !isLongAudio {
                // Round up and add a safety margin: truncating to exactly dur*50 drops the final
                // encoder frames, which clips the last word of the utterance.
                targetCtx = Int32(min(1500, max(64, Int((dur * 50.0).rounded(.up)) + 32)))
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
            // Suppress non-speech tokens (♪, *, brackets, etc.) that show up as stray symbols
            wparams.suppress_nst = true
            
            // Issue 5 Fix: Hook ggml_abort_callback to enable instant cancellation mid-inference
            if self.isAborted {
                throw TranscriberError.transcriptionCancelled
            }
            wparams.abort_callback = { userData in
                guard let ptr = userData?.assumingMemoryBound(to: Int32.self) else { return false }
                return ptr.pointee != 0
            }
            wparams.abort_callback_user_data = UnsafeMutableRawPointer(self.abortFlagPtr)
            
            let resolvedLang: String? = (language.isEmpty || language.lowercased() == "auto") ? nil : language
            
            let start = DispatchTime.now()
            var status: Int32 = 0
            
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
            
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            
            if self.isAborted || status != 0 {
                // Free corrupted or partially-evaluated context so subsequent calls re-initialize cleanly
                if let ctx = self.context {
                    whisper_free(ctx)
                    self.context = nil
                }
                if self.isAborted {
                    throw TranscriberError.transcriptionCancelled
                }
                throw TranscriberError.transcriptionFailed(status)
            }
            
            let nSegments = whisper_full_n_segments(ctx)
            // Concatenate raw bytes across segments before decoding so multi-byte UTF-8
            // characters split across segment boundaries are reassembled correctly.
            var recognizedBytes: [UInt8] = []
            for i in 0..<nSegments {
                if let segPtr = whisper_full_get_segment_text(ctx, i) {
                    recognizedBytes.append(contentsOf: UnsafeBufferPointer(start: UnsafeRawPointer(segPtr).assumingMemoryBound(to: UInt8.self), count: strlen(segPtr)))
                }
            }
            let recognized = String(decoding: recognizedBytes, as: UTF8.self)

            // Issue 8 Fix: Strip [BLANK_AUDIO]-style annotations and do NOT inject diagnostic messages
            // into recognized output text. Silent audio returns empty text so it never pastes into apps.
            // Also drop U+FFFD replacement chars left by incomplete UTF-8 sequences when decoding
            // stops mid-character (shows up as garbage symbols at the end of the text).
            let cleanText = recognized
                .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\u{FFFD}", with: "")
                .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
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
    
    private func _transcribeAsr4allUnlocked(
        samples: [Float],
        audioData: AudioData,
        modelPath: String,
        useDynamicContext: Bool,
        threads: Int32
    ) throws -> TranscriptionResult {
        if self.isAborted {
            throw TranscriberError.transcriptionCancelled
        }
        
        if asr4allContext == nil || currentAsr4allPath != modelPath {
            try self._loadAsr4allUnlocked(at: modelPath, threads: threads)
        }
        guard let ctx = asr4allContext else {
            throw TranscriberError.contextInitializationFailed("No active ASR4ALL context")
        }
        
        if self.isAborted {
            throw TranscriberError.transcriptionCancelled
        }
        asr4all_reset_abort(ctx)
        
        let dur = Double(samples.count) / 16000.0
        let tierName: String
        if useDynamicContext {
            tierName = dur <= 2.5 ? "stream_c16r4" : "stream_c32r8"
        } else {
            tierName = "stream_c256r32"
        }
        
        var outTextPtr: UnsafeMutablePointer<CChar>? = nil
        var outWindowSamples: Int32 = 0
        var errBuf = [CChar](repeating: 0, count: 512)
        
        let start = DispatchTime.now()
        let rc = samples.withUnsafeBufferPointer { buf in
            asr4all_transcribe(
                ctx,
                buf.baseAddress,
                buf.count,
                tierName,
                true,
                &outTextPtr,
                &outWindowSamples,
                &errBuf,
                errBuf.count
            )
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        
        if self.isAborted || rc == -2 {
            if let ptr = outTextPtr {
                asr4all_free_string(ptr)
            }
            throw TranscriberError.transcriptionCancelled
        }
        if rc != 0 {
            if let ptr = outTextPtr {
                asr4all_free_string(ptr)
            }
            throw TranscriberError.transcriptionFailed(rc)
        }
        
        let recognized: String
        if let ptr = outTextPtr {
            recognized = String(cString: ptr)
            asr4all_free_string(ptr)
        } else {
            recognized = ""
        }
        
        let cleanText = recognized
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let isSilence = cleanText.isEmpty
        let audioDur = audioData.originalDurationSec
        let rtf = audioDur > 0 ? (elapsedMs / 1000.0) / audioDur : 0.0
        let modelName = URL(fileURLWithPath: modelPath).lastPathComponent
        
        return TranscriptionResult(
            text: cleanText,
            originalDurationSec: audioDur,
            processedDurationSec: audioData.trimmedDurationSec,
            inferenceDurationMs: elapsedMs,
            realTimeFactor: rtf,
            audioContextSize: Int(outWindowSamples / 640),
            modelPath: modelPath,
            modelName: modelName,
            isSilence: isSilence
        )
    }
}
