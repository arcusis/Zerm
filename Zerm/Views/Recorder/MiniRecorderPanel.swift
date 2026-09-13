import SwiftUI
import AppKit

class MiniRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }
    
    private func configurePanel() {
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }
    
    /// `nil` when there is no screen at all, so the panel is skipped rather than placed at the
    /// global origin.
    static func calculateWindowMetrics() -> NSRect? {
        guard let screen = RecorderScreenResolver.resolve() else { return nil }

        // Fixed window size — large enough to accommodate live transcript content
        let width: CGFloat = 300
        let height: CGFloat = 120
        let padding: CGFloat = 24

        let visibleFrame = screen.visibleFrame
        let centerX = visibleFrame.midX
        let xPosition = centerX - (width / 2)
        let yPosition = visibleFrame.minY + padding

        return NSRect(
            x: xPosition,
            y: yPosition,
            width: width,
            height: height
        )
    }

    func show() {
        guard let metrics = MiniRecorderPanel.calculateWindowMetrics() else { return }
        setFrame(metrics, display: true)
        orderFrontRegardless()
    }
    
    func hide(completion: @escaping () -> Void) {
        completion()
    }
} 