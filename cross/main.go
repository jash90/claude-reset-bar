// ClaudeResetBar (cross) — ikona w zasobniku systemowym pokazująca limity Claude
// i powiadamiająca, gdy okno 5h albo 7d się zresetuje. macOS, Windows, Linux.
//
// Odpowiednik natywnej wersji Swift (../src/main.swift), z tą samą logiką wykrywania
// resetu. Różnice wymuszone przez systray: menu buduje się raz przy starcie i tylko
// aktualizuje tytuły pozycji, a kont nie dodaje się przez okno dialogowe — tylko
// edycją pliku konfiguracyjnego.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/gen2brain/beeep"
)

// ─── Model ────────────────────────────────────────────────────────────────────

type UsageWindow struct {
	Utilization float64 `json:"utilization"`
	ResetsAt    string  `json:"resets_at"`
}

type UsageLimit struct {
	Kind     string `json:"kind"`
	Group    string `json:"group"`
	IsActive bool   `json:"is_active"`
}

type UsageResponse struct {
	FiveHour       UsageWindow  `json:"five_hour"`
	SevenDay       UsageWindow  `json:"seven_day"`
	SevenDayOpus   *UsageWindow `json:"seven_day_opus"`
	SevenDaySonnet *UsageWindow `json:"seven_day_sonnet"`
	Limits         []UsageLimit `json:"limits"`
}

type Account struct {
	Name       string `json:"name"`
	SessionKey string `json:"session_key"`
	OrgID      string `json:"org_id"`
}

type Config struct {
	Accounts             []Account `json:"accounts"`
	CheckIntervalMinutes int       `json:"check_interval_minutes,omitempty"`
	SlackWebhookURL      string    `json:"slack_webhook_url,omitempty"`
}

type reading struct {
	name             string
	fiveHourPct      float64
	sevenDayPct      float64
	fiveHourResetsAt time.Time
	sevenDayResetsAt time.Time
	opusPct          *float64
	sonnetPct        *float64
	active           bool
	err              string
}

// ─── Wykrywanie resetu (czysta logika, bez I/O) ───────────────────────────────

type windowState struct {
	resetsAt    time.Time
	utilization float64
}

// Prawdziwy reset przesuwa resets_at o 5 godzin albo 7 dni. Próg 1h ignoruje drobne
// fluktuacje znacznika czasu z API, a wciąż łapie każdy realny reset.
const resetMinInterval = time.Hour

// API potrafi zwrócić epokę (1970) jako resets_at. Zapisanie tego jako punktu odniesienia
// sprawiłoby, że następny poprawny znacznik wygląda jak skok o ~56 lat → fałszywy alarm.
var minPlausible = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)

// detectReset zwraca (czy reset właśnie nastąpił, jaki stan zapisać na następny raz).
// Pierwszy odczyt zawsze tylko ustawia punkt odniesienia — nigdy nie strzela powiadomieniem.
func detectReset(prev *windowState, resetsAt time.Time, utilization float64) (bool, windowState) {
	fresh := windowState{resetsAt: resetsAt, utilization: utilization}
	if prev == nil {
		return false, fresh
	}
	fired := resetsAt.Sub(prev.resetsAt) > resetMinInterval
	// Niewiarygodny znacznik odrzucamy, żeby nie zatruł porównania w następnej turze.
	if resetsAt.Before(minPlausible) {
		return fired, *prev
	}
	return fired, fresh
}

// ─── Formatowanie ─────────────────────────────────────────────────────────────

// "2h 14m" / "3d 4h" / "teraz" — ile zostało z podanej liczby sekund.
func remaining(seconds int) string {
	if seconds <= 0 {
		return "teraz"
	}
	d, h, m := seconds/86400, (seconds%86400)/3600, (seconds%3600)/60
	switch {
	case d > 0:
		return fmt.Sprintf("%dd %dh", d, h)
	case h > 0:
		return fmt.Sprintf("%dh %dm", h, m)
	default:
		return fmt.Sprintf("%dm", m)
	}
}

func remainingUntil(t time.Time) string {
	return remaining(int(time.Until(t).Round(time.Second).Seconds()))
}

var plDays = [...]string{"niedz.", "pon.", "wt.", "śr.", "czw.", "pt.", "sob."}

func clock(t time.Time) string {
	t = t.Local()
	return fmt.Sprintf("%s %s", plDays[int(t.Weekday())], t.Format("15:04"))
}

func pct(v float64) string { return fmt.Sprintf("%d%%", int(math.Round(v))) }

// ─── Poświadczenia ────────────────────────────────────────────────────────────

func homeFile(parts ...string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(append([]string{home}, parts...)...)
}

func tokenFromJSON(raw []byte) string {
	var doc struct {
		ClaudeAiOauth struct {
			AccessToken string `json:"accessToken"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(raw, &doc) != nil {
		return ""
	}
	return doc.ClaudeAiOauth.AccessToken
}

// oauthToken zwraca token subskrypcji zapisany przez Claude Code. Na Windows i Linux
// leży on w ~/.claude/.credentials.json; na macOS Claude Code trzyma go w Keychainie,
// więc plik jest tylko pierwszym miejscem, w które zaglądamy.
//
// Świadomie NIE używamy refresh tokena — własne odświeżanie unieważniłoby sesję
// Claude Code. Token czytamy przy każdym odpytaniu, więc odświeżenie po stronie
// Claude Code jest widoczne od razu.
func oauthToken() string {
	if raw, err := os.ReadFile(homeFile(".claude", ".credentials.json")); err == nil {
		if tok := tokenFromJSON(raw); tok != "" {
			return tok
		}
	}
	if runtime.GOOS == "darwin" {
		out, err := exec.Command("/usr/bin/security",
			"find-generic-password", "-s", "Claude Code-credentials", "-w").Output()
		if err == nil {
			return tokenFromJSON(bytes.TrimSpace(out))
		}
	}
	return ""
}

// ─── Klienci HTTP ─────────────────────────────────────────────────────────────

var httpClient = &http.Client{Timeout: 20 * time.Second}

func doJSON(req *http.Request, out any) error {
	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("błąd sieci: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return fmt.Errorf("autoryzacja odrzucona (HTTP %d) — uruchom Claude Code, "+
			"żeby odświeżył token, albo wpisz nowy sessionKey", resp.StatusCode)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("nieoczekiwany kształt odpowiedzi: %w", err)
	}
	return nil
}

func anthropicReq(path, token string) *http.Request {
	req, _ := http.NewRequest("GET", "https://api.anthropic.com"+path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	return req
}

func fetchUsageOAuth(token string) (UsageResponse, error) {
	var u UsageResponse
	return u, doJSON(anthropicReq("/api/oauth/usage", token), &u)
}

// fetchOAuthLabel podpisuje konto e-mailem, żeby przy kilku kontach było widać które.
func fetchOAuthLabel(token string) string {
	var doc struct {
		Account struct {
			Email       string `json:"email"`
			DisplayName string `json:"display_name"`
		} `json:"account"`
	}
	if doJSON(anthropicReq("/api/oauth/profile", token), &doc) != nil {
		return ""
	}
	if doc.Account.Email != "" {
		return doc.Account.Email
	}
	return doc.Account.DisplayName
}

// Nagłówki naśladują żądanie przeglądarki z panelu claude.ai/settings/limits.
// Brakujący albo zły User-Agent / Referer wywołuje challenge Cloudflare.
var browserHeaders = map[string]string{
	"User-Agent":      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
	"Accept":          "application/json, text/plain, */*",
	"Accept-Language": "en-US,en;q=0.9",
	"Cache-Control":   "no-cache",
	"Pragma":          "no-cache",
	"Referer":         "https://claude.ai/settings/limits",
	"sec-fetch-dest":  "empty",
	"sec-fetch-mode":  "cors",
	"sec-fetch-site":  "same-origin",
}

func fetchUsageSession(a Account) (UsageResponse, error) {
	url := "https://claude.ai/api/organizations/" + a.OrgID + "/usage"
	req, _ := http.NewRequest("GET", url, nil)
	for k, v := range browserHeaders {
		req.Header.Set(k, v)
	}
	req.Header.Set("Cookie", "sessionKey="+a.SessionKey)
	var u UsageResponse
	return u, doJSON(req, &u)
}

// ─── Konfiguracja (wspólna z claude-reset i wersją Swift) ──────────────────────

func configPath() string { return homeFile(".config", "claude-reset", "config.json") }

func loadConfig() Config {
	var cfg Config
	if raw, err := os.ReadFile(configPath()); err == nil {
		json.Unmarshal(bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf")), &cfg)
	}
	return cfg
}

// ensureConfig tworzy pusty szkielet, żeby "Otwórz plik konfiguracji" miało co otworzyć.
func ensureConfig() error {
	if _, err := os.Stat(configPath()); err == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(configPath()), 0o700); err != nil {
		return err
	}
	skeleton := []byte("{\n  \"accounts\": [\n" +
		"    { \"name\": \"\", \"session_key\": \"\", \"org_id\": \"\" }\n" +
		"  ],\n  \"check_interval_minutes\": 15\n}\n")
	// 0o600 — plik trzyma klucze sesji, nikt poza właścicielem go nie czyta.
	return os.WriteFile(configPath(), skeleton, 0o600)
}

func openInEditor(path string) {
	switch runtime.GOOS {
	case "darwin":
		exec.Command("open", path).Start()
	case "windows":
		exec.Command("cmd", "/c", "start", "", path).Start()
	default:
		exec.Command("xdg-open", path).Start()
	}
}

// ─── Ikona ────────────────────────────────────────────────────────────────────

const iconSize = 32

// drawIcon rysuje tarczę wypełnioną proporcjonalnie do zużycia. Na Windows i Linux
// to jedyny nośnik informacji w zasobniku — tam nie ma tekstu obok ikony, jak w pasku
// menu macOS.
func drawIcon(percent float64, c color.RGBA) []byte {
	img := image.NewRGBA(image.Rect(0, 0, iconSize, iconSize))
	center := float64(iconSize) / 2
	radius := center - 1.5
	frac := math.Max(0, math.Min(1, percent/100))
	dim := color.RGBA{c.R, c.G, c.B, 70}

	for y := 0; y < iconSize; y++ {
		for x := 0; x < iconSize; x++ {
			dx, dy := float64(x)+0.5-center, float64(y)+0.5-center
			dist := math.Hypot(dx, dy)
			if dist > radius {
				continue
			}
			// Kąt liczony od godziny 12, zgodnie z ruchem wskazówek.
			angle := math.Atan2(dx, -dy)
			if angle < 0 {
				angle += 2 * math.Pi
			}
			switch {
			case dist > radius-2.5: // obwódka zawsze pełna, żeby ikona była czytelna przy 0%
				img.Set(x, y, c)
			case angle <= frac*2*math.Pi:
				img.Set(x, y, c)
			default:
				img.Set(x, y, dim)
			}
		}
	}

	var buf bytes.Buffer
	png.Encode(&buf, img)
	return buf.Bytes()
}

// toICO pakuje jeden lub więcej PNG-ów w kontener ICO — tego wymaga zasobnik Windows
// i ikona pliku .exe. PNG wewnątrz ICO jest poprawne od Visty.
func toICO(pngs ...[]byte) []byte {
	var b bytes.Buffer
	binary.Write(&b, binary.LittleEndian, uint16(0))           // zarezerwowane
	binary.Write(&b, binary.LittleEndian, uint16(1))           // typ: ikona
	binary.Write(&b, binary.LittleEndian, uint16(len(pngs)))   // liczba obrazów
	offset := 6 + 16*len(pngs)

	for _, p := range pngs {
		cfg, err := png.DecodeConfig(bytes.NewReader(p))
		if err != nil {
			continue
		}
		// Wymiar 256 zapisuje się jako 0 — tak mówi specyfikacja ICO i tak wychodzi
		// z konwersji na bajt.
		b.WriteByte(byte(cfg.Width))
		b.WriteByte(byte(cfg.Height))
		b.WriteByte(0)                                    // paleta: brak
		b.WriteByte(0)                                    // zarezerwowane
		binary.Write(&b, binary.LittleEndian, uint16(1))  // płaszczyzny
		binary.Write(&b, binary.LittleEndian, uint16(32)) // bitów na piksel
		binary.Write(&b, binary.LittleEndian, uint32(len(p)))
		binary.Write(&b, binary.LittleEndian, uint32(offset))
		offset += len(p)
	}
	for _, p := range pngs {
		b.Write(p)
	}
	return b.Bytes()
}

// ─── Ikona aplikacji (Dock, Eksplorator, launcher) ────────────────────────────

// Koralowy odcień Claude na tle, biały wskaźnik na wierzchu. Ikona zasobnika jest
// minimalistyczna z konieczności; ta ma być rozpoznawalna w Docku i na liście aplikacji.
var brandBG = color.RGBA{217, 119, 87, 255}

// blend miesza dwa nieprzezroczyste kolory: t=1 daje czysty fg, t=0 czyste bg.
func blend(fg, bg color.RGBA, t float64) color.RGBA {
	mix := func(a, b uint8) uint8 { return uint8(float64(a)*t + float64(b)*(1-t)) }
	return color.RGBA{mix(fg.R, bg.R), mix(fg.G, bg.G), mix(fg.B, bg.B), 255}
}

// appIcon rysuje zaokrąglony kwadrat ze wskaźnikiem zużycia. Próbkowanie 3×3 na piksel
// wygładza krawędzie — bez tego łuk i narożniki są poszarpane w małych rozmiarach.
func appIcon(size int) []byte {
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	s := float64(size)
	radius := s * 0.225        // promień zaokrąglenia narożników
	center := s / 2
	ringOuter := s * 0.32
	ringInner := s * 0.225
	const gaugeFrac = 0.68 // pokazowe wypełnienie wskaźnika na ikonie statycznej

	inRoundedRect := func(x, y float64) bool {
		dx := math.Max(math.Max(radius-x, x-(s-radius)), 0)
		dy := math.Max(math.Max(radius-y, y-(s-radius)), 0)
		return math.Hypot(dx, dy) <= radius
	}

	for py := 0; py < size; py++ {
		for px := 0; px < size; px++ {
			var rr, gg, bb float64
			covered := 0
			for sy := 0; sy < 3; sy++ {
				for sx := 0; sx < 3; sx++ {
					x := float64(px) + (float64(sx)+0.5)/3
					y := float64(py) + (float64(sy)+0.5)/3
					if !inRoundedRect(x, y) {
						continue
					}
					// Każda podpróbka jest nieprzezroczysta — półprzezroczysty łuk mieszamy
					// z tłem od razu. Dzięki temu krycie niesie wyłącznie informację
					// o pokryciu piksela, a uśrednianie koloru jest zwykłą średnią.
					c := brandBG
					dist := math.Hypot(x-center, y-center)
					if dist <= ringOuter {
						angle := math.Atan2(x-center, center-y)
						if angle < 0 {
							angle += 2 * math.Pi
						}
						white := color.RGBA{255, 255, 255, 255}
						switch {
						case dist >= ringInner && angle <= gaugeFrac*2*math.Pi:
							c = white
						case dist >= ringInner:
							c = blend(white, brandBG, 0.35) // niewypełniona część pierścienia
						case dist <= ringInner*0.42:
							c = white // kropka w środku
						}
					}
					rr += float64(c.R)
					gg += float64(c.G)
					bb += float64(c.B)
					covered++
				}
			}
			const samples = 9
			if covered == 0 {
				continue
			}
			n := float64(covered)
			img.Set(px, py, color.RGBA{
				uint8(rr / n),
				uint8(gg / n),
				uint8(bb / n),
				uint8(covered * 255 / samples),
			})
		}
	}

	var buf bytes.Buffer
	png.Encode(&buf, img)
	return buf.Bytes()
}

// writeIcons generuje komplet plików ikon do katalogu (PNG w wielu rozmiarach + ICO).
func writeIcons(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	sizes := []int{16, 32, 48, 64, 128, 256, 512, 1024}
	byPNG := map[int][]byte{}
	for _, s := range sizes {
		data := appIcon(s)
		byPNG[s] = data
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("icon_%d.png", s)), data, 0o644); err != nil {
			return err
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "icon.png"), byPNG[512], 0o644); err != nil {
		return err
	}
	// ICO nie przyjmuje wymiarów powyżej 256.
	ico := toICO(byPNG[16], byPNG[32], byPNG[48], byPNG[64], byPNG[128], byPNG[256])
	return os.WriteFile(filepath.Join(dir, "icon.ico"), ico, 0o644)
}

// Bursztyn czytelny i na jasnym, i na ciemnym pasku. Na macOS i tak nadpisuje go
// tryb szablonowy, w którym system sam dobiera kolor.
var iconColor = color.RGBA{224, 122, 63, 255}

func setTrayIcon(percent float64) {
	switch runtime.GOOS {
	case "darwin":
		white := drawIcon(percent, color.RGBA{255, 255, 255, 255})
		systray.SetTemplateIcon(white, white)
	case "windows":
		systray.SetIcon(toICO(drawIcon(percent, iconColor)))
	default:
		systray.SetIcon(drawIcon(percent, iconColor))
	}
}

// ─── Stan ─────────────────────────────────────────────────────────────────────

var (
	mu         sync.Mutex
	readings   []reading
	baselines  = map[string]map[string]windowState{}
	fastPolled = map[string]time.Time{}
	oauthLabel = ""
	pollNow    = make(chan struct{}, 1)
)

func requestPoll() {
	select {
	case pollNow <- struct{}{}:
	default: // odpytanie już zakolejkowane
	}
}

func parseISO(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339, s)
	return t, err == nil
}

func toReading(name string, u UsageResponse, err error) reading {
	if err != nil {
		return reading{name: name, err: err.Error()}
	}
	five, ok1 := parseISO(u.FiveHour.ResetsAt)
	seven, ok2 := parseISO(u.SevenDay.ResetsAt)
	if !ok1 || !ok2 {
		return reading{name: name, err: "nieczytelny znacznik resets_at"}
	}
	r := reading{
		name:             name,
		fiveHourPct:      u.FiveHour.Utilization,
		sevenDayPct:      u.SevenDay.Utilization,
		fiveHourResetsAt: five,
		sevenDayResetsAt: seven,
	}
	if u.SevenDayOpus != nil {
		r.opusPct = &u.SevenDayOpus.Utilization
	}
	if u.SevenDaySonnet != nil {
		r.sonnetPct = &u.SevenDaySonnet.Utilization
	}
	for _, l := range u.Limits {
		if l.Group == "session" || l.Kind == "session" {
			r.active = l.IsActive
			break
		}
	}
	return r
}

func checkReset(name, window, label string, resetsAt time.Time, utilization float64) {
	var prev *windowState
	if w, ok := baselines[name][window]; ok {
		prev = &w
	}
	fired, next := detectReset(prev, resetsAt, utilization)

	if fired && prev != nil {
		beeep.Notify(
			name+": limit zresetowany",
			fmt.Sprintf("%s odświeżone (%s → %s). Następny reset: %s.",
				label, pct(prev.utilization), pct(utilization), clock(resetsAt)),
			"")
	}
	if baselines[name] == nil {
		baselines[name] = map[string]windowState{}
	}
	baselines[name][window] = next
}

// switchOAuthAccount reaguje na zmianę konta zalogowanego w Claude Code. Stary punkt
// odniesienia dotyczy okna limitów innego konta, więc go porzucamy — nowe konto zaczyna
// od własnego pierwszego odczytu i nie dostaje fałszywego powiadomienia o resecie.
func switchOAuthAccount(label string) {
	mu.Lock()
	defer mu.Unlock()
	if label == oauthLabel {
		return
	}
	if oauthLabel != "" {
		delete(baselines, oauthLabel)
		delete(fastPolled, oauthLabel)
	}
	oauthLabel = label
}

func poll() {
	cfg := loadConfig()
	var out []reading

	// Konto zalogowane w Claude Code — bez żadnej konfiguracji.
	if token := oauthToken(); token != "" {
		// Etykietę pobieramy przy każdym odpytaniu, bo /login w Claude Code podmienia
		// konto pod tym samym wpisem w Keychainie. Nazwa jest kluczem stanu, więc bez
		// tego nowe konto porównywałoby się z punktem odniesienia poprzedniego.
		label := fetchOAuthLabel(token)
		if label == "" && oauthLabel == "" {
			label = "Claude Code" // profil niedostępny przy pierwszym odczycie
		}
		if label != "" {
			switchOAuthAccount(label)
		}
		u, err := fetchUsageOAuth(token)
		out = append(out, toReading(oauthLabel, u, err))
	}

	// Dodatkowe konta z configu (sessionKey). Izolowane: wygasły klucz na jednym
	// nie blokuje pozostałych.
	for _, a := range cfg.Accounts {
		if a.Name == "" || a.SessionKey == "" || a.OrgID == "" {
			continue // szkielet z ensureConfig, jeszcze niewypełniony
		}
		u, err := fetchUsageSession(a)
		out = append(out, toReading(a.Name, u, err))
	}

	mu.Lock()
	readings = out
	for _, r := range out {
		if r.err != "" {
			continue
		}
		checkReset(r.name, "five_hour", "okno 5-godzinne", r.fiveHourResetsAt, r.fiveHourPct)
		checkReset(r.name, "seven_day", "okno 7-dniowe", r.sevenDayResetsAt, r.sevenDayPct)
	}
	mu.Unlock()

	render()
}

// fastPollIfResetDue: minął zapamiętany czas resetu — odpytaj od razu, zamiast czekać
// do końca interwału. Każdy znacznik resets_at wyzwala to dokładnie raz, inaczej konto,
// dla którego API zwraca nieruchomą przeszłą datę, byłoby odpytywane co minutę bez końca.
func fastPollIfResetDue() {
	mu.Lock()
	defer mu.Unlock()
	now := time.Now()
	for _, r := range readings {
		if r.err != "" || r.fiveHourResetsAt.After(now) {
			continue
		}
		if done, ok := fastPolled[r.name]; ok && done.Equal(r.fiveHourResetsAt) {
			continue
		}
		fastPolled[r.name] = r.fiveHourResetsAt
		requestPoll()
		return
	}
}

// ─── Menu ─────────────────────────────────────────────────────────────────────

// systray tworzy pozycje menu raz — nie da się ich usuwać ani przestawiać. Trzymamy
// więc pulę pozycji i tylko podmieniamy tytuły oraz chowamy nadmiar.
const infoSlots = 40

var infoItems []*systray.MenuItem

func render() {
	mu.Lock()
	snapshot := append([]reading(nil), readings...)
	mu.Unlock()

	var lines []string
	worst := -1.0
	var worstReset time.Time

	if len(snapshot) == 0 {
		lines = append(lines, "Brak kont — zaloguj się w Claude Code")
		lines = append(lines, "albo wpisz sessionKey w pliku konfiguracji")
	}
	for _, r := range snapshot {
		if r.err != "" {
			lines = append(lines, r.name+" — błąd", "   "+r.err)
			continue
		}
		dot := "○"
		if r.active {
			dot = "●"
		}
		lines = append(lines,
			fmt.Sprintf("%s %s", dot, r.name),
			fmt.Sprintf("   5h: %s — reset za %s (%s)", pct(r.fiveHourPct), remainingUntil(r.fiveHourResetsAt), clock(r.fiveHourResetsAt)),
			fmt.Sprintf("   7d: %s — reset za %s (%s)", pct(r.sevenDayPct), remainingUntil(r.sevenDayResetsAt), clock(r.sevenDayResetsAt)))
		if r.opusPct != nil {
			lines = append(lines, "   7d Opus: "+pct(*r.opusPct))
		}
		if r.sonnetPct != nil {
			lines = append(lines, "   7d Sonnet: "+pct(*r.sonnetPct))
		}
		if r.fiveHourPct > worst {
			worst, worstReset = r.fiveHourPct, r.fiveHourResetsAt
		}
	}

	for i, item := range infoItems {
		if i < len(lines) {
			item.SetTitle(lines[i])
			item.Show()
		} else {
			item.Hide()
		}
	}

	title := "Claude ⚙︎"
	if worst >= 0 {
		if worst >= 100 {
			// Przy wyczerpanym oknie liczy się już tylko to, kiedy wróci.
			title = "Claude ⏳ " + remainingUntil(worstReset)
		} else {
			title = "Claude " + pct(worst)
		}
	}
	// Tekst obok ikony pokazuje tylko macOS; na Windows i Linux niesie go podpowiedź.
	systray.SetTitle(title)
	systray.SetTooltip(title)
	setTrayIcon(math.Max(0, worst))
}

func onReady() {
	setTrayIcon(0)
	systray.SetTitle("Claude ⚙︎")
	systray.SetTooltip("ClaudeResetBar")

	for i := 0; i < infoSlots; i++ {
		item := systray.AddMenuItem("", "")
		item.Disable()
		item.Hide()
		// Kanał kliknięć trzeba opróżniać, inaczej może zablokować pętlę systray.
		go func(it *systray.MenuItem) {
			for range it.ClickedCh {
			}
		}(item)
		infoItems = append(infoItems, item)
	}

	systray.AddSeparator()
	refresh := systray.AddMenuItem("Odśwież teraz", "")
	openCfg := systray.AddMenuItem("Otwórz plik konfiguracji", "")
	systray.AddSeparator()
	quit := systray.AddMenuItem("Zakończ", "")

	go func() {
		for {
			select {
			case <-refresh.ClickedCh:
				requestPoll()
			case <-openCfg.ClickedCh:
				ensureConfig()
				openInEditor(configPath())
			case <-quit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()

	go loop()
	requestPoll()
}

func loop() {
	cfg := loadConfig()
	minutes := cfg.CheckIntervalMinutes
	if minutes < 1 {
		minutes = 15
	}
	// Odpytywanie API jest rzadkie, bo limity zmieniają się wolno. Osobny, częsty tick
	// tylko przelicza odliczanie z zapamiętanych resets_at, żeby menu nie stało w miejscu.
	apiTick := time.NewTicker(time.Duration(minutes) * time.Minute)
	uiTick := time.NewTicker(time.Minute)
	defer apiTick.Stop()
	defer uiTick.Stop()

	for {
		select {
		case <-pollNow:
			poll()
		case <-apiTick.C:
			poll()
		case <-uiTick.C:
			render()
			fastPollIfResetDue()
		}
	}
}

// ─── Self-check ───────────────────────────────────────────────────────────────

func assert(cond bool, what string) {
	if !cond {
		fmt.Fprintln(os.Stderr, "self-check FAILED:", what)
		os.Exit(1)
	}
}

func runSelfCheck() {
	now := time.Now()
	plus5h := now.Add(5 * time.Hour)

	// Pierwszy odczyt tylko ustawia punkt odniesienia.
	fired, base := detectReset(nil, now, 80)
	assert(!fired, "pierwszy odczyt nie powiadamia")
	assert(base.resetsAt.Equal(now), "pierwszy odczyt zapisuje znacznik")

	// Ten sam znacznik = brak resetu.
	fired, _ = detectReset(&base, now, 95)
	assert(!fired, "ten sam znacznik to nie reset")

	// Skok o 5h = reset.
	fired, next := detectReset(&base, plus5h, 0)
	assert(fired, "skok o 5h to reset")
	assert(next.resetsAt.Equal(plus5h), "reset zapisuje nowy znacznik")

	// Drobne przesunięcie poniżej progu 1h = nie reset.
	fired, _ = detectReset(&base, now.Add(10*time.Minute), 81)
	assert(!fired, "przesunięcie o 10 min to nie reset")

	// Epoka z API nie może zatruć punktu odniesienia.
	_, kept := detectReset(&base, time.Unix(0, 0), 0)
	assert(kept.resetsAt.Equal(base.resetsAt), "epoka nie nadpisuje punktu odniesienia")

	assert(remaining(-5) == "teraz", "ujemny czas")
	assert(remaining(3*3600+120) == "3h 2m", "godziny i minuty")
	assert(remaining(45*60) == "45m", "same minuty")
	assert(remaining(3*86400+4*3600) == "3d 4h", "dni i godziny")

	// Ikona musi być poprawnym PNG-iem, a kontener ICO musi go wskazywać.
	raw := drawIcon(42, iconColor)
	cfg, err := png.DecodeConfig(bytes.NewReader(raw))
	assert(err == nil, "ikona dekoduje się jako PNG")
	assert(cfg.Width == iconSize && cfg.Height == iconSize, "ikona ma zadany rozmiar")
	ico := toICO(raw)
	assert(len(ico) == 22+len(raw), "ICO ma nagłówek 22 bajtów")
	assert(bytes.Equal(ico[22:], raw), "ICO zawiera PNG w całości")

	// ICO z wieloma obrazami: nagłówek 6 B + 16 B na wpis, potem dane po kolei.
	a16, a32 := appIcon(16), appIcon(32)
	multi := toICO(a16, a32)
	assert(len(multi) == 6+2*16+len(a16)+len(a32), "wielorozmiarowe ICO ma poprawną długość")
	assert(multi[4] == 2 && multi[5] == 0, "ICO deklaruje dwa obrazy")
	assert(multi[6] == 16 && multi[6+16] == 32, "wpisy ICO mają właściwe wymiary")
	// Offset pierwszego obrazu musi wskazywać tuż za katalog wpisów.
	assert(bytes.Equal(multi[6+2*16:6+2*16+len(a16)], a16), "pierwszy obraz leży pod swoim offsetem")

	// Ikona aplikacji: 256 px zapisuje się w ICO jako 0.
	big := appIcon(256)
	bigCfg, err := png.DecodeConfig(bytes.NewReader(big))
	assert(err == nil && bigCfg.Width == 256, "ikona 256 px dekoduje się")
	assert(toICO(big)[6] == 0, "wymiar 256 zapisany jako 0")

	// Narożnik zaokrąglonego kwadratu musi być przezroczysty, a środek pełny.
	corner, _ := png.Decode(bytes.NewReader(appIcon(64)))
	_, _, _, cornerA := corner.At(0, 0).RGBA()
	_, _, _, centerA := corner.At(32, 32).RGBA()
	assert(cornerA == 0, "narożnik ikony jest przezroczysty")
	assert(centerA == 0xffff, "środek ikony jest pełny")

	// 0% i 100% nie mogą się wysypać na krawędziach kąta.
	assert(len(drawIcon(0, iconColor)) > 0 && len(drawIcon(100, iconColor)) > 0, "skrajne wartości")

	// Konfiguracja claude-reset (z BOM-em i webhookiem) musi się wczytać.
	var parsed Config
	err = json.Unmarshal([]byte(`{"accounts":[{"name":"a","session_key":"k","org_id":"o"}],`+
		`"slack_webhook_url":"https://x","check_interval_minutes":5}`), &parsed)
	assert(err == nil && len(parsed.Accounts) == 1 && parsed.CheckIntervalMinutes == 5, "config claude-reset")

	// Token wyciągany z obu układów pliku poświadczeń.
	assert(tokenFromJSON([]byte(`{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x"}}`)) == "sk-ant-oat01-x", "token z JSON-a")
	assert(tokenFromJSON([]byte(`{"mcpOAuth":{}}`)) == "", "brak tokenu gdy nie ma sekcji")

	fmt.Println("self-check OK")
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--test" {
		runSelfCheck()
		return
	}
	// Generowanie ikon aplikacji do repo/paczek releasowych.
	if len(os.Args) > 2 && os.Args[1] == "--icons" {
		if err := writeIcons(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, "nie udało się zapisać ikon:", err)
			os.Exit(1)
		}
		fmt.Println("ikony zapisane w", os.Args[2])
		return
	}
	// Sprawdzenie, czy powiadomienia w ogóle przechodzą na tym systemie — bez czekania
	// na prawdziwy reset. Na Linuksie wymaga działającego demona powiadomień.
	if len(os.Args) > 1 && os.Args[1] == "--notify" {
		if err := beeep.Notify("ClaudeResetBar", "Powiadomienia działają.", ""); err != nil {
			fmt.Fprintln(os.Stderr, "powiadomienie nie przeszło:", err)
			os.Exit(1)
		}
		fmt.Println("powiadomienie wysłane")
		return
	}
	systray.Run(onReady, func() {})
}
