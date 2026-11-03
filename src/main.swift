// ClaudeResetBar — a macOS menu bar app showing Claude usage limits that notifies you the
// moment a limit resets.
//
// It shares ~/.config/claude-reset/config.json with the portable Go build (../cross) and
// with the claude-reset CLI, so all three can drive the same set of accounts.

import AppKit
import Foundation

// MARK: - Model

/// An extra account read with a claude.ai sessionKey. This is the shape the claude-reset
/// CLI reads too, so it stays exactly as it was.
struct Account: Codable {
    var name: String
    var session_key: String
    /// May be left empty in a hand-written entry: it is discovered from the session key on
    /// the next poll and written back.
    var org_id: String
    /// Set once the key lives in the Keychain; `session_key` is empty then.
    var keychain: Bool?

    init(name: String, session_key: String, org_id: String, keychain: Bool? = nil) {
        self.name = name
        self.session_key = session_key
        self.org_id = org_id
        self.keychain = keychain
    }

    // A missing field leaves it empty instead of throwing — one incomplete entry must not
    // cost the whole config file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        session_key = try c.decodeIfPresent(String.self, forKey: .session_key) ?? ""
        org_id = try c.decodeIfPresent(String.self, forKey: .org_id) ?? ""
        keychain = try c.decodeIfPresent(Bool.self, forKey: .keychain)
    }

    var inKeychain: Bool { keychain == true }
    var isFilledIn: Bool { !name.isEmpty && (inKeychain || !session_key.isEmpty) }
}

/// An extra account read with an OAuth token, such as one from `claude setup-token`. Kept
/// apart from `accounts`, whose shape the claude-reset CLI relies on.
struct OAuthAccount: Codable {
    var name: String
    var token: String
    /// Set once the token lives in the Keychain; `token` is empty then.
    var keychain: Bool?

    init(name: String, token: String, keychain: Bool? = nil) {
        self.name = name
        self.token = token
        self.keychain = keychain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        keychain = try c.decodeIfPresent(Bool.self, forKey: .keychain)
    }

    var inKeychain: Bool { keychain == true }
    var isFilledIn: Bool { !name.isEmpty && (inKeychain || !token.isEmpty) }
}

// MARK: - Keys of added accounts (Keychain)

// A key added to the app is kept in the login Keychain, not in config.json. The config only
// names the account and marks it `"keychain": true`. Items carry the service name below and
// the account "sessionKey:<name>" or "token:<name>". The app reads them through the Security
// framework, and because it created them, it reads them without a password prompt.

let addedKeyService = "ClaudeResetBar"

enum KeyKind: String {
    case sessionKey, token
}

func keyAccount(_ kind: KeyKind, _ name: String) -> String { "\(kind.rawValue):\(name)" }

private func keyQuery(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: addedKeyService,
     kSecAttrAccount as String: account]
}

/// Stores the key, replacing any earlier one under the same account. Returns the OSStatus.
@discardableResult
func storeAddedKey(_ value: String, account: String) -> OSStatus {
    SecItemDelete(keyQuery(account) as CFDictionary)
    var item = keyQuery(account)
    item[kSecValueData as String] = Data(value.utf8)
    item[kSecAttrLabel as String] = "\(addedKeyService) (\(account))"
    return SecItemAdd(item as CFDictionary, nil)
}

func readAddedKey(account: String) -> String? {
    var query = keyQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
          let data = out as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
    else { return nil }
    return value
}

func deleteAddedKey(account: String) {
    SecItemDelete(keyQuery(account) as CFDictionary)
}

/// Moves every key still written in plain text in the config into the Keychain and blanks
/// it in the file. An entry whose key cannot be stored stays as it is. Returns the config
/// as it now stands.
func moveKeysToKeychain(_ cfg: Config) -> Config {
    var out = cfg
    var changed = false
    out.accounts = cfg.accounts?.map { a in
        guard !a.inKeychain, !a.name.isEmpty, !a.session_key.isEmpty,
              storeAddedKey(a.session_key, account: keyAccount(.sessionKey, a.name)) == errSecSuccess
        else { return a }
        changed = true
        return Account(name: a.name, session_key: "", org_id: a.org_id, keychain: true)
    }
    out.oauth_accounts = cfg.oauth_accounts?.map { a in
        guard !a.inKeychain, !a.name.isEmpty, !a.token.isEmpty,
              storeAddedKey(a.token, account: keyAccount(.token, a.name)) == errSecSuccess
        else { return a }
        changed = true
        return OAuthAccount(name: a.name, token: "", keychain: true)
    }
    guard changed, (try? saveConfig(out)) != nil else { return cfg }
    return out
}

struct Config: Codable {
    // Every field is optional so a partial file still decodes. A config holding nothing but
    // a language setting is normal on a fresh install, and a strict decoder would throw the
    // whole file away over the missing key.
    var accounts: [Account]?
    var oauth_accounts: [OAuthAccount]?
    var check_interval_minutes: Int?
    var slack_webhook_url: String?   // unused here, kept for claude-reset compatibility
    var language: String?

    var accountList: [Account] { accounts ?? [] }
    var oauthAccountList: [OAuthAccount] { oauth_accounts ?? [] }
    /// Every account the config names, in display order.
    var configuredNames: [String] {
        accountList.filter(\.isFilledIn).map(\.name) + oauthAccountList.filter(\.isFilledIn).map(\.name)
    }
}

// Every field is optional. The API has already moved one reading out of its dedicated
// field once (the per-model caps), and a null arriving where a number used to be should
// cost one row, not the whole account.
struct UsageWindow: Codable {
    let utilization: Double?
    let resets_at: String?
}

struct UsageLimit: Codable {
    let group: String?
    let kind: String?
    let percent: Double?
    let is_active: Bool?
    let resets_at: String?
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
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let limits: [UsageLimit]?
}

/// One limit window: how much of it is used and when it starts over.
typealias Window = (pct: Double, resetsAt: Date)

/// The latest reading for one account — this is what the menu draws.
struct Reading {
    /// nil when the API reports no such window. A 5-hour window only exists while one is
    /// running, and since 2026-11 the API answers an idle one with `"five_hour": null` and
    /// no session entry in `limits` at all, so its absence is a normal state, not an error.
    var fiveHour: Window?
    var sevenDay: Window?
    var models: [ModelWindow] = []
    var active: Bool
    var error: String?
    /// nil for a live account. Set when the account can no longer be polled — Claude Code
    /// was signed into a different one — and the row becomes a read-only snapshot of the
    /// final reading.
    var lastSeen: Date?

    /// The window that limits you right now: the 5-hour one while it runs, otherwise the
    /// weekly one. This is what the menu bar figure shows.
    var headline: Window? { fiveHour ?? sevenDay }
}

/// Turns a usage response into a reading. Each window is optional; the account only counts
/// as unreadable when neither the 5-hour nor the 7-day window can be found anywhere.
func makeReading(_ usage: UsageResponse) -> Reading? {
    let five = windowReading(usage.five_hour, usage.limits, kind: "session")
    let seven = windowReading(usage.seven_day, usage.limits, kind: "weekly_all")
    guard five != nil || seven != nil else { return nil }
    let session = usage.limits?.first { $0.group == "session" || $0.kind == "session" }
    return Reading(fiveHour: five, sevenDay: seven, models: modelWindows(usage),
                   active: session?.is_active ?? false, error: nil, lastSeen: nil)
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

/// One window as the menu needs it, taken from whichever shape carried it this time.
///
/// The API reports each reading twice: as a dedicated `five_hour` / `seven_day` object and
/// as an entry in `limits` with the same percentage and reset time. It has already retired
/// one of those shapes once — the per-model caps went null in their own fields and turned up
/// under `limits` — so neither is treated as the one that must be there. A row is only lost
/// when both come back empty.
func windowReading(_ dedicated: UsageWindow?, _ limits: [UsageLimit]?,
                   kind: String) -> Window? {
    let entry = limits?.first { $0.kind == kind }
    guard let pct = dedicated?.utilization ?? entry?.percent,
          let stamp = dedicated?.resets_at ?? entry?.resets_at,
          let resetsAt = parseISO(stamp)
    else { return nil }
    return (pct, resetsAt)
}

func decodeUsage(_ result: Result<Data, Error>) -> Result<UsageResponse, Error> {
    result.flatMap { data in
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            recordUnexpected(data)
            return .failure(ClaudeError.shape)
        }
        return .success(usage)
    }
}

/// Writes aside a response the app could not read. "The private API may have changed" is
/// a guess without the payload that caused it; this leaves the payload next to the config,
/// overwritten each time. It carries usage numbers and no credentials.
func recordUnexpected(_ data: Data) {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try? data.write(to: configDir.appendingPathComponent("last-unexpected-response.json"))
}

func fetchUsage(_ account: Account, completion: @escaping (Result<UsageResponse, Error>) -> Void) {
    let path = "/api/organizations/\(account.org_id)/usage"
    fetchJSON(claudeRequest(path: path, sessionKey: account.session_key)) { completion(decodeUsage($0)) }
}

// MARK: - The Claude Code account (OAuth token from the Keychain)

// Claude Code stores its subscription token in the Keychain and refreshes it itself. We
// re-read it on every poll, so a refresh performed by Claude Code is picked up immediately.
// We deliberately do NOT use the refresh token — refreshing it ourselves would invalidate
// Claude Code's own session.

/// One `security find-generic-password` lookup. Returns nothing when the item is absent.
func keychainSecret(service: String, account: String?) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    var args = ["find-generic-password", "-s", service]
    if let account { args += ["-a", account] }
    args.append("-w")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 && !data.isEmpty ? data : nil
}

/// Every Keychain service that may hold Claude Code credentials: the plain name plus the
/// per-profile "Claude Code-credentials-<hash>" variants. Listing them costs one cheap
/// `dump-keychain` — it reads attributes only, never a secret, so it prompts for nothing.
func keychainCredentialServices() -> [String] {
    let base = "Claude Code-credentials"
    var services = [base]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["dump-keychain"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return services }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    for line in out.split(separator: "\n") where line.contains("\"svce\"") {
        guard let open = line.range(of: "=\""), let close = line.range(of: "\"", options: .backwards),
              open.upperBound < close.lowerBound else { continue }
        let name = String(line[open.upperBound..<close.lowerBound])
        if name.hasPrefix(base) && !services.contains(name) { services.append(name) }
    }
    return services
}

/// One login Claude Code stored: the access token and when it stops working (Unix ms, 0 when
/// the item does not say).
struct StoredCredential {
    let token: String
    let expiresAt: Double
}

func storedCredential(_ data: Data) -> StoredCredential? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty
    else { return nil }
    return StoredCredential(token: token, expiresAt: (oauth["expiresAt"] as? Double) ?? 0)
}

/// The tokens worth polling, freshest first, each once. An expired token is dropped: it
/// belongs to a profile nobody has used lately, and only Claude Code may refresh it. When
/// every token has expired the freshest one is still returned, so the row says "run Claude
/// Code" instead of the account silently disappearing.
func liveTokens(_ creds: [StoredCredential], now: Date) -> [String] {
    let nowMs = now.timeIntervalSince1970 * 1000
    let sorted = creds.sorted { $0.expiresAt > $1.expiresAt }
    var live = sorted.filter { $0.expiresAt == 0 || $0.expiresAt > nowMs }
    if live.isEmpty, let freshest = sorted.first { live = [freshest] }
    var seen = Set<String>()
    return live.compactMap { seen.insert($0.token).inserted ? $0.token : nil }
}

/// Credential files Claude Code may have written: the default profile, the one
/// CLAUDE_CONFIG_DIR points at, and the common habit of keeping extra profiles in
/// ~/.claude-<name>. On macOS Claude Code normally uses the Keychain, so these are usually
/// absent here.
func credentialFiles() -> [URL] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    var dirs = [home.appendingPathComponent(".claude")]
    if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
        dirs.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
    }
    let entries = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
    for name in entries.sorted() where name.hasPrefix(".claude-") {
        dirs.append(home.appendingPathComponent(name))
    }
    return dirs.map { $0.appendingPathComponent(".credentials.json") }
}

/// Every Claude Code login on this machine that can be polled.
///
/// Claude Code writes one Keychain item per profile ("Claude Code-credentials-<hash>"), and
/// an MCP OAuth flow writes its own under account "unknown" holding only `mcpOAuth`. Asking
/// `security` for a service alone returns whichever it finds first, so every item is read.
/// Each live login gets its own row — several profiles signed into different accounts are
/// all shown.
func claudeCodeTokens() -> [String] {
    var creds: [StoredCredential] = []
    for url in credentialFiles() {
        if let data = try? Data(contentsOf: url), let c = storedCredential(data) { creds.append(c) }
    }
    for service in keychainCredentialServices() {
        for account in [NSUserName(), nil] as [String?] {
            if let data = keychainSecret(service: service, account: account),
               let c = storedCredential(data) { creds.append(c) }
        }
    }
    return liveTokens(creds, now: Date())
}

/// Names the logins found this poll. A login whose email could not be fetched keeps the
/// name it had before; failing that it gets a numbered "Claude Code" name. A name the config
/// already uses is skipped — that account is on screen already — and so is a second login
/// into the same account.
func nameClaudeCodeLogins(tokens: [String], emails: [String?], known: [String: String],
                          previous: [String], configured: Set<String>) -> [(name: String, token: String)] {
    var out: [(name: String, token: String)] = []
    for (i, token) in tokens.enumerated() {
        let fallback = tokens.count == 1 && previous.count == 1 ? previous[0]
            : (i == 0 ? "Claude Code" : "Claude Code \(i + 1)")
        let name = emails[i] ?? known[token] ?? fallback
        guard !configured.contains(name), !out.contains(where: { $0.name == name }) else { continue }
        out.append((name, token))
    }
    return out
}

/// A token Claude Code issues, as opposed to a claude.ai sessionKey.
func isOAuthToken(_ key: String) -> Bool { key.hasPrefix("sk-ant-oat") }

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
/// One window's menu line, or the "no active window" line when the API reported none.
func windowLine(_ format: String, tag: String, _ w: Window?) -> String {
    guard let w else { return String(format: T.idleLine, tag, bar(0)) }
    return String(format: format, bar(w.pct), paddedPct(w.pct), remaining(until: w.resetsAt), clock(w.resetsAt))
}

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
    /// Source names in display order — the Claude Code logins first, then config accounts,
    /// then snapshots of accounts that dropped out of reach.
    private var sourceNames: [String] = []
    /// Names of the Claude Code logins seen on the last poll.
    private var claudeCodeNames: [String] = []
    /// The name each Claude Code token was last shown under, for a poll where its email
    /// cannot be fetched.
    private var tokenNames: [String: String] = [:]
    /// Created the first time "Manage accounts…" is chosen, then kept for reuse.
    private var accountsWindow: AccountsWindowController?
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
        for name in sourceNames {
            guard let reading = readings[name], reading.lastSeen == nil, reading.error == nil,
                  let due = reading.headline?.resetsAt, due <= now else { continue }
            guard fastPolled[name] != due else { continue }
            fastPolled[name] = due
            poll()
            return
        }
    }

    // MARK: Polling

    @objc func poll() {
        config = moveKeysToKeychain(loadConfig())

        // Extra accounts from the config. Isolated: an expired key on one must not block
        // the others.
        for var account in config.accountList where account.isFilledIn {
            if account.inKeychain {
                guard let key = readAddedKey(account: keyAccount(.sessionKey, account.name)) else {
                    note(error: T.keyMissing, for: account.name)
                    continue
                }
                account.session_key = key
            }
            pollSessionAccount(account)
        }
        for account in config.oauthAccountList where account.isFilledIn {
            guard let token = account.inKeychain
                    ? readAddedKey(account: keyAccount(.token, account.name)) : account.token
            else {
                note(error: T.keyMissing, for: account.name)
                continue
            }
            fetchUsageOAuth(token: token) { [weak self] result in
                DispatchQueue.main.async { self?.apply(result, for: account.name) }
            }
        }
        refreshSourceNames()

        // Every Claude Code login — no configuration needed. Emails are fetched first:
        // the name keys our state, so the usage request only goes out once it is settled.
        let tokens = claudeCodeTokens()
        var emails = [String?](repeating: nil, count: tokens.count)
        let group = DispatchGroup()
        for (i, token) in tokens.enumerated() {
            group.enter()
            fetchOAuthLabel(token: token) { email in
                DispatchQueue.main.async {
                    emails[i] = email
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.pollClaudeCode(tokens: tokens, emails: emails)
        }
    }

    private func pollClaudeCode(tokens: [String], emails: [String?]) {
        let logins = nameClaudeCodeLogins(tokens: tokens, emails: emails, known: tokenNames,
                                          previous: claudeCodeNames,
                                          configured: Set(config.configuredNames))
        tokenNames = Dictionary(logins.map { ($0.token, $0.name) }, uniquingKeysWith: { a, _ in a })
        retire(claudeCodeNames.filter { name in !logins.contains { $0.name == name } })
        claudeCodeNames = logins.map(\.name)
        refreshSourceNames()

        for login in logins {
            fetchUsageOAuth(token: login.token) { [weak self] result in
                DispatchQueue.main.async { self?.apply(result, for: login.name) }
            }
        }
    }

    /// A sessionKey account whose org_id was left out gets it discovered and written back,
    /// so a hand-written entry needs nothing but a name and a key.
    private func pollSessionAccount(_ account: Account) {
        guard account.org_id.isEmpty else {
            fetchUsage(account) { [weak self] result in
                DispatchQueue.main.async { self?.apply(result, for: account.name) }
            }
            return
        }
        discoverOrgId(sessionKey: account.session_key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let err):
                    self.apply(.failure(err), for: account.name)
                case .success(let orgId):
                    var cfg = loadConfig()
                    cfg.accounts = cfg.accountList.map {
                        guard $0.name == account.name && $0.org_id.isEmpty else { return $0 }
                        var found = $0
                        found.org_id = orgId
                        return found
                    }
                    try? saveConfig(cfg)
                    self.config = cfg
                    var found = account
                    found.org_id = orgId
                    self.pollSessionAccount(found)
                }
            }
        }
    }

    /// Claude Code logins that are gone — signed out, or swapped by /login. Their old
    /// baseline describes a limit window we can no longer follow, so it is dropped, and the
    /// final reading is kept as a snapshot: resets_at does not move until the window
    /// actually resets, so its countdown stays truthful even though nothing refreshes it.
    private func retire(_ names: [String]) {
        for name in names {
            if var last = readings.removeValue(forKey: name), last.error == nil {
                last.lastSeen = Date()
                staleAccounts[name] = last
            }
            baselines.removeValue(forKey: name)
            fastPolled.removeValue(forKey: name)
        }
    }

    private func refreshSourceNames() {
        var names = claudeCodeNames
        for name in config.configuredNames where !names.contains(name) { names.append(name) }

        // A stale account that came back within reach — signed into again, or added to the
        // config — is live now, so its snapshot goes away.
        for name in names { staleAccounts.removeValue(forKey: name) }
        for (name, snapshot) in staleAccounts.sorted(by: { $0.key < $1.key }) {
            names.append(name)
            readings[name] = snapshot
        }

        sourceNames = names
        updateTitle()
        rebuildMenu()
    }

    private func apply(_ result: Result<UsageResponse, Error>, for name: String) {
        polled = true
        switch result {
        case .failure(let err):
            note(error: err.localizedDescription, for: name)

        case .success(let usage):
            guard let reading = makeReading(usage) else {
                note(error: ClaudeError.shape.localizedDescription, for: name)
                break
            }
            readings[name] = reading

            if let five = reading.fiveHour {
                check(name: name, window: "five_hour", label: T.fiveHourWindow,
                      resetsAt: five.resetsAt, utilization: five.pct)
            }
            if let seven = reading.sevenDay {
                check(name: name, window: "seven_day", label: T.sevenDayWindow,
                      resetsAt: seven.resetsAt, utilization: seven.pct)
            }
        }
        updateTitle()
        rebuildMenu()
    }

    /// Marks the row as failed while keeping whatever it already showed, so a hiccup turns
    /// a live account into a labelled error rather than into nothing at all.
    private func note(error: String, for name: String) {
        var r = readings[name] ?? Reading(fiveHour: nil, sevenDay: nil,
                                          models: [], active: false, error: nil, lastSeen: nil)
        r.error = error
        readings[name] = r
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
        let live = sourceNames.compactMap { readings[$0] }.filter { $0.error == nil && $0.lastSeen == nil }
        guard let worst = live.compactMap(\.headline).max(by: { $0.pct < $1.pct }) else {
            statusItem.button?.title = "Claude ⚠︎"
            return
        }
        // Once a window is exhausted the only thing that matters is when it returns.
        statusItem.button?.title = worst.pct >= 100
            ? "Claude \(pct(worst.pct)) · \(remaining(until: worst.resetsAt))"
            : "Claude \(pct(worst.pct))"
    }

    private func rebuildMenu() {
        accountsWindow?.reload()
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
            let lines = ["\(r.active && r.lastSeen == nil ? "●" : "○") \(label)",
                         windowLine(T.fiveHourLine, tag: "5h", r.fiveHour),
                         windowLine(T.sevenDayLine, tag: "7d", r.sevenDay)]
                + r.models.map { String(format: T.modelLine, bar($0.pct), paddedPct($0.pct), $0.label) }
            for line in lines { menu.addItem(disabled(line)) }
        }

        menu.addItem(.separator())
        menu.addItem(action(T.refreshNow, #selector(poll)))
        menu.addItem(action(T.addAccount, #selector(addAccount)))
        menu.addItem(action(T.manageAccounts, #selector(manageAccounts)))
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
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return showError(T.keyRequired) }
        if !name.isEmpty, isTaken(name) { return showError(String(format: T.accountExists, name)) }

        if isOAuthToken(key) { return addOAuthAccount(name: name, token: key) }
        guard !name.isEmpty else { return showError(T.nameRequired) }

        discoverOrgId(sessionKey: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let err):
                    self.showError(err.localizedDescription)
                case .success(let orgId):
                    let status = storeAddedKey(key, account: keyAccount(.sessionKey, name))
                    guard status == errSecSuccess else {
                        return self.showError(String(format: T.keychainFailed, Int(status)))
                    }
                    var cfg = loadConfig()
                    cfg.accounts = cfg.accountList
                        + [Account(name: name, session_key: "", org_id: orgId, keychain: true)]
                    self.save(cfg)
                }
            }
        }
    }

    /// A name already on screen or in the config — two rows under one name would share
    /// their state.
    private func isTaken(_ name: String) -> Bool {
        sourceNames.contains(name) || config.configuredNames.contains(name)
    }

    /// Checks the token against the usage endpoint before saving it, so a token that cannot
    /// read limits is turned away here instead of becoming an error row.
    private func addOAuthAccount(name: String, token: String) {
        checkToken(token) { [weak self] in
            guard let self else { return }
            guard name.isEmpty else { return self.saveOAuthAccount(name: name, token: token) }
            fetchOAuthLabel(token: token) { email in
                DispatchQueue.main.async {
                    guard let email else { return self.showError(T.tokenNeedsName) }
                    self.saveOAuthAccount(name: email, token: token)
                }
            }
        }
    }

    /// Runs `then` on the main thread only if the token can read usage limits; otherwise
    /// says why it cannot.
    private func checkToken(_ token: String, then: @escaping () -> Void) {
        fetchUsageOAuth(token: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let err):
                    if case .auth(let code)? = err as? ClaudeError {
                        return self.showError(String(format: T.tokenRejected, code))
                    }
                    self.showError(err.localizedDescription)
                case .success(let usage):
                    guard makeReading(usage) != nil else { return self.showError(T.shapeError) }
                    then()
                }
            }
        }
    }

    private func saveOAuthAccount(name: String, token: String) {
        guard !isTaken(name) else { return showError(String(format: T.accountExists, name)) }
        let status = storeAddedKey(token, account: keyAccount(.token, name))
        guard status == errSecSuccess else {
            return showError(String(format: T.keychainFailed, Int(status)))
        }
        var cfg = loadConfig()
        cfg.oauth_accounts = cfg.oauthAccountList + [OAuthAccount(name: name, token: "", keychain: true)]
        save(cfg)
    }

    private func save(_ cfg: Config) {
        do {
            try saveConfig(cfg)
            config = cfg
            startTimers()
            poll()
        } catch {
            showError(String(format: T.saveFailed, error.localizedDescription))
        }
    }

    // MARK: Accounts window

    @objc private func manageAccounts() {
        if accountsWindow == nil {
            accountsWindow = AccountsWindowController(
                rows: { [weak self] in self?.accountRows() ?? [] },
                onAdd: { [weak self] in self?.addAccount() },
                onReplaceKey: { [weak self] in self?.replaceKey(for: $0) },
                onRemove: { [weak self] in self?.removeAccount(named: $0.name) })
        }
        accountsWindow?.show()
    }

    private func accountRows() -> [AccountRow] {
        claudeCodeNames.map { AccountRow(name: $0, kind: .claudeCode, inKeychain: true, status: statusText($0)) }
            + config.accountList.filter(\.isFilledIn).map {
                AccountRow(name: $0.name, kind: .sessionKey, inKeychain: $0.inKeychain, status: statusText($0.name))
            }
            + config.oauthAccountList.filter(\.isFilledIn).map {
                AccountRow(name: $0.name, kind: .token, inKeychain: $0.inKeychain, status: statusText($0.name))
            }
    }

    private func statusText(_ name: String) -> String {
        guard let r = readings[name] else { return T.loading }
        if let err = r.error { return err }
        func figure(_ w: Window?) -> String { w.map { pct($0.pct) } ?? "—" }
        return String(format: T.statusLine, figure(r.fiveHour), figure(r.sevenDay))
    }

    /// Asks for a new key, checks it the same way adding an account does, and only then
    /// replaces the old one in the Keychain.
    private func replaceKey(for row: AccountRow) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(format: T.replaceKeyTitle, row.name)
        alert.informativeText = T.replaceKeyHint
        alert.addButton(withTitle: T.saveButton)
        alert.addButton(withTitle: T.cancelButton)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = row.kind == .token ? "sk-ant-oat…" : "sk-ant-sid…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return showError(T.keyRequired) }
        guard isOAuthToken(key) == (row.kind == .token) else {
            return showError(String(format: T.wrongKeyKind, row.typeText))
        }
        if row.kind == .token {
            checkToken(key) { [weak self] in self?.commitKey(key, for: row, orgId: nil) }
            return
        }
        discoverOrgId(sessionKey: key) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let err): self?.showError(err.localizedDescription)
                case .success(let orgId): self?.commitKey(key, for: row, orgId: orgId)
                }
            }
        }
    }

    private func commitKey(_ key: String, for row: AccountRow, orgId: String?) {
        let kind: KeyKind = row.kind == .token ? .token : .sessionKey
        let status = storeAddedKey(key, account: keyAccount(kind, row.name))
        guard status == errSecSuccess else { return showError(String(format: T.keychainFailed, Int(status))) }
        var cfg = loadConfig()
        if kind == .token {
            cfg.oauth_accounts = cfg.oauthAccountList.map {
                $0.name == row.name ? OAuthAccount(name: $0.name, token: "", keychain: true) : $0
            }
        } else {
            cfg.accounts = cfg.accountList.map {
                $0.name == row.name
                    ? Account(name: $0.name, session_key: "", org_id: orgId ?? $0.org_id, keychain: true) : $0
            }
        }
        // The new key may belong to a different account, so the old baseline cannot be
        // trusted to tell a reset from a switch.
        baselines.removeValue(forKey: row.name)
        fastPolled.removeValue(forKey: row.name)
        save(cfg)
    }

    private func removeAccount(named name: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(format: T.removeTitle, name)
        alert.informativeText = T.removeHint
        alert.addButton(withTitle: T.removeButton)
        alert.addButton(withTitle: T.cancelButton)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var cfg = loadConfig()
        cfg.accounts = cfg.accountList.filter { $0.name != name }
        let tokens = cfg.oauthAccountList.filter { $0.name != name }
        cfg.oauth_accounts = tokens.isEmpty ? nil : tokens
        deleteAddedKey(account: keyAccount(.sessionKey, name))
        deleteAddedKey(account: keyAccount(.token, name))
        // Forgotten outright — a removed account should not linger as a snapshot.
        readings.removeValue(forKey: name)
        baselines.removeValue(forKey: name)
        fastPolled.removeValue(forKey: name)
        staleAccounts.removeValue(forKey: name)
        save(cfg)
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
        assert(!l.lastSeen.isEmpty && !l.loading.isEmpty && !l.idleLine.isEmpty, "status strings: \(code)")
        assert(!l.manageAccounts.isEmpty && !l.removeTitle.isEmpty && !l.removeButton.isEmpty
               && l.statusLine.components(separatedBy: "%@").count == 3
               && l.replaceKeyTitle.contains("%@") && l.wrongKeyKind.contains("%@")
               && !l.colStorage.isEmpty && !l.storageKeychain.isEmpty && !l.keyRequired.isEmpty && !l.nameRequired.isEmpty
               && !l.tokenNeedsName.isEmpty && l.tokenRejected.contains("%d")
               && !l.keyMissing.isEmpty && l.keychainFailed.contains("%d"), "account strings: \(code)")
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

    // A window whose dedicated field went null is read from limits[] instead — the same
    // move the per-model caps already made, and the shape that left the app showing
    // "unexpected shape" while Claude Code itself was fine.
    let nulledJSON = """
    {"five_hour":null,
     "seven_day":{"utilization":null,"resets_at":null},
     "limits":[{"kind":"session","group":"session","percent":9,"is_active":true,
                "resets_at":"2026-08-17T14:29:59Z"},
               {"kind":"weekly_all","group":"weekly","percent":25,
                "resets_at":"2026-08-22T22:59:59Z"}]}
    """
    let nulled = try! JSONDecoder().decode(UsageResponse.self, from: nulledJSON.data(using: .utf8)!)
    let fromLimits = windowReading(nulled.five_hour, nulled.limits, kind: "session")
    assert(fromLimits?.pct == 9, "a null five_hour falls back to the session entry")
    assert(windowReading(nulled.seven_day, nulled.limits, kind: "weekly_all")?.pct == 25,
           "null fields inside a window fall back the same way")
    assert(fromLimits?.resetsAt == parseISO("2026-08-17T14:29:59Z"),
           "the reset time comes along with the percentage")

    // The dedicated field still wins while the API reports it.
    assert(windowReading(scoped.five_hour, scoped.limits, kind: "session")?.pct == 9)

    // Nothing to read anywhere is still an error rather than a row of zeros.
    let emptyJSON = #"{"five_hour":null,"seven_day":null,"limits":[]}"#
    let empty = try! JSONDecoder().decode(UsageResponse.self, from: emptyJSON.data(using: .utf8)!)
    assert(windowReading(empty.five_hour, empty.limits, kind: "session") == nil,
           "an empty response reports failure, it does not invent a reading")

    // The shape the API sends since 2026-11 while no 5-hour window is running: five_hour
    // is null and limits[] has no session entry at all. The account stays readable, with
    // the weekly window on show and the 5-hour one marked idle — this used to fail the
    // whole Keychain account with "unexpected response shape".
    let idleJSON = """
    {"five_hour":null,
     "seven_day":{"utilization":58.0,"resets_at":"2026-11-08T00:59:59.858545+00:00"},
     "limits":[{"kind":"weekly_all","group":"weekly","percent":58,
                "resets_at":"2026-11-08T00:59:59.858545+00:00","is_active":true},
               {"kind":"weekly_scoped","group":"weekly","percent":0,
                "resets_at":"2026-11-08T01:00:00+00:00",
                "scope":{"model":{"display_name":"Fable"}},"is_active":false}]}
    """
    let idle = try! JSONDecoder().decode(UsageResponse.self, from: idleJSON.data(using: .utf8)!)
    let idleReading = makeReading(idle)
    assert(idleReading != nil, "a missing 5-hour window does not fail the account")
    assert(idleReading?.fiveHour == nil, "an idle 5-hour window is reported as absent, not as 0%")
    assert(idleReading?.sevenDay?.pct == 58, "the weekly window still comes through")
    assert(idleReading?.headline?.pct == 58, "the menu bar falls back to the weekly figure")
    assert(idleReading?.models.first?.label == "Fable", "per-model caps still come through")
    assert(windowLine(T.fiveHourLine, tag: "5h", nil).contains("5h"), "the idle line names its window")
    assert(makeReading(empty) == nil, "nothing readable anywhere still fails")
    assert(makeReading(scoped)?.headline?.pct == 9, "a running 5-hour window drives the menu bar")

    // Several Claude Code logins: expired ones are dropped, the rest come freshest first,
    // and a token stored twice (Keychain and file) is polled once.
    let nowMs = now.timeIntervalSince1970 * 1000
    let creds = [StoredCredential(token: "old", expiresAt: nowMs - 1000),
                 StoredCredential(token: "b", expiresAt: nowMs + 1000),
                 StoredCredential(token: "a", expiresAt: nowMs + 9000),
                 StoredCredential(token: "b", expiresAt: nowMs + 1000)]
    assert(liveTokens(creds, now: now) == ["a", "b"], "live tokens, freshest first, each once")
    assert(liveTokens([StoredCredential(token: "x", expiresAt: 0)], now: now) == ["x"],
           "a token without an expiry is kept")
    assert(liveTokens([StoredCredential(token: "old", expiresAt: nowMs - 1000),
                       StoredCredential(token: "older", expiresAt: nowMs - 9000)], now: now) == ["old"],
           "with every token expired the freshest stays, so the row can say why")
    assert(liveTokens([], now: now).isEmpty)

    let named = nameClaudeCodeLogins(tokens: ["t1", "t2", "t3", "t4"],
                                     emails: ["a@x", nil, "a@x", "cfg@x"],
                                     known: ["t2": "b@x"], previous: [], configured: ["cfg@x"])
    assert(named.map(\.name) == ["a@x", "b@x"],
           "emails name logins, a known token keeps its name, duplicates and configured names are skipped")
    assert(nameClaudeCodeLogins(tokens: ["new"], emails: [nil], known: [:], previous: ["me@x"],
                                configured: [])[0].name == "me@x",
           "a single login whose email is unavailable keeps the previous name")
    assert(nameClaudeCodeLogins(tokens: ["t1", "t2"], emails: [nil, nil], known: [:], previous: [],
                                configured: []).map(\.name) == ["Claude Code", "Claude Code 2"],
           "unnamed logins get distinct names")

    // A hand-written account may leave out org_id; it decodes empty instead of costing the
    // whole file. OAuth accounts sit in their own key.
    let multiJSON = #"{"accounts":[{"name":"s","session_key":"sk-ant-sid1"}],"oauth_accounts":[{"name":"t","token":"sk-ant-oat1"}]}"#
    let multi = try! JSONDecoder().decode(Config.self, from: multiJSON.data(using: .utf8)!)
    assert(multi.accountList.first?.org_id == "", "a missing org_id decodes empty")
    assert(multi.configuredNames == ["s", "t"], "both kinds of account are listed, in order")
    assert(isOAuthToken("sk-ant-oat01-abc") && !isOAuthToken("sk-ant-sid01-abc"))
    let skeletonJSON = #"{"accounts":[{"name":"","session_key":"","org_id":""}]}"#
    let skeleton = try! JSONDecoder().decode(Config.self, from: skeletonJSON.data(using: .utf8)!)
    assert(skeleton.configuredNames.isEmpty, "an unfilled skeleton entry is not an account")

    // An account whose key moved to the Keychain has an empty key in the file and is still
    // an account; the marker survives a round trip through the encoder.
    let kcJSON = #"{"accounts":[{"name":"s","session_key":"","org_id":"o","keychain":true}],"oauth_accounts":[{"name":"t","token":"","keychain":true}]}"#
    let kc = try! JSONDecoder().decode(Config.self, from: kcJSON.data(using: .utf8)!)
    assert(kc.configuredNames == ["s", "t"], "Keychain-backed entries count as accounts")
    let kcBack = try! JSONDecoder().decode(Config.self, from: JSONEncoder().encode(kc))
    assert(kcBack.accountList.first?.inKeychain == true && kcBack.oauthAccountList.first?.inKeychain == true,
           "the Keychain marker is written back")
    assert(keyAccount(.sessionKey, "a") != keyAccount(.token, "a"), "the two kinds never share an item")

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
