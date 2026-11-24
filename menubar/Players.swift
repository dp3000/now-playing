// AppleScript bridge to Music and Spotify: current track/position, artwork, and playback controls.
//
// Every call first checks the player is already running — `tell application "X"` would launch it.

import Cocoa

struct PlayerSnapshot: Equatable {
    var player: String
    var title: String
    var artist: String
    var album: String
    var duration: Double  // seconds
    var position: Double  // seconds, as of when the snapshot was taken
    var isPlaying: Bool

    var trackKey: String { "\(player)|\(title)|\(artist)|\(album)" }
}

enum Players {
    static let all = ["Music", "Spotify"]
    static let bundleIDs = ["Music": "com.apple.Music", "Spotify": "com.spotify.client"]

    static func isRunning(_ player: String) -> Bool {
        guard let id = bundleIDs[player] else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            NSLog("now-playing AppleScript error: \(error)")
            return nil
        }
        return result
    }

    static func snapshot(_ player: String) -> PlayerSnapshot? {
        guard isRunning(player) else { return nil }
        let script = """
        tell application "\(player)"
            if player state is stopped then return {"stopped"}
            set t to current track
            return {player state as text, name of t, artist of t, album of t, duration of t, player position}
        end tell
        """
        guard let d = run(script), d.numberOfItems >= 6 else { return nil }
        var duration = d.atIndex(5)?.doubleValue ?? 0
        if player == "Spotify" { duration /= 1000 }  // Spotify reports milliseconds
        return PlayerSnapshot(
            player: player,
            title: d.atIndex(2)?.stringValue ?? "",
            artist: d.atIndex(3)?.stringValue ?? "",
            album: d.atIndex(4)?.stringValue ?? "",
            duration: duration,
            position: d.atIndex(6)?.doubleValue ?? 0,
            isPlaying: d.atIndex(1)?.stringValue == "playing"
        )
    }

    /// Music returns the image bytes for library tracks; Spotify returns a URL we fetch. Streamed
    /// Apple Music tracks have no artwork via AppleScript, so we fall back to the iTunes Search API.
    static func artwork(_ s: PlayerSnapshot, completion: @escaping (NSImage?) -> Void) {
        guard isRunning(s.player) else { return completion(nil) }
        if s.player == "Music" {
            let d = run("tell application \"Music\" to try\nreturn raw data of artwork 1 of current track\nend try")
            if let image = d.flatMap({ NSImage(data: $0.data) }) { return completion(image) }
            return storeArtwork(s, completion: completion)
        }
        guard let urlString = run("tell application \"Spotify\" to return artwork url of current track")?.stringValue,
              let url = URL(string: urlString) else { return completion(nil) }
        fetchImage(url, completion: completion)
    }

    /// Album cover from Apple's public iTunes Search API (no account; sends artist + album/title).
    private static func storeArtwork(_ s: PlayerSnapshot, completion: @escaping (NSImage?) -> Void) {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        let byAlbum = !s.album.isEmpty
        c.queryItems = [
            URLQueryItem(name: "term", value: "\(s.artist) \(byAlbum ? s.album : s.title)"),
            URLQueryItem(name: "entity", value: byAlbum ? "album" : "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            let results = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["results"]
                as? [[String: Any]]) ?? []
            // prefer the result whose album name matches
            let match = results.first { ($0["collectionName"] as? String)?.lowercased() == s.album.lowercased() }
                ?? results.first
            guard let small = match?["artworkUrl100"] as? String,
                  let url = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")) else {
                return DispatchQueue.main.async { completion(nil) }
            }
            fetchImage(url, completion: completion)
        }.resume()
    }

    private static func fetchImage(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    /// Lyrics saved in the Music library itself (only set for some local files).
    static func libraryLyrics(_ player: String) -> String? {
        guard player == "Music", isRunning(player) else { return nil }
        let text = run("tell application \"Music\" to try\nreturn lyrics of current track\nend try")?.stringValue
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    static func playPause(_ player: String) { send(player, "playpause") }
    static func next(_ player: String) { send(player, "next track") }
    // Music's `back track` restarts the song if you're past the start, like the Previous button.
    static func previous(_ player: String) { send(player, player == "Music" ? "back track" : "previous track") }
    static func seek(_ player: String, to seconds: Double) {
        send(player, "set player position to \(String(format: "%.2f", seconds))")
    }

    private static func send(_ player: String, _ command: String) {
        guard isRunning(player) else { return }
        run("tell application \"\(player)\" to \(command)")
    }
}
