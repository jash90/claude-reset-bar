//! Interface strings. They live in a struct rather than a key-value map so a typo is a
//! compile error instead of a blank menu entry at runtime.

use std::sync::atomic::{AtomicUsize, Ordering};

pub struct Strings {
    pub code: &'static str,
    pub name: &'static str,

    pub refresh_now: &'static str,
    pub open_config: &'static str,
    pub quit: &'static str,
    pub language: &'static str,
    pub no_accounts: &'static str,
    pub loading: &'static str,
    pub error_word: &'static str,
    pub now: &'static str,
    /// Appended to an unreachable account's name. Takes the time of day.
    pub last_seen: &'static str,
    pub days: [&'static str; 7],

    /// Take: gauge, percentage, time left, clock time.
    pub five_hour_line: &'static str,
    pub seven_day_line: &'static str,
    /// A weekly cap that applies to one model only. Takes: gauge, percentage, model.
    pub model_line: &'static str,
    /// Limit resets the account still holds. Takes: count, kind.
    pub reset_line: &'static str,
    /// The API reported nothing for the window. Takes: tag, gauge, dash.
    pub idle_line: &'static str,

    pub five_hour_window: &'static str,
    pub seven_day_window: &'static str,
    /// Takes the account name.
    pub reset_title: &'static str,
    /// Takes: window, percentage before, percentage after, next reset.
    pub reset_body: &'static str,

    /// Takes the HTTP status.
    pub auth_rejected: &'static str,
    pub network_error: &'static str,
    pub bad_shape: &'static str,
    pub add_account: &'static str,
    pub shape_error: &'static str,
    pub add_account_hint: &'static str,
    pub add_button: &'static str,
    pub name_placeholder: &'static str,
    pub key_placeholder: &'static str,
    pub key_required: &'static str,
    pub name_required: &'static str,
    pub token_needs_name: &'static str,
    pub token_rejected: &'static str,
    pub account_exists: &'static str,
    pub save_failed: &'static str,
    pub key_missing: &'static str,
    pub keychain_failed: &'static str,
    pub remove_button: &'static str,
    pub manage_accounts: &'static str,
    pub accounts_title: &'static str,
    pub col_account: &'static str,
    pub col_type: &'static str,
    pub col_key: &'static str,
    pub col_status: &'static str,
    pub type_claude_code: &'static str,
    pub type_session_key: &'static str,
    pub type_token: &'static str,
    pub key_in_keychain: &'static str,
    pub key_in_config: &'static str,
    pub key_claude_code: &'static str,
    pub status_line: &'static str,
    pub status_hidden: &'static str,
    pub wrong_key_kind: &'static str,
    pub confirm_remove: &'static str,
    pub hide_login: &'static str,
    pub show_login: &'static str,
    pub checking: &'static str,
    pub edit_hint: &'static str,
    pub menu_bar_shows: &'static str,
    pub menu_bar_default: &'static str,
    pub menu_bar_most_used: &'static str,
    pub msg_added: &'static str,
    pub msg_key_replaced: &'static str,
    pub msg_removed: &'static str,
    pub msg_renamed: &'static str,
    pub msg_hidden: &'static str,
    pub msg_shown: &'static str,
    pub rate_limited: &'static str,
    pub notify_works: &'static str,
    pub tooltip_idle: &'static str,
}

// What the system's key store is called, for the strings that name it: in English after
// "in" / "from", in Polish in the locative, after "w".
#[cfg(target_os = "macos")]
macro_rules! store_en {
    () => {
        "the Keychain"
    };
}
#[cfg(target_os = "macos")]
macro_rules! store_pl {
    () => {
        "pęku kluczy"
    };
}
#[cfg(windows)]
macro_rules! store_en {
    () => {
        "Credential Manager"
    };
}
#[cfg(windows)]
macro_rules! store_pl {
    () => {
        "Menedżerze poświadczeń"
    };
}
#[cfg(not(any(target_os = "macos", windows)))]
macro_rules! store_en {
    () => {
        "the system keyring"
    };
}
#[cfg(not(any(target_os = "macos", windows)))]
macro_rules! store_pl {
    () => {
        "systemowym pęku kluczy"
    };
}

/// The order of this list is the order of the language submenu.
pub static LANGUAGES: [Strings; 2] = [
    Strings {
        code: "en",
        name: "English",
        refresh_now: "Refresh now",
        open_config: "Open config file",
        quit: "Quit",
        language: "Language",
        no_accounts: "No accounts — sign in to Claude Code or add one",
        loading: "loading…",
        error_word: "error",
        now: "now",
        last_seen: "   · last seen {}",
        days: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
        five_hour_line: "   5h  {}  {}  resets in {} ({})",
        seven_day_line: "   7d  {}  {}  resets in {} ({})",
        model_line: "   7d  {}  {}  {} only",
        reset_line: "   {} x {} reset",
        idle_line: "   {}  {}  {}  no active window",
        five_hour_window: "5-hour window",
        seven_day_window: "7-day window",
        reset_title: "{}: limit reset",
        reset_body: "{} refreshed ({} → {}). Next reset: {}.",
        auth_rejected: "Authorization rejected (HTTP {}). Run Claude Code so it refreshes the token, \
                        or add the account again with a fresh sessionKey.",
        network_error: "network error: {}",
        bad_shape: "unexpected response shape: {}",
        add_account: "Add account…",
        shape_error: "Unexpected response shape — the private API may have changed.",
        add_account_hint: "Paste a sessionKey (DevTools → Application → Cookies → claude.ai → sessionKey) or an OAuth token from `claude setup-token`. For a token the name is optional — the account's email is used.",
        add_button: "Add",
        name_placeholder: "Account name (e.g. personal)",
        key_placeholder: "sk-ant-sid… or sk-ant-oat…",
        key_required: "Paste a sessionKey or an OAuth token.",
        name_required: "An account added with a sessionKey needs a name.",
        token_needs_name: "This token cannot read the account's email — enter a name for it.",
        token_rejected: "This token was refused when reading usage limits (HTTP {}). Add the account with a sessionKey instead.",
        account_exists: "An account named \"{}\" already exists.",
        save_failed: "Could not save the configuration: {}",
        key_missing: concat!("The key for this account is missing from ", store_en!(), " — remove the account and add it again."),
        keychain_failed: concat!("Could not save the key in ", store_en!(), " (error {})."),
        remove_button: "Remove",
        manage_accounts: "Manage accounts…",
        accounts_title: "Accounts",
        col_account: "Account",
        col_type: "Type",
        col_key: "Key",
        col_status: "Status",
        type_claude_code: "Claude Code login",
        type_session_key: "sessionKey",
        type_token: "OAuth token",
        key_in_keychain: concat!("•••••••• in ", store_en!(), " — double-click to change"),
        key_in_config: "in the config file — double-click to change",
        key_claude_code: "managed by Claude Code",
        status_line: "5h {} · 7d {}",
        status_hidden: "Hidden from the menu",
        wrong_key_kind: "This account needs a {}.",
        confirm_remove: "Click again to remove",
        hide_login: "Hide",
        show_login: "Show",
        checking: "Checking the key…",
        edit_hint: "Double-click a name or a key to edit it. Press Return to save.",
        menu_bar_shows: "Menu bar shows",
        menu_bar_default: "Claude Code account (default)",
        menu_bar_most_used: "Most used account",
        msg_added: "Added {}.",
        msg_key_replaced: "New key saved for {}.",
        msg_removed: "Removed {}.",
        msg_renamed: "Renamed to {}.",
        msg_hidden: "{} is hidden from the menu.",
        msg_shown: "{} is shown in the menu again.",
        rate_limited: "The API is limiting requests — trying again at the next refresh.",
        notify_works: "Notifications are working.",
        tooltip_idle: "Claude Reset Bar",
    },
    Strings {
        code: "pl",
        name: "Polski",
        refresh_now: "Odśwież teraz",
        open_config: "Otwórz plik konfiguracji",
        quit: "Zakończ",
        language: "Język",
        no_accounts: "Brak kont — zaloguj się w Claude Code albo dodaj konto",
        loading: "ładowanie…",
        error_word: "błąd",
        now: "teraz",
        last_seen: "   · ostatnio widziane {}",
        days: ["niedz.", "pon.", "wt.", "śr.", "czw.", "pt.", "sob."],
        five_hour_line: "   5h  {}  {}  reset za {} ({})",
        seven_day_line: "   7d  {}  {}  reset za {} ({})",
        model_line: "   7d  {}  {}  tylko {}",
        reset_line: "   {} x {} reset",
        idle_line: "   {}  {}  {}  brak aktywnego okna",
        five_hour_window: "okno 5-godzinne",
        seven_day_window: "okno 7-dniowe",
        reset_title: "{}: limit zresetowany",
        reset_body: "{} odświeżone ({} → {}). Następny reset: {}.",
        auth_rejected: "Autoryzacja odrzucona (HTTP {}). Uruchom Claude Code, żeby odświeżył token, \
                        albo dodaj konto ponownie z nowym sessionKey.",
        network_error: "błąd sieci: {}",
        bad_shape: "nieoczekiwany kształt odpowiedzi: {}",
        add_account: "Dodaj konto…",
        shape_error: "Nieoczekiwany kształt odpowiedzi — prywatne API mogło się zmienić.",
        add_account_hint: "Wklej sessionKey (DevTools → Application → Cookies → claude.ai → sessionKey) albo token OAuth z `claude setup-token`. Przy tokenie nazwa jest opcjonalna — zostanie użyty e-mail konta.",
        add_button: "Dodaj",
        name_placeholder: "Nazwa konta (np. prywatne)",
        key_placeholder: "sk-ant-sid… albo sk-ant-oat…",
        key_required: "Wklej sessionKey albo token OAuth.",
        name_required: "Konto dodawane przez sessionKey musi mieć nazwę.",
        token_needs_name: "Ten token nie odczyta e-maila konta — wpisz dla niego nazwę.",
        token_rejected: "Token został odrzucony przy odczycie limitów (HTTP {}). Dodaj to konto przez sessionKey.",
        account_exists: "Konto o nazwie \"{}\" już istnieje.",
        save_failed: "Nie udało się zapisać konfiguracji: {}",
        key_missing: concat!("Brak klucza tego konta w ", store_pl!(), " — usuń konto i dodaj je ponownie."),
        keychain_failed: concat!("Nie udało się zapisać klucza w ", store_pl!(), " (błąd {})."),
        remove_button: "Usuń",
        manage_accounts: "Zarządzaj kontami…",
        accounts_title: "Konta",
        col_account: "Konto",
        col_type: "Rodzaj",
        col_key: "Klucz",
        col_status: "Stan",
        type_claude_code: "Logowanie Claude Code",
        type_session_key: "sessionKey",
        type_token: "token OAuth",
        key_in_keychain: concat!("•••••••• w ", store_pl!(), " — kliknij dwukrotnie, by zmienić"),
        key_in_config: "w pliku konfiguracji — kliknij dwukrotnie, by zmienić",
        key_claude_code: "zarządza nim Claude Code",
        status_line: "5h {} · 7d {}",
        status_hidden: "Ukryte w menu",
        wrong_key_kind: "To konto wymaga klucza typu: {}.",
        confirm_remove: "Kliknij ponownie, aby usunąć",
        hide_login: "Ukryj",
        show_login: "Pokaż",
        checking: "Sprawdzam klucz…",
        edit_hint: "Kliknij dwukrotnie nazwę lub klucz, aby je edytować. Return zapisuje.",
        menu_bar_shows: "W pasku menu",
        menu_bar_default: "Konto Claude Code (domyślnie)",
        menu_bar_most_used: "Najbardziej wykorzystane konto",
        msg_added: "Dodano {}.",
        msg_key_replaced: "Zapisano nowy klucz dla {}.",
        msg_removed: "Usunięto {}.",
        msg_renamed: "Zmieniono nazwę na {}.",
        msg_hidden: "{} ukryto w menu.",
        msg_shown: "{} znów jest widoczne w menu.",
        rate_limited: "API ogranicza liczbę zapytań — spróbuję przy następnym odświeżeniu.",
        notify_works: "Powiadomienia działają.",
        tooltip_idle: "Claude Reset Bar",
    },
];

static CURRENT: AtomicUsize = AtomicUsize::new(0);

/// The strings of the active language.
pub fn t() -> &'static Strings {
    &LANGUAGES[CURRENT.load(Ordering::Relaxed)]
}

pub fn current_language() -> &'static str {
    t().code
}

pub fn set_language(code: &str) {
    if let Some(index) = LANGUAGES.iter().position(|l| l.code == code) {
        CURRENT.store(index, Ordering::Relaxed);
    }
}

/// Puts the arguments into the template's `{}` slots, in order.
pub fn fill(template: &str, args: &[&str]) -> String {
    let mut out = String::with_capacity(template.len() + 16);
    let mut args = args.iter();
    let mut rest = template;
    while let Some(at) = rest.find("{}") {
        out.push_str(&rest[..at]);
        out.push_str(args.next().copied().unwrap_or(""));
        rest = &rest[at + 2..];
    }
    out.push_str(rest);
    out
}

/// Picks the interface language: an explicit setting in the config file wins, otherwise
/// the system locale, otherwise English. `env` looks up an environment variable.
pub fn resolve_language(configured: &str, env: impl Fn(&str) -> Option<String>) -> &'static str {
    let known = |code: &str| LANGUAGES.iter().find(|l| l.code == code).map(|l| l.code);
    if let Some(code) = known(configured) {
        return code;
    }
    if !configured.is_empty() && configured != "auto" {
        return "en"; // unknown code in the config — fall back rather than fail
    }
    for var in ["LC_ALL", "LC_MESSAGES", "LANG"] {
        let Some(value) = env(var).filter(|v| !v.is_empty()) else { continue };
        let lower = value.to_lowercase();
        let code = match lower.find(['_', '.', '-']) {
            Some(i) if i > 0 => &lower[..i],
            _ => &lower[..],
        };
        if let Some(code) = known(code) {
            return code;
        }
    }
    "en"
}
