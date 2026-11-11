import SwiftUI
import AppKit

// MARK: - Instant Minimalist Hover Popup

private struct HoverTipData: Equatable {
    let id: String
    let text: String
    let anchor: Anchor<CGRect>
    
    static func == (lhs: HoverTipData, rhs: HoverTipData) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text
    }
}

private struct HoverTipKey: PreferenceKey {
    static var defaultValue: HoverTipData? = nil
    static func reduce(value: inout HoverTipData?, nextValue: () -> HoverTipData?) {
        // Keep the innermost hovered child's tooltip instead of letting outer row containers overwrite it
        if value == nil, let next = nextValue() {
            value = next
        }
    }
}

private struct HoverPopupModifier: ViewModifier {
    let id: String
    let text: String
    @State private var isHovered = false
    
    func body(content: Content) -> some View {
        content
            .help(text)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.10)) {
                    isHovered = hovering
                }
            }
            .anchorPreference(key: HoverTipKey.self, value: .bounds) { anchor in
                isHovered && !text.isEmpty ? HoverTipData(id: id, text: text, anchor: anchor) : nil
            }
    }
}

private extension View {
    func hoverPopup(_ text: String, id: String? = nil) -> some View {
        modifier(HoverPopupModifier(id: id ?? text, text: text))
    }
}

// MARK: - Main Minimalist Window

public struct MinimalMainView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var downloadManager = ModelDownloadManager.shared
    
    // Strict Monochrome Minimalist Palette:
    public static let textBright = Color.white
    public static let textGray   = Color(white: 0.60)
    
    public static let bgGeneral    = Color(white: 0.13)
    public static let bgActive     = Color(white: 0.26)
    public static let bgInactive   = Color(white: 0.17)
    public static let dividerColor = Color(white: 0.22)
    
    public init() {}
    
    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    headerControlRow
                    
                    Divider()
                        .background(MinimalMainView.dividerColor)
                    
                    modelsVerticalControl
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
                
                Spacer(minLength: 0)
                
                Divider()
                    .background(MinimalMainView.dividerColor)
                    .padding(.horizontal, 14)
                
                footerBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            
            if appState.showQuitToast {
                quitToastView
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(100)
            }
        }
        .frame(width: 460, height: 470)
        .background(MinimalMainView.bgGeneral)
        .overlayPreferenceValue(HoverTipKey.self) { tip in
            GeometryReader { geo in
                if let tip = tip {
                    hoverTipOverlay(for: tip, in: geo)
                }
            }
            .allowsHitTesting(false)
        }
    }
    
    // MARK: - Header: App Icon + Compact Shortcut / Icon Toggle Card
    
    private var headerControlRow: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = Bundle.main.image(forResource: "AppIconTile")
                ?? Bundle.main.image(forResource: "AppIconMaster")
                ?? NSImage(contentsOfFile: "Resources/AppIconTile.png")
                ?? NSImage(contentsOfFile: "Resources/AppIconMaster.png") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 78, height: 78)
                    .cornerRadius(17)
                    .hoverPopup("VoiceBoy — \(activeModelDisplayName)", id: "header-logo")
            }
            
            VStack(spacing: 0) {
                // Row 1: Full-width shortcut recorder (or Recording indicator when active)
                shortcutRecorderCell
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                
                Rectangle()
                    .fill(MinimalMainView.dividerColor)
                    .frame(height: 1)
                
                // Row 2: Pure icon segmented toggles
                HStack(spacing: 0) {
                    SegmentedIconToggle(
                        systemName: "doc.on.clipboard",
                        activeSystemName: "doc.on.clipboard.fill",
                        isOn: $appState.copyToClipboard,
                        hoverText: appState.copyToClipboard
                            ? "Copy to clipboard: On — keeps transcript on clipboard"
                            : "Copy to clipboard: Off — restores prior clipboard",
                        id: "toggle-clipboard"
                    )
                    
                    iconBarDivider
                    
                    SegmentedIconToggle(
                        systemName: "wand.and.stars",
                        activeSystemName: "wand.and.stars",
                        isOn: $appState.enableFinalizing,
                        hoverText: appState.enableFinalizing
                            ? "Post-processing: On — full finalizing pass for best accuracy"
                            : "Post-processing: Off — fastest live paste",
                        id: "toggle-postprocess"
                    )
                    
                    iconBarDivider
                    
                    SegmentedIconToggle(
                        systemName: "dock.rectangle",
                        activeSystemName: "dock.rectangle",
                        isOn: $appState.showDockIcon,
                        hoverText: appState.showDockIcon
                            ? "Dock icon: Shown"
                            : "Dock icon: Hidden (Menu bar only)",
                        id: "toggle-dock"
                    )
                    
                    iconBarDivider
                    
                    SegmentedIconToggle(
                        systemName: "waveform.circle",
                        activeSystemName: "waveform.circle.fill",
                        isOn: $appState.saveRecordingsToDisk,
                        hoverText: appState.saveRecordingsToDisk
                            ? "Save audio: On (\(abbreviatedPath(appState.recordingsDirectory.path)))"
                            : "Save audio: Off",
                        id: "toggle-saveaudio"
                    )
                }
                .frame(height: 39)
            }
            .background(MinimalMainView.bgInactive)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
    
    private var iconBarDivider: some View {
        Rectangle()
            .fill(MinimalMainView.dividerColor)
            .frame(width: 1)
    }
    
    @ViewBuilder
    private var shortcutRecorderCell: some View {
        if appState.isRecording {
            Button(action: { appState.stopRecording() }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(MinimalMainView.textBright)
                        .frame(width: 6, height: 6)
                    Text("Recording…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(MinimalMainView.textBright)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MinimalMainView.bgActive)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverPopup("Click or press \(appState.currentHotkey.displayString) to finish • Esc to cancel", id: "hotkey-rec")
        } else {
            KeyboardShortcuts.Recorder(for: .toggleDictation) { newShortcut in
                if let shortcut = newShortcut {
                    appState.currentHotkey = shortcut
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .hoverPopup("Dictation shortcut — click to rebind", id: "hotkey-cell")
        }
    }
    
    // MARK: - Compact Models Card (all 8 models visible without scrolling)
    
    private var modelsVerticalControl: some View {
        let models = AudioTranscriber.knownModels
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(0..<models.count, id: \.self) { index in
                    let model = models[index]
                    let isDownloaded = downloadManager.isModelDownloaded(model.filename)
                    let isDownloading = downloadManager.isDownloading(model.filename)
                    let isSelected = (appState.selectedModel == model.filename) && isDownloaded
                    let progress = downloadManager.downloadProgress[model.filename] ?? 0.0
                    
                    modelRow(
                        model: model,
                        isDownloaded: isDownloaded,
                        isDownloading: isDownloading,
                        isSelected: isSelected,
                        progress: progress
                    )
                    
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
        }
        .frame(height: 303)
        .background(MinimalMainView.bgInactive)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
    
    private func modelRow(
        model: AudioTranscriber.ModelInfo,
        isDownloaded: Bool,
        isDownloading: Bool,
        isSelected: Bool,
        progress: Double
    ) -> some View {
        let kindIcon: String
        let kindHint: String
        if model.engine == .whisper {
            kindIcon = "globe"
            kindHint = "Auto-detect language"
        } else if model.filename.hasSuffix("-plus") {
            kindIcon = "person.2.fill"
            kindHint = "English streaming + speaker diarization"
        } else {
            kindIcon = "waveform"
            kindHint = "English streaming + punctuation"
        }
        
        let actionHint = isSelected
            ? "Active model"
            : (isDownloaded ? "Click to select" : (isDownloading ? "Downloading…" : "Click to download"))
        
        return Button(action: {
            if isDownloaded {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.selectedModel = model.filename
                    appState.statusMessage = "Switched to \(model.displayName)"
                }
            } else if !isDownloading {
                downloadManager.startDownload(model: model)
            }
        }) {
            HStack(spacing: 9) {
                Image(systemName: kindIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? MinimalMainView.textBright : MinimalMainView.textGray)
                    .frame(width: 15)
                
                Text(model.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? MinimalMainView.textBright : MinimalMainView.textGray)
                    .lineLimit(1)
                
                Text(compactSpecs(model.parameterCount))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(MinimalMainView.textGray.opacity(isSelected ? 0.85 : 0.70))
                    .lineLimit(1)
                
                Spacer(minLength: 4)
                
                if isDownloaded {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12.5))
                            .foregroundColor(MinimalMainView.textBright)
                    } else {
                        Circle()
                            .stroke(MinimalMainView.textGray.opacity(0.40), lineWidth: 1)
                            .frame(width: 9, height: 9)
                    }
                } else if isDownloading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.45)
                            .frame(width: 12, height: 12)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(MinimalMainView.textGray)
                        Button(action: {
                            downloadManager.cancelDownload(filename: model.filename)
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12.5))
                                .foregroundColor(MinimalMainView.textGray)
                        }
                        .buttonStyle(.plain)
                        .hoverPopup("Cancel download", id: "cancel-\(model.filename)")
                    }
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13))
                        .foregroundColor(MinimalMainView.textGray)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 37)
            .background(isSelected ? MinimalMainView.bgActive : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPopup("\(kindHint) · \(model.bestFor) (\(actionHint))", id: "model-\(model.filename)")
    }
    
    // MARK: - Minimalist 1-Line Footer
    
    private var footerBar: some View {
        HStack(spacing: 8) {
            if let errorMsg = downloadManager.lastError, !errorMsg.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(MinimalMainView.textBright)
                    Text(errorMsg)
                        .font(.system(size: 10))
                        .foregroundColor(MinimalMainView.textGray)
                        .lineLimit(1)
                    Button(action: { downloadManager.lastError = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(MinimalMainView.textGray)
                    }
                    .buttonStyle(.plain)
                    .hoverPopup("Dismiss error", id: "dismiss-dl-err")
                }
                .hoverPopup(errorMsg, id: "dl-err-msg")
            } else {
                if appState.saveRecordingsToDisk {
                    HStack(spacing: 7) {
                        Button(action: { appState.changeRecordingsDirectory() }) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundColor(MinimalMainView.textGray)
                        }
                        .buttonStyle(.plain)
                        .hoverPopup("Recordings folder: \(abbreviatedPath(appState.recordingsDirectory.path)) — click to change", id: "rec-folder")
                        
                        Button(action: { appState.openRecordingsDirectory() }) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11))
                                .foregroundColor(MinimalMainView.textGray)
                        }
                        .buttonStyle(.plain)
                        .hoverPopup("Open recordings folder in Finder", id: "rec-finder")
                    }
                }
                
                Text(appState.statusMessage)
                    .font(.system(size: 10))
                    .foregroundColor(MinimalMainView.textGray)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 6)
            
            Link(destination: URL(string: "https://keyboard.futo.tech/voice-input-models")!) {
                HStack(spacing: 3) {
                    Text("FUTO")
                        .font(.system(size: 9.5, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(MinimalMainView.textGray)
            }
            .hoverPopup("Speech models lifted from FUTO (keyboard.futo.tech)", id: "futo-link")
        }
        .frame(height: 18)
    }
    
    // MARK: - Helpers & Overlays
    
    @ViewBuilder
    private func hoverTipOverlay(for tip: HoverTipData, in geo: GeometryProxy) -> some View {
        let rect = geo[tip.anchor]
        let placeBelow = rect.minY < 56
        let anchorY = placeBelow ? rect.maxY + 20 : max(20, rect.minY - 22)
        let clampedX = min(max(rect.midX, 136), geo.size.width - 136)
        
        Text(tip.text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(MinimalMainView.textBright)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 260)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(MinimalMainView.bgActive)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(MinimalMainView.dividerColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 2)
            .position(x: clampedX, y: anchorY)
            .transition(.opacity)
    }
    
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
    
    private var activeModelDisplayName: String {
        AudioTranscriber.knownModels.first(where: { $0.filename == appState.selectedModel })?.displayName
            ?? appState.selectedModel
    }
    
    private func compactSpecs(_ raw: String) -> String {
        raw.replacingOccurrences(of: " params (~", with: " · ")
           .replacingOccurrences(of: ")", with: "")
    }
    
    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Segmented Icon Toggle Cell

private struct SegmentedIconToggle: View {
    let systemName: String
    let activeSystemName: String
    @Binding var isOn: Bool
    let hoverText: String
    let id: String
    
    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                isOn.toggle()
            }
        }) {
            Image(systemName: isOn ? activeSystemName : systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isOn ? MinimalMainView.textBright : MinimalMainView.textGray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isOn ? MinimalMainView.bgActive : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverPopup(hoverText, id: id)
    }
}
