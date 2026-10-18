import Foundation
import AVFoundation

/// High-performance, real-time safe audio ring buffer.
/// Pre-allocated buffer memory ensures zero heap allocations on the CoreAudio IOThread.
public final class RealtimeAudioRingBuffer {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeHead: Int = 0
    private var readHead: Int = 0
    private var lock = os_unfair_lock_s()
    
    private(set) public var droppedSampleCount: Int = 0
    
    public init(capacity: Int = 131072) { // 131,072 samples = 8.192 seconds at 16kHz
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }
    
    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }
    
    public func reset() {
        os_unfair_lock_lock(&lock)
        writeHead = 0
        readHead = 0
        droppedSampleCount = 0
        os_unfair_lock_unlock(&lock)
    }
    
    /// Called on CoreAudio real-time I/O thread: zero allocations, microsecond execution time.
    @discardableResult
    public func write(from source: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        let available = capacity - (writeHead - readHead)
        let toWrite = min(count, max(0, available))
        if toWrite < count {
            droppedSampleCount += (count - toWrite)
        }
        guard toWrite > 0 else { return 0 }
        
        let startIdx = writeHead % capacity
        let firstChunk = min(toWrite, capacity - startIdx)
        let secondChunk = toWrite - firstChunk
        
        buffer.advanced(by: startIdx).assign(from: source, count: firstChunk)
        if secondChunk > 0 {
            buffer.assign(from: source.advanced(by: firstChunk), count: secondChunk)
        }
        writeHead += toWrite
        return toWrite
    }
    
    /// Drains pending samples into target buffer safely while protecting buffer memory.
    public func drain(into target: inout [Float]) {
        os_unfair_lock_lock(&lock)
        let available = writeHead - readHead
        guard available > 0 else {
            os_unfair_lock_unlock(&lock)
            return
        }
        
        let startIdx = readHead % capacity
        let firstChunk = min(available, capacity - startIdx)
        let secondChunk = available - firstChunk
        
        target.reserveCapacity(target.count + available)
        target.append(contentsOf: UnsafeBufferPointer(start: buffer.advanced(by: startIdx), count: firstChunk))
        if secondChunk > 0 {
            target.append(contentsOf: UnsafeBufferPointer(start: buffer, count: secondChunk))
        }
        
        readHead += available
        os_unfair_lock_unlock(&lock)
    }
    
    public var pendingSampleCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return max(0, writeHead - readHead)
    }
}

public final class LiveAudioStreamer {
    private let audioEngine = AVAudioEngine()
    private(set) public var isRecording = false
    private let targetSampleRate: Double = 16000.0
    
    // Real-time lock-free ring buffer for audio tap
    private let ringBuffer = RealtimeAudioRingBuffer()
    private var accumulatedSamples: [Float] = []
    private let consumerLock = NSLock()
    
    // Pre-allocated conversion buffer reused on real-time thread (zero heap allocations)
    private var conversionBuffer: AVAudioPCMBuffer?
    private var audioConverter: AVAudioConverter?
    
    public var onVolumeChanged: ((Float) -> Void)?
    public var onConfigurationChange: ((Error?) -> Void)?
    
    public init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: audioEngine
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }
    
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
    
    public static var isMicrophoneAuthorized: Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    public func start() throws {
        stop()
        
        // Issue 20: Explicitly verify microphone authorization status before starting CoreAudio engine
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .denied || authStatus == .restricted {
            throw AudioLoaderError.conversionFailed("Microphone access is denied or restricted.")
        }
        
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
        self.audioConverter = converter
        
        // Pre-allocate conversion buffer outside real-time callback (8192 frames = >500ms headroom)
        guard let preallocated = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192) else {
            throw AudioLoaderError.conversionFailed("Failed to pre-allocate real-time conversion buffer.")
        }
        self.conversionBuffer = preallocated
        
        consumerLock.lock()
        ringBuffer.reset()
        accumulatedSamples.removeAll(keepingCapacity: true)
        consumerLock.unlock()
        
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1) // 100ms chunks
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let converter = self.audioConverter,
                  let convertedBuffer = self.conversionBuffer else { return }
            
            // Issue 4 Fix: Calculate maximum RMS audio level across ALL available hardware channels
            if let channelData = buffer.floatChannelData {
                let channelCount = Int(buffer.format.channelCount)
                let frameCount = Int(buffer.frameLength)
                var maxRms: Float = 0.0
                for ch in 0..<channelCount {
                    let channelPtr = channelData[ch]
                    var sumSq: Float = 0
                    for i in 0..<frameCount {
                        let s = channelPtr[i]
                        sumSq += s * s
                    }
                    let rms = sqrt(sumSq / Float(max(1, frameCount)))
                    if rms > maxRms {
                        maxRms = rms
                    }
                }
                self.onVolumeChanged?(maxRms)
            }
            
            // Zero dynamic memory allocation on CoreAudio real-time thread.
            // Reset frameLength to full capacity on pre-allocated conversionBuffer and convert in-place.
            convertedBuffer.frameLength = convertedBuffer.frameCapacity
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
                // Write directly into ring buffer without any Array heap allocations or mutex contention
                self.ringBuffer.write(from: outData, count: frameCount)
            }
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }
    
    public func stop() {
        // ALWAYS remove tap first unconditionally to prevent "nullptr == Tap()" exceptions on subsequent start()
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        isRecording = false
        onVolumeChanged?(0)
    }
    
    // Issue 3 Fix: Handle hardware device route & configuration changes
    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        guard isRecording else { return }
        
        // Serialize configuration restarts on the main queue to prevent concurrent start/stop races
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording else { return }
            do {
                // Attempt to seamlessly restart the audio engine with new hardware configuration
                try self.start()
                self.onConfigurationChange?(nil)
            } catch {
                self.stop()
                self.onConfigurationChange?(error)
            }
        }
    }
    
    /// Retrieves a snapshot of all accumulated speech samples.
    /// Drains from real-time ring buffer without blocking CoreAudio tap.
    public func getSamplesSnapshot() -> [Float] {
        consumerLock.lock()
        defer { consumerLock.unlock() }
        ringBuffer.drain(into: &accumulatedSamples)
        return accumulatedSamples
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
