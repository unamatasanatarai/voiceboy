import Cocoa
import SwiftUI
import Combine

public class ModelDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = ModelDownloadManager()
    
    @Published public var downloadProgress: [String: Double] = [:]
    @Published public var activeDownloads: Set<String> = []
    @Published public var downloadedModels: Set<String> = []
    @Published public var lastError: String? = nil
    
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
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
            let fileURL = dir.appendingPathComponent(model.filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
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
    
    public func startDownload(model: AudioTranscriber.ModelInfo) {
        guard let url = URL(string: model.downloadURL) else { return }
        guard !activeDownloads.contains(model.filename) else { return }
        
        lastError = nil
        activeDownloads.insert(model.filename)
        downloadProgress[model.filename] = 0.01
        
        let task = session.downloadTask(with: url)
        activeTasks[model.filename] = task
        taskToFilename[task.taskIdentifier] = model.filename
        task.resume()
    }
    
    public func cancelDownload(filename: String) {
        if let task = activeTasks[filename] {
            task.cancel()
            taskToFilename.removeValue(forKey: task.taskIdentifier)
            activeTasks.removeValue(forKey: filename)
        }
        activeDownloads.remove(filename)
        downloadProgress.removeValue(forKey: filename)
    }
    
    // MARK: - URLSessionDownloadDelegate
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let filename = taskToFilename[downloadTask.taskIdentifier] else { return }
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async {
                self.downloadProgress[filename] = progress
            }
        }
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let filename = taskToFilename[downloadTask.taskIdentifier] else { return }
        let destinationURL = AudioTranscriber.xdgModelsDirectory.appendingPathComponent(filename)
        
        do {
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
            }
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let filename = taskToFilename[task.taskIdentifier] else { return }
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
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
