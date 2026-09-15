import AppKit
import SwiftUI

@MainActor
public final class OverlayWindowController: NSObject {
    public static let shared = OverlayWindowController()
    
    private var panel: NSPanel!
    private var isExpanded: Bool = false
    private var hostingView: NSHostingView<AnyView>!
    
    private let pillSize = CGSize(width: 290, height: 38)
    private let expandedSize = CGSize(width: 324, height: 310)
    
    public override init() {
        super.init()
        setupPanel()
    }
    
    private func setupPanel() {
        let binding = Binding<Bool>(
            get: { [weak self] in self?.isExpanded ?? false },
            set: { [weak self] val in self?.setExpanded(val) }
        )
        
        let bubbleView = BubbleView(isExpanded: binding)
        hostingView = NSHostingView(rootView: AnyView(bubbleView))
        
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: pillSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .mainMenu + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        
        repositionPanel(animated: false)
    }
    
    public func show() {
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        repositionPanel(animated: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1.0
        }
    }
    
    public func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel.orderOut(nil)
            }
        })
    }
    
    public func toggle() {
        if panel.isVisible && panel.alphaValue > 0.05 {
            hide()
        } else {
            show()
        }
    }
    
    public func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        
        let targetSize = expanded ? expandedSize : pillSize
        guard (panel.screen ?? NSScreen.main) != nil else { return }
        
        let currentFrame = panel.frame
        let targetX = currentFrame.midX - (targetSize.width / 2.0)
        // Expand downwards while keeping top aligned
        let targetY = currentFrame.maxY - targetSize.height
        let targetFrame = NSRect(x: targetX, y: targetY, width: targetSize.width, height: targetSize.height)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }
    
    public func repositionPanel(animated: Bool = false) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        
        let size = isExpanded ? expandedSize : pillSize
        let screenFrame = screen.frame
        let safeTop = screen.safeAreaInsets.top
        
        // Position adjacent to top camera / notch
        let x = screenFrame.midX - (size.width / 2.0)
        let topOffset: CGFloat = safeTop > 0 ? (safeTop + 4) : 10
        let y = screenFrame.maxY - topOffset - size.height
        
        let newFrame = NSRect(x: x, y: y, width: size.width, height: size.height)
        
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }
}
