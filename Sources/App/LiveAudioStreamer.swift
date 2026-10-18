import Foundation
import AVFoundation

public final class LiveAudioStreamer {
    private let audioEngine = AVAudioEngine()
    private var isRecording = false
    private let targetSampleRate: Double = 16000.0
    
    // Samples buffer locked with NSLock
    private let lock = NSLock()
    private var sampleBuffer: [Float] = []
    
    public var onVolumeChanged: ((Float) -> Void)?
    
    public init() {}
    
    public static func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
    
    public func start() throws {
        stop()
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            throw AudioLoaderError.conversionFailed("Microphone input format invalid or device unavailable.")
        }
        
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetSampleRate,
                                               channels: 1,
                                               interleaved: false) else {
            throw AudioLoaderError.conversionFailed("Could not create 16kHz mono audio format.")
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioLoaderError.conversionFailed("Could not instantiate audio converter from \(inputFormat) to 16kHz mono.")
        }
        
        lock.lock()
        sampleBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
        
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1) // 100ms chunks
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // Calculate audio level (RMS) for UI visualization
            if let channelData = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                var sumSq: Float = 0
                for i in 0..<count {
                    let s = channelData[i]
                    sumSq += s * s
                }
                let rms = sqrt(sumSq / Float(max(1, count)))
                self.onVolumeChanged?(rms)
            }
            
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * (self.targetSampleRate / inputFormat.sampleRate)) + 512)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            
            var error: NSError?
            var isDone = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if !isDone {
                    isDone = true
                    outStatus.pointee = .haveData
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            if error == nil, let outData = convertedBuffer.floatChannelData?[0] {
                let frameCount = Int(convertedBuffer.frameLength)
                let newSamples = Array(UnsafeBufferPointer(start: outData, count: frameCount))
                
                self.lock.lock()
                self.sampleBuffer.append(contentsOf: newSamples)
                self.lock.unlock()
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }
    
    public func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        isRecording = false
        onVolumeChanged?(0)
    }
    
    /// Retrieves a snapshot of the current accumulated speech samples.
    public func getSamplesSnapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return sampleBuffer
    }
    
    /// Saves the current recording buffer to the specified directory
    public func saveWav(samples: [Float], to destinationDir: URL) -> URL? {
        guard !samples.isEmpty else { return nil }
        
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let fileURL = destinationDir.appendingPathComponent("VoiceBoy_\(timestamp).wav")
        
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: targetSampleRate,
                                         channels: 1,
                                         interleaved: false),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = pcmBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                channel.initialize(from: base, count: samples.count)
            }
        }
        
        do {
            let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            try audioFile.write(from: pcmBuffer)
            return fileURL
        } catch {
            return nil
        }
    }
}
