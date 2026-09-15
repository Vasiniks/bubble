import AppKit
import SwiftUI

@MainActor
@Observable
final class OverlayState {
    var isExpanded = false
    var isPressed = false
    var geometry = BubbleGeometry(centerWidth: 16, topHeight: 24)
}

/// Sizes of the black shape wrapped around the camera housing, in points.
struct BubbleGeometry: Equatable {
    /// Width of the notch, or a small gap on displays without one.
    var centerWidth: CGFloat
    /// Height of the notch / menu bar.
    var topHeight: CGFloat

    /// Concave top corners, echoing the notch's own flare into the screen edge.
    static let flare: CGFloat = 6
    /// Wing either side of the notch holding a load ring and its label.
    static let ringWing: CGFloat = 66
    /// Extra wing for battery time (left) and temperature (right).
    static let statusWing: CGFloat = 78
    static let expandedMinWidth: CGFloat = 540
    static let detailHeight: CGFloat = 104

    var ringDiameter: CGFloat {
        min(24, max(16, topHeight - 8))
    }

    /// Largest size the shape can take; the SwiftUI host is fixed at this size.
    var expandedSize: CGSize {
        size(expanded: true, compactStatus: true)
    }

    func wing(compactStatus: Bool) -> CGFloat {
        Self.ringWing + (compactStatus ? Self.statusWing : 0)
    }

    func size(expanded: Bool, compactStatus: Bool) -> CGSize {
        let width = centerWidth + 2 * (wing(compactStatus: compactStatus) + Self.flare)
        guard expanded else { return CGSize(width: width, height: topHeight) }
        return CGSize(width: max(width, Self.expandedMinWidth), height: topHeight + Self.detailHeight)
    }
}

/// Owns the single overlay panel. Expansion never animates the window frame: the SwiftUI
/// content is pinned top-center inside a fixed-size host and animates its own shape, while
/// the window is resized instantly (and invisibly) around it.
@MainActor
final class OverlayWindowController {
    static let shared = OverlayWindowController()

    private static let animationDuration: TimeInterval = 0.3
    private static let animation = Animation.smooth(duration: animationDuration)

    private let state: OverlayState
    private let panel: OverlayPanel
    private let container: OverlayContainerView
    private let hostingView: NSHostingView<BubbleView>
    /// Top-center of the camera housing, in global screen coordinates.
    private var anchor = CGPoint.zero
    private var transitionGeneration = 0

    private init() {
        let state = OverlayState()
        self.state = state

        hostingView = NSHostingView(rootView: BubbleView(state: state, monitor: .shared, prefs: .shared))
        // By default the hosting view pushes its fitting size onto the window, which fights
        // our manual frame management and causes jumps.
        hostingView.sizingOptions = []

        container = OverlayContainerView()
        container.addSubview(hostingView)

        panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar so the shape can sit flush with the top edge around the notch.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        container.hitSize = { [unowned self] in self.visibleSize(expanded: self.state.isExpanded) }
        container.onPress = { [unowned self] pressed in
            withAnimation(.easeOut(duration: 0.12)) { self.state.isPressed = pressed }
        }
        container.onClick = { PreferencesWindowController.shared.show() }
        container.menu = makeContextMenu()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OverlayWindowController.shared.updateLayout() }
        }
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OverlayWindowController.shared.updateLayout() }
        }
    }

    func show() {
        updateLayout()
        panel.orderFrontRegardless()
    }

    func toggleExpanded() {
        setExpanded(!state.isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != state.isExpanded else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        MetricsMonitor.shared.setDetailed(expanded)

        if expanded {
            // Grow the window first. The content is pinned top-center, so nothing moves on screen.
            applyFrame(expanded: true)
            withAnimation(Self.animation) { state.isExpanded = true }
        } else {
            withAnimation(Self.animation) { state.isExpanded = false }
            // Shrink the window once the shape has finished collapsing — unless another toggle
            // happened meanwhile, in which case that newer transition owns the frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration + 0.05) { [weak self] in
                guard let self, generation == self.transitionGeneration else { return }
                self.applyFrame(expanded: false)
            }
        }
    }

    func updateLayout() {
        guard let screen = targetScreen() else { return }

        let geometry: BubbleGeometry
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The notch is the gap between the two menu bar areas either side of it.
            let notchWidth = right.minX - left.maxX
            let notchMidX = screen.frame.minX + (left.maxX + right.minX) / 2 - left.minX
            geometry = BubbleGeometry(centerWidth: notchWidth, topHeight: screen.safeAreaInsets.top)
            anchor = CGPoint(x: notchMidX, y: screen.frame.maxY)
        } else {
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            geometry = BubbleGeometry(centerWidth: 16, topHeight: min(32, max(24, menuBarHeight)))
            anchor = CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        }

        if state.geometry != geometry {
            state.geometry = geometry
        }
        let hostSize = geometry.expandedSize
        if hostingView.frame.size != hostSize {
            hostingView.setFrameSize(hostSize)
            container.centerSubviews()
        }
        applyFrame(expanded: state.isExpanded)
    }

    private func visibleSize(expanded: Bool) -> CGSize {
        state.geometry.size(expanded: expanded, compactStatus: Preferences.shared.showsCompactStatus)
    }

    private func applyFrame(expanded: Bool) {
        let size = visibleSize(expanded: expanded)
        let frame = CGRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y - size.height, width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        switch Preferences.shared.display {
        case .primary:
            return screens.first
        case .automatic:
            return screens.first(where: \.isBuiltIn) ?? screens.first
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let preferences = NSMenuItem(title: "Preferences…", action: #selector(MenuActions.showPreferences), keyEquivalent: "")
        preferences.target = MenuActions.shared
        menu.addItem(preferences)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Bubble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return menu
    }
}

@MainActor
private final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func showPreferences() {
        PreferencesWindowController.shared.show()
    }
}

private extension NSScreen {
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}

/// Never becomes key, so clicking Bubble doesn't steal focus from the frontmost app.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Handles all mouse input at the AppKit level. The SwiftUI content is display-only.
final class OverlayContainerView: NSView {
    var hitSize: () -> CGSize = { .zero }
    var onPress: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}

    override var isFlipped: Bool { true }

    // The panel is never key; without this the first click would only be swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        visibleRect(contains: convert(point, from: superview)) ? self : nil
    }

    // Called synchronously inside setFrame, so the content is re-centered in the same
    // pass as the window resize and never appears offset for a frame.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        centerSubviews()
    }

    func centerSubviews() {
        for subview in subviews {
            subview.setFrameOrigin(CGPoint(x: ((bounds.width - subview.frame.width) / 2).rounded(), y: 0))
        }
    }

    override func mouseDown(with event: NSEvent) {
        onPress(true)
    }

    override func mouseUp(with event: NSEvent) {
        onPress(false)
        if visibleRect(contains: convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }

    private func visibleRect(contains point: CGPoint) -> Bool {
        let size = hitSize()
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        return rect.contains(point)
    }
}
