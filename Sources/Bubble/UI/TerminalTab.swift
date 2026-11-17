import AppKit
import SwiftUI

/// Quick terminal: scrollback above a one-line prompt. Keys: ↩ run, ↑/↓ history,
/// ⌃C stop, ⌃L or ⌘K clear, esc close.
struct TerminalTab: View {
    @Bindable var session: TerminalSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            TerminalScrollback(output: session.output)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 6) {
                Text(session.directoryName)
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(session.directory)
                Text("❯")
                    .foregroundStyle(session.lastStatus == 0 ? Palette.good : Palette.hot)
                    .fontWeight(.bold)
                TextField("", text: $session.draft, prompt: Text(session.isRunning ? "Running… ⌃C to stop" : "Type a command").foregroundStyle(Palette.tertiary))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.primary)
                    .focused($focused)
                    .onSubmit { session.submit() }
                    .disabled(session.isRunning)
                if session.isRunning {
                    GlyphButton(symbol: "stop.fill", size: 9, help: "Stop (⌃C)") { session.interrupt() }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 22)
        }
        .padding(.top, 6)
        .onAppear {
            session.prepare()
            focused = true
        }
        .onChange(of: session.isRunning) { _, running in
            if !running { focused = true }
        }
    }
}

/// Hosts the session's long-lived NSScrollView rather than a SwiftUI Text, which would
/// re-layout the whole scrollback on every chunk of output.
private struct TerminalScrollback: NSViewRepresentable {
    let output: TerminalOutput

    func makeNSView(context: Context) -> NSScrollView {
        output.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
