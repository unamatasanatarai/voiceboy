import Cocoa
import SwiftUI

public class ToastWindowController: NSWindowController {
    public static let shared = ToastWindowController()
    
    private var hostingView: NSHostingView<ToastView>?
    private var viewModel = ToastViewModel()
    
    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hasShadow = true
        window.ignoresMouseEvents = true
        
        super.init(window: window)
        
        let view = ToastView(viewModel: self.viewModel)
        let hosting = NSHostingView(rootView: view)
        self.hostingView = hosting
        window.contentView = hosting
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func showToast(status: String, text: String, audioLevel: Float) {
        viewModel.statusText = status
        viewModel.liveWords = truncateToLastWords(text, limit: 50)
        viewModel.audioLevel = audioLevel
        
        guard let window = self.window else { return }
        
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = screenRect.midX - 220
            let y = screenRect.maxY - 92
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        if !window.isVisible {
            window.alphaValue = 0.0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 1.0
            }
        }
    }
    
    public func hideToast(completion: (() -> Void)? = nil) {
        guard let window = self.window, window.isVisible else {
            completion?()
            return
        }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            window.orderOut(nil)
            completion?()
        })
    }
    
    private func truncateToLastWords(_ text: String, limit: Int = 50) -> String {
        let words = text.split { $0.isWhitespace }
        if words.count <= limit {
            return text
        }
        let tail = words.suffix(limit)
        return "..." + tail.joined(separator: " ")
    }
}

public class ToastViewModel: ObservableObject {
    @Published public var statusText: String = "Listening..."
    @Published public var liveWords: String = ""
    @Published public var audioLevel: Float = 0.0
}

public struct ToastView: View {
    @ObservedObject var viewModel: ToastViewModel
    
    public var body: some View {
        HStack(spacing: 12) {
            // Minimal pulsing indicator
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .scaleEffect(1.0 + CGFloat(viewModel.audioLevel) * 1.5)
                
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.statusText.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color.secondary)
                    .tracking(0.8)
                
                Text(viewModel.liveWords.isEmpty ? "Speak now..." : viewModel.liveWords)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(viewModel.liveWords.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 440, height: 68)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}
