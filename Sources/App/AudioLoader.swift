import Foundation
import AVFoundation

public enum AudioLoaderError: LocalizedError {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case conversionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Audio file not found: \(path)"
        case .unsupportedFormat(let msg):
            return "Unsupported audio format: \(msg)"
        case .conversionFailed(let msg):
            return "Failed to convert audio to 16kHz mono PCM: \(msg)"
        }
    }
}

public struct AudioData {
    public let samples: [Float]
    public let originalDurationSec: Double
    public let trimmedDurationSec: Double
    public let sampleRate: Int
    
    public init(samples: [Float], originalDurationSec: Double, trimmedDurationSec: Double, sampleRate: Int = 16000) {
        self.samples = samples
        self.originalDurationSec = originalDurationSec
        self.trimmedDurationSec = trimmedDurationSec
        self.sampleRate = sampleRate
    }
}

public final class AudioLoader {
    
    /// Loads any audio file supported by macOS CoreAudio and resamples to 16kHz Float32 mono.
    public static func loadAudio(from url: URL, trimSilence: Bool = true) throws -> AudioData {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioLoaderError.fileNotFound(url.path)
        }
        
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw AudioLoaderError.unsupportedFormat(error.localizedDescription)
        }
        
        let targetRate: Double = 16000.0
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetRate,
                                               channels: 1,
                                               interleaved: false) else {
            throw AudioLoaderError.conversionFailed("Unable to create 16kHz mono format")
        }
        
        let srcFormat = audioFile.processingFormat
        let origDuration = Double(audioFile.length) / srcFormat.sampleRate
        
        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw AudioLoaderError.conversionFailed("Unable to instantiate AVAudioConverter for \(srcFormat)")
        }
        
        // Estimated frames at target sample rate
        let estimatedFrames = AVAudioFrameCount(ceil(Double(audioFile.length) * (targetRate / srcFormat.sampleRate)) + 4096)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
            throw AudioLoaderError.conversionFailed("Failed to allocate destination PCM buffer")
        }
        
        var convertError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: inNumPackets) else {
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try audioFile.read(into: readBuffer, frameCount: inNumPackets)
                if readBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                } else {
                    outStatus.pointee = .haveData
                }
                return readBuffer
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
        }
        
        let status = converter.convert(to: outBuffer, error: &convertError, withInputFrom: inputBlock)
        if status == .error || convertError != nil {
            throw AudioLoaderError.conversionFailed(convertError?.localizedDescription ?? "Conversion ended in error status")
        }
        
        guard let channelData = outBuffer.floatChannelData else {
            throw AudioLoaderError.conversionFailed("Missing channel data in converted buffer")
        }
        
        let frameCount = Int(outBuffer.frameLength)
        let rawSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        
        if trimSilence {
            let (trimmed, trimmedDur) = stripLeadingAndTrailingSilence(samples: rawSamples, sampleRate: Int(targetRate))
            return AudioData(samples: trimmed,
                             originalDurationSec: origDuration,
                             trimmedDurationSec: trimmedDur,
                             sampleRate: Int(targetRate))
        } else {
            return AudioData(samples: rawSamples,
                             originalDurationSec: origDuration,
                             trimmedDurationSec: origDuration,
                             sampleRate: Int(targetRate))
        }
    }
    
    /// Trims leading and trailing silence using RMS energy detection to eliminate empty encoder cycles.
    public static func stripLeadingAndTrailingSilence(samples: [Float],
                                                      sampleRate: Int = 16000,
                                                      threshold: Float = 0.008) -> ([Float], Double) {
        guard !samples.isEmpty else { return ([], 0.0) }
        
        let windowSize = sampleRate / 20 // 50ms chunk
        guard samples.count > windowSize * 2 else {
            return (samples, Double(samples.count) / Double(sampleRate))
        }
        
        var startIndex = 0
        var endIndex = samples.count
        
        // Find speech onset
        var i = 0
        while i + windowSize <= samples.count {
            var sumSq: Float = 0.0
            for j in 0..<windowSize {
                let v = samples[i + j]
                sumSq += v * v
            }
            let rms = sqrt(sumSq / Float(windowSize))
            if rms > threshold {
                startIndex = max(0, i - sampleRate / 10) // 100ms lead-in padding
                break
            }
            i += windowSize
        }
        
        // Find speech offset
        var k = samples.count - windowSize
        while k >= startIndex {
            var sumSq: Float = 0.0
            for j in 0..<windowSize {
                let v = samples[k + j]
                sumSq += v * v
            }
            let rms = sqrt(sumSq / Float(windowSize))
            if rms > threshold {
                endIndex = min(samples.count, k + windowSize + sampleRate / 10) // 100ms lead-out padding
                break
            }
            k -= windowSize
        }
        
        guard startIndex < endIndex else {
            return (samples, Double(samples.count) / Double(sampleRate))
        }
        
        let slice = Array(samples[startIndex..<endIndex])
        let duration = Double(slice.count) / Double(sampleRate)
        return (slice, duration)
    }
    
    /// Locates an optimal natural pause / silence split point (RMS < threshold) within the given search range.
    public static func findSilenceSplitPoint(samples: [Float],
                                             sampleRate: Int = 16000,
                                             searchStart: Int,
                                             searchEnd: Int,
                                             threshold: Float = 0.012) -> Int? {
        guard searchStart >= 0, searchEnd <= samples.count, searchStart < searchEnd else { return nil }
        let windowSize = sampleRate / 20 // 50ms window
        var bestIndex: Int? = nil
        var lowestRms: Float = Float.greatestFiniteMagnitude
        
        var idx = searchStart
        while idx + windowSize <= searchEnd {
            var sumSq: Float = 0.0
            for j in 0..<windowSize {
                let v = samples[idx + j]
                sumSq += v * v
            }
            let rms = sqrt(sumSq / Float(windowSize))
            if rms < threshold && rms < lowestRms {
                lowestRms = rms
                bestIndex = idx + windowSize / 2
            }
            idx += windowSize
        }
        return bestIndex
    }
}
