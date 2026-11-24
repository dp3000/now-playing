// Shared state for the menu bar title, the popover, and the right-click menu.

import Cocoa

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/now-playing")
let stateURL = supportDir.appendingPathComponent("state.json")
let configURL = supportDir.appendingPathComponent("config.json")
let logPath = NSString(string: "~/Library/Logs/now-playing.log").expandingTildeInPath
let syncAgent = "gui/\(getuid())/com.\(NSUserName()).now-playing"

struct OutputStatus: Identifiable {
    let name: String
    let note: String
    var id: String { name }
    var label: String { name == "github" ? "GitHub" : name == "slack-tab" ? "Slack (tab)" : name.capitalized }
}

func readJSON(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}

final class NowPlayingModel: ObservableObject {
    @Published var snapshot: PlayerSnapshot?
    @Published var artwork: NSImage?
    @Published var lyrics: Lyrics = .off
    @Published var outputs: [OutputStatus] = []
    @Published var now = Date()  // ticks while the popover or lyrics window is open; drives position + highlight
    @Published var lyricsOnTop: Bool = UserDefaults.standard.bool(forKey: "lyricsOnTop") {
        didSet { UserDefaults.standard.set(lyricsOnTop, forKey: "lyricsOnTop") }
    }
    var popOut: (() -> Void)?  // opens the lyrics window (set by the app delegate)
    @Published var lyricsEnabled: Bool {
        didSet {
            guard lyricsEnabled != oldValue else { return }
            var config = readJSON(configURL)
            config["lyrics"] = lyricsEnabled
            if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: configURL, options: .atomic)
            }
            lyricsKey = nil
            loadLyrics()
        }
    }

    private var anchor = Date()  // when `snapshot.position` was read
    private var lastPlayer: String?
    private var lyricsKey: String?
    private var artworkKey: String?
    private var timer: Timer?
    private var ticks = 0
    private var viewers = 0  // open popover + lyrics window
    var isOpen: Bool { viewers > 0 }

    init() {
        lyricsEnabled = readJSON(configURL)["lyrics"] as? Bool ?? false
    }

    var position: Double {
        guard let s = snapshot else { return 0 }
        let elapsed = s.isPlaying ? now.timeIntervalSince(anchor) : 0
        return min(max(s.position + elapsed, 0), s.duration > 0 ? s.duration : .infinity)
    }

    /// Current synced line (shown 0.3s early, so it's up as it's sung) and how much of it has been sung.
    func syncedProgress(_ lines: [LyricLine]) -> (current: Int, fraction: Double) {
        let t = position + 0.3
        guard let cur = lines.lastIndex(where: { $0.time <= t }) else { return (-1, 0) }
        let start = lines[cur].time
        let end = cur + 1 < lines.count ? lines[cur + 1].time : start + 5
        return (cur, min(max((t - start) / max(end - start, 0.5), 0), 1))
    }

    // MARK: viewer lifecycle (popover and lyrics window)

    func opened() {
        viewers += 1
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func closed() {
        viewers = max(viewers - 1, 0)
        if viewers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        now = Date()
        ticks += 1
        // Re-read the real position every 5s (drift, seeks from the player), or when the track should have ended.
        if ticks % 50 == 0 || (snapshot.map { $0.duration > 0 && position >= $0.duration - 0.3 } ?? false) {
            refresh()
        }
    }

    // MARK: updates

    /// A player posted a play/pause/track-change notification.
    func playerNotification(_ player: String, _ info: [AnyHashable: Any]?) {
        if info?["Player State"] as? String == "Playing" { lastPlayer = player }
        if isOpen {
            refresh()
        } else if lyricsEnabled, info?["Player State"] as? String == "Playing",
                  let title = info?["Name"] as? String {
            // Warm the lyrics cache (network only — no AppleScript while the popover is closed).
            let artist = info?["Artist"] as? String ?? ""
            let album = info?["Album"] as? String ?? ""
            let ms = (info?["Total Time"] ?? info?["Duration"]) as? Double ?? 0
            Task { _ = await LyricsFetcher.fetch(title: title, artist: artist, album: album, duration: ms / 1000) }
        }
    }

    func refresh() {
        let snaps = Players.all.compactMap(Players.snapshot)
        let s = snaps.first(where: { $0.isPlaying }) ?? snaps.first(where: { $0.player == lastPlayer }) ?? snaps.first
        snapshot = s
        anchor = Date()
        now = anchor
        outputs = readOutputs()
        if let s = s {
            lastPlayer = s.player
            if artworkKey != s.trackKey {
                artworkKey = s.trackKey
                artwork = nil
                Players.artwork(s) { [weak self] image in
                    if self?.artworkKey == s.trackKey { self?.artwork = image }
                }
            }
        } else {
            artworkKey = nil
            artwork = nil
        }
        loadLyrics()
    }

    private func loadLyrics() {
        guard lyricsEnabled else { lyrics = .off; lyricsKey = nil; return }
        guard let s = snapshot else { lyrics = .notFound; lyricsKey = nil; return }
        guard lyricsKey != s.trackKey else { return }
        lyricsKey = s.trackKey
        lyrics = .loading
        Task {
            let record = await LyricsFetcher.fetch(title: s.title, artist: s.artist, album: s.album, duration: s.duration)
            await MainActor.run {
                guard self.lyricsKey == s.trackKey else { return }  // track changed meanwhile
                if let synced = record.synced, case let lines = LyricsFetcher.parse(synced), !lines.isEmpty {
                    self.lyrics = .synced(lines, source: "LRCLIB")
                } else if let plain = record.plain, !plain.isEmpty {
                    self.lyrics = .plain(plain, source: "LRCLIB")
                } else if record.instrumental {
                    self.lyrics = .instrumental
                } else if let library = Players.libraryLyrics(s.player) {
                    self.lyrics = .plain(library, source: "Music library")
                } else {
                    self.lyrics = .notFound
                }
            }
        }
    }

    func readOutputs() -> [OutputStatus] {
        let outs = readJSON(stateURL)["outputs"] as? [String: [String: Any]] ?? [:]
        return outs.keys.sorted().map { OutputStatus(name: $0, note: outs[$0]?["note"] as? String ?? "idle") }
    }

    // MARK: controls

    func playPause() {
        guard let s = snapshot else { return }
        Players.playPause(s.player)
        refresh()
    }

    func next() { snapshot.map { Players.next($0.player) } }
    func previous() { snapshot.map { Players.previous($0.player) } }

    func seek(to seconds: Double) {
        guard let s = snapshot else { return }
        Players.seek(s.player, to: seconds)
        snapshot?.position = seconds
        anchor = Date()
        now = anchor
    }

    func syncNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", syncAgent]
        try? p.run()
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }
}
