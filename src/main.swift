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
    /// Emails of Claude Code logins hidden from the menu. Hiding never touches the login.
    var hidden_logins: [String]?
    /// Which account the menu bar figure follows: absent for the Claude Code login,
    /// `mostUsedChoice` for the fullest account, or an account's name.
    var menu_bar_account: String?
    var check_interval_minutes: Int?
    var slack_webhook_url: String?   // unused here, kept for claude-reset compatibility
    var language: String?

    var accountList: [Account] { accounts ?? [] }
    var oauthAccountList: [OAuthAccount] { oauth_accounts ?? [] }
    var hiddenLogins: [String] { hidden_logins ?? [] }
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
    /// The limit resets the account holds. Only sent when the request asks for it.
    var cedar_ember: ResetStatus? = nil
}

/// The block that lists an account's limit resets: grants that clear a limit before its
/// window ends. Decoding never fails — the block is undocumented, and a grant that has
/// changed shape should cost that grant, not the account's whole reading.
struct ResetStatus: Codable {
    let grants: [Grant]

    struct Grant: Codable {
        /// The limits the reset clears, by the API's own names ("seven_day", ...).
        let clears: [String]?
        let resets_left: Int?
        let ends_at: String?
    }

    private struct Lossy: Decodable {
        let grant: Grant?
        init(from decoder: Decoder) { grant = try? Grant(from: decoder) }
    }

    init(grants: [Grant]) { self.grants = grants }

    init(from decoder: Decoder) {
        let box = try? decoder.container(keyedBy: CodingKeys.self)
        grants = ((try? box?.decode([Lossy].self, forKey: .grants)) ?? []).compactMap(\.grant)
    }
}

/// How many resets of one kind an account still holds.
struct ResetCount: Equatable {
    /// "full", "session", or a model's name in lower case.
    let kind: String
    let count: Int
}

/// What a reset is called, from the limits it clears. One that clears the weekly limit is
/// a full reset, whatever else it clears with it; one for the 5-hour window alone is a
/// session reset; anything else clears one model's weekly cap and carries that model's name.
func resetKind(clears: [String]) -> String? {
    if clears.contains("seven_day") { return "full" }
    if clears.contains("five_hour") { return "session" }
    guard let first = clears.first else { return nil }
    // The models billed against the plan beyond its base allowance — today that is Fable.
    if first == "seven_day_overage_included" { return "fable" }
    return first.hasPrefix("seven_day_") ? String(first.dropFirst("seven_day_".count)) : first
}

/// The resets still to be used, added up per kind: the full one first, then the rest by
/// name. A grant that is spent or past its end date counts for nothing.
func resetCounts(_ usage: UsageResponse, now: Date) -> [ResetCount] {
    var totals: [String: Int] = [:]
    for grant in usage.cedar_ember?.grants ?? [] {
        guard let left = grant.resets_left, left > 0, let kind = resetKind(clears: grant.clears ?? [])
        else { continue }
        if let end = grant.ends_at.flatMap(parseISO), end <= now { continue }
        totals[kind, default: 0] += left
    }
    func rank(_ kind: String) -> Int { kind == "full" ? 0 : kind == "session" ? 1 : 2 }
    return totals.map { ResetCount(kind: $0.key, count: $0.value) }
        .sorted { (rank($0.kind), $0.kind) < (rank($1.kind), $1.kind) }
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
    var resets: [ResetCount] = []
    var active: Bool
    var error: String?
    /// nil for a live account. Set when the account can no longer be polled — Claude Code
    /// was signed into a different one — and the row becomes a read-only snapshot of the
    /// final reading.
    var lastSeen: Date?

    /// The window that limits you right now: the fuller of the two. A spent weekly limit
    /// blocks the account however empty the 5-hour window is. This is what the menu bar
    /// figure shows.
    var headline: Window? {
        guard let five = fiveHour else { return sevenDay }
        guard let seven = sevenDay else { return five }
        return seven.pct > five.pct ? seven : five
    }
}

/// The `menu_bar_account` value that makes the menu bar follow the fullest account.
let mostUsedChoice = "*most-used"

/// The reading the menu bar figure follows. By default that is the account signed into
/// Claude Code. A chosen account wins while it has a live reading; otherwise, and when no
/// Claude Code login is readable either, the fullest account stands in, so the figure
/// never goes blank while some account can be read.
func menuBarReading(choice: String?, claudeCode: [String], all: [String],
                    readings: [String: Reading]) -> Reading? {
    func live(_ name: String) -> Reading? {
        guard let r = readings[name], r.error == nil, r.lastSeen == nil, r.headline != nil else { return nil }
        return r
    }
    let mostUsed = all.compactMap(live).max { ($0.headline?.pct ?? 0) < ($1.headline?.pct ?? 0) }
    if choice == mostUsedChoice { return mostUsed }
    if let choice, let r = live(choice) { return r }
    return claudeCode.lazy.compactMap(live).first ?? mostUsed
}

/// Turns a usage response into a reading. Each window is optional; the account only counts
/// as unreadable when neither the 5-hour nor the 7-day window can be found anywhere.
func makeReading(_ usage: UsageResponse) -> Reading? { makeReading(usage, now: Date()) }

func makeReading(_ usage: UsageResponse, now: Date) -> Reading? {
    let five = windowReading(usage.five_hour, usage.limits, kind: "session")
    let seven = windowReading(usage.seven_day, usage.limits, kind: "weekly_all")
    guard five != nil || seven != nil else { return nil }
    let session = usage.limits?.first { $0.group == "session" || $0.kind == "session" }
    return Reading(fiveHour: five, sevenDay: seven, models: modelWindows(usage),
                   resets: resetCounts(usage, now: now),
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
        case .http(429, _):
            return T.rateLimited
        case .http(let code, let body):
            return String(format: T.httpError, code, apiErrorMessage(body))
        case .shape:
            return T.shapeError
        }
    }
}

/// The readable part of an error body: the API's own message when it sent one, otherwise
/// the body squeezed onto one line — a menu item and a table cell show a single line.
func apiErrorMessage(_ body: String) -> String {
    if let data = body.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let message = (json["error"] as? [String: Any])?["message"] as? String, !message.isEmpty {
        return message
    }
    let oneLine = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return String(oneLine.prefix(120))
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

/// The usage endpoint lists an account's limit resets only for a request that names the
/// Claude Code CLI; any other client is told the account is not eligible.
let claudeCodeUserAgent = "claude-cli/2.1.323 (external, cli)"

func anthropicRequest(path: String, token: String) -> URLRequest {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue(claudeCodeUserAgent, forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    return req
}

func fetchUsageOAuth(token: String, completion: @escaping (Result<UsageResponse, Error>) -> Void) {
    // cedar_ember=1 asks for the limit resets on top of the usual reading.
    fetchJSON(anthropicRequest(path: "/api/oauth/usage?cedar_ember=1", token: token)) { completion(decodeUsage($0)) }
}

// MARK: - Limits from inference headers (tokens from `claude setup-token`)

// A token from `claude setup-token` carries only the user:inference scope. The usage
// endpoint answers it with 429 and a retry-after of about an hour, and the profile endpoint
// with 403. Every inference response, though, reports the account's limits in its headers
// (anthropic-ratelimit-unified-5h-utilization, -7d-utilization, -5h-reset, ...). So for such
// a token the limits are read from a one-token request. It costs that account a few dozen
// tokens per poll. count_tokens would be free, but it does not send these headers.
//
// A weekly cap that applies to one model only is reported solely on a request to that
// model, as a second weekly claim (anthropic-ratelimit-unified-7d_<claim>-utilization). So
// the probe goes to the capped model, and its few dozen tokens count against that cap. An
// account that may not use the model is probed on the smallest one instead and shows no
// per-model line.

/// One model the probe can be sent to. `scopedLabel` names the per-model weekly cap its
/// response reports; nil when the model has none.
struct ProbeModel {
    let id: String
    let scopedLabel: String?
}

/// The model with a weekly cap of its own.
let scopedProbe = ProbeModel(id: "claude-fable-5-2", scopedLabel: "Fable")
/// The smallest current model: the probe for accounts the capped model turns away.
let plainProbe = ProbeModel(id: "claude-haiku-5-5", scopedLabel: nil)

/// Turns the unified rate-limit headers into the same shape the usage endpoint returns.
/// Utilization comes as a fraction (0.16) and the reset as Unix seconds. Keys must be
/// lowercased. A scoped weekly claim becomes a "weekly_scoped" entry under `scopedLabel`,
/// the model the request went to. Returns nil when no window is reported at all.
func usageFromHeaders(_ headers: [String: String], scopedLabel: String? = nil) -> UsageResponse? {
    let prefix = "anthropic-ratelimit-unified-"
    func window(_ tag: String) -> UsageWindow? {
        guard let raw = headers["\(prefix)\(tag)-utilization"],
              let fraction = Double(raw) else { return nil }
        let reset = headers["\(prefix)\(tag)-reset"].flatMap(Double.init)
            .map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
        return UsageWindow(utilization: fraction * 100, resets_at: reset)
    }
    let five = window("5h"), seven = window("7d")
    guard five != nil || seven != nil else { return nil }

    // The claim's own name ("7d_oi") is opaque, so any scoped weekly claim is taken; should
    // a response carry several, the fullest one is the one that limits the model.
    var limits: [UsageLimit]?
    if let scopedLabel {
        let scoped = headers.keys
            .filter { $0.hasPrefix("\(prefix)7d_") && $0.hasSuffix("-utilization") }
            .compactMap { window(String($0.dropFirst(prefix.count).dropLast("-utilization".count))) }
            .max { ($0.utilization ?? 0) < ($1.utilization ?? 0) }
        if let scoped {
            limits = [UsageLimit(group: "weekly", kind: "weekly_scoped", percent: scoped.utilization,
                                 is_active: nil, resets_at: scoped.resets_at,
                                 scope: .init(model: .init(display_name: scopedLabel)))]
        }
    }
    return UsageResponse(five_hour: five, seven_day: seven, seven_day_opus: nil,
                         seven_day_sonnet: nil, limits: limits)
}

/// Tokens the capped model turned away, and until when to probe the smallest one for them.
private let scopedProbeRefusals = UsageRefusals()

/// Whether a failed probe says the account may not use the model at all, as opposed to the
/// API having a bad moment: 403 for no access, 404 or 400 for a model it does not offer.
func modelIsRefused(_ error: Error) -> Bool {
    switch error {
    case ClaudeError.auth(403), ClaudeError.http(400, _), ClaudeError.http(404, _): return true
    default: return false
    }
}

/// Limits for a token the usage endpoint refuses. The capped model is asked first, because
/// only its response carries the per-model weekly cap. When it answers without limit
/// headers the smallest model is asked instead; when the answer was that the account may
/// not use the capped model, for the next day directly.
func fetchUsageFromHeaders(token: String, completion: @escaping (Result<UsageResponse, Error>) -> Void) {
    guard !scopedProbeRefusals.isRefused(token) else {
        return probeUsage(token: token, model: plainProbe, completion: completion)
    }
    probeUsage(token: token, model: scopedProbe) { result in
        // A dead token (401) and a network error fail on any model alike.
        guard case .failure(let error) = result, case let failure as ClaudeError = error,
              !{ if case .auth(401) = failure { return true } else { return false } }()
        else { return completion(result) }
        probeUsage(token: token, model: plainProbe) { second in
            if case .success = second, modelIsRefused(failure) {
                scopedProbeRefusals.refuse(token, for: 86400)
            }
            completion(second)
        }
    }
}

func probeUsage(token: String, model: ProbeModel,
                completion: @escaping (Result<UsageResponse, Error>) -> Void) {
    var req = anthropicRequest(path: "/v1/messages", token: token)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    let body: [String: Any] = [
        "model": model.id,
        "max_tokens": 1,
        // OAuth tokens are only accepted for requests that present themselves as Claude Code.
        "system": "You are Claude Code, Anthropic's official CLI for Claude.",
        "messages": [["role": "user", "content": "hi"]],
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err { return completion(.failure(err)) }
        guard let http = resp as? HTTPURLResponse else { return completion(.failure(ClaudeError.shape)) }
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if http.statusCode == 401 || http.statusCode == 403 { return completion(.failure(ClaudeError.auth(http.statusCode))) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        // A 429 from inference still carries the headers — and then they matter most.
        if let usage = usageFromHeaders(headers, scopedLabel: model.scopedLabel) {
            return completion(.success(usage))
        }
        guard (200..<300).contains(http.statusCode) else {
            return completion(.failure(ClaudeError.http(http.statusCode, text)))
        }
        completion(.failure(ClaudeError.shape))
    }.resume()
}

/// Tokens the usage endpoint turned away, and until when to leave it alone for them.
private let usageRefusals = UsageRefusals()

final class UsageRefusals {
    private var until: [String: Date] = [:]
    private let lock = NSLock()

    func isRefused(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (until[token] ?? .distantPast) > Date()
    }

    func refuse(_ token: String, for seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        until[token] = Date().addingTimeInterval(seconds)
    }
}

/// Usage for a token added to the app: the usage endpoint while it answers, the inference
/// headers when it refuses the token (403 for a missing scope, 429 for its hourly cap).
func fetchUsageForToken(token: String, completion: @escaping (Result<UsageResponse, Error>) -> Void) {
    guard !usageRefusals.isRefused(token) else { return fetchUsageFromHeaders(token: token, completion: completion) }
    fetchUsageOAuth(token: token) { result in
        switch result {
        case .failure(ClaudeError.http(429, _)):
            usageRefusals.refuse(token, for: 3600)
            fetchUsageFromHeaders(token: token, completion: completion)
        case .failure(ClaudeError.auth(403)):
            usageRefusals.refuse(token, for: 86400)
            fetchUsageFromHeaders(token: token, completion: completion)
        default:
            completion(result)
        }
    }
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
            fetchUsageForToken(token: token) { [weak self] result in
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
                                          configured: Set(config.configuredNames + config.hiddenLogins))
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
        case .failure(ClaudeError.http(429, _)) where readings[name].map({ $0.error == nil && $0.lastSeen == nil }) == true:
            // Rate limited: the last reading is minutes old at most and resets_at has not
            // moved, so it stays on show until the next poll gets through.
            break
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
        guard let worst = menuBarReading(choice: config.menu_bar_account, claudeCode: claudeCodeNames,
                                         all: sourceNames, readings: readings)?.headline else {
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
                + r.resets.map { String(format: T.resetLine, $0.count, $0.kind) }
            for line in lines { menu.addItem(disabled(line)) }
        }

        menu.addItem(.separator())
        menu.addItem(action(T.refreshNow, #selector(poll)))
        menu.addItem(action(T.addAccount, #selector(addAccountFromMenu)))
        menu.addItem(action(T.manageAccounts, #selector(manageAccounts)))
        menu.addItem(action(T.openConfig, #selector(openConfig)))
        menu.addItem(menuBarChoiceItem())
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

    /// Which account the menu bar figure follows. Only live accounts are offered; a chosen
    /// account that disappears falls back to the default without losing the setting.
    private func menuBarChoiceItem() -> NSMenuItem {
        let parent = NSMenuItem(title: T.menuBarShows, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = config.menu_bar_account
        func item(_ title: String, _ choice: String?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(pickMenuBarAccount(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = choice
            i.state = choice == current ? .on : .off
            return i
        }
        submenu.addItem(item(T.menuBarDefault, nil))
        submenu.addItem(item(T.menuBarMostUsed, mostUsedChoice))
        let named = sourceNames.filter { readings[$0]?.lastSeen == nil }
        if !named.isEmpty { submenu.addItem(.separator()) }
        for name in named { submenu.addItem(item(name, name)) }
        parent.submenu = submenu
        return parent
    }

    @objc private func pickMenuBarAccount(_ sender: NSMenuItem) {
        let choice = sender.representedObject as? String
        do {
            try saveConfigField("menu_bar_account", choice)
        } catch {
            return showError(String(format: T.saveFailed, error.localizedDescription))
        }
        config = loadConfig()
        updateTitle()
        rebuildMenu()
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

    // MARK: Accounts window
    //
    // Everything about accounts is edited in one window, without dialogs: the operations
    // below report back through a completion, and the window shows the outcome inline.

    @objc private func manageAccounts() {
        if accountsWindow == nil {
            accountsWindow = AccountsWindowController(
                rows: { [weak self] in self?.accountRows() ?? [] },
                onAdd: { [weak self] name, key, done in self?.addAccount(name: name, key: key, done: done) },
                onRename: { [weak self] row, name, done in self?.rename(row, to: name, done: done) },
                onReplaceKey: { [weak self] row, key, done in self?.replaceKey(of: row, with: key, done: done) },
                onRemove: { [weak self] row, done in self?.remove(row, done: done) },
                onSetHidden: { [weak self] row, hidden, done in self?.setHidden(row, hidden, done: done) })
        }
        accountsWindow?.show()
    }

    @objc private func addAccountFromMenu() {
        manageAccounts()
        accountsWindow?.focusAddForm()
    }

    private func accountRows() -> [AccountRow] {
        claudeCodeNames.map {
            AccountRow(name: $0, kind: .claudeCode, inKeychain: true, hidden: false, status: statusText($0))
        }
        + config.hiddenLogins.map {
            AccountRow(name: $0, kind: .claudeCode, inKeychain: true, hidden: true, status: T.statusHidden)
        }
        + config.accountList.filter(\.isFilledIn).map {
            AccountRow(name: $0.name, kind: .sessionKey, inKeychain: $0.inKeychain, hidden: false,
                       status: statusText($0.name))
        }
        + config.oauthAccountList.filter(\.isFilledIn).map {
            AccountRow(name: $0.name, kind: .token, inKeychain: $0.inKeychain, hidden: false,
                       status: statusText($0.name))
        }
    }

    private func statusText(_ name: String) -> String {
        guard let r = readings[name] else { return T.loading }
        if let err = r.error { return err }
        func figure(_ w: Window?) -> String { w.map { pct($0.pct) } ?? "—" }
        return String(format: T.statusLine, figure(r.fiveHour), figure(r.sevenDay))
    }

    /// A name already on screen or in the config — two rows under one name would share
    /// their state.
    private func isTaken(_ name: String) -> Bool {
        sourceNames.contains(name) || config.configuredNames.contains(name) || config.hiddenLogins.contains(name)
    }

    /// What checking a key found out about its account.
    private struct VerifiedKey {
        var orgId: String?
        var email: String?
    }

    /// Checks a key before anything is saved: a token must be able to read usage limits,
    /// a sessionKey must lead to an organization.
    private func verify(_ key: String, done: @escaping (Result<VerifiedKey, EditFailure>) -> Void) {
        guard isOAuthToken(key) else {
            discoverOrgId(sessionKey: key) { result in
                DispatchQueue.main.async {
                    done(result.map { VerifiedKey(orgId: $0) }
                        .mapError { EditFailure($0.localizedDescription) })
                }
            }
            return
        }
        fetchUsageForToken(token: key) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    if case .auth(let code)? = err as? ClaudeError {
                        return done(.failure(EditFailure(String(format: T.tokenRejected, code))))
                    }
                    done(.failure(EditFailure(err.localizedDescription)))
                case .success(let usage):
                    guard makeReading(usage) != nil else { return done(.failure(EditFailure(T.shapeError))) }
                    fetchOAuthLabel(token: key) { email in
                        DispatchQueue.main.async { done(.success(VerifiedKey(email: email))) }
                    }
                }
            }
        }
    }

    private func addAccount(name rawName: String, key rawKey: String, done: @escaping (EditResult) -> Void) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return done(.failure(EditFailure(T.keyRequired))) }
        let isToken = isOAuthToken(key)
        guard isToken || !name.isEmpty else { return done(.failure(EditFailure(T.nameRequired))) }
        if !name.isEmpty, isTaken(name) {
            return done(.failure(EditFailure(String(format: T.accountExists, name))))
        }
        verify(key) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let f):
                done(.failure(f))
            case .success(let found):
                guard let finalName = name.isEmpty ? found.email : name else {
                    return done(.failure(EditFailure(T.tokenNeedsName)))
                }
                guard name.isEmpty == false || !self.isTaken(finalName) else {
                    return done(.failure(EditFailure(String(format: T.accountExists, finalName))))
                }
                let status = storeAddedKey(key, account: keyAccount(isToken ? .token : .sessionKey, finalName))
                guard status == errSecSuccess else {
                    return done(.failure(EditFailure(String(format: T.keychainFailed, Int(status)))))
                }
                var cfg = loadConfig()
                if isToken {
                    cfg.oauth_accounts = cfg.oauthAccountList + [OAuthAccount(name: finalName, token: "", keychain: true)]
                } else {
                    cfg.accounts = cfg.accountList
                        + [Account(name: finalName, session_key: "", org_id: found.orgId ?? "", keychain: true)]
                }
                done(self.persist(cfg).map { finalName })
            }
        }
    }

    /// Checks the new key the same way adding an account does, and only then replaces the
    /// old one in the Keychain.
    private func replaceKey(of row: AccountRow, with rawKey: String, done: @escaping (EditResult) -> Void) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard row.editable else { return }
        guard !key.isEmpty else { return done(.failure(EditFailure(T.keyRequired))) }
        guard isOAuthToken(key) == (row.kind == .token) else {
            return done(.failure(EditFailure(String(format: T.wrongKeyKind, row.typeText))))
        }
        verify(key) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let f):
                done(.failure(f))
            case .success(let found):
                let kind: KeyKind = row.kind == .token ? .token : .sessionKey
                let status = storeAddedKey(key, account: keyAccount(kind, row.name))
                guard status == errSecSuccess else {
                    return done(.failure(EditFailure(String(format: T.keychainFailed, Int(status)))))
                }
                var cfg = loadConfig()
                cfg.oauth_accounts = cfg.oauth_accounts?.map {
                    $0.name == row.name && kind == .token ? OAuthAccount(name: $0.name, token: "", keychain: true) : $0
                }
                cfg.accounts = cfg.accounts?.map {
                    $0.name == row.name && kind == .sessionKey
                        ? Account(name: $0.name, session_key: "", org_id: found.orgId ?? $0.org_id, keychain: true) : $0
                }
                // The new key may belong to a different account, so the old baseline cannot
                // be trusted to tell a reset from a switch.
                self.baselines.removeValue(forKey: row.name)
                self.fastPolled.removeValue(forKey: row.name)
                done(self.persist(cfg).map { row.name })
            }
        }
    }

    /// Renames an added account, carrying its key and its state over to the new name.
    private func rename(_ row: AccountRow, to rawName: String, done: @escaping (EditResult) -> Void) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard row.editable, name != row.name else { return }
        guard !name.isEmpty else { return done(.failure(EditFailure(T.nameRequired))) }
        guard !isTaken(name) else { return done(.failure(EditFailure(String(format: T.accountExists, name)))) }

        let kind: KeyKind = row.kind == .token ? .token : .sessionKey
        if row.inKeychain {
            guard let key = readAddedKey(account: keyAccount(kind, row.name)) else {
                return done(.failure(EditFailure(T.keyMissing)))
            }
            let status = storeAddedKey(key, account: keyAccount(kind, name))
            guard status == errSecSuccess else {
                return done(.failure(EditFailure(String(format: T.keychainFailed, Int(status)))))
            }
        }
        var cfg = loadConfig()
        cfg.accounts = cfg.accounts?.map {
            guard $0.name == row.name, kind == .sessionKey else { return $0 }
            var a = $0
            a.name = name
            return a
        }
        cfg.oauth_accounts = cfg.oauth_accounts?.map {
            guard $0.name == row.name, kind == .token else { return $0 }
            var a = $0
            a.name = name
            return a
        }
        if case .failure(let f) = persist(cfg, pollAfter: false) {
            if row.inKeychain { deleteAddedKey(account: keyAccount(kind, name)) }
            return done(.failure(f))
        }
        if row.inKeychain { deleteAddedKey(account: keyAccount(kind, row.name)) }
        readings[name] = readings.removeValue(forKey: row.name)
        baselines[name] = baselines.removeValue(forKey: row.name)
        fastPolled[name] = fastPolled.removeValue(forKey: row.name)
        poll()
        done(.success(name))
    }

    private func remove(_ row: AccountRow, done: @escaping (EditResult) -> Void) {
        guard row.editable else { return }
        var cfg = loadConfig()
        cfg.accounts = cfg.accounts?.filter { $0.name != row.name }
        let tokens = cfg.oauthAccountList.filter { $0.name != row.name }
        cfg.oauth_accounts = tokens.isEmpty ? nil : tokens
        if case .failure(let f) = persist(cfg, pollAfter: false) { return done(.failure(f)) }
        deleteAddedKey(account: keyAccount(.sessionKey, row.name))
        deleteAddedKey(account: keyAccount(.token, row.name))
        // Forgotten outright — a removed account should not linger as a snapshot.
        forget(row.name)
        poll()
        done(.success(row.name))
    }

    /// Hides a Claude Code login from the menu, or shows it again. The login itself — its
    /// Keychain item, Claude Code's session — is never touched.
    private func setHidden(_ row: AccountRow, _ hidden: Bool, done: @escaping (EditResult) -> Void) {
        guard row.kind == .claudeCode else { return }
        var cfg = loadConfig()
        var list = cfg.hiddenLogins.filter { $0 != row.name }
        if hidden { list.append(row.name) }
        cfg.hidden_logins = list.isEmpty ? nil : list
        if case .failure(let f) = persist(cfg, pollAfter: false) { return done(.failure(f)) }
        if hidden {
            claudeCodeNames.removeAll { $0 == row.name }
            forget(row.name)
        }
        poll()
        done(.success(row.name))
    }

    private func forget(_ name: String) {
        readings.removeValue(forKey: name)
        baselines.removeValue(forKey: name)
        fastPolled.removeValue(forKey: name)
        staleAccounts.removeValue(forKey: name)
    }

    private func persist(_ cfg: Config, pollAfter: Bool = true) -> Result<Void, EditFailure> {
        do {
            try saveConfig(cfg)
        } catch {
            return .failure(EditFailure(String(format: T.saveFailed, error.localizedDescription)))
        }
        config = cfg
        if pollAfter {
            startTimers()
            poll()
        }
        return .success(())
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
        assert(!l.manageAccounts.isEmpty && !l.removeButton.isEmpty && !l.confirmRemove.isEmpty
               && l.statusLine.components(separatedBy: "%@").count == 3 && l.wrongKeyKind.contains("%@")
               && [l.msgAdded, l.msgKeyReplaced, l.msgRemoved, l.msgRenamed, l.msgHidden, l.msgShown]
                    .allSatisfy { $0.contains("%@") }
               && !l.colKey.isEmpty && !l.keyInKeychain.isEmpty && !l.hideLogin.isEmpty
               && !l.showLogin.isEmpty && !l.editHint.isEmpty && !l.keyRequired.isEmpty && !l.nameRequired.isEmpty
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
    assert(makeReading(scoped)?.headline?.pct == 25, "the fuller window drives the menu bar")
    let spent = Reading(fiveHour: (0, now), sevenDay: (100, now), active: false)
    assert(spent.headline?.pct == 100, "a spent weekly limit is not hidden behind an empty 5-hour window")

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

    // Limits read from inference headers — the route for setup-token tokens, which the usage
    // endpoint refuses. Values are the ones a real response carried.
    let fromHeaders = usageFromHeaders([
        "anthropic-ratelimit-unified-7d-utilization": "0.16",
        "anthropic-ratelimit-unified-7d-reset": "1794092400",
        "anthropic-ratelimit-unified-status": "allowed",
    ])
    let headerReading = fromHeaders.flatMap(makeReading)
    assert(headerReading?.sevenDay?.pct == 16, "the fraction becomes a percentage")
    assert(headerReading?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1794092400), "the reset time is carried")
    assert(headerReading?.fiveHour == nil, "no 5-hour header, no 5-hour window")
    assert(usageFromHeaders(["anthropic-ratelimit-unified-5h-utilization": "0.5",
                             "anthropic-ratelimit-unified-5h-reset": "1794000000"])?.five_hour?.utilization == 50)
    assert(usageFromHeaders(["content-type": "application/json"]) == nil, "no limit headers, no reading")

    // A request to a model with a weekly cap of its own reports that cap as a second weekly
    // claim. Headers are the ones a real response to such a request carried.
    let scopedHeaders = [
        "anthropic-ratelimit-unified-7d-utilization": "0.24",
        "anthropic-ratelimit-unified-7d-reset": "1794704400",
        "anthropic-ratelimit-unified-7d-status": "allowed",
        "anthropic-ratelimit-unified-7d_oi-utilization": "0.21",
        "anthropic-ratelimit-unified-7d_oi-reset": "1794704400",
        "anthropic-ratelimit-unified-7d_oi-status": "allowed",
        "anthropic-ratelimit-unified-reset": "1794704400",
    ]
    let scopedReading = usageFromHeaders(scopedHeaders, scopedLabel: "Fable").flatMap(makeReading)
    assert(scopedReading?.sevenDay?.pct == 24, "the scoped claim is not taken for the weekly window")
    assert(scopedReading?.models.count == 1 && scopedReading?.models.first?.label == "Fable"
           && scopedReading?.models.first?.pct == 21, "the scoped claim becomes the model's weekly cap")
    assert(usageFromHeaders(scopedHeaders).flatMap(makeReading)?.models.isEmpty == true,
           "a probe to a model without a cap of its own names no model")
    // Limit resets: counted per kind from the limits each grant clears. The first two
    // grants are the ones a real response carried; the rest cover what must not count.
    let resetJSON = #"""
    {"five_hour":null,
     "seven_day":{"utilization":24,"resets_at":"2026-11-15T01:00:00+00:00"},
     "cedar_ember":{"eligible":true,"grants":[
       {"id":"full-reset-2611","resets_total":1,"resets_left":1,"ends_at":"2026-12-10T22:00:00+00:00",
        "clears":["seven_day","seven_day_overage_included"],"type":"weekly"},
       {"id":"launch-2610-fable","resets_total":1,"resets_left":0,"ends_at":"2027-03-09T07:59:00+00:00",
        "clears":["seven_day_overage_included"],"type":"full"},
       {"id":"fable-a","resets_left":1,"clears":["seven_day_overage_included"]},
       {"id":"fable-b","resets_left":1,"clears":["seven_day_overage_included"],"ends_at":null},
       {"id":"opus","resets_left":3,"clears":["seven_day_opus"]},
       {"id":"expired","resets_left":5,"clears":["seven_day"],"ends_at":"2026-11-01T00:00:00+00:00"},
       {"id":"session","resets_left":1,"clears":["five_hour"]},
       {"id":"malformed","resets_left":"many","clears":["seven_day"]},
       "not a grant"]}}
    """#
    let resetUsage = try! JSONDecoder().decode(UsageResponse.self, from: Data(resetJSON.utf8))
    let resetNow = parseISO("2026-11-13T20:00:00+00:00")!
    assert(makeReading(resetUsage, now: resetNow)?.resets == [
        ResetCount(kind: "full", count: 1), ResetCount(kind: "session", count: 1),
        ResetCount(kind: "fable", count: 2), ResetCount(kind: "opus", count: 3),
    ], "resets are added up per kind; spent, expired and malformed grants count for nothing")
    let oddBlock = #"{"seven_day":{"utilization":1,"resets_at":"2026-11-15T01:00:00+00:00"},"cedar_ember":"soon"}"#
    assert((try? JSONDecoder().decode(UsageResponse.self, from: Data(oddBlock.utf8)))
            .flatMap { makeReading($0) }?.sevenDay?.pct == 1, "an unreadable resets block does not cost the reading")
    assert(String(format: T.resetLine, 2, "fable").contains("2 x fable reset"), "the line reads as a count of a kind")
    assert(modelIsRefused(ClaudeError.http(404, "")) && modelIsRefused(ClaudeError.auth(403)),
           "an account without the capped model is remembered")
    assert(!modelIsRefused(ClaudeError.http(529, "")) && !modelIsRefused(ClaudeError.http(429, ""))
           && !modelIsRefused(ClaudeError.shape), "a passing failure does not hide the model's cap for a day")

    // The menu bar follows the Claude Code login by default, a chosen account while it is
    // readable, and the fullest account when asked to or when nothing else can be read.
    func r(_ p: Double) -> Reading { Reading(fiveHour: nil, sevenDay: (p, now), active: false) }
    var errored = r(90); errored.error = "x"
    var snapshot = r(95); snapshot.lastSeen = now
    let rs = ["cc@x": r(59), "tok": r(100), "low": r(16), "bad": errored, "old": snapshot]
    let all = ["cc@x", "tok", "low", "bad", "old"]
    assert(menuBarReading(choice: nil, claudeCode: ["cc@x"], all: all, readings: rs)?.headline?.pct == 59,
           "the Claude Code login by default")
    assert(menuBarReading(choice: mostUsedChoice, claudeCode: ["cc@x"], all: all, readings: rs)?.headline?.pct == 100,
           "the fullest live account when asked for")
    assert(menuBarReading(choice: "low", claudeCode: ["cc@x"], all: all, readings: rs)?.headline?.pct == 16,
           "a chosen account")
    assert(menuBarReading(choice: "bad", claudeCode: ["cc@x"], all: all, readings: rs)?.headline?.pct == 59,
           "a chosen account without a reading falls back to the default")
    assert(menuBarReading(choice: nil, claudeCode: [], all: all, readings: rs)?.headline?.pct == 100,
           "no Claude Code login: the fullest account stands in")
    assert(menuBarReading(choice: nil, claudeCode: [], all: ["bad"], readings: rs) == nil, "nothing readable")

    // Error bodies are shown on one line, preferring the API's own message.
    assert(apiErrorMessage(#"{"error":{"type":"x","message":"Rate limited. Please try again later."}}"#)
           == "Rate limited. Please try again later.")
    assert(apiErrorMessage("{\n  \"oops\": 1\n}") == "{ \"oops\": 1 }", "a body without a message is squeezed")
    assert(ClaudeError.http(429, "").localizedDescription == T.rateLimited)

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
