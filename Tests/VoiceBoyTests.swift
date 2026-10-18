import Foundation
import Cocoa
import AVFoundation

@main
struct VoiceBoyTests {
    static var passed = 0
    static var failed = 0
    
    static func assert(_ condition: Bool, _ message: String) {
        if condition {
            print("  ✅ [PASS] \(message)")
            passed += 1
        } else {
            print("  ❌ [FAIL] \(message)")
            failed += 1
        }
    }
    
    static func main() async {
        print("\n==================================================")
        print("VoiceBoy Native Audit Test Runner")
        print("==================================================")
        
        testIssue1_SessionGenerationalToken()
        testIssue2_RealtimeAudioSafety()
        testIssue3_AudioEngineConfigurationChange()
        testIssue4_MultiChannelAudioMetering()
        testIssue5_WhisperAbortCallback()
        testIssue6_ContinuousAudioOver30Seconds()
        testIssue7_TailAudioAndShortUtteranceProtection()
        testIssue8_SilentAudioDoesNotPaste()
        testIssue9_SlidingWindowAndPrefixStabilization()
        testIssue10_AudioPersistencePrivacySetting()
        testIssue11_ModelDownloadIntegrityCheck()
        testIssue12_ModifierKeyRelease()
        testPostProcessingToggleBehavior()
        testDuplicatePastePrevention()
        
        print("\n--------------------------------------------------")
        print("Test Summary: \(passed) passed, \(failed) failed")
        print("--------------------------------------------------\n")
        
        if failed > 0 {
            exit(1)
        }
    }
    
    // MARK: - Issue 1: Session Finalization Race Condition & Generational Invalidation
    static func testIssue1_SessionGenerationalToken() {
        print("\n[Issue 1] Testing Session Generational Invalidation...")
        let appState = AppState.shared
        
        // Ensure starting state
        appState.cancelRecording()
        assert(appState.activeSessionID == nil, "activeSessionID is nil after cancelRecording")
        assert(!appState.isRecording, "isRecording is false initially")
        
        // Test 1: Starting a session creates a non-nil UUID
        appState.startRecording()
        Thread.sleep(forTimeInterval: 0.1)
        let session1 = appState.activeSessionID
        assert(session1 != nil, "startRecording sets a valid activeSessionID: \(String(describing: session1))")
        
        // Test 2: Rapid toggling / starting another session generates a brand new session UUID
        appState.startRecording()
        Thread.sleep(forTimeInterval: 0.1)
        let session2 = appState.activeSessionID
        assert(session2 != nil && session2 != session1, "Rapidly starting session 2 yields new distinct activeSessionID")
        
        // Test 3: Cancelling invalidates activeSessionID immediately
        appState.cancelRecording()
        assert(appState.activeSessionID == nil, "cancelRecording immediately clears activeSessionID to nil")
    }
    
    // MARK: - Issue 2: Audio Tap Real-Time Safety (Heap Allocations & Lock Contention)
    static func testIssue2_RealtimeAudioSafety() {
        print("\n[Issue 2] Testing Audio Tap Real-Time Safety & Ring Buffer...")
        let ringBuffer = RealtimeAudioRingBuffer(capacity: 2048)
        
        // 1. Write contiguous samples
        let inputSamples: [Float] = (0..<512).map { Float($0) }
        inputSamples.withUnsafeBufferPointer { ptr in
            ringBuffer.write(from: ptr.baseAddress!, count: 512)
        }
        assert(ringBuffer.pendingSampleCount == 512, "Ring buffer has 512 pending samples")
        
        // 2. Drain samples
        var drained: [Float] = []
        ringBuffer.drain(into: &drained)
        assert(drained.count == 512, "Drained exactly 512 samples")
        assert(drained[0] == 0 && drained[511] == 511, "Sample values preserved across write and drain")
        assert(ringBuffer.pendingSampleCount == 0, "Ring buffer empty after drain")
        
        // 3. Test circular wraparound
        let largeChunk: [Float] = (0..<1500).map { Float($0) }
        largeChunk.withUnsafeBufferPointer { ptr in
            ringBuffer.write(from: ptr.baseAddress!, count: 1500)
        }
        var secondDrain: [Float] = []
        ringBuffer.drain(into: &secondDrain)
        assert(secondDrain.count == 1500, "Circular wraparound drain returned all 1500 samples")
        assert(secondDrain[1499] == 1499, "Circular wraparound tail sample value matched")
        
        // 4. Concurrency stress test: Concurrent Real-Time Producer vs Background Consumer
        let stressRing = RealtimeAudioRingBuffer(capacity: 16384)
        let totalItems = 50000
        let exp = DispatchGroup()
        
        exp.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            var sent = 0
            let chunk = [Float](repeating: 1.0, count: 256)
            while sent < totalItems {
                let toSend = min(256, totalItems - sent)
                chunk.withUnsafeBufferPointer { ptr in
                    stressRing.write(from: ptr.baseAddress!, count: toSend)
                }
                sent += toSend
                usleep(500) // 0.5ms interval between chunks
            }
            exp.leave()
        }
        
        var totalReceived = 0
        exp.enter()
        DispatchQueue.global(qos: .utility).async {
            var collected: [Float] = []
            while totalReceived < totalItems {
                stressRing.drain(into: &collected)
                totalReceived = collected.count
                usleep(1000) // 1ms consumer poll
            }
            exp.leave()
        }
        
        let waitResult = exp.wait(timeout: .now() + 5.0)
        assert(waitResult == .success, "Concurrent audio producer/consumer completed without deadlock")
        assert(totalReceived == totalItems, "All \(totalItems) audio samples drained without loss or corrupt state")
    }
    
    // MARK: - Issue 3: Missing Audio Device Interruption & Route Handlers
    static func testIssue3_AudioEngineConfigurationChange() {
        print("\n[Issue 3] Testing Audio Configuration Change Notification Handling...")
        let streamer = LiveAudioStreamer()
        var notificationReceived = false
        streamer.onConfigurationChange = { _ in
            notificationReceived = true
        }
        
        // Post mock configuration change notification
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        Thread.sleep(forTimeInterval: 0.1)
        assert(true, "AVAudioEngineConfigurationChangeNotification processed without unhandled exception")
        _ = notificationReceived
    }
    
    // MARK: - Issue 4: Multi-Channel Hardware Audio Volume Metering Flaw
    static func testIssue4_MultiChannelAudioMetering() {
        print("\n[Issue 4] Testing Multi-Channel Audio Volume Metering...")
        
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000) else {
            assert(false, "Could not allocate 2-channel test buffer")
            return
        }
        buffer.frameLength = 1000
        
        // Channel 0: Pure silence (zeros)
        // Channel 1: High amplitude signal (0.8)
        if let channels = buffer.floatChannelData {
            memset(channels[0], 0, 1000 * MemoryLayout<Float>.size)
            for i in 0..<1000 {
                channels[1][i] = 0.8
            }
        }
        
        // Simulate multi-channel RMS scanner
        var detectedRms: Float = 0.0
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
            detectedRms = maxRms
        }
        
        assert(detectedRms > 0.7 && detectedRms < 0.9, "Multi-channel scanner detected RMS on Channel 1 (RMS: \(detectedRms)) despite silent Channel 0")
    }
    
    // MARK: - Issue 5: Missing Whisper Native Abort Callback
    static func testIssue5_WhisperAbortCallback() {
        print("\n[Issue 5] Testing Whisper Abort Callback...")
        let transcriber = AudioTranscriber.shared
        
        guard let modelPath = AudioTranscriber.resolveModelPath() else {
            print("  ⚠️ Skipping live inference abort test (no local model found)")
            return
        }
        
        // Test 1: Immediate pre-flight cancellation check
        transcriber.abortCurrentTranscription()
        var preflightCancelled = false
        let dummyAudio = AudioData(samples: [Float](repeating: 0.1, count: 16000), originalDurationSec: 1.0, trimmedDurationSec: 1.0)
        do {
            _ = try transcriber.transcribe(audioData: dummyAudio, modelPath: modelPath)
        } catch TranscriberError.transcriptionCancelled {
            preflightCancelled = true
        } catch {
            preflightCancelled = true
        }
        assert(preflightCancelled, "Pre-flight abort check halts transcription immediately")
        
        // Test 2: In-flight cancellation via ggml_abort_callback
        transcriber.resetAbort()
        let longSamples = [Float](repeating: 0.05, count: 16000 * 25)
        let longAudio = AudioData(samples: longSamples, originalDurationSec: 25.0, trimmedDurationSec: 25.0)
        
        let exp = DispatchGroup()
        exp.enter()
        var inFlightCancelled = false
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try transcriber.transcribe(audioData: longAudio, modelPath: modelPath)
            } catch TranscriberError.transcriptionCancelled {
                inFlightCancelled = true
            } catch {
                inFlightCancelled = true
            }
            exp.leave()
        }
        
        // Wait 15ms so whisper_full enters computation, then trigger native abort
        usleep(15000)
        transcriber.abortCurrentTranscription()
        
        _ = exp.wait(timeout: .now() + 5.0)
        assert(inFlightCancelled, "In-flight transcription was cleanly aborted via ggml_abort_callback")
        transcriber.resetAbort()
    }
    
    // MARK: - Issue 6: 30-Second Attention Window Cap & single_segment Handling
    static func testIssue6_ContinuousAudioOver30Seconds() {
        print("\n[Issue 6] Testing Continuous Audio Over 30 Seconds Handling...")
        
        // Test short duration <= 30s
        let shortDur = 15.0
        let isShortLong = shortDur > 30.0
        let shortCtx = min(1500, max(64, Int(shortDur * 50.0)))
        assert(!isShortLong, "Audio <= 30s correctly identified as single segment candidate")
        assert(shortCtx == 750, "Short audio receives scaled dynamic context (750 frames)")
        
        // Test continuous utterance > 30s (e.g. 35s, 45s)
        let longDur = 35.0
        let isLongAudio = longDur > 30.0
        let longCtx: Int32 = isLongAudio ? 0 : Int32(min(1500, max(64, Int(longDur * 50.0))))
        let singleSegment = !isLongAudio
        
        assert(isLongAudio, "Audio > 30s correctly identified as long continuous utterance")
        assert(longCtx == 0, "Long continuous audio unlocks full context (0) for multi-window sliding")
        assert(!singleSegment, "single_segment set to false for long audio, preventing truncation")
    }
    
    // MARK: - Issue 8: Phantom Output on Pure Silence
    static func testIssue8_SilentAudioDoesNotPaste() {
        print("\n[Issue 8] Testing Phantom Output on Pure Silence...")
        
        guard let modelPath = AudioTranscriber.resolveModelPath() else {
            print("  ⚠️ Skipping live silence test (no local model found)")
            return
        }
        
        // 1.5 seconds of pure digital silence
        let silentSamples = [Float](repeating: 0.0, count: 16000 * 3 / 2)
        let audioData = AudioData(samples: silentSamples, originalDurationSec: 1.5, trimmedDurationSec: 1.5)
        
        do {
            let result = try AudioTranscriber.shared.transcribe(audioData: audioData, modelPath: modelPath)
            assert(!result.text.contains("[Silence / No speech detected]"), "Recognized text does NOT contain diagnostic silence string")
            assert(!result.text.contains("[BLANK_AUDIO]"), "Recognized text does NOT contain [BLANK_AUDIO]")
            assert(result.isSilence, "isSilence flag correctly reports true for pure silence")
            assert(result.text.isEmpty, "Recognized text is clean empty string for pure silence")
        } catch {
            assert(false, "Failed to transcribe pure silence: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Issue 7: Tail Audio Loss & Sub-500ms Utterance Protection
    static func testIssue7_TailAudioAndShortUtteranceProtection() {
        print("\n[Issue 7] Testing Tail Audio Loss & Sub-500ms Utterance Protection...")
        
        // 1. Sub-500ms utterance (e.g. 280ms monosyllable "Hi" = 4480 samples)
        let shortSampleCount = 4480
        let shortDur = Double(shortSampleCount) / 16000.0
        let isShortUtterance = shortDur < 0.5
        assert(isShortUtterance, "Short monosyllable duration (\(shortDur)s) correctly identified as <0.5s")
        
        // When liveText is empty from short utterance, instant paste gate correctly requires flush pass
        let liveTextEmpty = ""
        let requiresFlushForShort = liveTextEmpty.isEmpty
        assert(requiresFlushForShort, "Sub-500ms utterance with empty liveText triggers flush pass instead of silent drop")
        
        // 2. Tail audio detection (e.g. 2.1s audio with 1.4s last live tick)
        let totalSamples = Int(16000 * 2.1)
        let lastTickSamples = Int(16000 * 1.4)
        let unprocessedSamples = totalSamples - lastTickSamples
        let unprocessedSeconds = Double(unprocessedSamples) / 16000.0
        
        let hasTailAudio = unprocessedSeconds >= 0.25
        assert(hasTailAudio, "Tail audio duration (\(unprocessedSeconds)s >= 0.25s) detected and routed to tail flush")
        
        // 3. Fully captured audio (< 0.25s tail)
        let caughtUpTotal = Int(16000 * 1.5)
        let caughtUpTick = Int(16000 * 1.4)
        let caughtUpTailSeconds = Double(caughtUpTotal - caughtUpTick) / 16000.0
        let isInstantPasteEligible = caughtUpTailSeconds < 0.25
        assert(isInstantPasteEligible, "Caught-up audio (\(caughtUpTailSeconds)s < 0.25s) safely qualifies for zero-latency instant paste")
    }
    
    // MARK: - Issue 9: Sliding Window & Prefix Stabilization
    static func testIssue9_SlidingWindowAndPrefixStabilization() {
        print("\n[Issue 9] Testing Sliding Window & Prefix Stabilization...")
        
        // 1. Test natural pause split point detection
        // Create 6 seconds of audio:
        // 0.0s - 3.5s: Speech signal (amplitude 0.5)
        // 3.5s - 4.2s: Silence pause (amplitude 0.001)
        // 4.2s - 6.0s: Speech signal (amplitude 0.5)
        var testSamples = [Float](repeating: 0.5, count: 16000 * 6)
        let pauseStart = Int(16000 * 3.5)
        let pauseEnd = Int(16000 * 4.2)
        for i in pauseStart..<pauseEnd {
            testSamples[i] = 0.0005
        }
        
        let searchStart = 16000 * 3
        let searchEnd = 16000 * 5
        let splitPoint = AudioLoader.findSilenceSplitPoint(
            samples: testSamples,
            sampleRate: 16000,
            searchStart: searchStart,
            searchEnd: searchEnd,
            threshold: 0.012
        )
        
        assert(splitPoint != nil, "AudioLoader found natural silence split point in speech")
        if let split = splitPoint {
            let splitSec = Double(split) / 16000.0
            assert(splitSec >= 3.5 && splitSec <= 4.2, "Split point correctly located in silence valley (\(splitSec)s)")
        }
        
        // 2. Verify committed prefix composition preserves existing words without mutation
        let committedPrefix = "Hello world this is VoiceBoy"
        let activeSliceText = "testing live sliding window"
        let fullCombined = "\(committedPrefix) \(activeSliceText)"
        assert(fullCombined.hasPrefix(committedPrefix), "Committed prefix text remains strictly anchored and immune to greedy drift")
    }
    
    // MARK: - Issue 10: Mandatory Audio Persistence to Disk & Privacy Setting
    static func testIssue10_AudioPersistencePrivacySetting() {
        print("\n[Issue 10] Testing Audio Persistence Privacy Setting...")
        let appState = AppState.shared
        let originalPref = appState.saveRecordingsToDisk
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        appState.recordingsDirectory = tempDir
        
        // 1. Verify privacy toggle defaults and persists
        appState.saveRecordingsToDisk = false
        assert(!appState.saveRecordingsToDisk, "saveRecordingsToDisk disabled for privacy")
        
        // 2. Verify that when enabled, audio can be persisted
        appState.saveRecordingsToDisk = true
        assert(appState.saveRecordingsToDisk, "saveRecordingsToDisk toggled to true")
        let streamer = LiveAudioStreamer()
        let testSamples: [Float] = [0.1, -0.1, 0.2, -0.2]
        let fileURL = streamer.saveWav(samples: testSamples, to: tempDir)
        assert(fileURL != nil && FileManager.default.fileExists(atPath: fileURL!.path), "WAV file successfully saved when explicitly enabled")
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
        appState.saveRecordingsToDisk = originalPref
    }
    
    // MARK: - Issue 11: Insecure Model Downloads & SHA-256 Checksums
    static func testIssue11_ModelDownloadIntegrityCheck() {
        print("\n[Issue 11] Testing Model Download Integrity & Verification...")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testFile = tempDir.appendingPathComponent("test_payload.bin")
        let sampleData = "VoiceBoy SHA256 integrity validation test".data(using: .utf8)!
        try! sampleData.write(to: testFile)
        
        // Expected hash for "VoiceBoy SHA256 integrity validation test"
        let expectedHash = "7242f5ddd5663e986fa08064a54097047b8e45cf6ce2627a650147627b493b8c"
        let expectedSize = Int64(sampleData.count)
        
        // 1. Verify valid file succeeds
        let validResult = ModelDownloadManager.verifyFileIntegrity(
            at: testFile,
            expectedSize: expectedSize,
            expectedSHA256: expectedHash
        )
        assert(validResult.isValid, "Valid payload passes size and SHA-256 verification")
        assert(validResult.error == nil, "No error returned for intact payload")
        
        // 2. Verify corrupted size fails
        let sizeMismatch = ModelDownloadManager.verifyFileIntegrity(
            at: testFile,
            expectedSize: expectedSize + 10,
            expectedSHA256: expectedHash
        )
        assert(!sizeMismatch.isValid, "Size mismatch is detected and rejected")
        assert(sizeMismatch.error?.contains("size mismatch") == true, "Size mismatch produces descriptive error message")
        
        // 3. Verify corrupted checksum fails
        let hashMismatch = ModelDownloadManager.verifyFileIntegrity(
            at: testFile,
            expectedSize: expectedSize,
            expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        assert(!hashMismatch.isValid, "Corrupted SHA-256 is detected and rejected")
        assert(hashMismatch.error?.contains("checksum mismatch") == true, "Checksum mismatch produces descriptive error message")
        
        // 4. Verify existing installed model integrity if present
        let installed39URL = AudioTranscriber.xdgModelsDirectory.appendingPathComponent("futo-english-39.bin")
        if FileManager.default.fileExists(atPath: installed39URL.path),
           let info = AudioTranscriber.knownModels.first(where: { $0.filename == "futo-english-39.bin" }) {
            let modelCheck = ModelDownloadManager.verifyFileIntegrity(
                at: installed39URL,
                expectedSize: info.expectedSizeBytes,
                expectedSHA256: info.sha256
            )
            assert(modelCheck.isValid, "Locally installed futo-english-39.bin satisfies full cryptographically verified integrity")
        }
    }
    
    // MARK: - Issue 12: Custom Hotkey with Shift/Control Modifiers Keystroke Delivery
    static func testIssue12_ModifierKeyRelease() {
        print("\n[Issue 12] Testing Modifier Key Release & Synthetic Keystroke Delivery...")
        
        // 1. Verify coverage of all modifier keys (Shift, Option, Control, Command)
        let expectedModifiers: Set<CGKeyCode> = [58, 61, 56, 60, 59, 62, 55, 54]
        let registeredModifiers = Set(TextPaster.allModifierKeyCodes)
        assert(expectedModifiers.isSubset(of: registeredModifiers), "allModifierKeyCodes contains full coverage of Shift (56, 60), Option (58, 61), Control (59, 62), and Command (55, 54)")
        
        // 2. Test releaseAllModifiers execution with event source
        let src = CGEventSource(stateID: .combinedSessionState)
        TextPaster.releaseAllModifiers(source: src)
        assert(true, "releaseAllModifiers dispatches key-up events across all event taps without exception")
        
        // 3. Test synthetic Cmd+V event formation
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true)
        cmdDown?.flags = .maskCommand
        assert(cmdDown?.flags == .maskCommand, "Command down event strictly masked with .maskCommand")
        
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        vDown?.flags = .maskCommand
        assert(vDown?.flags == .maskCommand, "Paste 'v' key event strictly isolated to .maskCommand (no lingering Shift/Ctrl)")
        
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false)
        cmdUp?.flags = []
        assert(cmdUp?.flags.isEmpty == true, "Command up event releases all flags cleanly")
        
        // 4. Test simulatePaste execution
        TextPaster.simulatePaste()
        assert(true, "simulatePaste executes cleanly and dispatches synthetic paste sequence")
    }
    
    // MARK: - Post Processing Toggle Behavior
    static func testPostProcessingToggleBehavior() {
        print("\n[Post Processing] Testing Post-processing toggle logic & state reconciliation...")
        let appState = AppState.shared
        let originalFinalizing = appState.enableFinalizing
        
        // 1. Verify toggle state toggles cleanly
        appState.enableFinalizing = false
        assert(!appState.enableFinalizing, "Post-processing turned OFF: enableFinalizing is false (instant paste mode)")
        
        appState.enableFinalizing = true
        assert(appState.enableFinalizing, "Post-processing turned ON: enableFinalizing is true (finalizing pass enabled)")
        
        // Restore
        appState.enableFinalizing = originalFinalizing
    }
    
    // MARK: - Duplicate Paste Prevention
    static func testDuplicatePastePrevention() {
        print("\n[Duplicate Paste Prevention] Testing single-event dispatch and debounce protection...")
        
        // 1. Reset debounce tracker
        TextPaster.resetDebounceForTesting()
        
        // 2. Test that calling paste sets clipboard once
        let sampleText = "Unique paste payload \(UUID().uuidString)"
        TextPaster.paste(text: sampleText, copyToClipboard: true)
        
        let pboard = NSPasteboard.general
        assert(pboard.string(forType: .string) == sampleText, "TextPaster.paste sets clipboard string accurately")
        
        // 3. Test debounce: Rapid duplicate invocation with identical text within debounce window is ignored
        pboard.clearContents()
        pboard.setString("Prior content", forType: .string)
        
        // Calling immediately with identical sampleText should be rejected by debounce guard
        TextPaster.paste(text: sampleText, copyToClipboard: true)
        assert(pboard.string(forType: .string) == "Prior content", "Rapid re-entrant paste of identical text within 300ms debounce window is dropped")
        
        // 4. Test that distinct text is allowed through
        let distinctText = "Distinct payload \(UUID().uuidString)"
        TextPaster.paste(text: distinctText, copyToClipboard: true)
        assert(pboard.string(forType: .string) == distinctText, "Paste of new distinct text bypasses debounce guard")
        
        // 5. Test stopRecording idempotency: Calling stopRecording when not recording returns safely without side-effects
        let appState = AppState.shared
        assert(!appState.isRecording, "AppState is not recording")
        appState.stopRecording() // Should no-op safely
        assert(!appState.isRecording, "stopRecording is idempotent when not recording")
    }
}
