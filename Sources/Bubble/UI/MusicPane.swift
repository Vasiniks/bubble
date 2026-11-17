import SwiftUI

/// Right half of Home. Compact: a mini player. Expanded: large artwork, track details,
/// seekable progress, controls, and the output picker with volume. When more than one app has
/// media, a stack of them sits at the far right, in the same place in both sizes.
struct MusicPane: View {
    let media: MediaController
    let outputs: AudioOutputs
    let expanded: Bool
    let layout: HomeLayout

    /// Switching the player between sources fades, starting the moment a block is hovered.
    static let swap = Animation.easeOut(duration: 0.2)

    var body: some View {
        let stack = media.stackSources
        let reserved = stack.isEmpty ? 0 : SourceStack.width + SourceStack.gap
        HStack(alignment: .top, spacing: SourceStack.gap) {
            ZStack(alignment: .topTrailing) {
                if expanded {
                    LargePlayer(media: media, outputs: outputs)
                        .frame(width: layout.expandedWidth - reserved, alignment: .topLeading)
                        .transition(.opacity)
                } else {
                    MiniPlayer(media: media, outputs: outputs)
                        .frame(width: HomeLayout.compactWidth - reserved, alignment: .topLeading)
                        .transition(.opacity)
                }
            }
            if !stack.isEmpty {
                SourceStack(media: media, sources: stack)
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topTrailing)
        .animation(.smooth(duration: 0.2), value: stack.map(\.id))
    }
}

// MARK: - Sources

/// Every app with media (up to four), like Control Center's list: artwork with the app's icon
/// as a badge, a green dot while playing, and a ring around the one in the player. Hovering a
/// block fades the player over to that source, where it stays after the pointer moves on;
/// clicking takes you to its tab or app.
private struct SourceStack: View {
    static let tile: CGFloat = 30
    static let spacing: CGFloat = 6
    /// Room for the ring and badge, which sit just outside the tile.
    static let width = tile + 6
    static let inset: CGFloat = 3
    static let gap: CGFloat = 10

    let media: MediaController
    let sources: [MediaController.Source]

    @State private var hovered: Int32?

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(sources) { source in
                SourceBlock(source: source, icon: media.icon(for: source),
                            shown: source.id == media.shownPID, highlighted: source.id == hovered) {
                    media.open(source)
                }
            }
        }
        .frame(width: Self.width)
        .padding(.vertical, Self.inset)
        .contentShape(Rectangle())
        // One hover region for the whole stack, mapped to blocks by position, so the swap starts
        // on the first pointer move over a block. The pick sticks: gaps between blocks and
        // leaving the stack keep the last one.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                guard let source = source(at: point.y), source.id != hovered else { return }
                hovered = source.id
                withAnimation(MusicPane.swap) { media.select(source) }
            case .ended:
                hovered = nil
            }
        }
    }

    private func source(at y: CGFloat) -> MediaController.Source? {
        let offset = y - Self.inset
        let pitch = Self.tile + Self.spacing
        guard offset >= 0 else { return nil }
        let index = Int(offset / pitch)
        guard index < sources.count, offset - CGFloat(index) * pitch <= Self.tile else { return nil }
        return sources[index]
    }
}

private struct SourceBlock: View {
    let source: MediaController.Source
    let icon: NSImage?
    let shown: Bool
    let highlighted: Bool
    let action: () -> Void

    private static let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)

    var body: some View {
        Button(action: action) {
            ZStack {
                Self.shape.fill(Palette.fill)
                if let artwork = source.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.tertiary)
                }
            }
            .frame(width: SourceStack.tile, height: SourceStack.tile)
            .clipShape(Self.shape)
            .overlay(alignment: .bottomTrailing) {
                if source.artwork != nil, let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.6), radius: 1.5)
                        .offset(x: 3, y: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if source.isPlaying {
                    Circle()
                        .fill(Palette.good)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(.black, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
            .overlay {
                if shown {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .strokeBorder(Palette.primary.opacity(0.75), lineWidth: 1.25)
                        .padding(-2.5)
                }
            }
            .opacity(shown || highlighted ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact

private struct MiniPlayer: View {
    let media: MediaController
    let outputs: AudioOutputs

    var body: some View {
        let playing = media.shownTrack
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Artwork(media: media, size: 58, radius: 6, badge: 18)
                TrackText(media: media, titleSize: 12, compact: true)
            }
            ZStack {
                if let playing {
                    PlaybackProgress(media: media, playing: playing)
                        .id(media.shownPID)
                        .transition(.opacity)
                }
            }
            .frame(height: 18)
            Controls(media: media, isPlaying: playing?.isPlaying ?? false, large: false)
            CurrentOutput(outputs: outputs)
        }
        .padding(.top, 2)
    }
}

// MARK: - Expanded

private struct LargePlayer: View {
    let media: MediaController
    let outputs: AudioOutputs

    @State private var choosingOutput = false

    private static let artSize: CGFloat = 156

    var body: some View {
        let playing = media.shownTrack
        HStack(alignment: .top, spacing: 18) {
            Artwork(media: media, size: Self.artSize, radius: 10, badge: 28)

            Group {
                if choosingOutput {
                    OutputList(outputs: outputs) {
                        withAnimation(.smooth(duration: 0.25)) { choosingOutput = false }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        TrackText(media: media, titleSize: 15, compact: false)
                        Spacer(minLength: 6)
                        ZStack {
                            if let playing {
                                PlaybackProgress(media: media, playing: playing)
                                    .id(media.shownPID)
                                    .transition(.opacity)
                            }
                        }
                        Controls(media: media, isPlaying: playing?.isPlaying ?? false, large: true)
                            .padding(.vertical, 4)
                        OutputSummary(outputs: outputs) {
                            withAnimation(.smooth(duration: 0.25)) { choosingOutput = true }
                        }
                    }
                }
            }
            .frame(height: Self.artSize)
            .transition(.opacity)
        }
    }
}

private struct OutputSummary: View {
    let outputs: AudioOutputs
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        let current = outputs.devices.first { $0.id == outputs.currentID }
        HStack(spacing: 10) {
            Button(action: choose) {
                HStack(spacing: 6) {
                    Image(systemName: current?.symbol ?? "hifispeaker")
                        .font(.system(size: 10))
                    Text(current?.name ?? "Output")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 84, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.tertiary)
                }
                .foregroundStyle(hovering ? Palette.primary : Palette.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(hovering ? Palette.track : Palette.fill))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Choose output")
            .layoutPriority(1)

            VolumeControl(outputs: outputs)
        }
    }
}

private struct OutputList: View {
    let outputs: AudioOutputs
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "OUTPUT")
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.primary)
            }
            VolumeControl(outputs: outputs)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(outputs.devices) { device in
                        DeviceRow(device: device, selected: device.id == outputs.currentID) {
                            outputs.select(device)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shared pieces

private struct TrackText: View {
    let media: MediaController
    let titleSize: CGFloat
    let compact: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            lines
                .id(media.shownPID)
                .transition(.opacity)
        }
    }

    private var lines: some View {
        let playing = media.shownTrack
        return VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            Text(playing?.title ?? (media.isAvailable ? "Nothing playing" : "Now Playing unavailable"))
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(Palette.primary)
                .lineLimit(compact ? 1 : 2)
            if let playing {
                Text(playing.artist.isEmpty ? (media.shownAppName ?? "") : playing.artist)
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                if !compact, !playing.album.isEmpty {
                    Text(playing.album)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text(media.isAvailable ? "Play something in any app" : "Rebuild with ./build.sh")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

private struct Artwork: View {
    let media: MediaController
    let size: CGFloat
    let radius: CGFloat
    let badge: CGFloat

    var body: some View {
        Button {
            media.openPlayer()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.fill)
                Group {
                    if let artwork = media.shownArtwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.3, weight: .medium))
                            .foregroundStyle(Palette.tertiary)
                    }
                }
                .id(media.shownPID)
                .transition(.opacity)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let icon = media.shownAppIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: badge, height: badge)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .offset(x: badge * 0.22, y: badge * 0.22)
                        .id(media.shownPID)
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .help(media.shownAppName.map { "Go to \($0)" } ?? "")
        .padding(.trailing, badge * 0.22)
    }
}

private struct PlaybackProgress: View {
    let media: MediaController
    let playing: MediaController.NowPlaying

    var body: some View {
        // Advances with the metrics sample (once a second while open) rather than its own timer,
        // so the notch redraws in a single pass each second.
        let now = playing.isPlaying ? MetricsMonitor.shared.sampledAt : playing.timestamp
        let position = playing.position(at: max(now, playing.timestamp))
        VStack(spacing: 1) {
                ScrubBar(
                    fraction: playing.duration > 0 ? position / playing.duration : 0,
                    onChange: { _ in },
                    onCommit: { fraction in
                        guard playing.duration > 0 else { return }
                        media.seek(to: fraction * playing.duration)
                    }
                )
                .allowsHitTesting(media.canControlShown)
                HStack {
                    Text(Format.playback(position))
                    Spacer()
                    Text("-" + Format.playback(max(0, playing.duration - position)))
                }
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.tertiary)
        }
    }
}

private struct Controls: View {
    let media: MediaController
    let isPlaying: Bool
    let large: Bool

    var body: some View {
        HStack(spacing: large ? 22 : 14) {
            Spacer(minLength: 0)
            GlyphButton(symbol: "backward.fill", size: large ? 15 : 12, help: "Previous") { media.previousTrack() }
            GlyphButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: large ? 24 : 17, help: isPlaying ? "Pause" : "Play") {
                media.togglePlayPause()
            }
            GlyphButton(symbol: "forward.fill", size: large ? 15 : 12, help: "Next") { media.nextTrack() }
            Spacer(minLength: 0)
        }
        // A source Bubble can't script (no playback scripting, no tab to find) rests here; the
        // artwork still takes you to it.
        .disabled(!media.canControlShown)
        .opacity(media.canControlShown ? 1 : 0.3)
        .help(media.canControlShown ? "" : "Bubble can't control \(media.shownAppName ?? "this app") from here. Click the artwork to go to it.")
    }
}

private struct CurrentOutput: View {
    let outputs: AudioOutputs

    var body: some View {
        let current = outputs.devices.first { $0.id == outputs.currentID }
        HStack(spacing: 6) {
            Image(systemName: current?.symbol ?? "hifispeaker")
                .font(.system(size: 9))
            Text(current?.name ?? "—")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let volume = outputs.volume {
                Text(outputs.isMuted ? "muted" : "\(Int(volume * 100))%")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Palette.tertiary)
    }
}

private struct VolumeControl: View {
    let outputs: AudioOutputs

    var body: some View {
        HStack(spacing: 4) {
            GlyphButton(symbol: symbol, size: 10, help: outputs.isMuted ? "Unmute" : "Mute") {
                outputs.toggleMute()
            }
            .frame(width: 24)
            if let volume = outputs.volume {
                ScrubBar(fraction: outputs.isMuted ? 0 : Double(volume), onChange: { outputs.setVolume(Float($0)) })
            } else {
                Text("Fixed volume")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
                Spacer(minLength: 0)
            }
        }
    }

    private var symbol: String {
        guard !outputs.isMuted, let volume = outputs.volume else { return "speaker.slash.fill" }
        return volume < 0.01 ? "speaker.fill" : volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

private struct DeviceRow: View {
    let device: AudioOutputs.Device
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: device.symbol)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(device.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Palette.good)
                }
            }
            .foregroundStyle(selected ? Palette.primary : Palette.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected || hovering ? Palette.fill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
