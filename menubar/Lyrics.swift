// Lyrics lookup via LRCLIB (https://lrclib.net), a free community lyrics database, with an on-disk cache.
//
// Lookup order: exact match (title/artist/album/duration) → search, picking the closest duration
// → search again with "(Remastered)"-style suffixes and featured artists stripped.

import CryptoKit
import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double  // seconds
    let text: String
}

enum Lyrics: Equatable {
    case off, loading, notFound, instrumental
    case plain(String, source: String)
    case synced([LyricLine], source: String)
}

enum LyricsFetcher {
    struct Record: Codable {
        var plain: String?
        var synced: String?
        var instrumental: Bool
        var fetched: Date
    }

    private struct Hit: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?

        var hasContent: Bool { instrumental == true || !(plainLyrics ?? "").isEmpty || !(syncedLyrics ?? "").isEmpty }
        var record: Record {
            Record(plain: plainLyrics, synced: syncedLyrics, instrumental: instrumental ?? false, fetched: Date())
        }
    }

    static let userAgent = "now-playing/1.0 (personal macOS menu bar app)"
    static let notFoundRetry: TimeInterval = 24 * 3600  // retry misses after a day; hits are kept forever
    static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("now-playing/lyrics", isDirectory: true)

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> Record {
        let key = cacheKey(title, artist, album, duration)
        if let cached = readCache(key), cached.plain != nil || cached.synced != nil || cached.instrumental
            || Date().timeIntervalSince(cached.fetched) < notFoundRetry {
            return cached
        }
        let record = await lookup(title: title, artist: artist, album: album, duration: duration)
            ?? Record(plain: nil, synced: nil, instrumental: false, fetched: Date())
        writeCache(key, record)
        return record
    }

    private static func lookup(title: String, artist: String, album: String, duration: Double) async -> Record? {
        if duration > 0, let data = await get("get", [
            "track_name": title, "artist_name": artist, "album_name": album, "duration": String(Int(duration.rounded())),
        ]), let hit = try? JSONDecoder().decode(Hit.self, from: data), hit.hasContent {
            return hit.record
        }
        let attempts = [(title, artist), (cleanTitle(title), primaryArtist(artist))]
        for (t, a) in attempts where !t.isEmpty {
            guard let data = await get("search", ["track_name": t, "artist_name": a]),
                  let hits = try? JSONDecoder().decode([Hit].self, from: data) else { continue }
            if let best = pick(hits, duration: duration) { return best.record }
        }
        return nil
    }

    /// Prefer synced lyrics, then the closest duration; reject anything more than 8s off (likely another version).
    private static func pick(_ hits: [Hit], duration: Double) -> Hit? {
        hits.filter { $0.hasContent }
            .filter { duration <= 0 || abs(($0.duration ?? duration) - duration) <= 8 }
            .min { a, b in
                let aSynced = (a.syncedLyrics ?? "").isEmpty ? 1 : 0, bSynced = (b.syncedLyrics ?? "").isEmpty ? 1 : 0
                if aSynced != bSynced { return aSynced < bSynced }
                return abs((a.duration ?? 0) - duration) < abs((b.duration ?? 0) - duration)
            }
    }

    private static func get(_ path: String, _ query: [String: String]) async -> Data? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// "Song (Remastered 2011)" / "Song - Live" → "Song"
    static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "A featuring B & C" → "A"
    static func primaryArtist(_ artist: String) -> String {
        artist.replacingOccurrences(of: #"(?i)\s*(,|&|\bfeat\.?|\bfeaturing\b|\bft\.?|\bwith\b|\bx\b).*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Parse LRC ("[mm:ss.xx] line", possibly several timestamps per line) into sorted lines.
    static func parse(_ lrc: String) -> [LyricLine] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var lines: [(Double, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                lines.append((minutes * 60 + seconds, text))
            }
        }
        return lines.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }

    // MARK: cache

    private static func cacheKey(_ title: String, _ artist: String, _ album: String, _ duration: Double) -> String {
        let raw = [title, artist, album, String(Int(duration.rounded()))].joined(separator: "\n").lowercased()
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func readCache(_ key: String) -> Record? {
        guard let data = try? Data(contentsOf: cacheDir.appendingPathComponent("\(key).json")) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func writeCache(_ key: String, _ record: Record) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: cacheDir.appendingPathComponent("\(key).json"), options: .atomic)
        }
    }
}
