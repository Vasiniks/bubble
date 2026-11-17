import AppKit
import Observation

/// Now Playing for any app (Music, Spotify, browsers…), via the MediaBridge helper.
///
/// macOS only reports Now Playing to Apple-signed processes, so the bridge (a tiny dylib,
/// see Sources/MediaBridge) runs inside /usr/bin/perl. It is started when Home
/// appears and stopped a little after it goes away, so Bubble pays nothing for music otherwise.
@MainActor
@Observable
final class MediaController {
    static let shared = MediaController()

    struct NowPlaying: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var rate: Double
        /// When `elapsed` was measured.
        var timestamp: Date
        var isPlaying: Bool

        func position(at date: Date) -> Double {
            guard isPlaying else { return clamp(elapsed) }
            return clamp(elapsed + date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1))
        }

        private func clamp(_ value: Double) -> Double {
            duration > 0 ? min(max(0, value), duration) : max(0, value)
        }
    }

    /// An app with media, for the source stack: Control Center's list of players.
    struct Source: Identifiable, Equatable {
        let id: Int32 // pid
        var bundle: String
        var name: String
        /// nil when the app has a session but nothing titled in it.
        var track: NowPlaying?
        var isPlaying: Bool
        var artwork: NSImage?
    }

    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var appIcon: NSImage?
    private(set) var appName: String?
    /// The Now Playing app's pid, which the source stack highlights.
    private(set) var currentPID: Int32 = 0
    /// Every app with media, in the order they first appeared (MediaRemote reorders by
    /// recency, which would shuffle the stack under the pointer).
    private(set) var sources: [Source] = []
    /// False when the helper can't run (missing library, or MediaRemote refused it).
    private(set) var isAvailable = true
    /// The source last hovered in the stack, which the player shows in place of Now Playing.
    /// It sticks until the notch closes, the source goes away, or another app becomes Now
    /// Playing (something new started, so show that).
    private(set) var selectedPID: Int32?

    static let maxSources = 4

    // What the player shows: the selected source, or else Now Playing. Separate accessors so
    // each view only depends on what it draws.
    private var selectedSource: Source? {
        guard let pid = selectedPID, pid != currentPID else { return nil }
        return sources.first { $0.id == pid }
    }

    var shownPID: Int32 { selectedSource?.id ?? currentPID }
    var shownTrack: NowPlaying? { if let source = selectedSource { source.track } else { nowPlaying } }
    var shownArtwork: NSImage? { if let source = selectedSource { source.artwork } else { artwork } }
    var shownAppIcon: NSImage? { if let source = selectedSource { icon(for: source) } else { appIcon } }
    var shownAppName: String? { if let source = selectedSource { source.name } else { appName } }
    /// Whether the buttons can reach what's shown: Now Playing through MediaRemote, another
    /// source through its own app's scripting (see `control`). For anything else they rest,
    /// and the artwork takes you there instead.
    var canControlShown: Bool {
        guard let source = selectedSource else { return true }
        return PlayerScript.canControl(source)
    }

    /// The stack's blocks: shown only when there's more than one source, up to four, always
    /// including the Now Playing one.
    var stackSources: [Source] {
        guard sources.count > 1 else { return [] }
        guard sources.count > Self.maxSources else { return sources }
        var shown = Array(sources.prefix(Self.maxSources))
        if !shown.contains(where: { $0.id == currentPID }), let current = sources.first(where: { $0.id == currentPID }) {
            shown[Self.maxSources - 1] = current
        }
        return shown
    }

    @ObservationIgnored private var process: ChildProcess?
    @ObservationIgnored private var spawnTime = Date.distantPast
    @ObservationIgnored private var receivedOutput = false
    @ObservationIgnored private var stopWork: DispatchWorkItem?
    @ObservationIgnored private var appPID: Int32 = 0
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    /// osascript runs in flight, kept alive until they finish.
    @ObservationIgnored private var scripts: [pid_t: ChildProcess] = [:]
    @ObservationIgnored private var tabFinder: pid_t?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.eason.bubble.media", qos: .utility)

    private static let gracePeriod: TimeInterval = 20

    private static let script = """
    use DynaLoader;
    my $h = DynaLoader::dl_load_file($ARGV[0], 0) or exit 4;
    my $s = DynaLoader::dl_find_symbol($h, 'bubble_media_run') or exit 5;
    DynaLoader::dl_install_xsub('main::run', $s);
    run();
    """

    private init() {}

    func activate() {
        stopWork?.cancel()
        stopWork = nil
        guard process == nil, isAvailable else { return }
        guard let library = Self.bridgeLibrary else {
            isAvailable = false
            return
        }
        guard let child = ChildProcess(path: "/usr/bin/perl", arguments: ["-e", Self.script, library], environment: ["PATH": "/usr/bin:/bin"]) else {
            isAvailable = false
            return
        }
        process = child
        spawnTime = Date()
        receivedOutput = false

        let splitter = LineSplitter()
        child.start(queue: queue, onOutput: { data in
            splitter.feed(data) { line in
                guard let update = Update(json: line) else { return }
                DispatchQueue.main.async { MediaController.shared.apply(update) }
            }
        }, onEnd: { [weak child] in
            DispatchQueue.main.async {
                guard let child else { return }
                MediaController.shared.helperEnded(child)
            }
        })
    }

    /// Keeps the helper briefly so flipping between tabs doesn't respawn it.
    func deactivate() {
        selectedPID = nil
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gracePeriod, execute: work)
    }

    // The buttons act on whatever the player shows: Now Playing through the bridge, or a source
    // picked from the stack through its app (two things can play at once).

    func togglePlayPause() {
        if let source = selectedSource { return control(source, .toggle) }
        send("toggle")
        // Reflect the change immediately; the bridge confirms a moment later.
        guard let playing = nowPlaying else { return }
        nowPlaying = PlayerCommand.toggle.predict(playing)
    }

    func nextTrack() {
        if let source = selectedSource { return control(source, .next) }
        send("next")
    }

    func previousTrack() {
        if let source = selectedSource { return control(source, .previous) }
        send("prev")
    }

    func seek(to seconds: Double) {
        if let source = selectedSource { return control(source, .seek(seconds)) }
        send("seek \(seconds)")
        guard let playing = nowPlaying else { return }
        nowPlaying = PlayerCommand.seek(seconds).predict(playing)
    }

    /// Plays, pauses, skips or seeks a source that isn't Now Playing. MediaRemote only lets
    /// Control Center aim commands at those, so this goes through the app's own scripting:
    /// Music, TV and Spotify directly, a browser tab through its page (which needs the
    /// browser's "Allow JavaScript from Apple Events"). If that doesn't work, Bubble takes you
    /// to the source instead, so you can press play there.
    private func control(_ source: Source, _ command: PlayerCommand) {
        guard let call = PlayerScript.script(for: source, command) else {
            open(source)
            return
        }
        // Show the change right away, and take it back if the app didn't do it.
        let guess = source.track.map { command.predict($0) }.map { track in
            var guess = source
            guess.track = track
            guess.isPlaying = track.isPlaying
            return guess
        }
        if let guess { replace(source, with: guess) }
        let ran = runScript(call.script, arguments: call.arguments) { result, _ in
            if result != "ok" { MediaController.shared.undo(guess, back: source) }
        }
        if ran == nil { undo(guess, back: source) }
    }

    /// The command didn't go through: take back what was shown, and go to the source instead.
    private func undo(_ guess: Source?, back source: Source) {
        if let guess { replace(guess, with: source) }
        open(source)
    }

    /// Swaps a source's state, unless the bridge has already moved it on.
    private func replace(_ old: Source, with new: Source) {
        guard let index = sources.firstIndex(of: old) else { return }
        sources[index] = new
    }

    /// Brings forward whatever the player is showing: the tab or app playing it.
    func openPlayer() {
        if let source = sources.first(where: { $0.id == shownPID }) {
            open(source)
        } else if appPID > 0 {
            NSRunningApplication(processIdentifier: appPID)?.activate()
        }
    }

    /// Shows a source in the player (hovering its block); nil goes back to Now Playing.
    func select(_ source: Source?) {
        let pid = source?.id == currentPID ? nil : source?.id
        if selectedPID != pid { selectedPID = pid }
    }

    /// Takes you to a source. For a browser, that's the tab playing it, found by its title
    /// through the browser's scripting (macOS asks once per browser whether Bubble may);
    /// otherwise, or if that fails, the app comes forward.
    func open(_ source: Source) {
        let title = source.track?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, let script = BrowserTab.selectScript(for: source.bundle) else {
            activateApp(of: source)
            return
        }
        // A newer click wins over a search still running.
        if let tabFinder { scripts[tabFinder]?.terminate() }
        tabFinder = runScript(script, arguments: BrowserTab.needles(for: title)) { result, pid in
            let controller = MediaController.shared
            // Only the latest click falls back; one it replaced just ends.
            guard controller.tabFinder == pid else { return }
            controller.tabFinder = nil
            if result != "ok" { controller.activateApp(of: source) }
        }
        if tabFinder == nil { activateApp(of: source) }
    }

    /// Runs an AppleScript in osascript, so a first-time permission prompt (macOS asks once per
    /// app) never holds up Bubble, and calls back on the main thread with what it returned.
    /// Returns nil, without calling back, if osascript couldn't start.
    private func runScript(_ script: String, arguments: [String], done: @escaping @MainActor (_ result: String, _ pid: pid_t) -> Void) -> pid_t? {
        // "--" so an argument starting with a dash isn't read as an option.
        guard let child = ChildProcess(path: "/usr/bin/osascript", arguments: ["-e", script, "--"] + arguments, environment: ["PATH": "/usr/bin:/bin"]) else {
            return nil
        }
        let pid = child.pid
        scripts[pid] = child
        let output = OutputBuffer()
        child.start(queue: queue, onOutput: { output.append($0) }, onEnd: {
            let result = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                MediaController.shared.scripts[pid] = nil
                done(result, pid)
            }
        })
        return pid
    }

    private func activateApp(of source: Source) {
        if let app = NSRunningApplication(processIdentifier: source.id), app.bundleIdentifier != nil {
            app.activate()
        } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: source.bundle).first {
            app.activate()
        }
    }

    /// The app icon for a source, looked up once per app.
    func icon(for source: Source) -> NSImage? {
        let key = source.bundle.isEmpty ? "pid:\(source.id)" : source.bundle
        if let icon = icons[key] { return icon }
        var icon = NSRunningApplication(processIdentifier: source.id)?.icon
        if icon == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundle) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        icons[key] = icon
        return icon
    }

    private func send(_ command: String) {
        process?.write(command + "\n")
    }

    private func stop() {
        process?.terminate()
        process = nil
    }

    private func helperEnded(_ child: ChildProcess) {
        guard child === process else { return }
        process = nil
        // Dying right away without a word means it can't work here; don't keep retrying.
        if !receivedOutput, Date().timeIntervalSince(spawnTime) < 3 {
            isAvailable = false
        }
    }

    private func apply(_ update: Update) {
        receivedOutput = true
        switch update {
        case .player(let player): apply(player)
        case .sources(let list): apply(list)
        }
    }

    private func apply(_ list: [SourceUpdate]) {
        // Keep known sources where they are, append new ones, drop the departed.
        var merged: [Source] = sources.compactMap { old in
            guard let new = list.first(where: { $0.pid == old.id }) else { return nil }
            return new.merged(into: old)
        }
        for new in list where !merged.contains(where: { $0.id == new.pid }) {
            merged.append(new.merged(into: nil))
        }
        if merged != sources { sources = merged }
        if let pid = selectedPID, !merged.contains(where: { $0.id == pid }) { selectedPID = nil }
    }

    private func apply(_ update: PlayerUpdate) {
        if let artwork = update.artwork {
            self.artwork = artwork.isEmpty ? nil : NSImage(data: artwork)
        }

        guard let title = update.title, !title.isEmpty else {
            nowPlaying = nil
            return
        }
        let playing = NowPlaying(
            title: title,
            artist: update.artist ?? "",
            album: update.album ?? "",
            duration: update.duration ?? 0,
            elapsed: update.elapsed ?? 0,
            rate: update.rate ?? (update.playing ? 1 : 0),
            timestamp: update.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            isPlaying: update.playing
        )
        if nowPlaying != playing { nowPlaying = playing }

        if currentPID != update.pid {
            currentPID = update.pid
            // Something else became Now Playing: show it rather than an older pick.
            if selectedPID != nil { selectedPID = nil }
        }
        if update.pid != appPID {
            appPID = update.pid
            let app = update.pid > 0 ? NSRunningApplication(processIdentifier: update.pid) : nil
            appIcon = app?.icon
            appName = app?.localizedName
        }
    }

    private static var bridgeLibrary: String? {
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaBridge.dylib").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MediaBridge.dylib").path,
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }
}

/// One line of bridge output, decoded off the main thread.
private enum Update: Sendable {
    case player(PlayerUpdate)
    case sources([SourceUpdate])

    init?(json line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if let list = object["sources"] as? [[String: Any]] {
            self = .sources(list.compactMap(SourceUpdate.init))
        } else {
            self = .player(PlayerUpdate(object))
        }
    }
}

private struct SourceUpdate: Sendable {
    var pid: Int32
    var bundle: String
    var name: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var rate: Double?
    var timestamp: Double?
    var playing: Bool
    /// nil: unchanged. Empty: cleared.
    var art: Data?

    init?(_ object: [String: Any]) {
        guard let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        self.pid = pid
        bundle = object["bundle"] as? String ?? ""
        name = object["name"] as? String ?? ""
        title = object["title"] as? String ?? ""
        artist = object["artist"] as? String ?? ""
        album = object["album"] as? String ?? ""
        duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
        elapsed = (object["elapsed"] as? NSNumber)?.doubleValue ?? 0
        rate = (object["rate"] as? NSNumber)?.doubleValue
        timestamp = (object["timestamp"] as? NSNumber)?.doubleValue
        playing = (object["playing"] as? NSNumber)?.boolValue ?? false
        if let encoded = object["art"] as? String {
            art = encoded.isEmpty ? Data() : Data(base64Encoded: encoded) ?? Data()
        }
    }

    @MainActor
    func merged(into old: MediaController.Source?) -> MediaController.Source {
        var artwork = old?.artwork
        if let art { artwork = art.isEmpty ? nil : NSImage(data: art) }
        let appName = name.isEmpty ? NSRunningApplication(processIdentifier: pid)?.localizedName ?? "" : name
        let track = title.isEmpty ? nil : MediaController.NowPlaying(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsed: elapsed,
            rate: rate ?? (playing ? 1 : 0),
            timestamp: timestamp.map { Date(timeIntervalSince1970: $0) } ?? old?.track?.timestamp ?? Date(),
            isPlaying: playing
        )
        return MediaController.Source(id: pid, bundle: bundle, name: appName, track: track, isPlaying: playing, artwork: artwork)
    }
}

private struct PlayerUpdate: Sendable {
    var pid: Int32
    var playing: Bool
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsed: Double?
    var rate: Double?
    var timestamp: Double?
    /// nil: unchanged. Empty: cleared.
    var artwork: Data?

    init(_ object: [String: Any]) {
        pid = (object["pid"] as? NSNumber)?.int32Value ?? 0
        playing = (object["playing"] as? NSNumber)?.boolValue ?? false
        title = object["title"] as? String
        artist = object["artist"] as? String
        album = object["album"] as? String
        duration = (object["duration"] as? NSNumber)?.doubleValue
        elapsed = (object["elapsed"] as? NSNumber)?.doubleValue
        rate = (object["rate"] as? NSNumber)?.doubleValue
        timestamp = (object["timestamp"] as? NSNumber)?.doubleValue
        if let encoded = object["artwork"] as? String {
            artwork = encoded.isEmpty ? Data() : Data(base64Encoded: encoded) ?? Data()
        }
    }
}

private enum PlayerCommand {
    case toggle, next, previous, seek(Double)

    /// The track as it will be once this lands, to show right away.
    func predict(_ track: MediaController.NowPlaying) -> MediaController.NowPlaying {
        var track = track
        let now = Date()
        switch self {
        case .toggle:
            track.elapsed = track.position(at: now)
            track.timestamp = now
            track.isPlaying.toggle()
        case .seek(let seconds):
            track.elapsed = seconds
            track.timestamp = now
        case .next, .previous:
            break
        }
        return track
    }
}

/// Scripts that control a source directly, for when it isn't Now Playing. Each returns "ok"
/// when the command went through. Bundle IDs only ever come from these literal lists, and
/// numbers are formatted here; titles go in as arguments.
private enum PlayerScript {
    /// Apps with Music-style playback scripting.
    private static let apps: Set<String> = ["com.apple.Music", "com.apple.TV", "com.spotify.client"]

    static func canControl(_ source: MediaController.Source) -> Bool {
        apps.contains(source.bundle) || BrowserTab.isScriptable(source.bundle) && !title(of: source).isEmpty
    }

    static func script(for source: MediaController.Source, _ command: PlayerCommand) -> (script: String, arguments: [String])? {
        let bundle = source.bundle
        if apps.contains(bundle) {
            let verb = switch command {
            case .toggle: "playpause"
            case .next: "next track"
            // Music and TV's back track restarts the song first, like their button; Spotify
            // only has previous track.
            case .previous: bundle == "com.spotify.client" ? "previous track" : "back track"
            case .seek(let seconds): "set player position to \(number(seconds))"
            }
            let script = """
            if application id "\(bundle)" is running then
                tell application id "\(bundle)" to \(verb)
                return "ok"
            end if
            return "gone"
            """
            return (script, [])
        }
        let title = title(of: source)
        guard !title.isEmpty, let script = BrowserTab.pageScript(for: bundle) else { return nil }
        return (script, [page(command)] + BrowserTab.needles(for: title))
    }

    /// JavaScript for the tab: acts on the page's playing video or audio (else the one furthest
    /// in). Next presses YouTube's next button, or runs the media to its end so the site moves on.
    private static func page(_ command: PlayerCommand) -> String {
        let action = switch command {
        case .toggle: "if (m.paused) m.play(); else m.pause();"
        case .next: "var b = document.querySelector('.ytp-next-button'); if (b) b.click(); else if (isFinite(m.duration)) m.currentTime = m.duration;"
        case .previous: "m.currentTime = 0;"
        case .seek(let seconds): "m.currentTime = \(number(seconds));"
        }
        return """
        (function () {
            var all = Array.prototype.slice.call(document.querySelectorAll('video, audio'));
            var m = all.filter(function (e) { return !e.paused; })[0]
                || all.sort(function (a, b) { return b.currentTime - a.currentTime; })[0];
            if (!m) return 'none';
            \(action)
            return 'ok';
        })()
        """
    }

    private static func title(of source: MediaController.Source) -> String {
        source.track?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value.isFinite ? max(0, value) : 0)
    }
}

/// Finds the tab playing a track, by title, in browsers that can be scripted, to bring it
/// forward or run the player's JavaScript in it. The bundle ID is only ever one of these
/// literals; the title goes in as an argument.
private enum BrowserTab {
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    ]
    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    static func isScriptable(_ bundle: String) -> Bool {
        chromium.contains(bundle) || safari.contains(bundle)
    }

    /// Brings the tab forward. Arguments: the needles.
    static func selectScript(for bundle: String) -> String? {
        let select: String
        if chromium.contains(bundle) {
            select = """
            set active tab index of window w to t
            try
                set minimized of window w to false
            end try
            """
        } else if safari.contains(bundle) {
            select = """
            set current tab of window w to tab t of window w
            try
                set miniaturized of window w to false
            end try
            """
        } else {
            return nil
        }
        return search(bundle, firstNeedle: 1, found: select + """

        set index of window w to 1
        activate
        return "ok"
        """)
    }

    /// Runs JavaScript in the tab, leaving it where it is, and returns its result: "blocked"
    /// when the browser has JavaScript from Apple Events turned off. Arguments: the
    /// JavaScript, then the needles.
    static func pageScript(for bundle: String) -> String? {
        let run: String
        if chromium.contains(bundle) {
            run = "execute tab t of window w javascript (item 1 of argv)"
        } else if safari.contains(bundle) {
            run = "do JavaScript (item 1 of argv) in tab t of window w"
        } else {
            return nil
        }
        return search(bundle, firstNeedle: 2, found: """
        try
            return (\(run)) as text
        on error
            return "blocked"
        end try
        """)
    }

    /// What to look for in tab titles, best first: the whole track title (YouTube's tab is
    /// "Title - YouTube", Spotify's "Title • Artist"), then its opening words, in case the site
    /// trims or decorates the title differently in each place.
    static func needles(for title: String) -> [String] {
        var needles = [title]
        let words = title.split(whereSeparator: \.isWhitespace)
        if words.count > 3 {
            let opening = words.prefix(max(3, words.count / 2)).joined(separator: " ")
            if opening.count >= 8 { needles.append(opening) }
        }
        return needles
    }

    /// Looks through every window's tabs for each needle (from argument `firstNeedle` on) and
    /// runs `found` on the first match, with the window in `w` and the tab in `t`.
    private static func search(_ bundle: String, firstNeedle: Int, found: String) -> String {
        let names = chromium.contains(bundle) ? "title" : "name"
        return """
        on run argv
            tell application id "\(bundle)"
                set windowCount to count of windows
                repeat with n from \(firstNeedle) to count of argv
                    set needle to (item n of argv) as text
                    repeat with w from 1 to windowCount
                        set titles to {}
                        try
                            set titles to \(names) of tabs of window w
                        end try
                        repeat with t from 1 to count of titles
                            if item t of titles contains needle then
                                \(found)
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "none"
        end run
        """
    }
}

/// Collects a helper's output across reads on one queue.
private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
    var text: String { String(decoding: data, as: UTF8.self) }
}

/// Splits a byte stream into newline-terminated lines. Used from a single queue.
final class LineSplitter: @unchecked Sendable {
    private var pending = Data()

    func feed(_ data: Data, line: (Data) -> Void) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let content = pending[pending.startIndex ..< newline]
            if !content.isEmpty { line(Data(content)) }
            pending.removeSubrange(pending.startIndex ... newline)
        }
    }
}
