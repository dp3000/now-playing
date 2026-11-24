# 🎶 Now Playing

Shows the track playing in Apple Music or Spotify on your Mac in:

- **Slack status**: `:notes: Song — Artist` (🎶)
- **GitHub status**: the same, on your profile, PRs and hovercards
- **Your menu bar**: instant. Click it for a **mini player** with artwork, play/pause/skip and optional **synced lyrics**
- **Your terminal**: `./lyrics.py`, big, high-contrast lyrics that fill gold as they're sung

Turn on whichever outputs you like. Each one:
- Leaves your own statuses alone by default. If you've set "In a meeting" or "OOO", it pauses until you clear it. Turn on [overwrite](#overwrite-your-own-statuses) to show the song anyway and get your status back when the music stops.
- Never launches Music or Spotify by itself.
- Expires its status after 10 minutes, so nothing sticks around if your Mac sleeps.
- Runs locally. Your Mac talks only to Slack and GitHub, and tokens stay in your Keychain.

## Install

Requires macOS. Uses the built-in `/usr/bin/python3`. The menu bar app needs Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/dp3000/now-playing.git ~/now-playing
cd ~/now-playing
./install.sh
```

No outputs are on until you [choose some](#choose-outputs).
The first time a song plays, macOS asks to let the script control **Music** (or Spotify). Click **OK**.
If you miss it: System Settings → Privacy & Security → Automation.

The background jobs run copies installed in `~/Library/Application Support/now-playing` (macOS blocks them from reading `~/Documents`), so rerun `./install.sh` after you `git pull`.

### Choose outputs

```bash
./install.sh enable github     # uses the GitHub CLI; grants it the `user` scope once
./install.sh enable slack      # needs your own Slack app (see below); signs you in
./install.sh disable slack     # e.g. while the Slack app is waiting for approval
./install.sh enable slack-tab  # Slack via a Chrome tab, no app approval needed (see below)
```

### Set up the Slack app

The `slack` output signs in through a Slack app you create once for your workspace:

1. Go to <https://api.slack.com/apps> → **Create New App** → **From a manifest**, pick your workspace, and paste `slack-app-manifest.json`.
2. Install it to your workspace. If your workspace requires admin approval, request it; use `slack-tab` meanwhile.
3. Copy the **Client ID** from *Basic Information*, and your workspace's team ID (the `T…` in `app.slack.com/client/T…/`), then run:

```bash
/usr/bin/python3 now_playing.py slack-app CLIENT_ID TEAM_ID   # TEAM_ID is optional
./install.sh enable slack
```

Everyone in the workspace can share one app. Each person signs in separately, so their token only works on their own profile.

### Slack without the app (`slack-tab`)

If you can't use a Slack app (or it's waiting for approval), `slack-tab` sets your status through your own signed-in Slack tab in Google Chrome instead. It runs a little JavaScript inside that tab that calls the same API Slack's web client uses, so your Slack session token never leaves the page. Use `slack` or `slack-tab`, not both.

It needs:
1. **Slack open in Chrome.** Sign in at <https://app.slack.com> and pin the tab. If Memory Saver is on, add `app.slack.com` to *Settings → Performance → Always keep these sites active*. The Slack desktop app doesn't count.
2. **Chrome → View → Developer → Allow JavaScript from Apple Events.** This is Chrome-wide: any app you've allowed to control Chrome (System Settings → Privacy & Security → Automation) can then run JavaScript in any of your tabs.
3. **The Automation prompt.** The first time it runs in the background, macOS asks to let it control **Google Chrome**. Click **OK**.

It never launches Chrome. If Chrome is closed or the tab is missing, it skips Slack and notifies you once. If Chrome is signed in to more than one Slack workspace, pick one with `now_playing.py slack-app --team TEAM_ID`.

Check that your workspace's policies allow this before you turn it on.

### Overwrite your own statuses

```bash
/usr/bin/python3 now_playing.py overwrite on    # or off (the default)
```

With overwrite on, a status you set by hand (or one an integration like Google Calendar set) is saved and replaced by the song while music plays. When the music stops, it's put back with its original expiry, unless it would have expired by then. If you change your status mid-song, the next track saves that one instead. This applies to every enabled output.

GitHub uses your existing `gh` login (`brew install gh && gh auth login`). Setting a status needs the `user` scope, which `enable github` adds with `gh auth refresh -s user`.

## Use

| | |
|---|---|
| Mini player | **Click** 🎶 for artwork, progress, previous / play-pause / next and lyrics (click a line to jump there). The first time, macOS asks to let **Now Playing** control Music. Click OK. |
| Lyrics window | Click the pop-out button in the mini player's footer, or choose **Pop Out Lyrics**, for a resizable window of large, high-contrast lyrics. The text resizes with the window and the sung part fills gold. A footer shows the album artwork, song info, playback controls and a **keep on top** pin. Full screen works too. |
| Menu | **Right-click** 🎶 (or use ⋯ in the mini player) for each output's status, **Show Lyrics**, **Pop Out Lyrics**, **Sync Status Now**, **Open Log** and **Quit**. Quit stays quit until next login or `./install.sh`. |
| Logs | `tail -f ~/Library/Logs/now-playing.log` |
| Sign in to Slack again | `./install.sh login` (you'll get a notification if needed) |
| Update | `git pull && ./install.sh` (rebuilds the menu bar app) |
| Uninstall | `./install.sh uninstall` (clears statuses, removes the Slack token and both background jobs) |

To change the emoji, expiry or which players are checked, edit the constants at the top of `now_playing.py`.

## Lyrics

Off by default. Turn them on with **Show Lyrics** in the mini player.

- Source: [LRCLIB](https://lrclib.net), a free community lyrics database (no account or API key). Each lookup sends the song's title, artist, album and length to lrclib.net. Results are cached in `~/Library/Caches/now-playing/lyrics`.
- Time-synced lyrics highlight and scroll with the song. Otherwise you get plain text, then any lyrics saved in your Music library.
- Lyrics are copyrighted and LRCLIB is user-contributed, so they're only shown on your own screen. They never go into your Slack or GitHub status.

## Lyrics in the terminal

```bash
./lyrics.py              # or: --size 2 (fixed size; 0 = normal text), --offset -0.5 (shift timing)
```

A full-window lyrics reader built for readability. The current lyric is in big, solid, bold letters: white, filling **gold** as it's sung. Upcoming lines are below in light grey and recent ones above in darker grey, all on solid black.

- **Size:** it uses the biggest size where every line fits the width, the tallest line fits the height, and a typical line leaves room for context. **+ / -** change it and **0** returns to automatic.
- **Lettering:** letters come from a built-in pixel font (`bigfont.py`). Solid cells are painted with the background colour, so there are no seams between rows or columns.
- **Fallback:** lyrics the font can't draw (e.g. Japanese) use normal text.
- **Keys:** **space** play/pause · **n/p** next/previous · **+/-** size (**0** auto) · **←/→** nudge the lyric timing by 0.2s · **q** quit.

Running it is your opt-in to lyrics lookups (same LRCLIB source and cache as the mini player). The first run asks to let your terminal control Music. Add `alias lyrics=~/path/to/now-playing/lyrics.py` to your `~/.zshrc` to run it from anywhere.

## What it can access

**Album artwork:** Music only provides artwork for songs in your library that include it. For streamed songs, the app looks up the album cover with Apple's public iTunes Search API, which sends the artist and album name.

**Slack:** the **Now Playing** app asks for `users.profile:read`, to avoid overwriting a status you set, and `users.profile:write`, to set and clear your status. It has no bot user and can't read messages, channels or files. Each person signs in separately, so their token only works on their own profile.

**Slack via Chrome tab:** it reads and sets only your own status (`users.profile.get` / `users.profile.set`) from inside your Slack tab. Only the status fields come back to the script.

**GitHub:** it uses your `gh` token. Of that token's access, it only uses the GraphQL `viewer.status` query and the `changeUserStatus` mutation.

## How it works

- **`now_playing.py`** runs every 20 seconds as a launchd agent (`com.$USER.now-playing`). It asks Music and Spotify, via AppleScript, what's playing, and updates each enabled output only when the track changes or a status needs renewing. It writes `~/Library/Application Support/now-playing/state.json`.
- **`menubar/`** is a small AppKit + SwiftUI menu bar app. `install.sh` compiles it into `NowPlaying.app` (ad-hoc signed, in the Application Support folder) and runs it as `com.$USER.now-playing-bar`. The menu bar title updates from Music's and Spotify's track-change notifications, and every change nudges the sync agent. The mini player uses AppleScript (`Players.swift`) for position, artwork and controls, but only while it's open and only for players that are already running. Lyrics come from `Lyrics.swift`. Rebuilding changes the app's signature, so macOS may ask for the Music permission again after an update.
- **Slack sign-in** uses OAuth v2 with PKCE and a loopback redirect (`http://localhost:8977/callback`). The repo holds no client secret, and the script refreshes rotating tokens automatically.
- **Settings** live in `~/Library/Application Support/now-playing/config.json` (`{"outputs": ["slack", "github"], "overwrite": false, "slack": {"client_id": "…", "team_id": "T…"}}`).

## Adding an output

To add an output, write a class in `now_playing.py` with `name`, `max_len`, `snapshot()` (returns `{"emoji", "text", "expires"}`) and `put(emoji, text, expires_at)` (empty emoji and text clear the status), then add it to `OUTPUTS`.

## License

[MIT](LICENSE)
