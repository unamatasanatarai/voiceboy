import SwiftUI
import AppKit

public struct MinimalMainView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var downloadManager = ModelDownloadManager.shared
    
    // Strict Color Palette:
    // Text: Exactly 2 colors
    public static let textBright = Color.white
    public static let textGray   = Color(white: 0.60)
    
    // Background: Exactly 3 colors
    public static let bgGeneral  = Color(white: 0.13) // Window canvas background
    public static let bgActive   = Color(white: 0.26) // Active button, active language, active model
    public static let bgInactive = Color(white: 0.17) // Inactive card/container background
    public static let dividerColor = Color(white: 0.22)
    
    public init() {}
    
    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    // Header: Prominent large logo + Two pill columns (Left: Languages, Right: Shortcut & Toggles)
                    HStack(alignment: .center, spacing: 14) {
                        if let icon = Bundle.main.image(forResource: "AppIconTile") ?? Bundle.main.image(forResource: "AppIconMaster") ?? NSImage(contentsOfFile: "Resources/AppIconTile.png") ?? NSImage(contentsOfFile: "Resources/AppIconMaster.png") {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 108, height: 108)
                                .cornerRadius(22)
                        }
                        
                        // Left Column: Languages (unified vertical pill block)
                        languageVerticalControl
                            .frame(maxWidth: .infinity)
                        
                        // Right Column: Controls in identical unified vertical pill container
                        settingsVerticalControl
                            .frame(maxWidth: .infinity)
                    }
                    
                    Divider()
                        .background(MinimalMainView.dividerColor)
                    
                    // Models in unified pill format matching language and controls selector
                    modelsVerticalControl
                }
                .padding(14)
                
                Spacer(minLength: 0)
                
                Divider()
                    .background(MinimalMainView.dividerColor)
                    .padding(.horizontal, 18)
                
                // 4. Pinned Footer anchored at the bottom
                VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    // Dock icon toggle on the left
                    Toggle("Dock icon", isOn: $appState.showDockIcon)
                        .toggleStyle(PillToggleStyle())
                    
                    // Save audio toggle (Issue 10)
                    Toggle("Save audio", isOn: $appState.saveRecordingsToDisk)
                        .toggleStyle(PillToggleStyle())
                        .help("Save WAV recordings to disk")
                    
                    if appState.saveRecordingsToDisk {
                        // Folder selection next to Save audio
                        HStack(spacing: 5) {
                            Button(action: {
                                appState.changeRecordingsDirectory()
                            }) {
                                Text(abbreviatedPath(appState.recordingsDirectory.path))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(MinimalMainView.textGray)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help("Click to change directory")
                            
                            Button(action: {
                                appState.openRecordingsDirectory()
                            }) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                    .foregroundColor(MinimalMainView.textGray)
                            }
                            .buttonStyle(.plain)
                            .help("Open in Finder")
                        }
                    }
                    
                    Spacer()
                    
                    // Attribution moved right into the bottom footer line
                    HStack(spacing: 4) {
                        Text("Speech models lifted from")
                            .font(.system(size: 9))
                            .foregroundColor(MinimalMainView.textGray)
                        
                        Link("FUTO ↗", destination: URL(string: "https://keyboard.futo.tech/voice-input-models")!)
                            .font(.system(size: 9))
                            .foregroundColor(MinimalMainView.textGray)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 12)
            }
            
            if appState.showQuitToast {
                quitToastView
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(100)
            }
        }
        .frame(width: 460, height: 470)
        .background(MinimalMainView.bgGeneral)
    }
    
    // Unified vertical pill control for models matching language and settings controls
    private var modelsVerticalControl: some View {
        let models = AudioTranscriber.knownModels
        return VStack(spacing: 0) {
            ForEach(0..<models.count, id: \.self) { index in
                let model = models[index]
                let isDownloaded = downloadManager.isModelDownloaded(model.filename)
                let isDownloading = downloadManager.isDownloading(model.filename)
                let isSelected = (appState.selectedModel == model.filename) && isDownloaded
                let progress = downloadManager.downloadProgress[model.filename] ?? 0.0
                
                Button(action: {
                    if isDownloaded {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            appState.selectedModel = model.filename
                            appState.statusMessage = "Switched to \(model.displayName)"
                        }
                    } else if !isDownloading {
                        downloadManager.startDownload(model: model)
                    }
                }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .center) {
                            Text(model.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(isSelected ? MinimalMainView.textBright : MinimalMainView.textGray)
                            
                            Text(model.parameterCount)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(MinimalMainView.textGray)
                            
                            Spacer()
                            
                            if isDownloaded {
                                if isSelected {
                                    Circle()
                                        .fill(MinimalMainView.textBright)
                                        .frame(width: 6, height: 6)
                                }
                            } else if isDownloading {
                                HStack(spacing: 5) {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 12, height: 12)
                                    Text("\(Int(progress * 100))%")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(MinimalMainView.textGray)
                                    Button("Cancel") {
                                        downloadManager.cancelDownload(filename: model.filename)
                                    }
                                    .font(.system(size: 10))
                                    .buttonStyle(.plain)
                                    .foregroundColor(MinimalMainView.textGray)
                                }
                            } else {
                                Text("Download")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(MinimalMainView.textGray)
                            }
                        }
                        
                        Text(model.bestFor)
                            .font(.system(size: 11))
                            .foregroundColor(MinimalMainView.textGray)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Rectangle()
                            .fill(isSelected ? MinimalMainView.bgActive : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: 50)
                
                if index < models.count - 1 {
                    let nextModel = models[index + 1]
                    let isNextDownloaded = downloadManager.isModelDownloaded(nextModel.filename)
                    let isNextSelected = (appState.selectedModel == nextModel.filename) && isNextDownloaded
                    Rectangle()
                        .fill(MinimalMainView.dividerColor)
                        .frame(height: 1)
                        .opacity((isSelected || isNextSelected) ? 0 : 1)
                }
            }
        }
        .background(MinimalMainView.bgInactive)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    // Vertical language segmented control matching logo height
    private var languageVerticalControl: some View {
        let items = [("Polish", "pl"), ("English", "en"), ("Auto Detect", "auto")]
        return VStack(spacing: 0) {
            ForEach(0..<items.count, id: \.self) { index in
                let item = items[index]
                let isSelected = appState.selectedLanguage == item.1
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.selectedLanguage = item.1
                    }
                }) {
                    Text(item.0)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isSelected ? MinimalMainView.textBright : MinimalMainView.textGray)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            Rectangle()
                                .fill(isSelected ? MinimalMainView.bgActive : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: 30)
                
                if index < items.count - 1 {
                    let nextItem = items[index + 1]
                    let isNextSelected = appState.selectedLanguage == nextItem.1
                    Rectangle()
                        .fill(MinimalMainView.dividerColor)
                        .frame(height: 1)
                        .opacity((isSelected || isNextSelected) ? 0 : 1)
                }
            }
        }
        .background(MinimalMainView.bgInactive)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    // Vertical settings control matching languageVerticalControl pill style exactly
    private var settingsVerticalControl: some View {
        VStack(spacing: 0) {
            // Row 1: Shortcut row (full button area, centered shortcut selector)
            HStack(spacing: 0) {
                if appState.isRecording {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(MinimalMainView.textBright)
                            .frame(width: 6, height: 6)
                        Text("Rec")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(MinimalMainView.textBright)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    KeyboardShortcuts.Recorder(for: .toggleDictation) { newShortcut in
                        if let shortcut = newShortcut {
                            appState.currentHotkey = shortcut
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(Rectangle())
            
            Rectangle()
                .fill(MinimalMainView.dividerColor)
                .frame(height: 1)
            
            // Row 2: Copy to clipboard toggle button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.copyToClipboard.toggle()
                }
            }) {
                Text("Copy to clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(appState.copyToClipboard ? MinimalMainView.textBright : MinimalMainView.textGray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Rectangle()
                            .fill(appState.copyToClipboard ? MinimalMainView.bgActive : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 30)
            .help("When processing is done, keep transcribed text in clipboard")
            
            Rectangle()
                .fill(MinimalMainView.dividerColor)
                .frame(height: 1)
            
            // Row 3: Post processing toggle button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.enableFinalizing.toggle()
                }
            }) {
                Text("Post processing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(appState.enableFinalizing ? MinimalMainView.textBright : MinimalMainView.textGray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Rectangle()
                            .fill(appState.enableFinalizing ? MinimalMainView.bgActive : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 30)
            .help("Runs a full-pass transcription after speaking for maximum accuracy. Adds a brief delay before pasting.")
        }
        .background(MinimalMainView.bgInactive)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    // In-window toast for double-tap to quit: Capsule pill matching reference
    private var quitToastView: some View {
        Text("Press ⌘Q again to quit")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(MinimalMainView.textBright)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(MinimalMainView.bgActive)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 4)
    }
    
    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// Minimalist Pill Toggle Style matching language selector buttons
struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: {
            configuration.isOn.toggle()
        }) {
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(configuration.isOn ? MinimalMainView.textBright : MinimalMainView.textGray)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(configuration.isOn ? MinimalMainView.bgActive : MinimalMainView.bgInactive)
                .cornerRadius(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
