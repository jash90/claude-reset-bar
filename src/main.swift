// ClaudeResetBar — pasek menu macOS pokazujący limity kont Claude i powiadamiający o resecie.
// Port logiki z github.com/nazarli-shabnam/claude-reset (TypeScript/Slack) na natywny Swift.
// Współdzieli plik konfiguracyjny ~/.config/claude-reset/config.json, więc oba narzędzia
// mogą korzystać z tych samych kont.

import AppKit
import Foundation

// MARK: - Model

struct Account: Codable {
    var name: String
    var session_key: String
    var org_id: String
}

struct Config: Codable {
    var accounts: [Account]
    var check_interval_minutes: Int?
    var slack_webhook_url: String?   // nieużywane tutaj, zachowane dla kompatybilności z claude-reset
}

struct UsageWindow: Codable {
    let utilization: Double
    let resets_at: String
}

struct UsageLimit: Codable {
    let group: String?
    let kind: String?
    let is_active: Bool?
}

struct UsageResponse: Codable {
    let five_hour: UsageWindow
    let seven_day: UsageWindow
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let limits: [UsageLimit]?
}

/// Ostatni odczyt dla jednego konta — to, co rysuje menu.
struct Reading {
    var fiveHourPct: Double
    var sevenDayPct: Double
    var fiveHourResetsAt: Date
    var sevenDayResetsAt: Date
    var opusPct: Double?
    var sonnetPct: Double?
    var active: Bool
    var error: String?
}

// MARK: - Wykrywanie resetu (czysta logika, bez I/O)

struct WindowState {
    var resetsAt: Date
    var utilization: Double
}

// Prawdziwy reset przesuwa resets_at o 5 godzin albo 7 dni. Próg 1h ignoruje drobne
// fluktuacje znacznika czasu z API, a wciąż łapie każdy realny reset.
let resetMinInterval: TimeInterval = 60 * 60

// API potrafi zwrócić epokę (1970) jako resets_at. Zapisanie tego jako punktu odniesienia
// sprawiłoby, że następny poprawny znacznik wygląda jak skok o ~56 lat → fałszywy alarm.
let minPlausibleDate = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01

/// Zwraca (czy reset właśnie nastąpił, jaki stan zapisać na następny raz).
/// Pierwszy odczyt zawsze tylko ustawia punkt odniesienia — nigdy nie strzela powiadomieniem.
func detectReset(prev: WindowState?, resetsAt: Date, utilization: Double) -> (fired: Bool, next: WindowState) {
    let fresh = WindowState(resetsAt: resetsAt, utilization: utilization)
    guard let prev else { return (false, fresh) }

    let fired = resetsAt.timeIntervalSince(prev.resetsAt) > resetMinInterval
    // Niewiarygodny znacznik odrzucamy, żeby nie zatruł porównania w następnej turze.
    let next = resetsAt >= minPlausibleDate ? fresh : prev
    return (fired, next)
}

// MARK: - Klient claude.ai

enum ClaudeError: LocalizedError {
    case auth(Int)
    case http(Int, String)
    case shape

    var errorDescription: String? {
        switch self {
        case .auth(let code):
            return "Autoryzacja odrzucona (HTTP \(code)). Uruchom Claude Code, żeby odświeżył token, "
                 + "albo dodaj konto z nowym sessionKey."
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(120))"
        case .shape:
            return "Nieoczekiwany kształt odpowiedzi — prywatne API mogło się zmienić."
        }
    }
}

// Nagłówki naśladują żądanie przeglądarki z panelu claude.ai/settings/limits.
// Brakujący albo zły User-Agent / Referer wywołuje challenge Cloudflare.
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

/// Każde konto claude.ai — również darmowe — należy do dokładnie jednej wewnętrznej
/// "organizacji"; endpoint zużycia jest do niej przypięty. UUID nie jest widoczny w UI,
/// więc pobieramy go sami, mając tylko sessionKey.
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

// MARK: - Konto z Claude Code (token OAuth z Keychaina)

// Claude Code trzyma token subskrypcji w Keychainie pod "Claude Code-credentials" i sam go
// odświeża. Czytamy go przy każdym odpytaniu, więc odświeżenie po stronie Claude Code jest
// widoczne od razu. Świadomie NIE używamy refresh tokena — własne odświeżanie unieważniłoby
// sesję Claude Code.
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

/// Etykieta konta zalogowanego w Claude Code — e-mail, żeby przy kilku kontach było widać które.
func fetchOAuthLabel(token: String, completion: @escaping (String?) -> Void) {
    fetchJSON(anthropicRequest(path: "/api/oauth/profile", token: token)) { result in
        guard case .success(let data) = result,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any]
        else { return completion(nil) }
        completion(account["email"] as? String ?? account["display_name"] as? String)
    }
}

// MARK: - Konfiguracja (wspólna z claude-reset)

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/claude-reset")
let configURL = configDir.appendingPathComponent("config.json")

func loadConfig() -> Config {
    guard let data = try? Data(contentsOf: configURL),
          let cfg = try? JSONDecoder().decode(Config.self, from: data)
    else { return Config(accounts: [], check_interval_minutes: nil, slack_webhook_url: nil) }
    return cfg
}

func saveConfig(_ cfg: Config) throws {
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(cfg).write(to: configURL)
    // 0o600 — plik trzyma klucze sesji, nikt poza właścicielem go nie czyta.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
}

// MARK: - Formatowanie

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
    f.locale = Locale(identifier: "pl_PL")
    f.dateFormat = "EEE HH:mm"
    return f
}()

/// "2h 14m" / "3d 4h" / "teraz" — ile zostało z podanej liczby sekund.
func remaining(seconds: Int) -> String {
    if seconds <= 0 { return "teraz" }
    let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func remaining(until date: Date) -> String {
    remaining(seconds: Int(date.timeIntervalSinceNow.rounded()))
}

func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

/// Powiadomienie systemowe. ponytail: osascript zamiast UNUserNotificationCenter —
/// nie wymaga podpisanego bundla ani dialogu o zgodę. Jeśli banner ma mieć własną ikonę
/// zamiast Script Editora, to jest moment na przejście na UNUserNotificationCenter.
func notify(title: String, message: String) {
    func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
    let script = "display notification \"\(esc(message))\" with title \"\(esc(title))\" sound name \"Glass\""
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}

// MARK: - Aplikacja

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var config = loadConfig()
    private var readings: [String: Reading] = [:]
    /// Punkt odniesienia per konto i okno — pierwszy odczyt tylko ustawia, nigdy nie powiadamia.
    private var baselines: [String: [String: WindowState]] = [:]
    /// Znaczniki resets_at, po których już wystrzeliło doraźne odpytanie — patrz fastPollIfResetDue().
    private var fastPolled: [String: Date] = [:]
    /// Nazwy źródeł w kolejności wyświetlania — konto z Claude Code, potem konta z configu.
    private var sourceNames: [String] = []
    private var keychainLabel = "Claude Code"
    private var pollTimer: Timer?
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
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
        // Odpytywanie API — rzadkie, bo limity zmieniają się wolno.
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Osobny, częsty tick tylko przelicza odliczanie z zapamiętanych resets_at,
        // żeby tytuł w pasku nie stał w miejscu między odpytaniami API.
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateTitle()
            self.fastPollIfResetDue()
        }
    }

    /// Minął zapamiętany czas resetu — odpytaj od razu, zamiast czekać do końca interwału.
    /// Skraca opóźnienie powiadomienia z ~15 minut do ~1 minuty. Każdy znacznik resets_at
    /// wyzwala to dokładnie raz — inaczej konto, dla którego API zwraca nieruchomą przeszłą
    /// datę, byłoby odpytywane co minutę bez końca.
    private func fastPollIfResetDue() {
        let now = Date()
        for (name, reading) in readings where reading.fiveHourResetsAt <= now {
            guard fastPolled[name] != reading.fiveHourResetsAt else { continue }
            fastPolled[name] = reading.fiveHourResetsAt
            poll()
            return
        }
    }

    // MARK: Odpytywanie

    @objc func poll() {
        config = loadConfig()
        var names: [String] = []

        // Konto zalogowane w Claude Code — bez żadnej konfiguracji.
        if let token = keychainOAuthToken() {
            names.append(keychainLabel)
            pollKeychainAccount(token: token)
        }

        // Dodatkowe konta z configu (sessionKey). Izolowane: wygasły klucz na jednym
        // nie blokuje pozostałych.
        for account in config.accounts {
            names.append(account.name)
            fetchUsage(account) { [weak self] result in
                DispatchQueue.main.async { self?.apply(result, for: account.name) }
            }
        }

        sourceNames = names
        updateTitle()
        rebuildMenu()
    }

    /// Etykietę pobieramy przy każdym odpytaniu — /login w Claude Code podmienia konto pod
    /// tym samym wpisem w Keychainie. Zapytanie o zużycie idzie dopiero po ustaleniu nazwy,
    /// bo nazwa jest kluczem stanu: odwrotna kolejność przypisałaby odczyt nowego konta do
    /// punktu odniesienia poprzedniego.
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

    /// Zmiana konta w Claude Code. Stary punkt odniesienia dotyczy okna limitów innego
    /// konta, więc go porzucamy — nowe konto zaczyna od własnego pierwszego odczytu
    /// i nie dostaje fałszywego powiadomienia o resecie.
    private func switchKeychainAccount(to email: String) {
        guard email != keychainLabel else { return }
        let old = keychainLabel
        readings.removeValue(forKey: old)
        baselines.removeValue(forKey: old)
        fastPolled.removeValue(forKey: old)
        keychainLabel = email
        sourceNames = sourceNames.map { $0 == old ? email : $0 }
        rebuildMenu()
    }

    private func apply(_ result: Result<UsageResponse, Error>, for name: String) {
        switch result {
        case .failure(let err):
            var r = readings[name] ?? Reading(fiveHourPct: 0, sevenDayPct: 0,
                                              fiveHourResetsAt: .distantFuture,
                                              sevenDayResetsAt: .distantFuture,
                                              opusPct: nil, sonnetPct: nil, active: false, error: nil)
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
                opusPct: usage.seven_day_opus?.utilization,
                sonnetPct: usage.seven_day_sonnet?.utilization,
                active: session?.is_active ?? false,
                error: nil)

            check(name: name, window: "five_hour", label: "okno 5-godzinne",
                  resetsAt: fiveReset, utilization: usage.five_hour.utilization)
            check(name: name, window: "seven_day", label: "okno 7-dniowe",
                  resetsAt: sevenReset, utilization: usage.seven_day.utilization)
        }
        updateTitle()
        rebuildMenu()
    }

    private func check(name: String, window: String, label: String, resetsAt: Date, utilization: Double) {
        let prev = baselines[name]?[window]
        let (fired, next) = detectReset(prev: prev, resetsAt: resetsAt, utilization: utilization)

        if fired, let prev {
            notify(title: "\(name): limit zresetowany",
                   message: "\(label) odświeżone (\(pct(prev.utilization)) → \(pct(utilization))). "
                          + "Następny reset: \(clockFormatter.string(from: resetsAt)).")
        }
        baselines[name, default: [:]][window] = next
    }

    // MARK: Pasek menu

    private func updateTitle() {
        guard !sourceNames.isEmpty else {
            statusItem.button?.title = "Claude ⚙︎"
            return
        }
        let live = readings.values.filter { $0.error == nil }
        guard let worst = live.max(by: { $0.fiveHourPct < $1.fiveHourPct }) else {
            statusItem.button?.title = "Claude ⚠︎"
            return
        }
        // Przy wyczerpanym oknie liczy się już tylko to, kiedy wróci.
        statusItem.button?.title = worst.fiveHourPct >= 100
            ? "Claude ⏳ \(remaining(until: worst.fiveHourResetsAt))"
            : "Claude \(pct(worst.fiveHourPct))"
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        if sourceNames.isEmpty {
            menu.addItem(disabled("Brak kont — zaloguj się w Claude Code albo dodaj konto"))
        }
        for name in sourceNames {
            guard let r = readings[name] else {
                menu.addItem(disabled("\(name) — ładowanie…"))
                continue
            }
            if let err = r.error {
                menu.addItem(disabled("\(name) — błąd"))
                menu.addItem(disabled("   \(err)"))
                continue
            }
            // Osobna pozycja menu na linię — NSMenuItem nie łamie tytułu po "\n".
            var lines = ["\(r.active ? "●" : "○") \(name)",
                         "   5h: \(pct(r.fiveHourPct)) — reset za \(remaining(until: r.fiveHourResetsAt)) (\(clockFormatter.string(from: r.fiveHourResetsAt)))",
                         "   7d: \(pct(r.sevenDayPct)) — reset za \(remaining(until: r.sevenDayResetsAt)) (\(clockFormatter.string(from: r.sevenDayResetsAt)))"]
            if let o = r.opusPct { lines.append("   7d Opus: \(pct(o))") }
            if let s = r.sonnetPct { lines.append("   7d Sonnet: \(pct(s))") }
            for line in lines { menu.addItem(disabled(line)) }
        }

        menu.addItem(.separator())
        menu.addItem(action("Odśwież teraz", #selector(poll)))
        menu.addItem(action("Dodaj konto…", #selector(addAccount)))
        menu.addItem(action("Otwórz plik konfiguracji", #selector(openConfig)))
        menu.addItem(.separator())
        menu.addItem(action("Zakończ", #selector(NSApplication.terminate(_:)), target: NSApp))
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

    // MARK: Akcje

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? saveConfig(config)
        }
        NSWorkspace.shared.open(configURL)
    }

    @objc private func addAccount() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Dodaj konto Claude"
        alert.informativeText = "sessionKey znajdziesz w DevTools → Application → Cookies → claude.ai → sessionKey"
        alert.addButton(withTitle: "Dodaj")
        alert.addButton(withTitle: "Anuluj")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        nameField.placeholderString = "Nazwa konta (np. prywatne)"
        let keyField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        keyField.placeholderString = "sk-ant-sid01-…"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        box.addSubview(nameField)
        box.addSubview(keyField)
        alert.accessoryView = box
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !key.isEmpty else { return showError("Nazwa i sessionKey są wymagane.") }
        guard !config.accounts.contains(where: { $0.name == name }) else {
            return showError("Konto o nazwie \"\(name)\" już istnieje.")
        }

        discoverOrgId(sessionKey: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let err):
                    self.showError(err.localizedDescription)
                case .success(let orgId):
                    var cfg = loadConfig()
                    cfg.accounts.append(Account(name: name, session_key: key, org_id: orgId))
                    do {
                        try saveConfig(cfg)
                        self.config = cfg
                        self.startTimers()
                        self.poll()
                    } catch {
                        self.showError("Nie udało się zapisać konfiguracji: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func showError(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Nie udało się"
        a.informativeText = text
        a.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    // Odliczanie w menu ma być świeże w chwili otwarcia, nie sprzed minuty.
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}

// MARK: - Self-check

/// `ClaudeResetBar --test` — sprawdza logikę wykrywania resetu (jedyny nietrywialny kawałek).
func runSelfCheck() {
    let now = Date()
    let plus5h = now.addingTimeInterval(5 * 3600)

    // Pierwszy odczyt tylko ustawia punkt odniesienia.
    let first = detectReset(prev: nil, resetsAt: now, utilization: 80)
    assert(first.fired == false)
    assert(first.next.resetsAt == now)

    // Ten sam znacznik = brak resetu.
    let same = detectReset(prev: first.next, resetsAt: now, utilization: 95)
    assert(same.fired == false)

    // Skok o 5h = reset.
    let jump = detectReset(prev: first.next, resetsAt: plus5h, utilization: 0)
    assert(jump.fired == true)
    assert(jump.next.resetsAt == plus5h)

    // Drobne przesunięcie poniżej progu 1h = nie reset.
    let drift = detectReset(prev: first.next, resetsAt: now.addingTimeInterval(600), utilization: 81)
    assert(drift.fired == false)

    // Epoka z API nie może zatruć punktu odniesienia.
    let epoch = detectReset(prev: first.next, resetsAt: Date(timeIntervalSince1970: 0), utilization: 0)
    assert(epoch.next.resetsAt == first.next.resetsAt)

    assert(remaining(seconds: -5) == "teraz")
    assert(remaining(seconds: 3 * 3600 + 120) == "3h 2m")
    assert(remaining(seconds: 45 * 60) == "45m")
    assert(remaining(seconds: 3 * 86400 + 4 * 3600) == "3d 4h")

    print("self-check OK")
}

// MARK: - Start

if CommandLine.arguments.contains("--test") {
    runSelfCheck()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // brak ikony w Docku — appka żyje tylko w pasku menu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
