import AppKit
import Observation

/// The quick terminal: one persistent zsh login shell fed through pipes.
///
/// There's no terminal emulator: each command is evaluated by the long-lived shell (so `cd`,
/// `export` and functions persist), with stdin from /dev/null, and followed by a marker line
/// carrying its exit status and the new working directory. Output is plain text with ANSI
/// codes stripped. Full-screen programs (vim, top) need a real terminal and won't work here.
@MainActor
@Observable
final class TerminalSession {
    static let shared = TerminalSession()

    var draft = ""
    private(set) var directory = NSHomeDirectory()
    private(set) var isRunning = false
    private(set) var lastStatus: Int32 = 0

    @ObservationIgnored let output = TerminalOutput()
    @ObservationIgnored private var shell: ChildProcess?
    @ObservationIgnored private var history: [String] = []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private let token = String(UInt32.random(in: .min ... .max), radix: 36)
    @ObservationIgnored private let queue = DispatchQueue(label: "com.eason.bubble.terminal", qos: .userInitiated)

    private static let historyLimit = 200

    private init() {}

    var directoryName: String {
        directory == NSHomeDirectory() ? "~" : (directory as NSString).lastPathComponent
    }

    /// Starts the shell ahead of the first command so it runs without the login delay.
    func prepare() {
        guard shell == nil else { return }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        environment["SHELL_SESSIONS_DISABLE"] = "1"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"

        let start = FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory()
        guard let child = ChildProcess(path: "/bin/zsh", arguments: ["-l", "-s"], environment: environment, directory: start) else {
            output.appendNote("Couldn't start /bin/zsh.")
            return
        }
        shell = child

        let stream = TerminalStream(token: token, queue: queue)
        child.start(queue: queue, onOutput: { data in
            stream.feed(data)
        }, onEnd: { [weak child] in
            DispatchQueue.main.async {
                guard let child else { return }
                TerminalSession.shared.shellEnded(child)
            }
        })
        // A handled (not ignored) INT trap: Ctrl-C ends the running command but not the shell.
        child.write("trap ':' INT\nsetopt no_hup no_check_jobs 2>/dev/null\n\(marker)")
    }

    func submit() {
        let command = draft
        draft = ""
        historyIndex = nil
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !isRunning else { return }

        output.appendCommand(command, directory: directoryName)
        guard !trimmed.isEmpty else { return }
        if history.last != trimmed {
            history.append(trimmed)
            if history.count > Self.historyLimit { history.removeFirst() }
        }
        if trimmed == "clear" {
            output.clear()
            return
        }

        prepare()
        guard let shell else { return }
        isRunning = true
        let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        if !shell.write("eval \(quoted) </dev/null\n\(marker)") {
            isRunning = false
            output.appendNote("The shell has exited.")
        }
    }

    /// Ends the shell (used when the terminal is turned off in Preferences).
    func shutdown() {
        shell?.terminate()
        shell = nil
        isRunning = false
    }

    func interrupt() {
        if isRunning {
            shell?.signalGroup(SIGINT)
        } else {
            draft = ""
        }
    }

    func clear() {
        output.clear()
    }

    /// Terminal keys while the input has focus. Returns true when handled.
    func handleKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let control = modifiers.contains(.control)
        let command = modifiers.contains(.command)
        switch (keyCode, control, command) {
        case (8, true, false): // ⌃C
            interrupt()
            return true
        case (37, true, false), (40, false, true): // ⌃L, ⌘K
            clear()
            return true
        case (126, false, false): // ↑
            recall(-1)
            return true
        case (125, false, false): // ↓
            recall(1)
            return true
        default:
            return false
        }
    }

    private var marker: String {
        // Status and directory travel on stdout, bracketed by RS characters and a session token.
        "print -rn -- $'\\x1e\(token):'\"$?:$PWD\"$'\\x1e'\n"
    }

    private func recall(_ step: Int) {
        guard !history.isEmpty else { return }
        let index = (historyIndex ?? history.count) + step
        if index >= history.count {
            historyIndex = nil
            draft = ""
        } else {
            historyIndex = max(0, index)
            draft = history[max(0, index)]
        }
    }

    fileprivate func received(_ text: String) {
        output.appendOutput(text)
    }

    fileprivate func finished(status: Int32, directory: String) {
        if !directory.isEmpty { self.directory = directory }
        guard isRunning else { return } // The setup marker.
        isRunning = false
        lastStatus = status
        if status == 130 {
            output.appendNote("^C")
        } else if status != 0 {
            output.appendNote("exit \(status)")
        }
    }

    private func shellEnded(_ child: ChildProcess) {
        guard child === shell else { return }
        shell = nil
        if isRunning {
            isRunning = false
            output.appendNote("Shell exited. The next command starts a new one.")
        }
    }
}

/// Turns raw shell output into display text and completion events. Lives on the terminal queue.
private final class TerminalStream: @unchecked Sendable {
    private let marker: String
    private let queue: DispatchQueue
    private var pendingBytes: [UInt8] = []
    private var carry = ""
    private var outgoing = ""
    private var flushScheduled = false

    private static let outgoingLimit = 64_000

    init(token: String, queue: DispatchQueue) {
        marker = "\u{1E}\(token):"
        self.queue = queue
    }

    func feed(_ data: Data) {
        pendingBytes.append(contentsOf: data)
        let complete = Self.completeUTF8Prefix(pendingBytes)
        var text = carry + String(decoding: pendingBytes[0 ..< complete], as: UTF8.self)
        pendingBytes.removeFirst(complete)
        carry = ""

        while let start = text.range(of: marker) {
            emit(String(text[..<start.lowerBound]))
            let rest = text[start.upperBound...]
            guard let end = rest.firstIndex(of: "\u{1E}") else {
                carry = String(text[start.lowerBound...])
                return
            }
            let fields = rest[..<end].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let status = Int32(fields.first ?? "") ?? 0
            let directory = fields.count > 1 ? String(fields[1]) : ""
            flush()
            DispatchQueue.main.async {
                TerminalSession.shared.finished(status: status, directory: directory)
            }
            text = String(rest[rest.index(after: end)...])
        }

        // Hold back a tail that might be a split marker, escape sequence or CRLF.
        var holdFrom: String.Index?
        if text.last == "\r" {
            holdFrom = text.index(before: text.endIndex)
        }
        if let escape = text.lastIndex(of: "\u{1B}"), text.distance(from: escape, to: text.endIndex) <= 16 {
            holdFrom = min(holdFrom ?? escape, escape)
        }
        if let separator = text.lastIndex(of: "\u{1E}"), text.distance(from: separator, to: text.endIndex) < marker.count {
            holdFrom = min(holdFrom ?? separator, separator)
        }
        if let holdFrom {
            carry = String(text[holdFrom...])
            text = String(text[..<holdFrom])
        }
        emit(text)
    }

    private func emit(_ raw: String) {
        guard !raw.isEmpty else { return }
        outgoing += Self.clean(raw)
        if outgoing.count > Self.outgoingLimit {
            outgoing = String(outgoing.suffix(Self.outgoingLimit))
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        // Coalesce bursts into at most ~30 UI updates a second.
        queue.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !outgoing.isEmpty else { return }
        let text = outgoing
        outgoing = ""
        DispatchQueue.main.async {
            TerminalSession.shared.received(text)
        }
    }

    /// Strips ANSI escape sequences and control characters other than newline, tab and CR.
    private static func clean(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r" }) else {
            return text
        }
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            switch scalar {
            case "\u{1B}":
                guard let next = scalars.next() else { return String(result) }
                if next == "[" {
                    while let byte = scalars.next(), !(0x40 ... 0x7E).contains(byte.value) {}
                } else if next == "]" {
                    while let byte = scalars.next(), byte != "\u{07}", byte != "\u{1B}" {}
                }
            case "\n", "\t", "\r":
                result.append(scalar)
            default:
                if scalar.value >= 0x20 { result.append(scalar) }
            }
        }
        return String(result)
    }

    /// Length of the longest prefix that ends on a complete UTF-8 sequence.
    private static func completeUTF8Prefix(_ bytes: [UInt8]) -> Int {
        var index = bytes.count
        var continuation = 0
        while index > 0, continuation < 4 {
            let byte = bytes[index - 1]
            if byte & 0xC0 == 0x80 {
                continuation += 1
                index -= 1
                continue
            }
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            return length == continuation + 1 ? bytes.count : index - 1
        }
        return bytes.count
    }
}

/// The scrollback: one NSTextView kept for the life of the app (created on first use), so
/// switching tabs never rebuilds or re-lays out the text.
@MainActor
final class TerminalOutput {
    private(set) lazy var scrollView: NSScrollView = makeScrollView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }
    private var pendingCarriageReturn = false

    private static let limit = 150_000
    private static let trimTo = 100_000
    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private static let outputAttributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.78),
    ]
    private static let noteAttributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.38),
    ]

    func appendCommand(_ command: String, directory: String) {
        let line = NSMutableAttributedString(string: "\(directory) ", attributes: Self.noteAttributes)
        line.append(NSAttributedString(string: "❯ ", attributes: [.font: Self.boldFont, .foregroundColor: NSColor.systemGreen]))
        line.append(NSAttributedString(string: command + "\n", attributes: [.font: Self.boldFont, .foregroundColor: NSColor(white: 1, alpha: 0.92)]))
        append(line)
    }

    func appendNote(_ note: String) {
        append(NSAttributedString(string: note + "\n", attributes: Self.noteAttributes), ensureNewline: true)
    }

    /// Program output. A lone carriage return rewrites the current line, so progress bars
    /// (curl, brew, pip) update in place instead of filling the scrollback.
    func appendOutput(_ text: String) {
        guard let storage = textView.textStorage else { return }
        let atBottom = isScrolledToBottom
        storage.beginEditing()
        var segments = text.components(separatedBy: "\r")
        if pendingCarriageReturn {
            if segments[0].hasPrefix("\n") { pendingCarriageReturn = false } else { truncateCurrentLine(storage) }
        }
        pendingCarriageReturn = text.hasSuffix("\r")
        if pendingCarriageReturn { segments.removeLast() }
        for (index, segment) in segments.enumerated() {
            if index > 0, !segment.hasPrefix("\n") { truncateCurrentLine(storage) }
            storage.append(NSAttributedString(string: segment, attributes: Self.outputAttributes))
        }
        trim(storage)
        storage.endEditing()
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    func clear() {
        textView.textStorage?.setAttributedString(NSAttributedString())
        pendingCarriageReturn = false
    }

    private func append(_ string: NSAttributedString, ensureNewline: Bool = false) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        if ensureNewline, storage.length > 0, !storage.string.hasSuffix("\n") {
            storage.append(NSAttributedString(string: "\n", attributes: Self.outputAttributes))
        }
        storage.append(string)
        trim(storage)
        storage.endEditing()
        pendingCarriageReturn = false
        textView.scrollToEndOfDocument(nil)
    }

    private func truncateCurrentLine(_ storage: NSTextStorage) {
        let string = storage.string as NSString
        let newline = string.range(of: "\n", options: .backwards)
        let lineStart = newline.location == NSNotFound ? 0 : newline.location + 1
        if lineStart < string.length {
            storage.deleteCharacters(in: NSRange(location: lineStart, length: string.length - lineStart))
        }
    }

    private func trim(_ storage: NSTextStorage) {
        guard storage.length > Self.limit else { return }
        let string = storage.string as NSString
        let cut = storage.length - Self.trimTo
        let newline = string.range(of: "\n", options: [], range: NSRange(location: cut, length: storage.length - cut))
        storage.deleteCharacters(in: NSRange(location: 0, length: newline.location == NSNotFound ? cut : newline.location + 1))
    }

    private var isScrolledToBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= textView.frame.height - 8
    }

    private func makeScrollView() -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.font = Self.font
        textView.textColor = NSColor(white: 1, alpha: 0.78)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.18)]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = false
        // Long lines wrap rather than scroll sideways.
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }
}
