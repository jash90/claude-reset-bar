package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// Interface strings live in a struct rather than a key-value map so a typo is a compile
// error instead of a blank menu entry at runtime.
type strings18n struct {
	refreshNow  string
	openConfig  string
	quit        string
	language    string
	noAccounts1 string
	noAccounts2 string
	loading     string
	errorWord   string
	now         string
	lastSeen    string // " · last seen %s", appended to an unreachable account's name
	days        [7]string

	fiveHourLine string // "5h: %s — resets in %s (%s)"
	sevenDayLine string
	opusLine     string
	sonnetLine   string

	fiveHourWindow string
	sevenDayWindow string
	resetTitle     string // "%s: limit reset"
	resetBody      string // "%s refreshed (%s → %s). Next reset: %s."

	authRejected string
	networkError string
	badShape     string
	badTimestamp string
	notifyWorks  string
	tooltipIdle  string
}

var languages = map[string]strings18n{
	"en": {
		refreshNow:  "Refresh now",
		openConfig:  "Open config file",
		quit:        "Quit",
		language:    "Language",
		noAccounts1: "No accounts — sign in to Claude Code",
		noAccounts2: "or add a sessionKey in the config file",
		loading:     "loading…",
		errorWord:   "error",
		now:         "now",
		lastSeen:    "   · last seen %s",
		days:        [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"},

		fiveHourLine: "   5h: %s — resets in %s (%s)",
		sevenDayLine: "   7d: %s — resets in %s (%s)",
		opusLine:     "   7d Opus: %s",
		sonnetLine:   "   7d Sonnet: %s",

		fiveHourWindow: "5-hour window",
		sevenDayWindow: "7-day window",
		resetTitle:     "%s: limit reset",
		resetBody:      "%s refreshed (%s → %s). Next reset: %s.",

		authRejected: "authorization rejected (HTTP %d) — run Claude Code so it refreshes " +
			"the token, or enter a new sessionKey",
		networkError: "network error: %w",
		badShape:     "unexpected response shape: %w",
		badTimestamp: "unreadable resets_at timestamp",
		notifyWorks:  "Notifications are working.",
		tooltipIdle:  "ClaudeResetBar",
	},
	"pl": {
		refreshNow:  "Odśwież teraz",
		openConfig:  "Otwórz plik konfiguracji",
		quit:        "Zakończ",
		language:    "Język",
		noAccounts1: "Brak kont — zaloguj się w Claude Code",
		noAccounts2: "albo wpisz sessionKey w pliku konfiguracji",
		loading:     "ładowanie…",
		errorWord:   "błąd",
		now:         "teraz",
		lastSeen:    "   · ostatnio widziane %s",
		days:        [7]string{"niedz.", "pon.", "wt.", "śr.", "czw.", "pt.", "sob."},

		fiveHourLine: "   5h: %s — reset za %s (%s)",
		sevenDayLine: "   7d: %s — reset za %s (%s)",
		opusLine:     "   7d Opus: %s",
		sonnetLine:   "   7d Sonnet: %s",

		fiveHourWindow: "okno 5-godzinne",
		sevenDayWindow: "okno 7-dniowe",
		resetTitle:     "%s: limit zresetowany",
		resetBody:      "%s odświeżone (%s → %s). Następny reset: %s.",

		authRejected: "autoryzacja odrzucona (HTTP %d) — uruchom Claude Code, żeby odświeżył " +
			"token, albo wpisz nowy sessionKey",
		networkError: "błąd sieci: %w",
		badShape:     "nieoczekiwany kształt odpowiedzi: %w",
		badTimestamp: "nieczytelny znacznik resets_at",
		notifyWorks:  "Powiadomienia działają.",
		tooltipIdle:  "ClaudeResetBar",
	},
}

// languageOrder fixes the order of the language submenu; map iteration is random.
var languageOrder = []struct{ code, name string }{
	{"en", "English"},
	{"pl", "Polski"},
}

var currentLang = "en"

func T() strings18n { return languages[currentLang] }

// resolveLanguage picks the interface language: an explicit setting in the config file
// wins, otherwise the system locale, otherwise English.
func resolveLanguage(configured string) string {
	if _, ok := languages[configured]; ok {
		return configured
	}
	if configured != "" && configured != "auto" {
		return "en" // unknown code in the config — fall back rather than fail
	}
	for _, env := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		v := os.Getenv(env)
		if v == "" {
			continue
		}
		code := strings.ToLower(v)
		if i := strings.IndexAny(code, "_.-"); i > 0 {
			code = code[:i]
		}
		if _, ok := languages[code]; ok {
			return code
		}
	}
	return "en"
}

// saveLanguage writes the chosen language back to the config file. It round-trips through
// a generic map so keys this program does not model — anything the claude-reset CLI keeps
// there — survive the write untouched.
func saveLanguage(code string) error {
	doc := map[string]any{}
	if raw, err := os.ReadFile(configPath()); err == nil {
		json.Unmarshal(raw, &doc)
	}
	doc["language"] = code

	out, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(configPath()), 0o700); err != nil {
		return err
	}
	// 0o600 — the file holds session keys, nobody but the owner reads it.
	return os.WriteFile(configPath(), append(out, '\n'), 0o600)
}
