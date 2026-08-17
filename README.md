<img src="assets/icon_128.png" align="right" width="128" alt="">

# ClaudeResetBar

A menu bar / system tray icon that shows your Claude usage limits and **notifies you the moment a limit resets** — so you stop guessing when you can get back to work.

- **Nothing to configure.** It reads the token Claude Code already stored on your machine.
- **Several accounts at once.** The Claude Code account plus any number of extra ones, each on its own row.
- **macOS, Windows, Linux.** One binary per system, no runtime, no installer.

```
● you@example.com
   5h  ■■■■■□□□□□□□  39%   resets in 15m (Mon 11:29)
   7d  ■■■□□□□□□□□□  23%   resets in 5d 13h (Sun 00:59)
```

Each window carries a fill gauge alongside the number, so you can judge how much is left without reading digits, and compare accounts at a glance. Any usage at all lights the first cell, so "barely used" never looks like "untouched".

## Install

Grab the package for your system from [Releases](../../releases).

**macOS** — unzip and drag `ClaudeResetBar.app` into `/Applications`. The app is not signed with an Apple certificate, so Gatekeeper blocks the first launch: right-click → *Open*, or confirm *Open Anyway* under *System Settings → Privacy & Security*.

**Windows** — unzip and run `claude-reset-bar.exe`. SmartScreen will warn about an unknown publisher (no code signature): *More info* → *Run anyway*.

**Linux** — unzip and run the binary. The package ships `claude-reset-bar.desktop` and an icon; copy them into `~/.local/share/applications/` and `~/.local/share/icons/` for a launcher entry. On GNOME the system tray needs the [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/).

### Start on login

- **macOS** — *System Settings → General → Login Items* → add the app.
- **Windows** — `Win+R`, `shell:startup`, drop a shortcut to the `.exe` in there.
- **Linux** — copy `claude-reset-bar.desktop` into `~/.config/autostart/`.

## Where the data comes from

In this order:

1. **The OAuth token Claude Code stored.** On Windows and Linux it lives in `~/.claude/.credentials.json`; on macOS in the Keychain (`Claude Code-credentials`). That token queries `api.anthropic.com/api/oauth/usage`. You supply nothing.
2. **Extra accounts via `sessionKey`** — optional, for accounts you are not signed into in Claude Code.

The token is only ever read. The app **does not use the refresh token** — refreshing it itself would invalidate Claude Code's session. If the token expires, just run Claude Code; the new one is picked up on the next poll.

Nothing leaves your machine beyond the requests to `api.anthropic.com` and `claude.ai`.

## Interface language

English and Polish, switchable from the **Language** submenu. Without an explicit setting the app follows your system locale and falls back to English. The choice is stored as `"language"` in the config file, so you can also set it by hand:

```json
{ "language": "pl" }
```

Use `"auto"` to go back to following the system locale.

## Several accounts

The account signed into Claude Code shows up on its own. Switching accounts with `/login` replaces it: Claude Code keeps one token at a time, so the previous account can no longer be polled.

Rather than dropping its row, the app keeps the last reading it got, marked with the time it was taken:

```
● new@example.com
   5h  ■□□□□□□□□□□□  2%    resets in 4h 47m (Mon 16:29)

○ old@example.com   · last seen 12:03
   5h  ■■■■■□□□□□□□  40%   resets in 2h 14m (Mon 14:03)
```

The countdown on a snapshot row stays truthful, because `resets_at` does not move until the window actually resets — so you can still see when the other account frees up. Nothing refreshes it though, and no reset notification will arrive for it. Sign back into that account, or add it via `sessionKey`, and the row goes live again.

Snapshots live in memory only; restarting the app forgets them. To watch **both accounts live**, add the second one via `sessionKey`.

The config lives in `~/.config/claude-reset/config.json`, in a format compatible with the [claude-reset](https://github.com/nazarli-shabnam/claude-reset) CLI:

```json
{
  "accounts": [
    { "name": "second-account", "session_key": "sk-ant-sid...", "org_id": "uuid" }
  ],
  "check_interval_minutes": 15,
  "language": "en"
}
```

Find `sessionKey` in DevTools → *Application* → *Cookies* → `claude.ai` → `sessionKey`. The macOS build has an **Add account…** entry that asks for a name and a key and discovers `org_id` on its own. In the portable build you fill in both fields by hand; the menu has an entry that opens the file.

Do not add the account you are already signed into in Claude Code via `sessionKey` — it would appear twice.

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
