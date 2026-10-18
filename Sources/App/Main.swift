import Cocoa

func runCLI(arguments: [String]) {
    if arguments.contains("--list-models") {
        print("Available FUTO Voice Input Models (from https://keyboard.futo.tech/voice-input-models):\n")
        var currentCategory = ""
        for model in AudioTranscriber.knownModels {
            if model.category != currentCategory {
                currentCategory = model.category
                print("[\(currentCategory) Models]")
            }
            let isInstalled = AudioTranscriber.resolveModelPath(named: model.filename) != nil
            let tag = isInstalled ? "✅ INSTALLED" : "⬇️ AVAILABLE"
            print("  • \(model.displayName) (\(model.filename)) [\(tag)]")
            print("    Specs:    \(model.parameterCount)")
            print("    Best for: \(model.bestFor)")
            print("    Usage:    \(model.recommendation)")
            print("")
        }
        exit(0)
    }
    
    if arguments.contains("-h") || arguments.contains("--help") {
        print("""
        VoiceBoy — Ultra-Fast Local Transcription with FUTO Voice Models

        Usage:
          VoiceBoy [AUDIO_FILE] [OPTIONS]

        Arguments:
          AUDIO_FILE          Path to audio file (.wav, .m4a, .mp3, .aac, .flac)

        Options:
          --model <name>      Model name or path (default: voice-input-multilingual-244.bin)
          --list-models       List all supported FUTO models and installation status
          --no-dynamic-ctx    Disable dynamic audio context (use full 30s)
          --no-trim           Disable silence trimming
          --gui               Force launch graphical interface
          -h, --help          Show this help message

        Examples:
          VoiceBoy input.wav
          VoiceBoy input.m4a --model voice-input-multilingual-244.bin
          VoiceBoy --list-models
        """)
        exit(0)
    }
    
    var audioPath: String?
    var modelName = "voice-input-multilingual-244.bin"
    var language = "auto"
    var useDynamicContext = true
    var trimSilence = true
    
    var idx = 1
    while idx < arguments.count {
        let arg = arguments[idx]
        if arg == "--model" && idx + 1 < arguments.count {
            modelName = arguments[idx + 1]
            idx += 2
        } else if (arg == "--language" || arg == "-l") && idx + 1 < arguments.count {
            language = arguments[idx + 1]
            idx += 2
        } else if arg == "--no-dynamic-ctx" {
            useDynamicContext = false
            idx += 1
        } else if arg == "--no-trim" {
            trimSilence = false
            idx += 1
        } else if arg == "--gui" {
            launchGUI()
            return
        } else if !arg.hasPrefix("-") && audioPath == nil {
            audioPath = arg
            idx += 1
        } else {
            idx += 1
        }
    }
    
    guard let path = audioPath else {
        // No audio file specified -> launch GUI
        launchGUI()
        return
    }
    
    let fileURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        fputs("Error: Audio file not found at '\(fileURL.path)'\n", stderr)
        exit(1)
    }
    
    guard let modelPath = AudioTranscriber.resolveModelPath(named: modelName) else {
        fputs("Error: Model '\(modelName)' not found in models/ directory.\n", stderr)
        exit(1)
    }
    
    do {
        let audioData = try AudioLoader.loadAudio(from: fileURL, trimSilence: trimSilence)
        let result = try AudioTranscriber.shared.transcribe(
            audioData: audioData,
            modelPath: modelPath,
            useDynamicContext: useDynamicContext,
            language: language
        )
        
        print("\nTranscription:")
        print(result.text)
        print("\nTelemetry: \(result.summary)\n")
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func launchGUI() {
    guard SingleInstanceManager.shared.acquireSingleInstanceLock() else {
        exit(0)
    }
    
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

@main
struct AppEntry {
    static func main() {
        if CommandLine.arguments.count > 1 {
            runCLI(arguments: CommandLine.arguments)
        } else {
            launchGUI()
        }
    }
}
