import Cocoa
import SwiftUI
import Combine
import CryptoKit

public class ModelDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = ModelDownloadManager()
    
    @Published public var downloadProgress: [String: Double] = [:]
    @Published public var activeDownloads: Set<String> = []
    @Published public var downloadedModels: Set<String> = []
    @Published public var lastError: String? = nil
    
    private struct BundleDownloadState {
        let model: AudioTranscriber.ModelInfo
        let stagingDir: URL
        var nextFileIndex: Int
        let totalExpectedBytes: Int64
        var completedBytes: Int64
        var activeTask: URLSessionDownloadTask?
    }
    
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var activeBundleDownloads: [String: BundleDownloadState] = [:]
    private var taskToFilename: [Int: String] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    
    public override init() {
        super.init()
        refreshDownloadedModels()
    }
    
    public func refreshDownloadedModels() {
        let dir = AudioTranscriber.xdgModelsDirectory
        var found = Set<String>()
        for model in AudioTranscriber.knownModels {
            let modelURL = dir.appendingPathComponent(model.filename)
            if AudioTranscriber.isModelInstalled(model, at: modelURL.path) {
                found.insert(model.filename)
            }
        }
        self.downloadedModels = found
    }
    
    public func isModelDownloaded(_ filename: String) -> Bool {
        return downloadedModels.contains(filename)
    }
    
    public func isDownloading(_ filename: String) -> Bool {
        return activeDownloads.contains(filename)
    }
    
    // Issue 21: Allowed trusted model download hostnames and HTTPS validation
    public static let allowedDownloadHosts: Set<String> = [
        "keyboard.futo.org",
        "futo.org",
        "huggingface.co"
    ]
    
    public static func isURLAllowedForDownload(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return allowedDownloadHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }
    
    public func startDownload(model: AudioTranscriber.ModelInfo) {
        guard !activeDownloads.contains(model.filename) else { return }
        
        if model.engine == .asr4all && !model.bundleFiles.isEmpty {
            startBundleDownload(model: model)
            return
        }
        
        guard let url = URL(string: model.downloadURL) else { return }
        guard Self.isURLAllowedForDownload(url) else {
            self.lastError = "Download rejected: URL must use HTTPS and point to a trusted model repository."
            return
        }
        
        lastError = nil
        activeDownloads.insert(model.filename)
        downloadProgress[model.filename] = 0.01
        
        let task = session.downloadTask(with: url)
        activeTasks[model.filename] = task
        taskToFilename[task.taskIdentifier] = model.filename
        task.resume()
    }
    
    private func startBundleDownload(model: AudioTranscriber.ModelInfo) {
        for file in model.bundleFiles {
            guard let url = URL(string: file.downloadURL), Self.isURLAllowedForDownload(url) else {
                self.lastError = "Download rejected: URL must use HTTPS and point to a trusted model repository."
                return
            }
        }
        
        let modelsDir = AudioTranscriber.xdgModelsDirectory
        let stagingDir = modelsDir.appendingPathComponent(".tmp-\(model.filename)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stagingDir.path) {
                try FileManager.default.removeItem(at: stagingDir)
            }
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            self.lastError = "Failed to prepare download folder: \(error.localizedDescription)"
            return
        }
        
        lastError = nil
        activeDownloads.insert(model.filename)
        downloadProgress[model.filename] = 0.01
        
        activeBundleDownloads[model.filename] = BundleDownloadState(
            model: model,
            stagingDir: stagingDir,
            nextFileIndex: 0,
            totalExpectedBytes: max(1, model.expectedSizeBytes),
            completedBytes: 0,
            activeTask: nil
        )
        startNextBundleFileDownload(for: model.filename)
    }
    
    private func startNextBundleFileDownload(for filename: String) {
        guard var state = activeBundleDownloads[filename] else { return }
        
        if state.nextFileIndex >= state.model.bundleFiles.count {
            let destinationURL = AudioTranscriber.xdgModelsDirectory.appendingPathComponent(filename, isDirectory: true)
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: state.stagingDir, to: destinationURL)
                
                DispatchQueue.main.async {
                    self.activeBundleDownloads.removeValue(forKey: filename)
                    self.activeDownloads.remove(filename)
                    self.downloadProgress.removeValue(forKey: filename)
                    self.downloadedModels.insert(filename)
                    
                    if !self.isModelDownloaded(AppState.shared.selectedModel) {
                        AppState.shared.selectedModel = filename
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: state.stagingDir)
                DispatchQueue.main.async {
                    self.lastError = "Failed to save model bundle: \(error.localizedDescription)"
                    self.activeBundleDownloads.removeValue(forKey: filename)
                    self.activeDownloads.remove(filename)
                    self.downloadProgress.removeValue(forKey: filename)
                }
            }
            return
        }
        
        let fileSpec = state.model.bundleFiles[state.nextFileIndex]
        guard let url = URL(string: fileSpec.downloadURL) else {
            try? FileManager.default.removeItem(at: state.stagingDir)
            activeBundleDownloads.removeValue(forKey: filename)
            activeDownloads.remove(filename)
            downloadProgress.removeValue(forKey: filename)
            self.lastError = "Invalid download URL for \(fileSpec.relativePath)"
            return
        }
        
        let task = session.downloadTask(with: url)
        state.activeTask = task
        activeBundleDownloads[filename] = state
        taskToFilename[task.taskIdentifier] = filename
        task.resume()
    }
    
    public func cancelDownload(filename: String) {
        if let task = activeTasks[filename] {
            task.cancel()
            taskToFilename.removeValue(forKey: task.taskIdentifier)
            activeTasks.removeValue(forKey: filename)
        }
        if let bundleState = activeBundleDownloads.removeValue(forKey: filename) {
            if let task = bundleState.activeTask {
                taskToFilename.removeValue(forKey: task.taskIdentifier)
                task.cancel()
            }
            try? FileManager.default.removeItem(at: bundleState.stagingDir)
        }
        activeDownloads.remove(filename)
        downloadProgress.removeValue(forKey: filename)
    }
    
    // MARK: - URLSessionDownloadDelegate
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let filename = taskToFilename[downloadTask.taskIdentifier] else { return }
        if let bundleState = activeBundleDownloads[filename] {
            let progress = min(0.99, max(0.01, Double(bundleState.completedBytes + totalBytesWritten) / Double(bundleState.totalExpectedBytes)))
            DispatchQueue.main.async {
                self.downloadProgress[filename] = progress
            }
            return
        }
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async {
                self.downloadProgress[filename] = progress
            }
        }
    }
    
    // MARK: - Integrity Verification (Issue 11)
    public static func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public static func verifyFileIntegrity(at url: URL, expectedSize: Int64, expectedSHA256: String) -> (isValid: Bool, error: String?) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let fileSize = attrs[.size] as? Int64 else {
                return (false, "Could not determine downloaded file size")
            }
            if fileSize != expectedSize {
                return (false, "Integrity check failed: file size mismatch (expected \(expectedSize) bytes, got \(fileSize) bytes)")
            }
            let computedSHA = try computeSHA256(of: url)
            if computedSHA.lowercased() != expectedSHA256.lowercased() {
                return (false, "Integrity check failed: SHA-256 checksum mismatch (expected \(expectedSHA256), got \(computedSHA))")
            }
            return (true, nil)
        } catch {
            return (false, "Integrity check failed: \(error.localizedDescription)")
        }
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let filename = taskToFilename[downloadTask.taskIdentifier] else { return }
        
        if var bundleState = activeBundleDownloads[filename] {
            taskToFilename.removeValue(forKey: downloadTask.taskIdentifier)
            let fileSpec = bundleState.model.bundleFiles[bundleState.nextFileIndex]
            let verification = Self.verifyFileIntegrity(
                at: location,
                expectedSize: fileSpec.expectedSizeBytes,
                expectedSHA256: fileSpec.sha256
            )
            
            if !verification.isValid {
                try? FileManager.default.removeItem(at: location)
                try? FileManager.default.removeItem(at: bundleState.stagingDir)
                let errorMsg = verification.error ?? "Downloaded model file \(fileSpec.relativePath) failed integrity check"
                print("❌ [ModelDownloadManager] \(errorMsg)")
                DispatchQueue.main.async {
                    self.lastError = errorMsg
                    self.activeBundleDownloads.removeValue(forKey: filename)
                    self.activeDownloads.remove(filename)
                    self.downloadProgress.removeValue(forKey: filename)
                }
                return
            }
            
            let targetFile = bundleState.stagingDir.appendingPathComponent(fileSpec.relativePath)
            do {
                try FileManager.default.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: targetFile.path) {
                    try FileManager.default.removeItem(at: targetFile)
                }
                try FileManager.default.moveItem(at: location, to: targetFile)
                
                bundleState.completedBytes += fileSpec.expectedSizeBytes
                bundleState.nextFileIndex += 1
                bundleState.activeTask = nil
                activeBundleDownloads[filename] = bundleState
                downloadProgress[filename] = min(0.99, Double(bundleState.completedBytes) / Double(bundleState.totalExpectedBytes))
                
                startNextBundleFileDownload(for: filename)
            } catch {
                try? FileManager.default.removeItem(at: location)
                try? FileManager.default.removeItem(at: bundleState.stagingDir)
                DispatchQueue.main.async {
                    self.lastError = "Failed to stage model file \(fileSpec.relativePath): \(error.localizedDescription)"
                    self.activeBundleDownloads.removeValue(forKey: filename)
                    self.activeDownloads.remove(filename)
                    self.downloadProgress.removeValue(forKey: filename)
                }
            }
            return
        }
        
        let destinationURL = AudioTranscriber.xdgModelsDirectory.appendingPathComponent(filename)
        
        // Issue 11: Validate file size and SHA-256 before moving to models directory
        if let modelInfo = AudioTranscriber.knownModels.first(where: { $0.filename == filename }) {
            let verification = Self.verifyFileIntegrity(
                at: location,
                expectedSize: modelInfo.expectedSizeBytes,
                expectedSHA256: modelInfo.sha256
            )
            
            if !verification.isValid {
                try? FileManager.default.removeItem(at: location)
                let errorMsg = verification.error ?? "Downloaded model failed integrity check"
                print("❌ [ModelDownloadManager] \(errorMsg)")
                DispatchQueue.main.async {
                    self.lastError = errorMsg
                    self.activeDownloads.remove(filename)
                    self.downloadProgress.removeValue(forKey: filename)
                    self.activeTasks.removeValue(forKey: filename)
                    self.taskToFilename.removeValue(forKey: downloadTask.taskIdentifier)
                }
                return
            }
        }
        
        do {
            try FileManager.default.createDirectory(at: AudioTranscriber.xdgModelsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            
            DispatchQueue.main.async {
                self.activeDownloads.remove(filename)
                self.downloadProgress.removeValue(forKey: filename)
                self.activeTasks.removeValue(forKey: filename)
                self.taskToFilename.removeValue(forKey: downloadTask.taskIdentifier)
                self.downloadedModels.insert(filename)
                
                // If current selected model is not downloaded, activate this one
                if !self.isModelDownloaded(AppState.shared.selectedModel) {
                    AppState.shared.selectedModel = filename
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.lastError = "Failed to save model: \(error.localizedDescription)"
                self.activeDownloads.remove(filename)
                self.downloadProgress.removeValue(forKey: filename)
                self.activeTasks.removeValue(forKey: filename)
                self.taskToFilename.removeValue(forKey: downloadTask.taskIdentifier)
            }
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let filename = taskToFilename[task.taskIdentifier] else { return }
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            if let bundleState = activeBundleDownloads.removeValue(forKey: filename) {
                try? FileManager.default.removeItem(at: bundleState.stagingDir)
            }
            DispatchQueue.main.async {
                self.lastError = "Download failed: \(error.localizedDescription)"
                self.activeDownloads.remove(filename)
                self.downloadProgress.removeValue(forKey: filename)
                self.activeTasks.removeValue(forKey: filename)
                self.taskToFilename.removeValue(forKey: task.taskIdentifier)
            }
        }
    }
}
