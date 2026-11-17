import AppKit
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case home
    case terminal

    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .terminal: return "apple.terminal"
        }
    }

    var title: String {
        switch self {
        case .home: return "Performance and music"
        case .terminal: return "Terminal"
        }
    }
}

@MainActor
@Observable
final class OverlayState {
    var isExpanded = false
    var isPressed = false
    var tab = NotchTab.home
    /// Which half of Home is popped up; follows the pointer.
    var focus = HomeFocus.performance
    var geometry = BubbleGeometry(centerWidth: 16, topHeight: 24)
}

/// Sizes of the black shape wrapped around the camera housing, in points.
struct BubbleGeometry: Equatable {
    /// Width of the notch, or a small gap on displays without one.
    var centerWidth: CGFloat
    /// Height of the notch / menu bar.
    var topHeight: CGFloat

    /// Concave top corners flare into the screen edge; the bottom corners round off.
    static let closedRadii = (top: CGFloat(6), bottom: CGFloat(14))
    static let openRadii = (top: CGFloat(19), bottom: CGFloat(24))
    /// Wing either side of the notch holding a load ring and its label.
    static let ringWing: CGFloat = 66
    /// Extra wing for temperature (left) and battery time (right).
    static let statusWing: CGFloat = 78
    /// Room outside the collapsed wings for the tab bar (left) and settings (right).
    static let toolWing: CGFloat = 120
    static let openMinWidth: CGFloat = 760
    /// Height of the tab content below the header, including its bottom inset.
    static let contentHeight: CGFloat = 196
    /// Space between the header and the tab content.
    static let contentTop: CGFloat = 4
    static let contentInset: CGFloat = 12
    /// Room around the open shape for its shadow.
    static let shadowPadding: CGFloat = 16

    var ringDiameter: CGFloat {
        min(24, max(16, topHeight - 8))
    }

    func wing(compactStatus: Bool) -> CGFloat {
        Self.ringWing + (compactStatus ? Self.statusWing : 0)
    }

    func closedSize(compactStatus: Bool) -> CGSize {
        CGSize(width: centerWidth + 2 * (wing(compactStatus: compactStatus) + Self.closedRadii.top), height: topHeight)
    }

    var openSize: CGSize {
        let width = centerWidth + 2 * (Self.ringWing + Self.statusWing + Self.toolWing + Self.openRadii.top)
        return CGSize(width: max(Self.openMinWidth, width), height: topHeight + Self.contentHeight)
    }

    /// Width between the open shape's flared top corners; the header is laid out across it.
    var interiorWidth: CGFloat {
        openSize.width - 2 * Self.openRadii.top
    }

    /// Width available to tab content.
    var contentWidth: CGFloat {
        interiorWidth - 2 * Self.contentInset
    }

    /// The SwiftUI host is fixed at this size; the window is resized around it.
    var hostSize: CGSize {
        CGSize(width: openSize.width + 2 * Self.shadowPadding, height: openSize.height + Self.shadowPadding)
    }
}

/// Owns the single overlay panel and the open/close mechanism.
///
/// Opening: hover for a moment, click, two-finger swipe down, or ⌃⌥⌘B. Closing: pointer
/// leaves, swipe up, click elsewhere, esc, or the hotkey. The shape springs open with a
/// little bounce and closes critically damped.
///
/// The window frame never animates: the SwiftUI content is pinned top-center inside a
/// fixed-size host and animates its own shape, while the window is resized instantly (and
/// invisibly) around it — grown before opening, shrunk once closing has settled.
@MainActor
final class OverlayWindowController {
    static let shared = OverlayWindowController()

    private static let openAnimation = Animation.spring(response: 0.25, dampingFraction: 0.82)
    private static let closeAnimation = Animation.spring(response: 0.28, dampingFraction: 1)
    /// When the critically damped close spring is within half a point of rest.
    private static let closeSettleTime: TimeInterval = 0.36
    private static let hoverOpenDelay: TimeInterval = 0.1
    private static let exitCloseDelay: TimeInterval = 0.1
    private static let swipeThreshold: CGFloat = 24
    private static let focusAnimation = Animation.spring(response: 0.245, dampingFraction: 0.88)

    let state: OverlayState
    private let panel: OverlayPanel
    private let container: OverlayContainerView
    private let hostingView: NSHostingView<BubbleView>
    /// Top-center of the camera housing, in global screen coordinates.
    private var anchor = CGPoint.zero
    private var transitionGeneration = 0
    private var isHovering = false
    /// Hover-to-open waits for the pointer to leave first after a close, so closing with the
    /// pointer resting on the notch doesn't immediately reopen it.
    private var hoverOpenArmed = true
    private var hoverOpenWork: DispatchWorkItem?
    private var exitCloseWork: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var swipeDistance: CGFloat = 0
    private var swipeHandled = false
    /// Last pointer position over the panel, in the container's (flipped) coordinates.
    private var pointer: CGPoint?

    private init() {
        let state = OverlayState()
        self.state = state

        hostingView = FirstMouseHostingView(rootView: BubbleView(state: state, monitor: .shared, prefs: .shared))
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
        // Only the terminal takes keyboard focus, and only while it's open.
        panel.allowsKey = { [unowned state] in state.isExpanded && state.tab == .terminal }

        container.visibleSize = { [unowned self] in self.visibleSize(expanded: self.state.isExpanded) }
        container.isExpanded = { [unowned state] in state.isExpanded }
        container.onHover = { [unowned self] inside in self.hoverChanged(inside) }
        container.onPointer = { [unowned self] point in self.pointerMoved(point) }
        container.onPress = { [unowned self] pressed in
            withAnimation(.easeOut(duration: 0.12)) { self.state.isPressed = pressed }
        }
        container.onClick = { [unowned self] in self.setExpanded(true) }
        container.onOutsideClick = { [unowned self] in self.setExpanded(false) }
        container.onScroll = { [unowned self] event in self.scrolled(event) }
        container.menu = makeContextMenu()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { OverlayWindowController.shared.updateLayout() }
        }
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                OverlayWindowController.shared.preferencesChanged()
            }
        }
    }

    func show() {
        updateLayout()
        panel.orderFrontRegardless()
    }

    func toggleExpanded() {
        setExpanded(!state.isExpanded)
    }

    /// The menu's Terminal item: open straight into the terminal, ready to type; again to close.
    func toggleTerminal() {
        guard Preferences.shared.terminalEnabled else { return }
        if state.isExpanded, state.tab == .terminal {
            setExpanded(false)
            return
        }
        select(.terminal)
        setExpanded(true)
        focusTerminal()
    }

    func select(_ tab: NotchTab) {
        if tab != state.tab {
            withAnimation(.smooth(duration: 0.16)) { state.tab = tab }
            updateModes()
        }
        if tab == .terminal {
            focusTerminal()
        } else {
            relinquishKey()
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != state.isExpanded else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        hoverOpenWork?.cancel()
        exitCloseWork?.cancel()

        if expanded {
            // Opened from the notch itself: the half you came in on pops up.
            if isHovering, let side = focus(forClosedPointer: pointer) {
                state.focus = side
            }
            // Grow the window first. The content is pinned top-center, so nothing moves on screen.
            applyFrame(expanded: true)
            withAnimation(Self.openAnimation) { state.isExpanded = true }
            state.isPressed = false
            installOutsideClickMonitor()
        } else {
            hoverOpenArmed = false
            relinquishKey()
            removeOutsideClickMonitor()
            withAnimation(Self.closeAnimation) { state.isExpanded = false }
            // Shrink the window once the shape has settled — unless another toggle happened
            // meanwhile, in which case that newer transition owns the frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeSettleTime) { [weak self] in
                guard let self, generation == self.transitionGeneration else { return }
                self.applyFrame(expanded: false)
            }
        }
        updateModes()
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
        let hostSize = geometry.hostSize
        if hostingView.frame.size != hostSize {
            hostingView.setFrameSize(hostSize)
            container.centerSubviews()
        }
        applyFrame(expanded: state.isExpanded)
    }

    // MARK: Pointer

    /// On Home, the half under the pointer pops up: performance on the left, music on the right.
    private func pointerMoved(_ point: CGPoint) {
        pointer = point
        guard state.isExpanded, state.tab == .home else { return }
        let geometry = state.geometry
        let contentTop = geometry.topHeight + BubbleGeometry.contentTop
        guard point.y > contentTop, point.y < geometry.openSize.height else { return }

        let contentLeft = (container.bounds.width - geometry.contentWidth) / 2
        let layout = HomeLayout(contentWidth: geometry.contentWidth)
        let wanted: HomeFocus = point.x - contentLeft < layout.boundary(state.focus) ? .performance : .music
        if wanted != state.focus {
            withAnimation(Self.focusAnimation) { state.focus = wanted }
        }
    }

    /// Which half of the collapsed notch the pointer is on.
    private func focus(forClosedPointer point: CGPoint?) -> HomeFocus? {
        guard let point else { return nil }
        return point.x < container.bounds.midX ? .performance : .music
    }

    private func preferencesChanged() {
        if !Preferences.shared.terminalEnabled {
            if state.tab == .terminal { select(.home) }
            TerminalSession.shared.shutdown()
        }
        container.menu = makeContextMenu()
        updateLayout()
        MetricsMonitor.shared.restart()
    }

    private func hoverChanged(_ inside: Bool) {
        if !inside { hoverOpenArmed = true }
        guard inside != isHovering else { return }
        isHovering = inside

        if inside {
            exitCloseWork?.cancel()
            guard !state.isExpanded else { return }
            if Preferences.shared.haptics {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            guard Preferences.shared.openOnHover, hoverOpenArmed else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isHovering else { return }
                self.setExpanded(true)
            }
            hoverOpenWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverOpenDelay, execute: work)
        } else {
            hoverOpenWork?.cancel()
            guard state.isExpanded, !staysOpenWithoutPointer else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isHovering, !self.staysOpenWithoutPointer else { return }
                self.setExpanded(false)
            }
            exitCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitCloseDelay, execute: work)
        }
    }

    /// Once you're typing in the terminal (or a command is running) it stays open when the
    /// pointer wanders off; click elsewhere, press esc or the hotkey to close it.
    private var staysOpenWithoutPointer: Bool {
        state.tab == .terminal && (panel.isKeyWindow || TerminalSession.shared.isRunning)
    }

    /// Two-finger swipe down opens, swipe up closes.
    private func scrolled(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swipeDistance = 0
            swipeHandled = false
        }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        // Positive when the fingers (or wheel) move down, whatever the scroll direction setting.
        let down = (event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY) * scale
        swipeDistance += down

        if !swipeHandled {
            if !state.isExpanded, swipeDistance > Self.swipeThreshold {
                swipeHandled = true
                tick()
                setExpanded(true)
            } else if state.isExpanded, swipeDistance < -Self.swipeThreshold {
                swipeHandled = true
                tick()
                setExpanded(false)
            }
        }
        if event.phase.isEmpty || event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            swipeDistance = 0
            swipeHandled = event.phase.isEmpty ? false : swipeHandled
        }
    }

    private func tick() {
        guard Preferences.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        // Clicks in other apps (no Accessibility permission needed for mouse events).
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { OverlayWindowController.shared.setExpanded(false) }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    // MARK: Keyboard

    private func focusTerminal() {
        guard state.isExpanded, state.tab == .terminal else { return }
        TerminalSession.shared.prepare()
        panel.makeKey()
    }

    /// A non-activating panel can't hand key status back directly; re-ordering it lets the
    /// window server give focus back to the frontmost app's window.
    private func relinquishKey() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// Sampling detail and the terminal's key handling follow what's on screen.
    private func updateModes() {
        MetricsMonitor.shared.setOpen(state.isExpanded)

        let wantsKeys = state.isExpanded && state.tab == .terminal
        if wantsKeys, keyMonitor == nil {
            // Local monitors run on the main thread, inside the app's event dispatch.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let keyCode = event.keyCode
                let modifiers = event.modifierFlags
                let windowNumber = event.windowNumber
                let handled = MainActor.assumeIsolated {
                    OverlayWindowController.shared.handleKey(keyCode, modifiers: modifiers, windowNumber: windowNumber)
                }
                return handled ? nil : event
            }
        } else if !wantsKeys, let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, windowNumber: Int) -> Bool {
        guard windowNumber == panel.windowNumber else { return false }
        if keyCode == 53 { // esc
            setExpanded(false)
            return true
        }
        return TerminalSession.shared.handleKey(keyCode, modifiers: modifiers)
    }

    // MARK: Frame

    private func visibleSize(expanded: Bool) -> CGSize {
        expanded ? state.geometry.openSize : state.geometry.closedSize(compactStatus: Preferences.shared.showsCompactStatus)
    }

    private func applyFrame(expanded: Bool) {
        // Open, the window includes room for the shadow; closed, it hugs the shape exactly.
        let size = expanded ? state.geometry.hostSize : visibleSize(expanded: false)
        let frame = CGRect(x: (anchor.x - size.width / 2).rounded(), y: anchor.y - size.height, width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        container.refreshHover()
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
        let tabs: [(NotchTab, String)] = Preferences.shared.terminalEnabled
            ? [(.home, "Open Bubble"), (.terminal, "Terminal")]
            : [(.home, "Open Bubble")]
        for (tab, title) in tabs {
            let item = NSMenuItem(title: title, action: #selector(MenuActions.open(_:)), keyEquivalent: "")
            item.representedObject = tab.rawValue
            item.target = MenuActions.shared
            menu.addItem(item)
        }
        menu.addItem(.separator())
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

    @objc func open(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tab = NotchTab(rawValue: raw) else { return }
        let controller = OverlayWindowController.shared
        if tab == .terminal {
            controller.toggleTerminal()
        } else {
            controller.select(tab)
            controller.setExpanded(true)
        }
    }
}

private extension NSScreen {
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}

/// Becomes key only when allowed (the open terminal), so clicking Bubble otherwise never
/// steals focus from the frontmost app.
final class OverlayPanel: NSPanel {
    var allowsKey: () -> Bool = { false }

    override var canBecomeKey: Bool { allowsKey() }
    override var canBecomeMain: Bool { false }
}

/// Bubble never activates, so without this the first click on a control would be swallowed.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hover tracking, clicks on the collapsed shape, clicks just outside the open one, and
/// swipes. While open, clicks inside go straight to the SwiftUI content.
final class OverlayContainerView: NSView {
    var visibleSize: () -> CGSize = { .zero }
    var isExpanded: () -> Bool = { false }
    var onHover: (Bool) -> Void = { _ in }
    var onPointer: (CGPoint) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onOutsideClick: () -> Void = {}
    var onScroll: (NSEvent) -> Void = { _ in }

    private var trackingArea: NSTrackingArea?
    private var isPressing = false

    override var isFlipped: Bool { true }

    // The panel is rarely key; without this the first click would only be swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let inside = visibleRect(contains: local)
        if isExpanded() {
            return inside ? (super.hitTest(point) ?? self) : self
        }
        return inside ? self : nil
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { reportHover(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { reportHover(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    /// Re-evaluates hover after the window changes size under a stationary pointer.
    func refreshHover() {
        guard let window else { return }
        let location = window.mouseLocationOutsideOfEventStream
        let local = convert(location, from: nil)
        onHover(bounds.contains(local) && visibleRect(contains: local))
    }

    private func reportHover(_ locationInWindow: NSPoint) {
        let point = convert(locationInWindow, from: nil)
        onPointer(point)
        onHover(visibleRect(contains: point))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect(contains: point) else {
            onOutsideClick()
            return
        }
        guard !isExpanded() else { return }
        isPressing = true
        onPress(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressing else { return }
        isPressing = false
        onPress(false)
        if visibleRect(contains: convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll(event)
    }

    private func visibleRect(contains point: CGPoint) -> Bool {
        let size = visibleSize()
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        return rect.contains(point)
    }
}
