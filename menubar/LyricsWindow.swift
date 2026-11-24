// Pop-out lyrics window: large, high-contrast karaoke lyrics whose text size follows the window size.

import Cocoa
import Combine
import SwiftUI

final class LyricsWindowController: NSObject, NSWindowDelegate {
    private let model: NowPlayingModel
    private var window: NSWindow?
    private var onTop: AnyCancellable?
    private static let autosaveName = "NowPlayingLyricsWindow"

    init(model: NowPlayingModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        if !window.isVisible { model.opened() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Lyrics"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.backgroundColor = .black
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenPrimary]
        w.contentMinSize = NSSize(width: 240, height: 180)
        w.delegate = self
        let host = NSHostingController(rootView: LyricsWindowView(model: model))
        host.sizingOptions = []  // the window decides the size; the text follows it
        w.contentViewController = host
        w.setContentSize(NSSize(width: 520, height: 720))  // attaching the view resets the size
        if !w.setFrameUsingName(Self.autosaveName) { w.center() }
        w.setFrameAutosaveName(Self.autosaveName)
        onTop = model.$lyricsOnTop.sink { [weak w] on in w?.level = on ? .floating : .normal }
        window = w
        return w
    }

    func windowWillClose(_ notification: Notification) {
        model.closed()
    }
}

struct LyricsWindowView: View {
    @ObservedObject var model: NowPlayingModel

    private static let gold = Color(red: 1.0, green: 0.80, blue: 0.16)

    var body: some View {
        GeometryReader { window in
            VStack(spacing: 0) {
                // the lyrics take whatever space the footer leaves; their text size follows that area
                GeometryReader { geo in
                    content(size: fontSize(geo.size), height: geo.size.height)
                }
                .clipped()
                footer(scale: footerScale(window.size))
            }
        }
        .background(Color.black)
        .ignoresSafeArea(edges: .top)  // lyrics run up under the transparent title bar
    }

    /// The footer grows a little with the window (1x up to 1.6x) so it doesn't look tiny when large.
    private func footerScale(_ size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) / 600, 1), 1.6)
    }

    /// Text size follows the lyrics area: roughly 13 characters across, and ~7 lines' worth of height.
    private func fontSize(_ size: CGSize) -> CGFloat {
        max(16, min(size.width / 13, size.height / 7))
    }

    private func font(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    // MARK: lyrics

    @ViewBuilder private func content(size: CGFloat, height: CGFloat) -> some View {
        switch model.lyrics {
        case .off:
            VStack(spacing: size * 0.4) {
                Text("Lyrics are off").font(font(size * 0.6)).foregroundColor(.white)
                Text("Lyrics come from LRCLIB, a free community lyrics database. Each lookup sends the song's title, artist, album and length to lrclib.net.")
                    .font(.system(size: max(12, size * 0.25))).foregroundColor(.gray)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Show Lyrics") { model.lyricsEnabled = true }.controlSize(.large)
            }
            .padding(size * 0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound:
            message(model.snapshot == nil ? "Nothing playing" : "No lyrics found", size: size)
        case .instrumental:
            message("♪ Instrumental ♪", size: size)
        case let .plain(text, _):
            ScrollView(showsIndicators: false) {
                Text(text)
                    .font(font(size * 0.7)).foregroundColor(Color(white: 0.85))
                    .multilineTextAlignment(.center).lineSpacing(size * 0.15)
                    .frame(maxWidth: .infinity).padding(size * 0.5)
            }
        case let .synced(lines, _):
            synced(lines, size: size, height: height)
        }
    }

    private func synced(_ lines: [LyricLine], size: CGFloat, height: CGFloat) -> some View {
        let progress = model.syncedProgress(lines)
        let current = progress.current
        let anchor = UnitPoint(x: 0.5, y: 0.35)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: size * 0.45) {
                    Color.clear.frame(height: height * 0.35)
                    ForEach(lines) { line in
                        lineView(line, current: current, fraction: progress.fraction, size: size)
                            .id(line.id)
                            .onTapGesture { model.seek(to: line.time) }
                    }
                    Color.clear.frame(height: height * 0.6)
                }
                .padding(.horizontal, size * 0.5)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(max(current, 0), anchor: anchor) }
            .onChange(of: current) { index in
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(max(index, 0), anchor: anchor) }
            }
            .onChange(of: size) { _ in proxy.scrollTo(max(current, 0), anchor: anchor) }  // keep place on resize
        }
    }

    private func lineView(_ line: LyricLine, current: Int, fraction: Double, size: CGFloat) -> some View {
        let text = line.text.isEmpty ? "♪" : line.text
        let styled: Text
        if line.id == current {
            // karaoke: the sung part turns gold
            let chars = Array(text)
            let sung = Int((Double(chars.count) * fraction).rounded())
            styled = Text(String(chars[..<sung])).foregroundColor(Self.gold)
                + Text(String(chars[sung...])).foregroundColor(.white)
        } else {
            let d = line.id - current
            let shade = d < 0 ? 0.42 : d == 1 ? 0.78 : d <= 3 ? 0.58 : 0.42
            styled = Text(text).foregroundColor(Color(white: shade))
        }
        return styled
            .font(font(size))
            .multilineTextAlignment(.center)
            .lineSpacing(-size * 0.08)  // keep wrapped rows of one lyric tight
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    private func message(_ text: String, size: CGFloat) -> some View {
        Text(text).font(font(size * 0.7)).foregroundColor(Color(white: 0.6))
            .multilineTextAlignment(.center).padding(size * 0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: footer: artwork, song info, controls

    private func footer(scale k: CGFloat) -> some View {
        HStack(spacing: 12 * k) {
            if let s = model.snapshot {
                artwork(size: 48 * k).frame(width: 48 * k, height: 48 * k)
                    .clipShape(RoundedRectangle(cornerRadius: 5 * k))
                VStack(alignment: .leading, spacing: 2 * k) {
                    Text(s.title).font(.system(size: 14 * k, weight: .semibold)).foregroundColor(.white)
                    Text(s.album.isEmpty ? s.artist : "\(s.artist) — \(s.album)")
                        .font(.system(size: 12 * k)).foregroundColor(Color(white: 0.6))
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                button("backward.fill", help: "Previous", k, action: model.previous)
                button(s.isPlaying ? "pause.fill" : "play.fill", help: s.isPlaying ? "Pause" : "Play", k,
                       action: model.playPause)
                button("forward.fill", help: "Next", k, action: model.next)
            } else {
                Text("Nothing playing").font(.system(size: 13 * k)).foregroundColor(.gray)
                Spacer()
            }
            Divider().frame(height: 20 * k)
            button(model.lyricsOnTop ? "pin.fill" : "pin", help: model.lyricsOnTop ? "Stop keeping on top" : "Keep on top", k) {
                model.lyricsOnTop.toggle()
            }
        }
        .padding(.horizontal, 14 * k).padding(.vertical, 10 * k)
        .background(Color(white: 0.07))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.1)), alignment: .top)
    }

    @ViewBuilder private func artwork(size: CGFloat) -> some View {
        if let image = model.artwork {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(white: 0.15)
                Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundColor(Color(white: 0.5))
            }
        }
    }

    private func button(_ symbol: String, help: String, _ k: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17 * k)).foregroundColor(.white)
                .frame(width: 32 * k, height: 28 * k).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
