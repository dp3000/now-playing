// The mini player shown when you click the menu bar icon.

import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        VStack(spacing: 0) {
            header.padding(14)
            Divider()
            lyricsArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer.padding(.horizontal, 12).padding(.vertical, 8)
        }
        // Fill whatever size the popover gives us (main.swift sets it, capped to the screen);
        // the lyrics area absorbs any shortfall.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: header: artwork, track, progress, controls

    @ViewBuilder private var header: some View {
        if let s = model.snapshot {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    artwork.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.headline).lineLimit(2)
                        Text(s.artist).foregroundStyle(.secondary).lineLimit(1)
                        if !s.album.isEmpty {
                            Text(s.album).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 2) {
                    ProgressView(value: min(model.position, max(s.duration, 1)), total: max(s.duration, 1))
                    HStack {
                        Text(timestamp(model.position))
                        Spacer()
                        Text("-" + timestamp(max(s.duration - model.position, 0)))
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 36) {
                    control("backward.fill", help: "Previous", action: model.previous)
                    control(s.isPlaying ? "pause.fill" : "play.fill", help: s.isPlaying ? "Pause" : "Play",
                            size: 26, action: model.playPause)
                    control("forward.fill", help: "Next", action: model.next)
                }
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "music.quarternote.3").font(.largeTitle).foregroundStyle(.secondary)
                Text("Nothing playing").font(.headline)
                Text("Start something in Music or Spotify.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
    }

    @ViewBuilder private var artwork: some View {
        if let image = model.artwork {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
            }
        }
    }

    private func control(_ symbol: String, help: String, size: CGFloat = 18, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 36, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: lyrics

    @ViewBuilder private var lyricsArea: some View {
        switch model.lyrics {
        case .off:
            VStack(spacing: 10) {
                Text("Lyrics are off").font(.headline)
                Text("Lyrics come from LRCLIB, a free community lyrics database. Each lookup sends the song's title, artist, album and length to lrclib.net.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Show Lyrics") { model.lyricsEnabled = true }
            }
            .padding(24)
        case .loading:
            ProgressView().controlSize(.small)
        case .notFound:
            message(model.snapshot == nil ? "" : "No lyrics found for this song")
        case .instrumental:
            message("♪ Instrumental")
        case let .plain(text, source):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text).font(.system(size: 14)).textSelection(.enabled)
                    sourceLabel(source)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        case let .synced(lines, source):
            syncedLyrics(lines, source: source)
        }
    }

    private func syncedLyrics(_ lines: [LyricLine], source: String) -> some View {
        let current = model.syncedProgress(lines).current
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 15, weight: line.id == current ? .semibold : .regular))
                            .foregroundStyle(line.id == current ? Color.primary : Color.secondary)
                            .opacity(line.id < current ? 0.55 : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { model.seek(to: line.time) }
                            .help("Jump to \(timestamp(line.time))")
                            .id(line.id)
                    }
                    sourceLabel(source).padding(.top, 8)
                }
                .padding(16)
            }
            .onAppear { proxy.scrollTo(max(current, 0), anchor: .center) }
            .onChange(of: current) { index in
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(max(index, 0), anchor: .center) }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(24)
    }

    private func sourceLabel(_ source: String) -> some View {
        Text("Lyrics: \(source)").font(.caption2).foregroundStyle(.tertiary)
    }

    // MARK: footer: output statuses + options

    private var footer: some View {
        HStack {
            Text(model.outputs.isEmpty ? "No status outputs" : model.outputs.map { "\($0.label): \($0.note)" }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer()
            Button { model.popOut?() } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Pop out lyrics into their own window")
            Menu {
                Toggle("Show Lyrics", isOn: $model.lyricsEnabled)
                Button("Pop Out Lyrics") { model.popOut?() }
                Button("Sync Status Now", action: model.syncNow)
                Button("Open Log", action: model.openLog)
                Divider()
                Button("Quit Now Playing") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
