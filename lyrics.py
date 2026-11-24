#!/usr/bin/python3
"""Big, high-contrast lyrics for the song playing in Music or Spotify, in your terminal.

The current line is shown in large solid letters (white, filling gold as it's sung), with upcoming
lines below and recent ones above, sized to fill the window. Optimised for reading at a distance.

Usage:  ./lyrics.py [--size N] [--offset SECONDS]
        --size: 0 = normal text, 1-4 = big letters (default: the biggest that fits)
        --offset: shift lyric timing, e.g. -0.5 if lyrics run late
Keys:   space  play/pause      n / p  next / previous track      + / -  bigger / smaller (0 = auto)
        ← / →  lyrics earlier/later by 0.2s      q  quit

Lyrics come from LRCLIB (lrclib.net, a free community database): each lookup sends the song's
title, artist, album and length. Results share the menu bar app's cache. Stdlib only.
"""
import curses
import hashlib
import json
import locale
import math
import os
import re
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

import bigfont

FPS = 20
POLL_SECONDS = 1.0
LEAD = 0.3  # show each line slightly before it's sung
CACHE_DIR = os.path.expanduser("~/Library/Caches/now-playing/lyrics")  # shared with the menu bar app
APPLE_EPOCH = 978307200  # Swift's JSONEncoder stores dates as seconds since 2001-01-01
NOT_FOUND_RETRY = 24 * 3600
USER_AGENT = "now-playing/1.0 (personal macOS terminal lyrics viewer)"


# --- Player (JXA, so results come back as JSON) ----------------------------------------------

PLAYERS = ["Music", "Spotify"]


def jxa(script):
    r = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def running(app):
    return subprocess.run(["pgrep", "-xq", app]).returncode == 0


def snapshot():
    """Current track of the first playing player (else the first paused one), or None."""
    found = []
    for app in PLAYERS:
        if not running(app):  # never launch a player ourselves
            continue
        out = jxa(f"""
            const p = Application("{app}");
            if (p.playerState() === "stopped") {{ "null" }} else {{
                const t = p.currentTrack();
                JSON.stringify({{state: p.playerState(), title: t.name(), artist: t.artist(), album: t.album(),
                                duration: t.duration(), position: p.playerPosition()}});
            }}""")
        try:
            s = json.loads(out) if out else None
        except ValueError:
            s = None
        if s:
            s["player"] = app
            if app == "Spotify":
                s["duration"] = (s.get("duration") or 0) / 1000  # Spotify reports milliseconds
            s["read_at"] = time.monotonic()
            found.append(s)
    return next((s for s in found if s["state"] == "playing"), found[0] if found else None)


def control(app, action):
    js = {
        "playpause": "playpause()",
        "next": "nextTrack()",
        "previous": "backTrack()" if app == "Music" else "previousTrack()",
    }[action]
    if running(app):
        jxa(f'Application("{app}").{js}')


# --- Lyrics (same lookup + cache format as menubar/Lyrics.swift) ------------------------------

def lrclib(path, params):
    url = f"https://lrclib.net/api/{path}?" + urllib.parse.urlencode(params)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.load(resp)
    except (urllib.error.URLError, ValueError, OSError):
        return None


def has_content(hit):
    return bool(hit.get("instrumental") or hit.get("plainLyrics") or hit.get("syncedLyrics"))


def pick(hits, duration):
    """Prefer synced lyrics, then the closest duration; skip anything >8s off (another version)."""
    ok = [h for h in hits if has_content(h)
          and (duration <= 0 or abs((h.get("duration") or duration) - duration) <= 8)]
    ok.sort(key=lambda h: (0 if h.get("syncedLyrics") else 1, abs((h.get("duration") or 0) - duration)))
    return ok[0] if ok else None


def clean_title(title):
    title = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]", "", title)
    return re.sub(r"\s+-\s+.*$", "", title).strip()


def primary_artist(artist):
    return re.sub(r"(?i)\s*(,|&|\bfeat\.?|\bfeaturing\b|\bft\.?|\bwith\b|\bx\b).*$", "", artist).strip()


def cache_path(title, artist, album, duration):
    raw = "\n".join([title, artist, album, str(int(math.floor(duration + 0.5)))]).lower()
    return os.path.join(CACHE_DIR, hashlib.sha256(raw.encode()).hexdigest() + ".json")


def fetch_lyrics(title, artist, album, duration):
    path = cache_path(title, artist, album, duration)
    try:
        with open(path) as f:
            rec = json.load(f)
        if rec.get("plain") or rec.get("synced") or rec.get("instrumental") \
                or time.time() - APPLE_EPOCH - rec.get("fetched", 0) < NOT_FOUND_RETRY:
            return rec
    except (OSError, ValueError):
        pass

    hit = None
    if duration > 0:
        h = lrclib("get", {"track_name": title, "artist_name": artist, "album_name": album,
                           "duration": int(math.floor(duration + 0.5))})
        if isinstance(h, dict) and has_content(h):
            hit = h
    for t, a in [(title, artist), (clean_title(title), primary_artist(artist))]:
        if hit or not t:
            break
        hits = lrclib("search", {"track_name": t, "artist_name": a})
        if isinstance(hits, list):
            hit = pick(hits, duration)

    rec = {"plain": (hit or {}).get("plainLyrics"), "synced": (hit or {}).get("syncedLyrics"),
           "instrumental": bool((hit or {}).get("instrumental")), "fetched": time.time() - APPLE_EPOCH}
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(path + ".tmp", "w") as f:
            json.dump({k: v for k, v in rec.items() if v is not None}, f)
        os.replace(path + ".tmp", path)
    except OSError:
        pass
    return rec


LRC_TAG = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]")


def parse_lrc(lrc):
    lines = []
    for raw in lrc.splitlines():
        tags = list(LRC_TAG.finditer(raw))
        if not tags:
            continue
        text = raw[tags[-1].end():].strip()
        for m in tags:
            lines.append((int(m.group(1)) * 60 + float(m.group(2)), text))
    return sorted(lines, key=lambda l: l[0])


def lyric_lines(rec, duration):
    """-> (lines [(time, text)], kind) where kind is synced / approx / instrumental / none."""
    if rec.get("synced"):
        lines = parse_lrc(rec["synced"])
        if lines:
            return lines, "synced"
    if rec.get("plain"):
        # No timing: spread the lines evenly over the song so they still roll by.
        texts = [t.strip() for t in rec["plain"].splitlines()]
        texts = [t for t in texts if t] or [""]
        step = (duration or 180) / (len(texts) + 1)
        return [(step * (i + 0.5), t) for i, t in enumerate(texts)], "approx"
    return [], "instrumental" if rec.get("instrumental") else "none"


# --- Text helpers ---------------------------------------------------------------------------

def cell_width(ch):
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def text_width(s):
    return sum(cell_width(c) for c in s)


def wrap(text, width):
    rows, row = [], ""
    for word in text.split():
        if row and text_width(row) + 1 + text_width(word) > width:
            rows.append(row)
            row = word
        else:
            row = f"{row} {word}" if row else word
    return rows + [row] if row else rows or [""]


def fmt_time(s):
    s = max(int(s), 0)
    return f"{s // 60}:{s % 60:02d}"


# --- Viewer ---------------------------------------------------------------------------------
#
# Size: big letters (bigfont.py, bold) at the largest scale where every line fits the width, the
# tallest line fits the height, and a typical line leaves room for context; +/- change it, 0 =
# automatic. Scale 0 is normal terminal text (also used when the font can't draw the lyrics).
#
# Letters are drawn seamlessly: a fully-on cell is painted with its *background* colour (a space),
# which fills the whole cell with no gaps between rows or columns; only half-filled edge cells
# use ▀ / ▄ characters.

TYPICAL_SHARE = 0.6  # a typical (90th percentile) line may use this much of the height
MAX_SCALE = 4
BG = 16              # pure black

# 256-colour palette: role -> colour
PALETTE = {"sung": 220, "current": 231, "next": 252, "near": 246, "far": 241, "past": 243, "footer": 245}
# 8-colour fallback: role -> (colour, extra attribute)
BASIC = {"sung": (curses.COLOR_YELLOW, curses.A_BOLD), "current": (curses.COLOR_WHITE, curses.A_BOLD),
         "next": (curses.COLOR_WHITE, 0), "near": (curses.COLOR_WHITE, curses.A_DIM),
         "far": (curses.COLOR_WHITE, curses.A_DIM), "past": (curses.COLOR_WHITE, curses.A_DIM),
         "footer": (curses.COLOR_WHITE, curses.A_DIM)}


class Viewer:
    def __init__(self, scr, offset=0.0, scale=None):
        self.scr = scr
        self.offset = offset
        self.manual_scale = scale  # None = automatic
        self.scale = 0
        self.scale_key = None
        self.render_cache = {}
        self.lock = threading.Lock()
        self.snap = None
        self.track_key = None
        self.lyrics = ([], "loading")
        self.stop = threading.Event()
        self.setup_colors()
        self.h, self.w = self.scr.getmaxyx()

    def setup_colors(self):
        """Per role: a text pair (colour on black) and a fill pair (colour on colour)."""
        curses.start_color()
        rich = curses.COLORS >= 256
        bg = BG if rich else curses.COLOR_BLACK
        self.text, self.fill = {}, {}
        for n, role in enumerate(PALETTE, start=1):
            color, extra = (PALETTE[role], 0) if rich else BASIC[role]
            curses.init_pair(n, color, bg)
            curses.init_pair(n + 20, color, color)
            self.text[role] = curses.color_pair(n) | extra
            self.fill[role] = curses.color_pair(n + 20)
        curses.init_pair(40, bg, bg)
        self.scr.bkgd(" ", curses.color_pair(40))  # solid black everywhere

    # -- background threads --

    def poll_loop(self):
        while not self.stop.is_set():
            s = snapshot()
            key = s and (s["player"], s["title"], s["artist"], s["album"])
            with self.lock:
                self.snap = s
                changed = key != self.track_key
                if changed:
                    self.track_key = key
                    self.lyrics = ([], "loading" if s else "none")
            if changed and s:
                threading.Thread(target=self.load_lyrics, args=(s, key), daemon=True).start()
            self.stop.wait(POLL_SECONDS)

    def load_lyrics(self, s, key):
        rec = fetch_lyrics(s["title"], s["artist"], s["album"], s["duration"])
        lines = lyric_lines(rec, s["duration"])
        with self.lock:
            if self.track_key == key:
                self.lyrics = lines
                self.scale_key = None

    def act(self, action):
        s = self.snap
        if s:
            threading.Thread(target=lambda: (control(s["player"], action), self.force_poll()), daemon=True).start()

    def force_poll(self):
        s = snapshot()
        with self.lock:
            if s and self.snap and s["title"] == self.snap["title"]:
                self.snap = s

    # -- sizing + layout --

    def width_avail(self):
        return max(self.w - 4, 10)

    def line_gap(self, scale):
        # clearly wider than the 1-row gap between wrapped rows of the same lyric, so each
        # lyric reads as one block
        return (2 * scale + 1) if scale else (1 if self.h - 1 >= 20 else 0)

    def choose_scale(self, lines):
        """Largest scale where every line fits the width, the tallest fits the height, and a
        typical line leaves room for context. Big text wins over showing many lines."""
        key = (id(lines), self.w, self.h, self.manual_scale)
        if key == self.scale_key:
            return self.scale
        self.scale_key = key
        texts = [t for _, t in lines if t.strip()]
        width, rows_avail = self.width_avail(), self.h - 1
        best = 0
        if texts and sum(bigfont.coverage(t) for t in texts) / len(texts) >= 0.9:
            for s in range(MAX_SCALE, 0, -1):
                if not all(bigfont.fits(t, s, width, bold=True) for t in texts):
                    continue
                heights = sorted(bigfont.height(t, s, width, bold=True) for t in texts)
                typical = heights[int(len(heights) * 0.9) - 1 if len(heights) > 1 else 0]
                if heights[-1] <= rows_avail and typical <= rows_avail * TYPICAL_SHARE:
                    best = s
                    break
        if self.manual_scale is not None:
            best = self.manual_scale
        if best != self.scale:
            self.scale = best
            self.render_cache = {}
        return self.scale

    def render(self, text):
        """-> (rows, n): rows of (width, [(dx, ch, k)]); k = source char index, n = char count."""
        key = (text, self.scale, self.w)
        if key not in self.render_cache:
            width = self.width_avail()
            if self.scale:
                self.render_cache[key] = bigfont.render(text, self.scale, width, bold=True)
            else:
                text = " ".join(text.split()) or "♪"
                rows, k = [], 0
                for row in wrap(text, width):
                    cells, dx = [], 0
                    for ch in row:
                        cells.append((dx, ch, k))
                        dx += cell_width(ch)
                        k += 1
                    k += 1
                    rows.append((dx, cells))
                self.render_cache[key] = (rows, len(text))
        return self.render_cache[key]

    def layout(self, lines, cur):
        """-> [(line index, [(y, x, ch, k)], n)] filling the screen around the current line."""
        rows_avail = self.h - 1  # footer
        gap = self.line_gap(self.scale)
        out = []

        def place(i, top, rows, n):
            cells = []
            for r, (width, row) in enumerate(rows):
                x0 = max((self.w - width) // 2, 0)
                cells += [(top + r, x0 + dx, ch, k) for dx, ch, k in row]
            out.append((i, cells, n))

        anchor = max(cur, 0)
        rows, n = self.render(lines[anchor][1])
        focal = max(0, min(int(rows_avail * 0.35), rows_avail - len(rows)))
        place(anchor, focal, rows, n)
        y, i = focal + len(rows) + gap, anchor + 1
        while i < len(lines):  # upcoming, below
            rows, n = self.render(lines[i][1])
            if y + len(rows) > rows_avail:
                break
            place(i, y, rows, n)
            y, i = y + len(rows) + gap, i + 1
        y, i = focal - gap, anchor - 1
        while i >= 0:  # recent, above
            rows, n = self.render(lines[i][1])
            if y - len(rows) < 0:
                break
            place(i, y - len(rows), rows, n)
            y, i = y - len(rows) - gap, i - 1
        return out

    # -- drawing --

    def role(self, i, cur):
        d = i - cur
        if d == 0:
            return "current"
        if d < 0:
            return "past"
        return "next" if d == 1 else "near" if d <= 3 else "far"

    def draw_line(self, cells, base, sung):
        """Draw one line's cells, batching same-style horizontal runs into one addstr.
        Blank cells are skipped so the black background shows through."""
        bold = curses.A_BOLD if base == "current" and not self.scale else 0
        run = None  # [y, x, next x, text, attr]
        for (y, x, ch, k) in cells:
            if ch == " ":
                continue
            role = "sung" if k < sung else base
            out, a = (" ", self.fill[role]) if ch == "█" else (ch, self.text[role] | bold)
            if run and run[0] == y and run[2] == x and run[4] == a:
                run[2] += cell_width(out)
                run[3] += out
            else:
                if run:
                    self.put(run[0], run[1], run[3], run[4])
                run = [y, x, x + cell_width(out), out, a]
        if run:
            self.put(run[0], run[1], run[3], run[4])

    def put(self, y, x, s, attr):
        if s and 0 <= y < self.h - 1 and 0 <= x < self.w:
            try:
                self.scr.addstr(y, x, s[: self.w - x], attr)
            except curses.error:
                pass

    def draw_footer(self, s, pos):
        if s:
            state = "▶" if s["state"] == "playing" else "❚❚"
            sync = " · lyrics unsynced" if self.lyrics[1] == "approx" else ""
            off = f" · offset {self.offset:+.1f}s" if self.offset else ""
            size = (f"{self.scale}x" if self.scale else "text") + ("" if self.manual_scale is not None else " auto")
            left = (f" {state} {s['title']} — {s['artist']}  {fmt_time(pos)} / {fmt_time(s['duration'])}"
                    f"{sync}{off} · size {size}")
        else:
            left = " start something in Music or Spotify"
        keys = "space pause · n/p skip · +/- size · ←/→ sync · q quit "
        line = left + " " * max(self.w - text_width(left) - len(keys), 1) + keys
        try:
            self.scr.addstr(self.h - 1, 0, line[: self.w - 1], self.text["footer"])
        except curses.error:
            pass

    def frame(self, now):
        s = self.snap
        playing = bool(s and s["state"] == "playing")
        pos = 0.0
        if s:
            pos = s["position"] + (now - s["read_at"] if playing else 0)
            pos = min(pos, s["duration"] or pos)

        self.scr.erase()
        lines, kind = self.lyrics
        if lines:
            self.choose_scale(lines)
            t = pos + self.offset + LEAD
            cur = max((i for i, (start, _) in enumerate(lines) if start <= t), default=-1)
            frac = 0.0
            if cur >= 0:
                start = lines[cur][0]
                end = lines[cur + 1][0] if cur + 1 < len(lines) else start + 5
                frac = min(max((t - start) / max(end - start, 0.5), 0), 1)
            for i, cells, n in self.layout(lines, cur):
                self.draw_line(cells, self.role(i, cur), frac * n if i == cur else -1)
        else:
            msg = "nothing playing" if s is None else {
                "loading": "loading lyrics…", "instrumental": "♪ instrumental ♪"}.get(kind, "no lyrics found")
            self.put((self.h - 1) // 2, max((self.w - text_width(msg)) // 2, 0), msg, self.text["near"])
        self.draw_footer(s, pos)

    def set_scale(self, scale):
        self.manual_scale = None if scale is None else max(0, min(scale, MAX_SCALE))
        self.scale_key = None

    def run(self):
        curses.curs_set(0)
        self.scr.nodelay(True)
        threading.Thread(target=self.poll_loop, daemon=True).start()
        while True:
            key = self.scr.getch()
            if key in (ord("q"), ord("Q"), 27):
                break
            with self.lock:
                if key == curses.KEY_RESIZE:
                    self.h, self.w = self.scr.getmaxyx()
                    self.scale_key = None
                    self.render_cache = {}
                elif key in (ord("+"), ord("=")):
                    self.set_scale(self.scale + 1)
                elif key in (ord("-"), ord("_")):
                    self.set_scale(self.scale - 1)
                elif key == ord("0"):
                    self.set_scale(None)
            if key == ord(" "):
                self.act("playpause")
            elif key in (ord("n"), ord("N")):
                self.act("next")
            elif key in (ord("p"), ord("P")):
                self.act("previous")
            elif key == curses.KEY_LEFT:
                self.offset = round(self.offset - 0.2, 1)
            elif key == curses.KEY_RIGHT:
                self.offset = round(self.offset + 0.2, 1)

            now = time.monotonic()
            with self.lock:
                self.frame(now)
            self.scr.refresh()
            time.sleep(max(1 / FPS - (time.monotonic() - now), 0.005))
        self.stop.set()


def main():
    args = sys.argv[1:]
    if "-h" in args or "--help" in args:
        sys.exit(__doc__)

    def number(flag, kind):
        try:
            return kind(args[args.index(flag) + 1])
        except (IndexError, ValueError):
            sys.exit(f"{flag} needs a number, e.g. {flag} 2")

    offset = number("--offset", float) if "--offset" in args else 0.0
    scale = number("--size", int) if "--size" in args else None
    locale.setlocale(locale.LC_ALL, "")
    os.environ.setdefault("ESCDELAY", "25")  # make Esc quit promptly
    curses.wrapper(lambda scr: Viewer(scr, offset=offset, scale=scale).run())


if __name__ == "__main__":
    main()
