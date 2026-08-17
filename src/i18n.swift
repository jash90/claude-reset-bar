import Foundation

/// Interface strings live in a struct rather than a key-value dictionary, so a typo is a
/// compile error instead of a blank menu entry at runtime.
struct UIStrings {
    let refreshNow: String
    let addAccount: String
    let openConfig: String
    let language: String
    let quit: String

    let noAccounts: String
    let loading: String
    let errorWord: String
    let now: String
    let activeSuffix: String   // appended to the name of an account in use right now
    let lastSeen: String   // "   · last seen %@", appended to an unreachable account's name
    let days: [String]

    let fiveHourLine: String   // "   5h: %@ — resets in %@ (%@)"
    let sevenDayLine: String
    let opusLine: String
    let sonnetLine: String

    let fiveHourWindow: String
    let sevenDayWindow: String
    let resetTitle: String     // "%@: limit reset"
    let resetBody: String      // "%@ refreshed (%@ → %@). Next reset: %@."

    let authRejected: String
    let httpError: String
    let shapeError: String

    let addAccountTitle: String
    let addAccountHint: String
    let addButton: String
    let cancelButton: String
    let namePlaceholder: String
    let keyPlaceholder: String

    let failedTitle: String
    let nameAndKeyRequired: String
    let accountExists: String   // "An account named \"%@\" already exists."
    let saveFailed: String      // "Could not save the configuration: %@"
}

let languages: [String: UIStrings] = [
    "en": UIStrings(
        refreshNow: "Refresh now",
        addAccount: "Add account…",
        openConfig: "Open config file",
        language: "Language",
        quit: "Quit",

        noAccounts: "No accounts — sign in to Claude Code or add one",
        loading: "loading…",
        errorWord: "error",
        now: "now",
        activeSuffix: "   · in use",
        lastSeen: "   · last seen %@",
        days: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],

        fiveHourLine: "   5h: %@ — resets in %@ (%@)",
        sevenDayLine: "   7d: %@ — resets in %@ (%@)",
        opusLine: "   7d Opus: %@",
        sonnetLine: "   7d Sonnet: %@",

        fiveHourWindow: "5-hour window",
        sevenDayWindow: "7-day window",
        resetTitle: "%@: limit reset",
        resetBody: "%@ refreshed (%@ → %@). Next reset: %@.",

        authRejected: "Authorization rejected (HTTP %d). Run Claude Code so it refreshes the "
                    + "token, or add the account again with a fresh sessionKey.",
        httpError: "HTTP %d: %@",
        shapeError: "Unexpected response shape — the private API may have changed.",

        addAccountTitle: "Add a Claude account",
        addAccountHint: "Find sessionKey in DevTools → Application → Cookies → claude.ai → sessionKey",
        addButton: "Add",
        cancelButton: "Cancel",
        namePlaceholder: "Account name (e.g. personal)",
        keyPlaceholder: "sk-ant-sid…",

        failedTitle: "That didn't work",
        nameAndKeyRequired: "Both a name and a sessionKey are required.",
        accountExists: "An account named \"%@\" already exists.",
        saveFailed: "Could not save the configuration: %@"
    ),
    "pl": UIStrings(
        refreshNow: "Odśwież teraz",
        addAccount: "Dodaj konto…",
        openConfig: "Otwórz plik konfiguracji",
        language: "Język",
        quit: "Zakończ",

        noAccounts: "Brak kont — zaloguj się w Claude Code albo dodaj konto",
        loading: "ładowanie…",
        errorWord: "błąd",
        now: "teraz",
        activeSuffix: "   · w użyciu",
        lastSeen: "   · ostatnio widziane %@",
        days: ["niedz.", "pon.", "wt.", "śr.", "czw.", "pt.", "sob."],

        fiveHourLine: "   5h: %@ — reset za %@ (%@)",
        sevenDayLine: "   7d: %@ — reset za %@ (%@)",
        opusLine: "   7d Opus: %@",
        sonnetLine: "   7d Sonnet: %@",

        fiveHourWindow: "okno 5-godzinne",
        sevenDayWindow: "okno 7-dniowe",
        resetTitle: "%@: limit zresetowany",
        resetBody: "%@ odświeżone (%@ → %@). Następny reset: %@.",

        authRejected: "Autoryzacja odrzucona (HTTP %d). Uruchom Claude Code, żeby odświeżył "
                    + "token, albo dodaj konto ponownie z nowym sessionKey.",
        httpError: "HTTP %d: %@",
        shapeError: "Nieoczekiwany kształt odpowiedzi — prywatne API mogło się zmienić.",

        addAccountTitle: "Dodaj konto Claude",
        addAccountHint: "sessionKey znajdziesz w DevTools → Application → Cookies → claude.ai → sessionKey",
        addButton: "Dodaj",
        cancelButton: "Anuluj",
        namePlaceholder: "Nazwa konta (np. prywatne)",
        keyPlaceholder: "sk-ant-sid…",

        failedTitle: "Nie udało się",
        nameAndKeyRequired: "Nazwa i sessionKey są wymagane.",
        accountExists: "Konto o nazwie \"%@\" już istnieje.",
        saveFailed: "Nie udało się zapisać konfiguracji: %@"
    ),
]

/// Order of the language submenu — dictionary iteration order is not stable.
let languageOrder: [(code: String, name: String)] = [("en", "English"), ("pl", "Polski")]

var currentLang = "en"
var T: UIStrings { languages[currentLang] ?? languages["en"]! }

/// Picks the interface language: an explicit setting in the config file wins, otherwise the
/// system's preferred language, otherwise English.
func resolveLanguage(configured: String?) -> String {
    if let configured, languages[configured] != nil { return configured }
    if let configured, !configured.isEmpty, configured != "auto" { return "en" }
    for preferred in Locale.preferredLanguages {
        let code = String(preferred.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()
        if languages[code] != nil { return code }
    }
    return "en"
}

/// Writes the chosen language back to the config file. It round-trips through a dictionary
/// so keys this program does not model — anything the claude-reset CLI keeps there — survive
/// the write untouched.
func saveLanguage(_ code: String) throws {
    var doc: [String: Any] = [:]
    if let data = try? Data(contentsOf: configURL),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        doc = parsed
    }
    doc["language"] = code

    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let out = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    try out.write(to: configURL)
    // 0o600 — the file holds session keys, nobody but the owner reads it.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
}
