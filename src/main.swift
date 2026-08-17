// ClaudeResetBar — a macOS menu bar app showing Claude usage limits that notifies you the
// moment a limit resets.
//
// It shares ~/.config/claude-reset/config.json with the portable Go build (../cross) and
// with the claude-reset CLI, so all three can drive the same set of accounts.

import AppKit
import Foundation

// MARK: - Model

struct Account: Codable {
    var name: String
    var session_key: String
    var org_id: String
}

struct Config: Codable {
    // Every field is optional so a partial file still decodes. A config holding nothing but
    // a language setting is normal on a fresh install, and a strict decoder would throw the
    // whole file away over the missing key.
    var accounts: [Account]?
    var check_interval_minutes: Int?
    var slack_webhook_url: String?   // unused here, kept for claude-reset compatibility
    var language: String?

    var accountList: [Account] { accounts ?? [] }
}

struct UsageWindow: Codable {
    let utilization: Double
    let resets_at: String
}

struct UsageLimit: Codable {
    let group: String?
    let kind: String?
    let percent: Double?
    let is_active: Bool?
    /// Set on a "weekly_scoped" entry: the weekly cap that applies to one model only.
    /// This is where per-model limits are reported now; the seven_day_opus and
    /// seven_day_sonnet fields come back null.
    let scope: Scope?

    struct Scope: Codable {
        let model: Model?
        struct Model: Codable { let display_name: String? }
    }
}

/// A weekly cap that applies to a single model.
struct ModelWindow {
    let label: String
    let pct: Double
}

struct UsageResponse: Codable {
    let five_hour: UsageWindow
    let seven_day: UsageWindow
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let limits: [UsageLimit]?
}

/// The latest reading for one account — this is what the menu draws.
struct Reading {
    var fiveHourPct: Double
    var sevenDayPct: Double
    var fiveHourResetsAt: Date
    var sevenDayResetsAt: Date
    var models: [ModelWindow] = []
    var active: Bool
    var error: String?
    /// nil for a live account. Set when the account can no longer be polled — Claude Code
    /// was signed into a different one — and the row becomes a read-only snapshot of the
    /// final reading.
    var lastSeen: Date?
}

// MARK: - Reset detection (pure logic, no I/O)

struct WindowState {
    var resetsAt: Date
    var utilization: Double
}

// A real reset pushes resets_at forward by 5 hours or 7 days. A 1-hour threshold ignores
// minor timestamp jitter from the API while still catching every legitimate reset.
let resetMinInterval: TimeInterval = 60 * 60

// The API occasionally returns the epoch (1970) for resets_at. Storing that as the baseline
// would make the next valid timestamp look like a ~56-year jump and fire a bogus alert.
let minPlausibleDate = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01

/// Reports whether a reset just happened and returns the baseline to persist.
/// The first reading only records a baseline — it never fires.
func detectReset(prev: WindowState?, resetsAt: Date, utilization: Double) -> (fired: Bool, next: WindowState) {
    let fresh = WindowState(resetsAt: resetsAt, utilization: utilization)
    guard let prev else { return (false, fresh) }

    let fired = resetsAt.timeIntervalSince(prev.resetsAt) > resetMinInterval
    // Discard an implausible timestamp so it cannot poison the next comparison.
    let next = resetsAt >= minPlausibleDate ? fresh : prev
    return (fired, next)
}

// MARK: - claude.ai client

enum ClaudeError: LocalizedError {
    case auth(Int)
    case http(Int, String)
    case shape

    var errorDescription: String? {
        switch self {
        case .auth(let code):
            return String(format: T.authRejected, code)
        case .http(let code, let body):
            return String(format: T.httpError, code, String(body.prefix(120)))
        case .shape:
            return T.shapeError
        }
    }
}

// These headers mimic the request the claude.ai/settings/limits dashboard fires. A missing
// or wrong User-Agent / Referer triggers a Cloudflare bot challenge.
let browserHeaders: [String: String] = [
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "en-US,en;q=0.9",
    "Cache-Control": "no-cache",
    "Pragma": "no-cache",
    "Referer": "https://claude.ai/settings/limits",
    "sec-fetch-dest": "empty",
    "sec-fetch-mode": "cors",
    "sec-fetch-site": "same-origin",
]

func claudeRequest(path: String, sessionKey: String) -> URLRequest {
    var req = URLRequest(url: URL(string: "https://claude.ai" + path)!)
    for (k, v) in browserHeaders { req.setValue(v, forHTTPHeaderField: k) }
    req.setValue("sessionKey=" + sessionKey, forHTTPHeaderField: "Cookie")
    req.timeoutInterval = 20
    return req
}

func fetchJSON(_ req: URLRequest, completion: @escaping (Result<Data, Error>) -> Void) {
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err { return completion(.failure(err)) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if code == 401 || code == 403 { return completion(.failure(ClaudeError.auth(code))) }
        guard (200..<300).contains(code), let data else {
            return completion(.failure(ClaudeError.http(code, body)))
        }
        completion(.success(data))
    }.resume()
}

/// Every claude.ai account — even a solo free one — belongs to exactly one internal
/// "organization", which is why the usage endpoint is org-scoped. That UUID appears nowhere
/// in the UI, so rather than asking the user to dig it out of DevTools we fetch it ourselves
/// with nothing but the session key.
func discoverOrgId(sessionKey: String, completion: @escaping (Result<String, Error>) -> Void) {
    fetchJSON(claudeRequest(path: "/api/organizations", sessionKey: sessionKey)) { result in
        completion(result.flatMap { data in
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let uuid = arr.first?["uuid"] as? String, !uuid.isEmpty
            else { return .failure(ClaudeError.shape) }
            return .success(uuid)
        })
    }
}

/// Per-model weekly caps arrive two ways depending on the account. The dedicated fields are
/// the older shape and now usually null; the scoped entries in `limits` are the current one,
/// and reading them means new model tiers appear without a code change.
func modelWindows(_ usage: UsageResponse) -> [ModelWindow] {
    var out: [ModelWindow] = []
    var seen = Set<String>()

    func add(_ label: String?, _ percent: Double?) {
        guard let label, !label.isEmpty, let percent, seen.insert(label).inserted else { return }
        out.append(ModelWindow(label: label, pct: percent))
    }

    add("Opus", usage.seven_day_opus?.utilization)
    add("Sonnet", usage.seven_day_sonnet?.utilization)
    for limit in usage.limits ?? [] where limit.group == "weekly" {
        add(limit.scope?.model?.display_name, limit.percent)
    }
    return out.sorted { $0.label < $1.label }
}

func decodeUsage(_ result: Result<Data, Error>) -> Result<UsageResponse, Error> {
    result.flatMap { data in
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return .failure(ClaudeError.shape)
        }
        return .success(usage)
    }
}

func fetchUsage(_ account: Account, completion: @escaping (Result<UsageResponse, Error>) -> Void) {
    let path = "/api/organizations/\(account.org_id)/usage"
    fetchJSON(claudeRequest(path: path, sessionKey: account.session_key)) { completion(decodeUsage($0)) }
}

// MARK: - The Claude Code account (OAuth token from the Keychain)

// Claude Code stores its subscription token in the Keychain under "Claude Code-credentials"
// and refreshes it itself. We re-read it on every poll, so a refresh performed by Claude Code
// is picked up immediately. We deliberately do NOT use the refresh token — refreshing it
// ourselves would invalidate Claude Code's own session.
func keychainOAuthToken() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty
    else { return nil }
    return token
}

func anthropicRequest(path: String, token: String) -> URLRequest {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 20
    return req
}

func fetchUsageOAuth(token: String, completion: @escaping (Result<UsageResponse, Error>) -> Void) {
    fetchJSON(anthropicRequest(path: "/api/oauth/usage", token: token)) { completion(decodeUsage($0)) }
}

/// Names the Claude Code account by its email, so several accounts stay distinguishable.
func fetchOAuthLabel(token: String, completion: @escaping (String?) -> Void) {
    fetchJSON(anthropicRequest(path: "/api/oauth/profile", token: token)) { result in
        guard case .success(let data) = result,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any]
        else { return completion(nil) }
        completion(account["email"] as? String ?? account["display_name"] as? String)
    }
}

// MARK: - Config (shared with claude-reset and the portable build)

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/claude-reset")
let configURL = configDir.appendingPathComponent("config.json")

func loadConfig() -> Config {
    guard let data = try? Data(contentsOf: configURL),
          let cfg = try? JSONDecoder().decode(Config.self, from: data)
    else { return Config() }
    return cfg
}

func saveConfig(_ cfg: Config) throws {
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(cfg).write(to: configURL)
    // 0o600 — the file holds session keys, nobody but the owner reads it.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
}

// MARK: - Formatting

let isoWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()

func parseISO(_ s: String) -> Date? {
    isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
}

let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

/// Weekday plus time, with the weekday coming from the active language rather than the
/// system locale — the whole interface follows one setting.
func clock(_ date: Date) -> String {
    let weekday = Calendar.current.component(.weekday, from: date) - 1
    return "\(T.days[weekday]) \(clockFormatter.string(from: date))"
}

/// "2h 14m" / "3d 4h" / "now" — how much of the given number of seconds is left.
func remaining(seconds: Int) -> String {
    if seconds <= 0 { return T.now }
    let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func remaining(until date: Date) -> String {
    remaining(seconds: Int(date.timeIntervalSinceNow.rounded()))
}

func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

/// Right-pads a percentage so the text after the gauge starts at the same offset.
func paddedPct(_ v: Double) -> String {
    let s = pct(v)
    return s.count >= 4 ? s : s + String(repeating: " ", count: 4 - s.count)
}

// A gauge is easier to read at a glance than a number: you see how full the window is
// without parsing digits, and several accounts line up for comparison.
let barCells = 12

// Filled and hollow squares rather than block-and-shade characters: at menu size the light
// shade (U+2591) anti-aliases into a solid block, which made an almost-empty gauge look
// full. These two stay distinguishable, and both are present in the default UI font on all
// three platforms.
let barFilled = "■"
let barEmpty = "□"

func bar(_ percent: Double) -> String {
    let frac = min(max(percent / 100, 0), 1)
    var full = Int((frac * Double(barCells)).rounded())
    // Any usage at all lights the first cell, so "a little" never looks like "none".
    if full == 0 && percent > 0 { full = 1 }

    return String(repeating: barFilled, count: full)
         + String(repeating: barEmpty, count: barCells - full)
}

/// A system notification. ponytail: osascript rather than UNUserNotificationCenter — it needs
/// neither a signed bundle nor an authorization dialog. If the banner should carry its own
/// icon instead of Script Editor's, that is the moment to switch.
func notify(title: String, message: String) {
    func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
    let script = "display notification \"\(esc(message))\" with title \"\(esc(title))\" sound name \"Glass\""
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var config = loadConfig()
    private var readings: [String: Reading] = [:]
    /// Per account and window — the first reading only records, it never notifies.
    private var baselines: [String: [String: WindowState]] = [:]
    /// resets_at values that already triggered an off-schedule poll — see fastPollIfResetDue().
    private var fastPolled: [String: Date] = [:]
    /// Source names in display order — the Claude Code account first, then config accounts.
    private var sourceNames: [String] = []
    private var keychainLabel = "Claude Code"
    /// Accounts that dropped out of reach, keyed by name, keeping their last reading so the
    /// row does not simply vanish. Memory only — a restart forgets them.
    private var staleAccounts: [String: Reading] = [:]
    private var polled = false
    private var pollTimer: Timer?
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        currentLang = resolveLanguage(configured: config.language)
        statusItem.button?.title = "Claude —"
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        rebuildMenu()
        startTimers()
        poll()
    }

    private var pollInterval: TimeInterval {
        TimeInterval(max(1, config.check_interval_minutes ?? 15) * 60)
    }

    private func startTimers() {
        pollTimer?.invalidate()
        // Polling the API is infrequent because limits move slowly.
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // A separate, frequent tick only recomputes countdowns from the cached resets_at, so
        // the menu bar title never goes stale between API calls.
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateTitle()
            self.fastPollIfResetDue()
        }
    }

    /// A remembered reset time has passed, so poll straight away instead of waiting out the
    /// interval. That cuts notification lag from ~15 minutes to ~1 minute. Each resets_at
    /// value triggers this exactly once — otherwise an account whose API keeps returning a
    /// stale past date would be polled every minute forever.
    private func fastPollIfResetDue() {
        let now = Date()
        for (name, reading) in readings where reading.fiveHourResetsAt <= now {
            guard reading.lastSeen == nil else { continue }
            guard fastPolled[name] != reading.fiveHourResetsAt else { continue }
            fastPolled[name] = reading.fiveHourResetsAt
            poll()
            return
        }
    }

    // MARK: Polling

    @objc func poll() {
        config = loadConfig()
        var names: [String] = []

        // The account signed into Claude Code — no configuration needed.
        if let token = keychainOAuthToken() {
            names.append(keychainLabel)
            pollKeychainAccount(token: token)
        }

        // Extra accounts from the config (sessionKey). Isolated: an expired key on one must
        // not block the others.
        for account in config.accountList {
            names.append(account.name)
            fetchUsage(account) { [weak self] result in
                DispatchQueue.main.async { self?.apply(result, for: account.name) }
            }
        }

        // A stale account that came back within reach — signed into again, or added by
        // sessionKey — is live now, so its snapshot goes away.
        for name in names { staleAccounts.removeValue(forKey: name) }
        for (name, snapshot) in staleAccounts.sorted(by: { $0.key < $1.key }) {
            names.append(name)
            readings[name] = snapshot
        }

        sourceNames = names
        updateTitle()
        rebuildMenu()
    }

    /// The label is fetched on every poll — /login in Claude Code swaps the account behind
    /// the same Keychain entry. The usage request only goes out once the name is settled,
    /// because the name keys our state: the other order would file a new account's reading
    /// under the previous account's baseline.
    private func pollKeychainAccount(token: String) {
        fetchOAuthLabel(token: token) { [weak self] email in
            DispatchQueue.main.async {
                guard let self else { return }
                if let email { self.switchKeychainAccount(to: email) }
                let label = self.keychainLabel
                fetchUsageOAuth(token: token) { result in
                    DispatchQueue.main.async { self.apply(result, for: label) }
                }
            }
        }
    }

    /// The Claude Code account changed. The old baseline describes a different account's
    /// limit window, so it is dropped — the new account starts from its own first reading
    /// and never gets a bogus reset notification.
    private func switchKeychainAccount(to email: String) {
        guard email != keychainLabel else { return }
        let old = keychainLabel
        // Keep the final reading around. resets_at does not move until the window actually
        // resets, so the countdown stays truthful even though nothing refreshes it.
        if var last = readings.removeValue(forKey: old), last.error == nil {
            last.lastSeen = Date()
            staleAccounts[old] = last
        }
        baselines.removeValue(forKey: old)
        fastPolled.removeValue(forKey: old)
        keychainLabel = email
        sourceNames = sourceNames.map { $0 == old ? email : $0 }
        rebuildMenu()
    }

    private func apply(_ result: Result<UsageResponse, Error>, for name: String) {
        polled = true
        switch result {
        case .failure(let err):
            var r = readings[name] ?? Reading(fiveHourPct: 0, sevenDayPct: 0,
                                              fiveHourResetsAt: .distantFuture,
                                              sevenDayResetsAt: .distantFuture,
                                              models: [], active: false, error: nil, lastSeen: nil)
            r.error = err.localizedDescription
            readings[name] = r

        case .success(let usage):
            guard let fiveReset = parseISO(usage.five_hour.resets_at),
                  let sevenReset = parseISO(usage.seven_day.resets_at) else {
                readings[name]?.error = ClaudeError.shape.localizedDescription
                break
            }
            let session = usage.limits?.first { $0.group == "session" || $0.kind == "session" }
            readings[name] = Reading(
                fiveHourPct: usage.five_hour.utilization,
                sevenDayPct: usage.seven_day.utilization,
                fiveHourResetsAt: fiveReset,
                sevenDayResetsAt: sevenReset,
                models: modelWindows(usage),
                active: session?.is_active ?? false,
                error: nil,
                lastSeen: nil)

            check(name: name, window: "five_hour", label: T.fiveHourWindow,
                  resetsAt: fiveReset, utilization: usage.five_hour.utilization)
            check(name: name, window: "seven_day", label: T.sevenDayWindow,
                  resetsAt: sevenReset, utilization: usage.seven_day.utilization)
        }
        updateTitle()
        rebuildMenu()
    }

    private func check(name: String, window: String, label: String, resetsAt: Date, utilization: Double) {
        let prev = baselines[name]?[window]
        let (fired, next) = detectReset(prev: prev, resetsAt: resetsAt, utilization: utilization)

        if fired, let prev {
            notify(title: String(format: T.resetTitle, name),
                   message: String(format: T.resetBody, label,
                                   pct(prev.utilization), pct(utilization), clock(resetsAt)))
        }
        baselines[name, default: [:]][window] = next
    }

    // MARK: Menu bar

    private func updateTitle() {
        guard !sourceNames.isEmpty else {
            statusItem.button?.title = "Claude ⚙︎"
            return
        }
        let live = readings.values.filter { $0.error == nil && $0.lastSeen == nil }
        guard let worst = live.max(by: { $0.fiveHourPct < $1.fiveHourPct }) else {
            statusItem.button?.title = "Claude ⚠︎"
            return
        }
        // Once a window is exhausted the only thing that matters is when it returns.
        statusItem.button?.title = worst.fiveHourPct >= 100
            ? "Claude \(pct(worst.fiveHourPct)) · \(remaining(until: worst.fiveHourResetsAt))"
            : "Claude \(pct(worst.fiveHourPct))"
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        if !polled && sourceNames.isEmpty {
            // Before the first poll returns there is nothing to say — and claiming there are
            // no accounts would be wrong for the second it takes.
            menu.addItem(disabled(T.loading))
        } else if sourceNames.isEmpty {
            menu.addItem(disabled(T.noAccounts))
        }

        for name in sourceNames {
            guard let r = readings[name] else {
                menu.addItem(disabled("\(name) — \(T.loading)"))
                continue
            }
            if let err = r.error {
                menu.addItem(disabled("\(name) — \(T.errorWord)"))
                menu.addItem(disabled("   \(err)"))
                continue
            }
            // One menu item per line — NSMenuItem does not wrap a title on "\n".
            var label = name
            if let seen = r.lastSeen {
                label += String(format: T.lastSeen, clockFormatter.string(from: seen))
            }
            var lines = ["\(r.active && r.lastSeen == nil ? "●" : "○") \(label)",
                         String(format: T.fiveHourLine, bar(r.fiveHourPct), paddedPct(r.fiveHourPct),
                                remaining(until: r.fiveHourResetsAt), clock(r.fiveHourResetsAt)),
                         String(format: T.sevenDayLine, bar(r.sevenDayPct), paddedPct(r.sevenDayPct),
                                remaining(until: r.sevenDayResetsAt), clock(r.sevenDayResetsAt))]
            for m in r.models {
                lines.append(String(format: T.modelLine, bar(m.pct), paddedPct(m.pct), m.label))
            }
            for line in lines { menu.addItem(disabled(line)) }
        }

        menu.addItem(.separator())
        menu.addItem(action(T.refreshNow, #selector(poll)))
        menu.addItem(action(T.addAccount, #selector(addAccount)))
        menu.addItem(action(T.openConfig, #selector(openConfig)))
        menu.addItem(languageMenuItem())
        menu.addItem(.separator())
        menu.addItem(action(T.quit, #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private func languageMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: T.language, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, entry) in languageOrder.enumerated() {
            let item = NSMenuItem(title: entry.name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = entry.code == currentLang ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ sel: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = target ?? self
        return item
    }

    // MARK: Actions

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard languageOrder.indices.contains(sender.tag) else { return }
        currentLang = languageOrder[sender.tag].code
        do {
            try saveLanguage(currentLang)
        } catch {
            showError(String(format: T.saveFailed, error.localizedDescription))
        }
        config = loadConfig()
        updateTitle()
        rebuildMenu()
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? saveConfig(config)
        }
        NSWorkspace.shared.open(configURL)
    }

    @objc private func addAccount() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = T.addAccountTitle
        alert.informativeText = T.addAccountHint
        alert.addButton(withTitle: T.addButton)
        alert.addButton(withTitle: T.cancelButton)

        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        nameField.placeholderString = T.namePlaceholder
        let keyField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        keyField.placeholderString = T.keyPlaceholder
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        box.addSubview(nameField)
        box.addSubview(keyField)
        alert.accessoryView = box
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !key.isEmpty else { return showError(T.nameAndKeyRequired) }
        guard !config.accountList.contains(where: { $0.name == name }) else {
            return showError(String(format: T.accountExists, name))
        }

        discoverOrgId(sessionKey: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let err):
                    self.showError(err.localizedDescription)
                case .success(let orgId):
                    var cfg = loadConfig()
                    cfg.accounts = cfg.accountList + [Account(name: name, session_key: key, org_id: orgId)]
                    do {
                        try saveConfig(cfg)
                        self.config = cfg
                        self.startTimers()
                        self.poll()
                    } catch {
                        self.showError(String(format: T.saveFailed, error.localizedDescription))
                    }
                }
            }
        }
    }

    private func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = T.failedTitle
        a.informativeText = text
        a.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    // Countdowns must be fresh at the moment the menu opens, not a minute old.
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}

// MARK: - Self-check

/// `ClaudeResetBar --test` — exercises reset detection and formatting, the only non-trivial
/// logic in the app.
func runSelfCheck() {
    let now = Date()
    let plus5h = now.addingTimeInterval(5 * 3600)

    // The first reading only records a baseline.
    let first = detectReset(prev: nil, resetsAt: now, utilization: 80)
    assert(first.fired == false)
    assert(first.next.resetsAt == now)

    // The same timestamp is not a reset.
    let same = detectReset(prev: first.next, resetsAt: now, utilization: 95)
    assert(same.fired == false)

    // A 5-hour jump is a reset.
    let jump = detectReset(prev: first.next, resetsAt: plus5h, utilization: 0)
    assert(jump.fired == true)
    assert(jump.next.resetsAt == plus5h)

    // Drift below the 1-hour threshold is not a reset.
    let drift = detectReset(prev: first.next, resetsAt: now.addingTimeInterval(600), utilization: 81)
    assert(drift.fired == false)

    // An epoch timestamp must not poison the baseline.
    let epoch = detectReset(prev: first.next, resetsAt: Date(timeIntervalSince1970: 0), utilization: 0)
    assert(epoch.next.resetsAt == first.next.resetsAt)

    // Duration formatting, in whichever language is active.
    currentLang = "en"
    assert(remaining(seconds: -5) == "now")
    assert(remaining(seconds: 3 * 3600 + 120) == "3h 2m")
    assert(remaining(seconds: 45 * 60) == "45m")
    assert(remaining(seconds: 3 * 86400 + 4 * 3600) == "3d 4h")
    currentLang = "pl"
    assert(remaining(seconds: -5) == "teraz")
    currentLang = "en"

    // Language resolution: the config wins, an unknown code falls back to English.
    assert(resolveLanguage(configured: "pl") == "pl")
    assert(resolveLanguage(configured: "de") == "en")
    assert(languages[resolveLanguage(configured: nil)] != nil)

    // Every language must define every string, or the menu shows blanks.
    for (code, l) in languages {
        assert(!l.refreshNow.isEmpty && !l.quit.isEmpty && !l.language.isEmpty, "menu strings: \(code)")
        assert(!l.resetTitle.isEmpty && !l.resetBody.isEmpty, "message templates: \(code)")
        assert(l.days.count == 7 && !l.days.contains(where: \.isEmpty), "weekday names: \(code)")
        assert(!l.lastSeen.isEmpty && !l.loading.isEmpty, "status strings: \(code)")
    }

    // A partial config must survive decoding — a fresh install writes nothing but the
    // language, and losing the whole file over a missing "accounts" key silently reverted
    // the interface to the system locale.
    let onlyLanguage = #"{"language":"en"}"#.data(using: .utf8)!
    let partial = try! JSONDecoder().decode(Config.self, from: onlyLanguage)
    assert(partial.language == "en")
    assert(partial.accountList.isEmpty)

    let full = #"{"accounts":[{"name":"a","session_key":"k","org_id":"o"}],"slack_webhook_url":"https://x","check_interval_minutes":5}"#
    let parsed = try! JSONDecoder().decode(Config.self, from: full.data(using: .utf8)!)
    assert(parsed.accountList.count == 1 && parsed.check_interval_minutes == 5)
    assert(parsed.language == nil)

    // Format strings must accept exactly the arguments the call sites pass.
    assert(String(format: T.lastSeen, "12:03").contains("12:03"))
    assert(String(format: T.resetTitle, "acc").contains("acc"))
    assert(String(format: T.fiveHourLine, bar(30), "30% ", "2h 1m", "Mon 11:29").contains("30%"))

    // Per-model weekly caps: read from the scoped entries in `limits`, which is where the
    // API reports them now that seven_day_opus and seven_day_sonnet come back null.
    let scopedJSON = """
    {"five_hour":{"utilization":9,"resets_at":"2026-08-17T14:29:59Z"},
     "seven_day":{"utilization":25,"resets_at":"2026-08-22T22:59:59Z"},
     "limits":[{"kind":"session","group":"session","percent":9,"is_active":true},
               {"kind":"weekly_all","group":"weekly","percent":25},
               {"kind":"weekly_scoped","group":"weekly","percent":40,
                "scope":{"model":{"display_name":"Opus"}}},
               {"kind":"weekly_scoped","group":"weekly","percent":3,
                "scope":{"model":{"display_name":"Fable"}}}]}
    """
    let scoped = try! JSONDecoder().decode(UsageResponse.self, from: scopedJSON.data(using: .utf8)!)
    let models = modelWindows(scoped)
    assert(models.count == 2, "both scoped models produce a row")
    assert(models[0].label == "Fable" && models[1].label == "Opus",
           "model rows keep a stable, sorted order")
    assert(models[1].pct == 40, "the scoped percentage is carried through")
    assert(scoped.limits?.first?.is_active == true, "the session entry still parses")

    // An account reporting no per-model caps simply has no such rows.
    let plainJSON = """
    {"five_hour":{"utilization":9,"resets_at":"2026-08-17T14:29:59Z"},
     "seven_day":{"utilization":25,"resets_at":"2026-08-22T22:59:59Z"},
     "limits":[{"kind":"session","group":"session"}]}
    """
    let plain = try! JSONDecoder().decode(UsageResponse.self, from: plainJSON.data(using: .utf8)!)
    assert(modelWindows(plain).isEmpty, "no scoped caps, no model rows")

    // The gauge must always occupy the same width, or the rows stop lining up.
    for v in [-5.0, 0, 0.4, 12.5, 50, 99.9, 100, 150] {
        assert(bar(v).count == barCells, "gauge width at \(v)%")
    }
    assert(bar(0) == String(repeating: barEmpty, count: barCells))
    assert(bar(100) == String(repeating: barFilled, count: barCells))
    assert(bar(150) == bar(100), "over 100% cannot overflow the gauge")
    assert(bar(-5) == bar(0), "a negative value cannot underflow the gauge")
    assert(bar(50) == String(repeating: barFilled, count: barCells / 2)
                    + String(repeating: barEmpty, count: barCells / 2))
    // Barely-used must still differ from unused, or a low reading reads as zero.
    assert(bar(1) != bar(0), "any usage lights the first cell")
    assert(paddedPct(5).count == 4 && paddedPct(100).count == 4, "percentages align")
    assert(String(format: T.accountExists, "dup").contains("dup"))

    print("self-check OK")
}

// MARK: - Start

if CommandLine.arguments.contains("--test") {
    runSelfCheck()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon — the app lives in the menu bar only
let delegate = AppDelegate()
app.delegate = delegate
app.run()
