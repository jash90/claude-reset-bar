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
    let lastSeen: String   // "   · last seen %@", appended to an unreachable account's name
    let days: [String]

    let fiveHourLine: String   // "   5h  <gauge>  %@  resets in %@ (%@)"
    let sevenDayLine: String
    let modelLine: String      // a weekly cap that applies to one model only
    let idleLine: String       // "   5h  <gauge>  —     no active window": the API reported nothing for it

    let fiveHourWindow: String
    let sevenDayWindow: String
    let resetTitle: String     // "%@: limit reset"
    let resetBody: String      // "%@ refreshed (%@ → %@). Next reset: %@."

    let authRejected: String
    let httpError: String
    let shapeError: String
    let rateLimited: String

    let addAccountHint: String
    let addButton: String
    let namePlaceholder: String
    let keyPlaceholder: String

    let failedTitle: String
    let keyRequired: String
    let nameRequired: String
    let tokenNeedsName: String
    let tokenRejected: String   // "This token was refused … (HTTP %d) …"
    let accountExists: String   // "An account named \"%@\" already exists."
    let saveFailed: String      // "Could not save the configuration: %@"
    let keyMissing: String
    let keychainFailed: String  // "Could not save the key in the Keychain (error %d)."

    let removeButton: String

    let manageAccounts: String
    let accountsTitle: String
    let colAccount: String
    let colType: String
    let colKey: String
    let colStatus: String
    let typeClaudeCode: String
    let typeSessionKey: String
    let typeToken: String
    let keyInKeychain: String
    let keyInConfig: String
    let keyClaudeCode: String
    let statusLine: String      // "5h %@ · 7d %@"
    let statusHidden: String
    let wrongKeyKind: String    // "This account needs a %@."
    let confirmRemove: String
    let hideLogin: String
    let showLogin: String
    let checking: String
    let editHint: String
    let msgAdded: String        // "Added %@."
    let msgKeyReplaced: String  // "New key saved for %@."
    let msgRemoved: String      // "Removed %@."
    let msgRenamed: String      // "Renamed to %@."
    let msgHidden: String       // "%@ is hidden from the menu."
    let msgShown: String        // "%@ is shown in the menu again."
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
        lastSeen: "   · last seen %@",
        days: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],

        fiveHourLine: "   5h  %@  %@  resets in %@ (%@)",
        sevenDayLine: "   7d  %@  %@  resets in %@ (%@)",
        modelLine: "   7d  %@  %@  %@ only",
        idleLine: "   %@  %@  —     no active window",

        fiveHourWindow: "5-hour window",
        sevenDayWindow: "7-day window",
        resetTitle: "%@: limit reset",
        resetBody: "%@ refreshed (%@ → %@). Next reset: %@.",

        authRejected: "Authorization rejected (HTTP %d). Run Claude Code so it refreshes the "
                    + "token, or add the account again with a fresh sessionKey.",
        httpError: "HTTP %d: %@",
        shapeError: "Unexpected response shape — the private API may have changed.",
        rateLimited: "The API is limiting requests — trying again at the next refresh.",

        addAccountHint: "Paste a sessionKey (DevTools → Application → Cookies → claude.ai → sessionKey) "
                      + "or an OAuth token from `claude setup-token`. For a token the name is optional "
                      + "— the account's email is used.",
        addButton: "Add",
        namePlaceholder: "Account name (e.g. personal)",
        keyPlaceholder: "sk-ant-sid… or sk-ant-oat…",

        failedTitle: "That didn't work",
        keyRequired: "Paste a sessionKey or an OAuth token.",
        nameRequired: "An account added with a sessionKey needs a name.",
        tokenNeedsName: "This token cannot read the account's email — enter a name for it.",
        tokenRejected: "This token was refused when reading usage limits (HTTP %d). "
                     + "Add the account with a sessionKey instead.",
        accountExists: "An account named \"%@\" already exists.",
        saveFailed: "Could not save the configuration: %@",
        keyMissing: "The key for this account is missing from the Keychain — remove the account "
                  + "and add it again.",
        keychainFailed: "Could not save the key in the Keychain (error %d).",

        removeButton: "Remove",

        manageAccounts: "Manage accounts…",
        accountsTitle: "Accounts",
        colAccount: "Account",
        colType: "Type",
        colKey: "Key",
        colStatus: "Status",
        typeClaudeCode: "Claude Code login",
        typeSessionKey: "sessionKey",
        typeToken: "OAuth token",
        keyInKeychain: "•••••••• in Keychain — double-click to change",
        keyInConfig: "in the config file — double-click to change",
        keyClaudeCode: "managed by Claude Code",
        statusLine: "5h %@ · 7d %@",
        statusHidden: "Hidden from the menu",
        wrongKeyKind: "This account needs a %@.",
        confirmRemove: "Click again to remove",
        hideLogin: "Hide",
        showLogin: "Show",
        checking: "Checking the key…",
        editHint: "Double-click a name or a key to edit it. Press Return to save.",
        msgAdded: "Added %@.",
        msgKeyReplaced: "New key saved for %@.",
        msgRemoved: "Removed %@.",
        msgRenamed: "Renamed to %@.",
        msgHidden: "%@ is hidden from the menu.",
        msgShown: "%@ is shown in the menu again."
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
        lastSeen: "   · ostatnio widziane %@",
        days: ["niedz.", "pon.", "wt.", "śr.", "czw.", "pt.", "sob."],

        fiveHourLine: "   5h  %@  %@  reset za %@ (%@)",
        sevenDayLine: "   7d  %@  %@  reset za %@ (%@)",
        modelLine: "   7d  %@  %@  tylko %@",
        idleLine: "   %@  %@  —     brak aktywnego okna",

        fiveHourWindow: "okno 5-godzinne",
        sevenDayWindow: "okno 7-dniowe",
        resetTitle: "%@: limit zresetowany",
        resetBody: "%@ odświeżone (%@ → %@). Następny reset: %@.",

        authRejected: "Autoryzacja odrzucona (HTTP %d). Uruchom Claude Code, żeby odświeżył "
                    + "token, albo dodaj konto ponownie z nowym sessionKey.",
        httpError: "HTTP %d: %@",
        shapeError: "Nieoczekiwany kształt odpowiedzi — prywatne API mogło się zmienić.",
        rateLimited: "API ogranicza liczbę zapytań — spróbuję przy następnym odświeżeniu.",

        addAccountHint: "Wklej sessionKey (DevTools → Application → Cookies → claude.ai → sessionKey) "
                      + "albo token OAuth z `claude setup-token`. Przy tokenie nazwa jest opcjonalna "
                      + "— zostanie użyty e-mail konta.",
        addButton: "Dodaj",
        namePlaceholder: "Nazwa konta (np. prywatne)",
        keyPlaceholder: "sk-ant-sid… albo sk-ant-oat…",

        failedTitle: "Nie udało się",
        keyRequired: "Wklej sessionKey albo token OAuth.",
        nameRequired: "Konto dodawane przez sessionKey musi mieć nazwę.",
        tokenNeedsName: "Ten token nie odczyta e-maila konta — wpisz dla niego nazwę.",
        tokenRejected: "Token został odrzucony przy odczycie limitów (HTTP %d). "
                     + "Dodaj to konto przez sessionKey.",
        accountExists: "Konto o nazwie \"%@\" już istnieje.",
        saveFailed: "Nie udało się zapisać konfiguracji: %@",
        keyMissing: "Brak klucza tego konta w pęku kluczy — usuń konto i dodaj je ponownie.",
        keychainFailed: "Nie udało się zapisać klucza w pęku kluczy (błąd %d).",

        removeButton: "Usuń",

        manageAccounts: "Zarządzaj kontami…",
        accountsTitle: "Konta",
        colAccount: "Konto",
        colType: "Rodzaj",
        colKey: "Klucz",
        colStatus: "Stan",
        typeClaudeCode: "Logowanie Claude Code",
        typeSessionKey: "sessionKey",
        typeToken: "token OAuth",
        keyInKeychain: "•••••••• w pęku kluczy — kliknij dwukrotnie, by zmienić",
        keyInConfig: "w pliku konfiguracji — kliknij dwukrotnie, by zmienić",
        keyClaudeCode: "zarządza nim Claude Code",
        statusLine: "5h %@ · 7d %@",
        statusHidden: "Ukryte w menu",
        wrongKeyKind: "To konto wymaga klucza typu: %@.",
        confirmRemove: "Kliknij ponownie, aby usunąć",
        hideLogin: "Ukryj",
        showLogin: "Pokaż",
        checking: "Sprawdzam klucz…",
        editHint: "Kliknij dwukrotnie nazwę lub klucz, aby je edytować. Return zapisuje.",
        msgAdded: "Dodano %@.",
        msgKeyReplaced: "Zapisano nowy klucz dla %@.",
        msgRemoved: "Usunięto %@.",
        msgRenamed: "Zmieniono nazwę na %@.",
        msgHidden: "%@ ukryto w menu.",
        msgShown: "%@ znów jest widoczne w menu."
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
