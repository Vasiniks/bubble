import SwiftUI

/// Which half of Home is popped up: performance on the left, music on the right.
enum HomeFocus {
    case performance
    case music
}

/// Widths of Home's two panes. The focused pane is wide; the other shrinks to a compact
/// summary against its own edge. Because the boundary jumps away from the pointer when focus
/// flips, the pointer never sits on it, so there's no flicker.
struct HomeLayout {
    static let compactWidth: CGFloat = 228
    static let gap: CGFloat = 17

    let contentWidth: CGFloat

    var expandedWidth: CGFloat {
        contentWidth - Self.compactWidth - Self.gap
    }

    func performanceWidth(_ focus: HomeFocus) -> CGFloat {
        focus == .performance ? expandedWidth : Self.compactWidth
    }

    func musicWidth(_ focus: HomeFocus) -> CGFloat {
        focus == .music ? expandedWidth : Self.compactWidth
    }

    /// Pointer x (from the content's left edge) where focus flips.
    func boundary(_ focus: HomeFocus) -> CGFloat {
        performanceWidth(focus) + Self.gap / 2
    }
}

/// Performance and music side by side. Each pane renders one fixed-width layout (compact or
/// expanded) inside a clipped frame whose width springs, so nothing reflows mid-animation.
struct HomeView: View {
    let state: OverlayState
    let monitor: MetricsMonitor
    let media: MediaController
    let outputs: AudioOutputs

    var body: some View {
        let layout = HomeLayout(contentWidth: state.geometry.contentWidth)
        let focus = state.focus

        HStack(spacing: 0) {
            PerformancePane(monitor: monitor)
                .frame(width: layout.performanceWidth(focus), alignment: .topLeading)
                .clipped()

            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 0.5)
                .padding(.vertical, 4)
                .frame(width: HomeLayout.gap)

            MusicPane(media: media, outputs: outputs, expanded: focus == .music, layout: layout)
                .frame(width: layout.musicWidth(focus), alignment: .topTrailing)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .onAppear {
            media.activate()
            outputs.activate()
        }
        .onDisappear {
            media.deactivate()
            outputs.deactivate()
        }
    }
}
