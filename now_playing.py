#!/usr/bin/python3
"""Sync the track currently playing in Apple Music (or Spotify) to your Slack and/or GitHub status.

Usage:
    now_playing.py                 Sync once (launchd runs this every 20s, and the menu bar app on track change)
    now_playing.py slack-app CLIENT_ID [TEAM_ID]   Use your Slack app (TEAM_ID picks the workspace)
    now_playing.py slack-app --team TEAM_ID        Just pick the workspace (e.g. for slack-tab)
    now_playing.py login           Sign in with Slack (opens browser) and store your token in Keychain
    now_playing.py logout          Clear your Slack status and remove your token from Keychain
    now_playing.py outputs         Show which outputs are enabled
    now_playing.py enable NAME     Enable an output (slack, slack-tab, github)
    now_playing.py disable NAME    Disable an output (clears the status it set)
    now_playing.py overwrite on|off   Replace a status you set while music plays, restoring it after

Stdlib only, Python 3.9+ (the system /usr/bin/python3 is fine).
"""
import base64
import datetime
import hashlib
import html
import http.server
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

# --- Slack app: create your own from slack-app-manifest.json (see the README), then run
#   now_playing.py slack-app CLIENT_ID [TEAM_ID]
# The client ID is public, and PKCE means there's no secret. Both live in config.json under "slack".
REDIRECT_PORT = 8977
REDIRECT_URI = f"http://localhost:{REDIRECT_PORT}/callback"
USER_SCOPES = "users.profile:read,users.profile:write"

EMOJI = ":notes:"  # 🎶
EXPIRE_SECONDS = 10 * 60  # statuses self-clear if this Mac sleeps / script stops
SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/now-playing")
STATE_FILE = os.path.join(SUPPORT_DIR, "state.json")    # also read by the menu bar app
CONFIG_FILE = os.path.join(SUPPORT_DIR, "config.json")
KEYCHAIN_SERVICE = "now-playing-slack"
PLAYERS = ["Music", "Spotify"]
GH_PATHS = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
DEFAULT_OUTPUTS = []


def log(msg):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


def osascript(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def notify(msg):
    try:
        osascript(f'display notification {json.dumps(msg)} with title "Now Playing"')
    except RuntimeError:
        pass


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)  # atomic, so the menu bar app never reads a half-written file


def slack_config():
    return read_json(CONFIG_FILE, {}).get("slack", {})


def slack_client_id():
    cid = slack_config().get("client_id")
    if not cid:
        raise AuthError("no Slack app set up — run now_playing.py slack-app CLIENT_ID (see the README)")
    return cid


def enabled_outputs():
    return read_json(CONFIG_FILE, {}).get("outputs", DEFAULT_OUTPUTS)


# --- Now playing ---------------------------------------------------------------------------

def now_playing():
    """Return 'Title — Artist' for the first player that is actively playing, else None."""
    for app in PLAYERS:
        # Skip players that aren't running: we never launch them, and AppleScript can't even
        # compile `tell application "Spotify"` on a Mac without Spotify installed.
        if subprocess.run(["pgrep", "-xq", app]).returncode != 0:
            continue
        script = f'''
        if application "{app}" is running then
            tell application "{app}"
                if player state is playing then
                    return (name of current track) & "\\n" & (artist of current track)
                end if
            end tell
        end if
        return ""
        '''
        try:
            out = osascript(script)
        except RuntimeError as e:
            log(f"{app}: {e}")
            continue
        if out:
            title, _, artist = out.partition("\n")
            return f"{title} — {artist}" if artist else title
    return None


def truncate(text, limit):
    return text if len(text) <= limit else text[: limit - 1] + "…"


# --- Keychain ------------------------------------------------------------------------------

class AuthError(Exception):
    pass


def keychain_read():
    r = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return None
    raw = r.stdout.strip()
    if not raw.startswith("{"):  # a plain pasted xoxp- token
        return {"access_token": raw}
    return json.loads(raw)


def keychain_write(creds):
    # Feed the command via `security -i` on stdin (hex-encoded) so the token never appears in argv / ps.
    hexpw = json.dumps(creds).encode().hex()
    cmd = f"add-generic-password -U -a {os.environ.get('USER', 'me')} -s {KEYCHAIN_SERVICE} -X {hexpw}\n"
    r = subprocess.run(["security", "-i"], input=cmd, capture_output=True, text=True)
    if r.returncode != 0 or "error" in r.stderr.lower():
        raise RuntimeError(f"Keychain write failed: {r.stderr.strip()}")


def keychain_delete():
    subprocess.run(["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE], capture_output=True)


# --- Outputs -------------------------------------------------------------------------------
# Each output exposes: name, max_len, get() -> (emoji, text), set(text, expires_at), clear().

class Slack:
    name = "slack"
    max_len = 100

    def token(self):
        creds = keychain_read()
        if not creds:
            raise AuthError("not signed in — run ./install.sh login")
        # Rotating tokens: refresh a few minutes before expiry.
        if creds.get("expires_at") and time.time() > creds["expires_at"] - 300:
            if not creds.get("refresh_token"):
                raise AuthError("token expired — run ./install.sh login")
            try:
                body = oauth_access({"grant_type": "refresh_token", "refresh_token": creds["refresh_token"]})
            except RuntimeError as e:
                raise AuthError(f"token refresh failed ({e}) — run ./install.sh login")
            new = creds_from_oauth(body)
            new["user_id"] = new.get("user_id") or creds.get("user_id")
            new.setdefault("refresh_token", creds["refresh_token"])
            keychain_write(new)
            creds = new
        return creds["access_token"]

    def call(self, method, payload=None):
        req = urllib.request.Request(
            f"https://slack.com/api/{method}",
            data=json.dumps(payload).encode() if payload is not None else None,
            headers={"Authorization": f"Bearer {self.token()}", "Content-Type": "application/json; charset=utf-8"},
            method="POST" if payload is not None else "GET",
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.load(resp)
        if not body.get("ok"):
            err = body.get("error")
            if err in ("invalid_auth", "token_expired", "token_revoked", "account_inactive", "not_authed"):
                raise AuthError(f"Slack rejected the token ({err}) — run ./install.sh login")
            raise RuntimeError(f"{method}: {err}")
        return body

    def snapshot(self):
        p = self.call("users.profile.get")["profile"]
        return {"emoji": p.get("status_emoji") or "", "text": p.get("status_text") or "",
                "expires": int(p.get("status_expiration") or 0)}

    def put(self, emoji, text, expires_at):
        self.call("users.profile.set", {"profile": {
            "status_text": text, "status_emoji": emoji, "status_expiration": expires_at}})


class GitHub:
    """Uses the gh CLI's token, which needs the `user` scope: gh auth refresh -h github.com -s user"""
    name = "github"
    max_len = 80

    def token(self):
        gh = next((p for p in GH_PATHS if os.path.exists(p)), None)
        if not gh:
            raise AuthError("gh CLI not found — brew install gh")
        r = subprocess.run([gh, "auth", "token", "-h", "github.com"], capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            raise AuthError("gh not signed in — run ./install.sh enable github")
        return r.stdout.strip()

    def graphql(self, query, variables=None):
        req = urllib.request.Request(
            "https://api.github.com/graphql",
            data=json.dumps({"query": query, "variables": variables or {}}).encode(),
            headers={"Authorization": f"Bearer {self.token()}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise AuthError("GitHub rejected the token — run ./install.sh enable github")
            raise
        if body.get("errors"):
            msg = body["errors"][0].get("message", "")
            if "scope" in msg.lower():
                raise AuthError("gh token lacks the `user` scope — run ./install.sh enable github")
            raise RuntimeError(f"GitHub: {msg}")
        return body["data"]

    def snapshot(self):
        s = self.graphql("query { viewer { status { emoji message expiresAt } } }")["viewer"]["status"] or {}
        exp = s.get("expiresAt")
        exp = int(datetime.datetime.fromisoformat(exp.replace("Z", "+00:00")).timestamp()) if exp else 0
        return {"emoji": s.get("emoji") or "", "text": s.get("message") or "", "expires": exp}

    def put(self, emoji, text, expires_at):
        status = {}  # an empty status clears it
        if emoji or text:
            status = {"emoji": emoji, "message": text}
            if expires_at:
                status["expiresAt"] = datetime.datetime.fromtimestamp(expires_at, datetime.timezone.utc).isoformat()
        self.graphql(
            "mutation($s: ChangeUserStatusInput!) { changeUserStatus(input: $s) { clientMutationId } }",
            {"s": status},
        )


class SlackTab:
    """Sets your Slack status through your own signed-in Slack tab in Google Chrome, for when the
    Now Playing Slack app isn't approved. The JavaScript runs inside that tab and calls the same API
    the Slack web client uses, so your session token never leaves the page.

    Needs: a Slack tab open in Chrome (app.slack.com/client/...), and Chrome's
    View → Developer → Allow JavaScript from Apple Events turned on.
    """
    name = "slack-tab"
    max_len = 100
    TAB_PREFIX = "https://app.slack.com/client/"

    # Runs in the Slack tab. Starts the API call and parks the (trimmed) response on window.__np
    # for poll() to collect; execute javascript can't wait for a promise itself.
    START_JS = """(function(){
      var id = %(id)s, method = %(method)s, params = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(%(params)s), function(c){ return c.charCodeAt(0); })));
      window.__np = window.__np || {};
      var done = function(o){ window.__np[id] = JSON.stringify(o); };
      try {
        var teams = JSON.parse(localStorage.getItem('localConfig_v2') || '{}').teams || {};
        var ids = Object.keys(teams);
        var team = %(team)s ? teams[%(team)s] : (ids.length === 1 ? teams[ids[0]] : null);
        if (!team && !%(team)s && ids.length > 1) { done({ok: false, error: 'multiple_workspaces'}); return 'started'; }
        if (!team || !team.token) { done({ok: false, error: 'not_signed_in_in_tab'}); return 'started'; }
        var body = new FormData();
        body.append('token', team.token);
        Object.keys(params).forEach(function(k){ body.append(k, params[k]); });
        // Same-origin /api/ (a call to the workspace domain is blocked by CORS).
        fetch('/api/' + method, {method: 'POST', body: body, credentials: 'include'})
          .then(function(r){ return r.json(); })
          .then(function(j){
            var p = j.profile || {};
            done({ok: !!j.ok, error: j.error, status_emoji: p.status_emoji, status_text: p.status_text,
                  status_expiration: p.status_expiration});
          })
          .catch(function(e){ done({ok: false, error: 'fetch: ' + e}); });
      } catch (e) { done({ok: false, error: 'js: ' + e.message}); }
      return 'started';
    })()"""
    POLL_JS = "(function(){var v=(window.__np||{})[%(id)s]; if(v){delete window.__np[%(id)s];} return v||'';})()"

    # Runs the JavaScript in the first Slack tab. argv avoids any AppleScript string escaping.
    APPLESCRIPT = f'''
    on run argv
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t starts with "{TAB_PREFIX}" then return execute t javascript (item 1 of argv)
                end repeat
            end repeat
        end tell
        return "NO_TAB"
    end run
    '''

    def run_js(self, js):
        # Never launch Chrome: `tell application` would open it.
        if subprocess.run(["pgrep", "-xq", "Google Chrome"]).returncode != 0:
            raise AuthError("Chrome isn't running — open Slack in a Chrome tab")
        r = subprocess.run(["osascript", "-e", self.APPLESCRIPT, js], capture_output=True, text=True)
        if r.returncode != 0:
            err = r.stderr.strip()
            if "Apple Events" in err or "AppleScript is turned off" in err:
                raise AuthError("turn on Chrome → View → Developer → Allow JavaScript from Apple Events")
            if "-1743" in err or "Not authorized" in err:
                raise AuthError("allow Now Playing to control Chrome: System Settings → Privacy & Security → Automation")
            raise RuntimeError(f"Chrome: {err}")
        out = r.stdout.strip()
        if out == "NO_TAB":
            raise AuthError("no Slack tab open in Chrome — open app.slack.com and keep the tab")
        return out

    def call(self, method, params=None):
        call_id = secrets.token_hex(8)
        encoded = base64.b64encode(json.dumps(params or {}).encode()).decode()  # ASCII-only in the JS
        self.run_js(self.START_JS % {
            "id": json.dumps(call_id), "method": json.dumps(method),
            "params": json.dumps(encoded), "team": json.dumps(slack_config().get("team_id"))})
        deadline = time.time() + 10
        while time.time() < deadline:
            time.sleep(0.25)
            out = self.run_js(self.POLL_JS % {"id": json.dumps(call_id)})
            if out and out != "missing value":
                body = json.loads(out)
                if not body.get("ok"):
                    err = body.get("error")
                    if err == "multiple_workspaces":
                        raise AuthError("Chrome is signed in to several Slack workspaces — run now_playing.py slack-app --team TEAM_ID")
                    if err in ("not_signed_in_in_tab", "invalid_auth", "not_authed", "account_inactive"):
                        raise AuthError(f"Slack tab isn't signed in ({err}) — sign in at app.slack.com in Chrome")
                    raise RuntimeError(f"{method}: {err}")
                return body
        raise RuntimeError(f"{method}: no response from the Slack tab within 10s")

    def snapshot(self):
        b = self.call("users.profile.get")
        return {"emoji": b.get("status_emoji") or "", "text": b.get("status_text") or "",
                "expires": int(b.get("status_expiration") or 0)}

    def put(self, emoji, text, expires_at):
        self.call("users.profile.set", {"profile": json.dumps({
            "status_text": text, "status_emoji": emoji, "status_expiration": expires_at})})


OUTPUTS = {o.name: o for o in (Slack(), SlackTab(), GitHub())}


def overwrite_enabled():
    return bool(read_json(CONFIG_FILE, {}).get("overwrite", False))


def still_valid(status, now):
    return bool(status) and (status["emoji"] or status["text"]) and (not status["expires"] or status["expires"] > now)


def update_output(out, text, st, now, overwrite=False):
    """Bring one output in line with `text` (None = nothing playing). Returns the output's new state.

    By default, never overwrites or clears a status the user set by hand: we only touch the status
    if it's empty, or it's still exactly the one we last set.

    With overwrite on, a status you set by hand is saved ("prev") and replaced while music plays,
    then put back when the music stops, unless it would have expired by then.
    """
    prev = st.get("prev")
    if text:
        text = truncate(text, out.max_len)
        # Skip the API when nothing changed, but renew halfway to expiry so it doesn't lapse mid-song.
        if text == st.get("text") and now < st.get("expires", 0) - EXPIRE_SECONDS // 2:
            return st
        cur = out.snapshot()
        if st.get("text"):
            ours = (cur["emoji"], cur["text"]) == (EMOJI, st["text"])
        else:
            ours = cur["emoji"] == EMOJI  # left over from an earlier run
        if (cur["emoji"] or cur["text"]) and not ours:
            if not overwrite:
                if st.get("text"):
                    log(f"{out.name}: status changed by hand; pausing until it's cleared.")
                return {"note": "paused — you set a status"}
            prev = cur
            log(f"{out.name}: saving your status ({cur['emoji']} {cur['text']}) to restore when the music stops")
        out.put(EMOJI, text, now + EXPIRE_SECONDS)
        log(f"{out.name}: set {text}")
        new = {"text": text, "expires": now + EXPIRE_SECONDS, "note": "showing"}
        if prev:
            new["prev"] = prev
        return new
    if st.get("text"):
        cur = out.snapshot()
        ours = (cur["emoji"], cur["text"]) == (EMOJI, st["text"])
        lapsed = not (cur["emoji"] or cur["text"])  # ours expired, e.g. while the Mac slept
        if ours or lapsed:
            if still_valid(prev, now):
                out.put(prev["emoji"], prev["text"], prev["expires"])
                log(f"{out.name}: restored your status ({prev['emoji']} {prev['text']})")
            elif ours:
                out.put("", "", 0)
                log(f"{out.name}: cleared (nothing playing)")
    return {"note": "idle"}


def sync():
    state = read_json(STATE_FILE, {})
    track = now_playing()
    now = int(time.time())
    outs = state.get("outputs", {})
    overwrite = overwrite_enabled()
    new_outs = {}
    for name in enabled_outputs():
        out, st = OUTPUTS.get(name), outs.get(name, {})
        if not out:
            continue
        try:
            new_outs[name] = update_output(out, track, st, now, overwrite)
        except AuthError as e:
            log(f"{name}: {e}")
            if not st.get("auth_notified"):  # notify once, not every 20s
                notify(f"{name.capitalize()}: {e}")
            new_outs[name] = {**st, "note": f"error — {e}", "auth_notified": True}
        except Exception as e:
            log(f"{name}: error: {e}")
            new_outs[name] = {**st, "note": f"error — {e}"}
    write_json(STATE_FILE, {"track": track, "updated": now, "outputs": new_outs})


# --- Slack sign-in (OAuth v2 + PKCE, loopback redirect) ------------------------------------

def creds_from_oauth(body):
    """Normalize an oauth.v2.access response (initial exchange or refresh) to our stored shape."""
    data = body.get("authed_user") if body.get("authed_user", {}).get("access_token") else body
    creds = {"access_token": data["access_token"], "user_id": data.get("id") or body.get("user_id")}
    if data.get("refresh_token"):
        creds["refresh_token"] = data["refresh_token"]
    if data.get("expires_in"):
        creds["expires_at"] = int(time.time()) + int(data["expires_in"])
    return creds


def oauth_access(params):
    data = urllib.parse.urlencode({"client_id": slack_client_id(), **params}).encode()
    with urllib.request.urlopen("https://slack.com/api/oauth.v2.access", data=data, timeout=15) as resp:
        body = json.load(resp)
    if not body.get("ok"):
        raise RuntimeError(body.get("error"))
    return body


def login():
    try:
        client_id = slack_client_id()
    except AuthError as e:
        sys.exit(str(e))
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            if url.path != "/callback":
                self.send_error(404)
                return
            q = dict(urllib.parse.parse_qsl(url.query))
            if q.get("state") != state:
                result["error"] = "state mismatch"
            elif "error" in q:
                result["error"] = q["error"]
            else:
                result["code"] = q.get("code")
            msg = "Signed in. You can close this tab." if "code" in result else f"Sign-in failed: {html.escape(result['error'])}"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(f"<html><body style='font:16px -apple-system;padding:3em'>{msg}</body></html>".encode())

        def log_message(self, *args):
            pass

    try:
        server = http.server.HTTPServer(("127.0.0.1", REDIRECT_PORT), Handler)
    except OSError:
        sys.exit(f"Port {REDIRECT_PORT} is in use; close whatever is using it and retry.")
    server.timeout = 5

    params = {
        "client_id": client_id,
        "user_scope": USER_SCOPES,
        "redirect_uri": REDIRECT_URI,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    if slack_config().get("team_id"):
        params["team"] = slack_config()["team_id"]  # skip Slack's workspace picker
    authorize_url = "https://slack.com/oauth/v2/authorize?" + urllib.parse.urlencode(params)
    print("Opening Slack in your browser to sign in…")
    print(f"If it doesn't open, visit:\n  {authorize_url}\n")
    webbrowser.open(authorize_url)

    deadline = time.time() + 300
    while not result and time.time() < deadline:
        server.handle_request()
    server.server_close()

    if "code" not in result:
        sys.exit(f"Sign-in failed: {result.get('error', 'timed out')}")
    body = oauth_access({
        "grant_type": "authorization_code",
        "code": result["code"],
        "code_verifier": verifier,
        "redirect_uri": REDIRECT_URI,
    })
    keychain_write(creds_from_oauth(body))
    reset_output_state("slack")
    print("Signed in to Slack. Token saved to Keychain.")


# --- Output management ---------------------------------------------------------------------

def reset_output_state(name):
    state = read_json(STATE_FILE, {})
    state.setdefault("outputs", {}).pop(name, None)
    write_json(STATE_FILE, state)


def clear_output(name):
    """Clear the status we set on `name`, if it's still ours."""
    st = read_json(STATE_FILE, {}).get("outputs", {}).get(name, {})
    if st.get("text"):
        try:
            update_output(OUTPUTS[name], None, st, int(time.time()), overwrite_enabled())
        except Exception as e:
            log(f"Couldn't clear {name} status: {e}")
    reset_output_state(name)


def set_enabled(name, on):
    if name not in OUTPUTS:
        sys.exit(f"Unknown output '{name}'. Choose from: {', '.join(OUTPUTS)}")
    outs = [o for o in enabled_outputs() if o != name] + ([name] if on else [])
    if not on:
        clear_output(name)
    write_json(CONFIG_FILE, {**read_json(CONFIG_FILE, {}), "outputs": outs})
    print(f"{name}: {'enabled' if on else 'disabled'}. Enabled outputs: {', '.join(outs) or 'none'}")


def main():
    args = sys.argv[1:] or ["sync"]
    cmd = args[0]
    if cmd == "sync":
        sync()
    elif cmd == "login":
        login()
    elif cmd == "logout":
        clear_output("slack")
        keychain_delete()
        print("Signed out of Slack.")
    elif cmd == "outputs":
        print("Enabled outputs:", ", ".join(enabled_outputs()) or "none")
    elif cmd == "slack-app" and len(args) >= 2:
        cfg = read_json(CONFIG_FILE, {})
        slack = dict(cfg.get("slack", {}))
        rest = args[1:]
        if rest[0] == "--team" and len(rest) == 2:
            slack["team_id"] = rest[1]
        elif len(rest) in (1, 2):
            slack["client_id"] = rest[0]
            if len(rest) == 2:
                slack["team_id"] = rest[1]
        else:
            sys.exit(__doc__)
        write_json(CONFIG_FILE, {**cfg, "slack": slack})
        print(f"Slack app: client ID {slack.get('client_id') or '(not set)'}, workspace {slack.get('team_id') or '(any)'}")
    elif cmd == "overwrite" and len(args) == 2 and args[1] in ("on", "off"):
        write_json(CONFIG_FILE, {**read_json(CONFIG_FILE, {}), "overwrite": args[1] == "on"})
        print(f"Overwrite your own statuses: {args[1]}")
    elif cmd in ("enable", "disable") and len(args) == 2:
        set_enabled(args[1], cmd == "enable")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
