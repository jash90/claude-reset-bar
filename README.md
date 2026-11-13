<img src="assets/icon_128.png" align="right" width="128" alt="">

# ClaudeResetBar

A menu bar / system tray icon that shows your Claude usage limits and **notifies you the moment a limit resets** — so you stop guessing when you can get back to work.

- **Nothing to configure.** It reads the token Claude Code already stored on your machine.
- **Several accounts at once.** Every Claude Code login on the machine, plus any number of extra accounts added by sessionKey or OAuth token, each on its own row.
- **macOS, Windows, Linux.** One binary per system, no runtime, no installer.

```
● you@example.com
   5h  ■■■■■□□□□□□□  39%   resets in 15m (Mon 11:29)
   7d  ■■■□□□□□□□□□  23%   resets in 5d 13h (Sun 00:59)
   7d  ■□□□□□□□□□□□  4%    Opus only
```

A third kind of row shows up when your plan caps a single model separately — `Opus only`, `Fable only`, whatever the API reports. Those come from the scoped weekly entries, so a new model tier appears without the app needing a change. If your account has no per-model cap, the row is simply absent.

Under those, an account read through a Claude Code login lists the limit resets it still holds, one line per kind: `1 x full reset`, `2 x fable reset`. A full reset clears the weekly limit; one named after a model clears that model's weekly cap. Spent and expired resets are not shown, and an account added with a `setup-token` token shows none, because the usage endpoint that lists them refuses such a token.

Each window carries a fill gauge alongside the number, so you can judge how much is left without reading digits, and compare accounts at a glance. Any usage at all lights the first cell, so "barely used" never looks like "untouched".

## Install

Grab the package for your system from [Releases](../../releases).

**macOS** — unzip and drag `ClaudeResetBar.app` into `/Applications`, then open it. The app is signed with a Developer ID certificate and notarized by Apple, with the ticket stapled into the bundle, so it launches on a double-click and Gatekeeper stays quiet even on a machine that is offline.

**Windows** — unzip and run `claude-reset-bar.exe`. SmartScreen will warn about an unknown publisher (no code signature): *More info* → *Run anyway*.

**Linux** — unzip and run the binary. The package ships `claude-reset-bar.desktop` and an icon; copy them into `~/.local/share/applications/` and `~/.local/share/icons/` for a launcher entry. On GNOME the system tray needs the [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/).

### Start on login

- **macOS** — *System Settings → General → Login Items* → add the app.
- **Windows** — `Win+R`, `shell:startup`, drop a shortcut to the `.exe` in there.
- **Linux** — copy `claude-reset-bar.desktop` into `~/.config/autostart/`.

## Where the data comes from

In this order:

1. **The OAuth tokens Claude Code stored.** On Windows and Linux they live in `~/.claude/.credentials.json` (plus `$CLAUDE_CONFIG_DIR` and any `~/.claude-<name>` profile); on macOS in the Keychain (`Claude Code-credentials`, one item per profile). Each live token queries `api.anthropic.com/api/oauth/usage`. You supply nothing.
2. **Extra accounts via `sessionKey` or an OAuth token** — optional, for accounts you are not signed into in Claude Code.

The token is only ever read. The app **does not use the refresh token** — refreshing it itself would invalidate Claude Code's session. If the token expires, just run Claude Code; the new one is picked up on the next poll.

Nothing leaves your machine beyond the requests to `api.anthropic.com` and `claude.ai`.

## Which account the menu bar shows

The figure next to the icon follows the account signed into Claude Code — the fuller of its two windows, with the time until it frees up once it reaches 100%. The **Menu bar shows** submenu switches it to another account or to the most used one. The choice is stored as `"menu_bar_account"` in the config (`"*most-used"` for the most used account; leave it out for the default), which is also how the portable build is set. A chosen account that cannot be read at the moment falls back to the Claude Code account, and with no Claude Code login the most used account stands in.

## Interface language

English and Polish, switchable from the **Language** submenu. Without an explicit setting the app follows your system locale and falls back to English. The choice is stored as `"language"` in the config file, so you can also set it by hand:

```json
{ "language": "pl" }
```

Use `"auto"` to go back to following the system locale.

## Several accounts

There are three ways to get an account on screen, and they mix freely.

**1. Sign into it in Claude Code.** Every Claude Code login on the machine gets its own row, named by its email. If you keep several profiles — separate `CLAUDE_CONFIG_DIR` directories, each signed into a different account — all of them show up live. An expired token belongs to a profile you have not used lately; it is skipped until Claude Code refreshes it.

Switching accounts with `/login` replaces a login: Claude Code keeps one token per profile, so the previous account can no longer be polled. Rather than dropping its row, the app keeps the last reading it got, marked with the time it was taken:

```
● new@example.com
   5h  ■□□□□□□□□□□□  2%    resets in 4h 47m (Mon 16:29)

○ old@example.com   · last seen 12:03
   5h  ■■■■■□□□□□□□  40%   resets in 2h 14m (Mon 14:03)
```

The countdown on a snapshot row stays truthful, because `resets_at` does not move until the window actually resets — so you can still see when the other account frees up. Nothing refreshes it though, and no reset notification will arrive for it. Sign back into that account, or add it by one of the ways below, and the row goes live again. Snapshots live in memory only; restarting the app forgets them.

**2. Add it with a `sessionKey`.** Find it in DevTools → *Application* → *Cookies* → `claude.ai` → `sessionKey`.

**3. Add it with an OAuth token.** Run `claude setup-token` while signed into that account and paste the `sk-ant-oat…` token it prints. Such a token only carries the inference scope: the usage endpoint refuses it and the account's email cannot be read, so give it a name. The app then reads the limits from the headers of a one-token request instead — a few dozen tokens of that account per poll. The request goes to Fable, because only a response from the capped model reports its weekly cap, so those tokens count against the Fable limit; an account that cannot use Fable is asked on the smallest model and shows no per-model line. The token is checked this way before it is saved.

On macOS everything about accounts happens in one window, **Manage accounts…**, with no dialogs. **Add account…** in the menu opens the same window with the cursor in its form. The list shows every account: what kind it is, where its key is stored, and how its last poll went.

- **Add** — type a name and a key in the form under the list and press Return or **Add**. Either kind of key works; the app tells them apart by the prefix. A sessionKey needs a name; for a token the name is optional and the account's email is used. The key is checked before anything is saved, and a problem is reported on the line at the bottom of the window.
- **Rename** — double-click the name and press Return. The key in the Keychain moves along with it.
- **Replace the key** — double-click the key cell, paste the new key and press Return. The key is never shown; it is checked like a new one, and the old one stays if the check fails. Escape abandons an edit.
- **Remove** — select the account and click **Remove** twice. The second click deletes it together with its key.
- **Hide / Show** — Claude Code logins belong to Claude Code, so their key cannot be changed or deleted here: that would sign Claude Code out. They can be hidden from the menu instead (`hidden_logins` in the config) and shown again from the same window.

### Where added keys are kept

On macOS a key you add goes into the login Keychain (service `ClaudeResetBar`, account `sessionKey:<name>` or `token:<name>`), not into the config file. The config only names the account and marks it `"keychain": true`. A key that is still written in plain text in the config, for example a hand-written entry, is moved into the Keychain on the next poll and blanked in the file. Such an entry no longer carries its key, so the claude-reset CLI cannot use it any more.

Windows and Linux have no Keychain, so the portable build keeps keys in the config file (readable only by you, `0600`). The portable build running on macOS cannot read the app's Keychain items without a password prompt on every poll, so it reports where the key is instead of polling that account.

In the portable build (Windows, Linux) you edit the config file; the menu has an entry that opens it. The config lives in `~/.config/claude-reset/config.json`, and its `accounts` list keeps the format of the [claude-reset](https://github.com/nazarli-shabnam/claude-reset) CLI:

```json
{
  "accounts": [
    { "name": "second-account", "session_key": "sk-ant-sid..." }
  ],
  "oauth_accounts": [
    { "name": "third-account", "token": "sk-ant-oat01-..." }
  ],
  "check_interval_minutes": 15,
  "language": "en"
}
```

`org_id` can be left out of a `sessionKey` entry: both builds look it up from the key on the next poll and write it into the file, leaving everything else in it as it was.

An account added by key under the same name as a Claude Code login (its email) replaces that login's row instead of appearing twice. Under a different name, it shows up twice.

## How reset detection works

On every poll the `resets_at` timestamp is compared with the previous one. A jump forward of more than an hour means the window reset, and that fires a notification.

- The first reading after startup only records a baseline and never notifies. A reset that happened while the app was closed therefore does not produce a notification — but the current percentage is visible immediately.
- A date before 2020 (the API sometimes returns the epoch) is discarded so it cannot poison the comparison.
- Polling runs every 15 minutes; once a remembered reset time passes, the app follows up within a minute. Each timestamp triggers that exactly once, so there is no endless polling.

## Building from source

The repository holds two implementations of the same thing:

| | `src/*.swift` | `cross/*.go` |
|---|---|---|
| Systems | macOS | macOS, Windows, Linux |
| Dependencies | none (AppKit) | `fyne.io/systray`, `gen2brain/beeep` |
| Text beside the icon | yes | macOS only |
| **Add account…** dialog | yes | no (edit the file) |

```bash
./build.sh                     # macOS native → build/ClaudeResetBar.app
cd cross && ./build.sh         # current system
cd cross && ./build.sh --all   # plus Windows and Linux
./release.sh v1.0.0            # release packages → dist/
```

Requirements: Xcode Command Line Tools for the Swift build, Go 1.21+ for the portable one. macOS only builds natively (CGO/AppKit); Windows and Linux cross-compile from any system.

Both builds run a self-check during the build (`--test` in the Go one): reset detection, duration formatting, icon generation, language resolution, config parsing. `--notify` checks whether notifications get through on a given system without waiting for a real reset. `--icons <dir>` regenerates the icon set.

## Credits

The reset-detection logic comes from [claude-reset](https://github.com/nazarli-shabnam/claude-reset), a CLI that does the same job with Slack notifications. This project moves it into the menu bar and adds the path that needs no `sessionKey`.

## License

MIT — see [LICENSE](LICENSE).

An independent project, not affiliated with Anthropic. It relies on undocumented endpoints that may stop working without notice.
