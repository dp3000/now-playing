// Menu bar companion for now_playing.py.
//
// - Shows the current track in the menu bar, updating instantly from the players' own
//   track-change notifications, and kicks the sync agent on every change so Slack/GitHub
//   update right away instead of on the next 20s tick.
// - Left-click: mini player popover (artwork, progress, controls, synced lyrics), which can pop
//   the lyrics out into their own resizable window (LyricsWindow.swift).
// - Right-click: menu with each output's status, Sync Now, Open Log, Quit.
//
// Build: install.sh compiles menubar/*.swift into NowPlaying.app.

import Cocoa
import SwiftUI

let maxTitleLength = 40
let popoverSize = NSSize(width: 340, height: 520)

// Player name -> distributed notification it posts on play/pause/track change.
let playerNotifications = [
    ("Music", "com.apple.Music.playerInfo"),
    ("Spotify", "com.spotify.client.PlaybackStateChanged"),
]

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = NowPlayingModel()
    private lazy var lyricsWindow = LyricsWindowController(model: model)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var playing: [String: String] = [:]  // player -> "Title — Artist", for the menu bar title
    private var fallbackTrack: String?           // from state.json until the first notification

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = []  // we set popover.contentSize ourselves; see statusItemClicked
        popover.contentViewController = host
        model.popOut = { [weak self] in self?.popOutLyrics() }

        let center = DistributedNotificationCenter.default()
        for (player, name) in playerNotifications {
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                self?.playerChanged(player, note.userInfo)
            }
        }
        fallbackTrack = readJSON(stateURL)["track"] as? String
        render()
    }

    private var currentTrack: String? {
        playerNotifications.lazy.compactMap { self.playing[$0.0] }.first ?? fallbackTrack
    }

    private func playerChanged(_ player: String, _ info: [AnyHashable: Any]?) {
        fallbackTrack = nil
        if info?["Player State"] as? String == "Playing", let name = info?["Name"] as? String {
            let artist = info?["Artist"] as? String ?? ""
            playing[player] = artist.isEmpty ? name : "\(name) — \(artist)"
        } else {
            playing.removeValue(forKey: player)
        }
        render()
        model.syncNow()
        model.playerNotification(player, info)
    }

    private func render() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "music.quarternote.3", accessibilityDescription: "Now Playing")
        button.imagePosition = .imageLeading
        if let track = currentTrack {
            button.title = " " + (track.count > maxTitleLength ? track.prefix(maxTitleLength - 1) + "…" : track)
        } else {
            button.title = ""
        }
        button.toolTip = currentTrack ?? "Nothing playing"
    }

    // MARK: clicks

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)  // shows the menu
            statusItem.menu = nil                 // so the next left-click opens the popover again
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            model.opened()
            // Size the popover before showing it. If SwiftUI resizes it afterwards, AppKit grows the
            // window upward from where it was placed, pushing the top off-screen (seen on external
            // displays that sit higher than the main one). Cap to the room below the menu bar.
            let room = button.window.flatMap { w in w.screen.map { w.frame.minY - $0.visibleFrame.minY - 12 } } ?? popoverSize.height
            popover.contentSize = NSSize(width: popoverSize.width, height: min(popoverSize.height, max(room, 260)))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.closed()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabled(currentTrack ?? "Nothing playing"))
        menu.addItem(.separator())
        let outputs = model.readOutputs()
        if outputs.isEmpty { menu.addItem(disabled("No status outputs")) }
        for o in outputs { menu.addItem(disabled("\(o.label): \(o.note)")) }
        menu.addItem(.separator())
        let lyrics = item("Show Lyrics", #selector(toggleLyrics), "")
        lyrics.state = model.lyricsEnabled ? .on : .off
        menu.addItem(lyrics)
        menu.addItem(item("Pop Out Lyrics", #selector(popOutLyrics), "o"))
        menu.addItem(item("Sync Status Now", #selector(syncNow), "s"))
        menu.addItem(item("Open Log", #selector(openLog), "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Now Playing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func popOutLyrics() {
        popover.performClose(nil)
        lyricsWindow.show()
    }

    @objc private func toggleLyrics() { model.lyricsEnabled.toggle() }
    @objc private func syncNow() { model.syncNow() }
    @objc private func openLog() { model.openLog() }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
