// ClaudeResetBar (portable) — a tray icon showing Claude usage limits that notifies you
// the moment a 5-hour or 7-day window resets. macOS, Windows, Linux.
//
// Counterpart to the native Swift build (../src/main.swift), sharing its reset-detection
// logic and config file. Two differences are forced by systray: the menu is built once at
// startup and only its titles change afterwards, and accounts are added by editing the
// config file rather than through a dialog.
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
	Language             string    `json:"language,omitempty"`
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

// ─── Reset detection (pure logic, no I/O) ─────────────────────────────────────

type windowState struct {
	resetsAt    time.Time
	utilization float64
}

// A real reset pushes resets_at forward by 5 hours or 7 days. A 1-hour threshold ignores
// minor timestamp jitter from the API while still catching every legitimate reset.
const resetMinInterval = time.Hour

// The API occasionally returns the epoch (1970) for resets_at. Storing that as the baseline
// would make the next valid timestamp look like a ~56-year jump and fire a bogus alert.
var minPlausible = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)

// detectReset reports whether a reset just happened and returns the baseline to persist.
// The first reading only records a baseline — it never fires.
func detectReset(prev *windowState, resetsAt time.Time, utilization float64) (bool, windowState) {
	fresh := windowState{resetsAt: resetsAt, utilization: utilization}
	if prev == nil {
		return false, fresh
	}
	fired := resetsAt.Sub(prev.resetsAt) > resetMinInterval
	// Discard an implausible timestamp so it cannot poison the next comparison.
	if resetsAt.Before(minPlausible) {
		return fired, *prev
	}
	return fired, fresh
}

// ─── Formatting ───────────────────────────────────────────────────────────────

// remaining renders a duration as "2h 14m" / "3d 4h" / "now".
func remaining(seconds int) string {
	if seconds <= 0 {
		return T().now
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

func clock(t time.Time) string {
	t = t.Local()
	return fmt.Sprintf("%s %s", T().days[int(t.Weekday())], t.Format("15:04"))
}

func pct(v float64) string { return fmt.Sprintf("%d%%", int(math.Round(v))) }

// ─── Credentials ──────────────────────────────────────────────────────────────

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

// oauthToken returns the subscription token Claude Code stored. On Windows and Linux it
// lives in ~/.claude/.credentials.json; on macOS Claude Code keeps it in the Keychain, so
// the file is only the first place we look.
//
// We deliberately do NOT use the refresh token — refreshing it ourselves would invalidate
// Claude Code's own session. The token is re-read on every poll, so a refresh performed by
// Claude Code is picked up immediately.
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

// ─── HTTP clients ─────────────────────────────────────────────────────────────

var httpClient = &http.Client{Timeout: 20 * time.Second}

func doJSON(req *http.Request, out any) error {
	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf(T().networkError, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return fmt.Errorf(T().authRejected, resp.StatusCode)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf(T().badShape, err)
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

// fetchOAuthLabel names the account by its email so several accounts stay distinguishable.
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

// These headers mimic the request the claude.ai/settings/limits dashboard fires. A missing
// or wrong User-Agent / Referer triggers a Cloudflare bot challenge.
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

// ─── Config (shared with claude-reset and the Swift build) ────────────────────

func configPath() string { return homeFile(".config", "claude-reset", "config.json") }

func loadConfig() Config {
	var cfg Config
	if raw, err := os.ReadFile(configPath()); err == nil {
		json.Unmarshal(bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf")), &cfg)
	}
	return cfg
}

// ensureConfig writes an empty skeleton so "Open config file" has something to open.
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
	// 0o600 — the file holds session keys, nobody but the owner reads it.
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

// ─── Tray icon ────────────────────────────────────────────────────────────────

const iconSize = 32

// drawIcon renders a dial filled in proportion to usage. On Windows and Linux this is the
// only carrier of information in the tray — unlike the macOS menu bar, there is no text
// next to the icon.
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
			// Angle measured from 12 o'clock, going clockwise.
			angle := math.Atan2(dx, -dy)
			if angle < 0 {
				angle += 2 * math.Pi
			}
			switch {
			case dist > radius-2.5: // the rim stays solid so the icon reads even at 0%
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

// toICO wraps one or more PNGs in an ICO container, which is what the Windows tray and the
// .exe icon resource require. PNG inside ICO is valid from Vista onwards.
func toICO(pngs ...[]byte) []byte {
	var b bytes.Buffer
	binary.Write(&b, binary.LittleEndian, uint16(0))         // reserved
	binary.Write(&b, binary.LittleEndian, uint16(1))         // type: icon
	binary.Write(&b, binary.LittleEndian, uint16(len(pngs))) // image count
	offset := 6 + 16*len(pngs)

	for _, p := range pngs {
		cfg, err := png.DecodeConfig(bytes.NewReader(p))
		if err != nil {
			continue
		}
		// A dimension of 256 is stored as 0 — that is what the ICO spec says, and what
		// the conversion to a byte produces anyway.
		b.WriteByte(byte(cfg.Width))
		b.WriteByte(byte(cfg.Height))
		b.WriteByte(0)                                    // no palette
		b.WriteByte(0)                                    // reserved
		binary.Write(&b, binary.LittleEndian, uint16(1))  // planes
		binary.Write(&b, binary.LittleEndian, uint16(32)) // bits per pixel
		binary.Write(&b, binary.LittleEndian, uint32(len(p)))
		binary.Write(&b, binary.LittleEndian, uint32(offset))
		offset += len(p)
	}
	for _, p := range pngs {
		b.Write(p)
	}
	return b.Bytes()
}

// Amber reads on both light and dark trays. On macOS the template mode overrides it anyway
// and the system picks the colour itself.
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

// ─── Application icon (Dock, Explorer, launcher) ──────────────────────────────

// Claude's coral on the backdrop, a white gauge on top. The tray icon is minimal out of
// necessity; this one has to stay recognisable in a Dock or an application list.
var brandBG = color.RGBA{217, 119, 87, 255}

// blend mixes two opaque colours: t=1 yields pure fg, t=0 pure bg.
func blend(fg, bg color.RGBA, t float64) color.RGBA {
	mix := func(a, b uint8) uint8 { return uint8(float64(a)*t + float64(b)*(1-t)) }
	return color.RGBA{mix(fg.R, bg.R), mix(fg.G, bg.G), mix(fg.B, bg.B), 255}
}

// appIcon draws a rounded square holding a usage gauge. Sampling 3×3 per pixel smooths the
// edges — without it the arc and the corners look ragged at small sizes.
func appIcon(size int) []byte {
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	s := float64(size)
	radius := s * 0.225 // corner radius
	center := s / 2
	ringOuter := s * 0.32
	ringInner := s * 0.225
	const gaugeFrac = 0.68 // decorative fill level for the static icon

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
					// Every subsample is opaque — the translucent arc is blended with the
					// backdrop right here. That way alpha carries pixel coverage only, and
					// averaging the colour is a plain mean.
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
							c = blend(white, brandBG, 0.35) // unfilled part of the ring
						case dist <= ringInner*0.42:
							c = white // centre dot
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

// writeIcons generates the full icon set (PNGs at several sizes plus an ICO) into a folder.
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
	// ICO does not accept dimensions above 256.
	ico := toICO(byPNG[16], byPNG[32], byPNG[48], byPNG[64], byPNG[128], byPNG[256])
	return os.WriteFile(filepath.Join(dir, "icon.ico"), ico, 0o644)
}

// ─── State ────────────────────────────────────────────────────────────────────

var (
	mu         sync.Mutex
	readings   []reading
	baselines  = map[string]map[string]windowState{}
	fastPolled = map[string]time.Time{}
	oauthLabel = ""
	polled     = false // set once the first poll returns, so the menu can say "loading"
	pollNow    = make(chan struct{}, 1)
)

func requestPoll() {
	select {
	case pollNow <- struct{}{}:
	default: // a poll is already queued
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
		return reading{name: name, err: T().badTimestamp}
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
			fmt.Sprintf(T().resetTitle, name),
			fmt.Sprintf(T().resetBody, label, pct(prev.utilization), pct(utilization), clock(resetsAt)),
			"")
	}
	if baselines[name] == nil {
		baselines[name] = map[string]windowState{}
	}
	baselines[name][window] = next
}

// switchOAuthAccount reacts to the account signed into Claude Code being swapped. The old
// baseline describes a different account's limit window, so it is dropped — the new account
// starts from its own first reading and never gets a bogus reset notification.
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

	// The account signed into Claude Code — no configuration needed.
	if token := oauthToken(); token != "" {
		// The label is fetched on every poll because /login in Claude Code swaps the
		// account behind the same Keychain entry. The name keys our state, so without
		// this a new account would be compared against the previous one's baseline.
		label := fetchOAuthLabel(token)
		if label == "" && oauthLabel == "" {
			label = "Claude Code" // profile unavailable on the very first reading
		}
		if label != "" {
			switchOAuthAccount(label)
		}
		u, err := fetchUsageOAuth(token)
		out = append(out, toReading(oauthLabel, u, err))
	}

	// Extra accounts from the config (sessionKey). Isolated: an expired key on one must
	// not block the others.
	for _, a := range cfg.Accounts {
		if a.Name == "" || a.SessionKey == "" || a.OrgID == "" {
			continue // skeleton written by ensureConfig, not filled in yet
		}
		u, err := fetchUsageSession(a)
		out = append(out, toReading(a.Name, u, err))
	}

	mu.Lock()
	readings = out
	polled = true
	for _, r := range out {
		if r.err != "" {
			continue
		}
		checkReset(r.name, "five_hour", T().fiveHourWindow, r.fiveHourResetsAt, r.fiveHourPct)
		checkReset(r.name, "seven_day", T().sevenDayWindow, r.sevenDayResetsAt, r.sevenDayPct)
	}
	mu.Unlock()

	render()
}

// fastPollIfResetDue: a remembered reset time has passed, so poll straight away instead of
// waiting out the interval. Each resets_at value triggers this exactly once — otherwise an
// account whose API keeps returning a stale past date would be polled every minute forever.
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

// systray creates menu items once — they cannot be removed or reordered. So we keep a pool
// of items and only swap their titles, hiding the surplus.
const infoSlots = 40

var (
	infoItems  []*systray.MenuItem
	miRefresh  *systray.MenuItem
	miOpenCfg  *systray.MenuItem
	miLanguage *systray.MenuItem
	miLangs    []*systray.MenuItem
	miQuit     *systray.MenuItem
)

// applyLanguage relabels every fixed menu entry. Called at startup and whenever the user
// picks a different language.
func applyLanguage() {
	miRefresh.SetTitle(T().refreshNow)
	miOpenCfg.SetTitle(T().openConfig)
	miLanguage.SetTitle(T().language)
	miQuit.SetTitle(T().quit)
	for i, item := range miLangs {
		if languageOrder[i].code == currentLang {
			item.Check()
		} else {
			item.Uncheck()
		}
	}
}

func render() {
	mu.Lock()
	snapshot := append([]reading(nil), readings...)
	mu.Unlock()

	var lines []string
	worst := -1.0
	var worstReset time.Time

	switch {
	case !polled:
		// Before the first poll returns there is nothing to say — and claiming there are
		// no accounts would be wrong for the second it takes.
		lines = append(lines, T().loading)
	case len(snapshot) == 0:
		lines = append(lines, T().noAccounts1, T().noAccounts2)
	}
	for _, r := range snapshot {
		if r.err != "" {
			lines = append(lines, r.name+" — "+T().errorWord, "   "+r.err)
			continue
		}
		dot := "○"
		if r.active {
			dot = "●"
		}
		lines = append(lines,
			fmt.Sprintf("%s %s", dot, r.name),
			fmt.Sprintf(T().fiveHourLine, pct(r.fiveHourPct), remainingUntil(r.fiveHourResetsAt), clock(r.fiveHourResetsAt)),
			fmt.Sprintf(T().sevenDayLine, pct(r.sevenDayPct), remainingUntil(r.sevenDayResetsAt), clock(r.sevenDayResetsAt)))
		if r.opusPct != nil {
			lines = append(lines, fmt.Sprintf(T().opusLine, pct(*r.opusPct)))
		}
		if r.sonnetPct != nil {
			lines = append(lines, fmt.Sprintf(T().sonnetLine, pct(*r.sonnetPct)))
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
			// Once a window is exhausted the only thing that matters is when it returns.
			title = "Claude ⏳ " + remainingUntil(worstReset)
		} else {
			title = "Claude " + pct(worst)
		}
	}
	// Only macOS shows text next to the icon; on Windows and Linux the tooltip carries it.
	systray.SetTitle(title)
	systray.SetTooltip(title)
	setTrayIcon(math.Max(0, worst))
}

func onReady() {
	setTrayIcon(0)
	systray.SetTitle("Claude ⚙︎")
	systray.SetTooltip(T().tooltipIdle)

	for i := 0; i < infoSlots; i++ {
		item := systray.AddMenuItem("", "")
		item.Disable()
		item.Hide()
		// The click channel has to be drained or it can block the systray loop.
		go func(it *systray.MenuItem) {
			for range it.ClickedCh {
			}
		}(item)
		infoItems = append(infoItems, item)
	}

	systray.AddSeparator()
	miRefresh = systray.AddMenuItem("", "")
	miOpenCfg = systray.AddMenuItem("", "")
	miLanguage = systray.AddMenuItem("", "")
	for _, l := range languageOrder {
		miLangs = append(miLangs, miLanguage.AddSubMenuItemCheckbox(l.name, "", l.code == currentLang))
	}
	systray.AddSeparator()
	miQuit = systray.AddMenuItem("", "")
	applyLanguage()

	go func() {
		for {
			select {
			case <-miRefresh.ClickedCh:
				requestPoll()
			case <-miOpenCfg.ClickedCh:
				ensureConfig()
				openInEditor(configPath())
			case <-miQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()

	// One goroutine per language entry — a shared select would need reflection.
	for i, item := range miLangs {
		go func(idx int, it *systray.MenuItem) {
			for range it.ClickedCh {
				currentLang = languageOrder[idx].code
				if err := saveLanguage(currentLang); err != nil {
					fmt.Fprintln(os.Stderr, "could not save language:", err)
				}
				applyLanguage()
				render()
			}
		}(i, item)
	}

	go loop()
	requestPoll()
}

func loop() {
	cfg := loadConfig()
	minutes := cfg.CheckIntervalMinutes
	if minutes < 1 {
		minutes = 15
	}
	// Polling the API is infrequent because limits move slowly. A separate, frequent tick
	// only recomputes countdowns from the cached resets_at so the menu never goes stale.
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

	// The first reading only records a baseline.
	fired, base := detectReset(nil, now, 80)
	assert(!fired, "first reading does not notify")
	assert(base.resetsAt.Equal(now), "first reading stores the timestamp")

	// The same timestamp is not a reset.
	fired, _ = detectReset(&base, now, 95)
	assert(!fired, "an unchanged timestamp is not a reset")

	// A 5-hour jump is a reset.
	fired, next := detectReset(&base, plus5h, 0)
	assert(fired, "a 5-hour jump is a reset")
	assert(next.resetsAt.Equal(plus5h), "a reset stores the new timestamp")

	// Drift below the 1-hour threshold is not a reset.
	fired, _ = detectReset(&base, now.Add(10*time.Minute), 81)
	assert(!fired, "a 10-minute shift is not a reset")

	// An epoch timestamp must not poison the baseline.
	_, kept := detectReset(&base, time.Unix(0, 0), 0)
	assert(kept.resetsAt.Equal(base.resetsAt), "the epoch does not overwrite the baseline")

	// Duration formatting, in whichever language is active.
	currentLang = "en"
	assert(remaining(-5) == "now", "negative duration")
	assert(remaining(3*3600+120) == "3h 2m", "hours and minutes")
	assert(remaining(45*60) == "45m", "minutes only")
	assert(remaining(3*86400+4*3600) == "3d 4h", "days and hours")
	currentLang = "pl"
	assert(remaining(-5) == "teraz", "negative duration translates")
	currentLang = "en"

	// Language resolution: config wins, then the locale, then English. Every locale
	// variable is cleared first so the result does not depend on the developer's shell.
	for _, env := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		os.Unsetenv(env)
	}
	assert(resolveLanguage("pl") == "pl", "explicit language from the config")
	assert(resolveLanguage("de") == "en", "unknown code falls back to English")
	assert(resolveLanguage("") == "en", "no locale at all falls back to English")
	os.Setenv("LC_ALL", "pl_PL.UTF-8")
	assert(resolveLanguage("") == "pl", "locale is honoured")
	assert(resolveLanguage("en") == "en", "config overrides the locale")
	os.Setenv("LC_ALL", "de_DE.UTF-8")
	assert(resolveLanguage("auto") == "en", "unsupported locale falls back to English")
	os.Unsetenv("LC_ALL")

	// Every language must define every string, or the menu shows blanks.
	for code, l := range languages {
		assert(l.refreshNow != "" && l.quit != "" && l.language != "" && l.now != "",
			"language "+code+" defines its menu strings")
		assert(l.resetTitle != "" && l.resetBody != "" && l.fiveHourLine != "",
			"language "+code+" defines its message templates")
		for _, d := range l.days {
			assert(d != "", "language "+code+" defines all weekday names")
		}
	}

	// The tray icon must be a valid PNG, and the ICO container must point at it.
	raw := drawIcon(42, iconColor)
	cfg, err := png.DecodeConfig(bytes.NewReader(raw))
	assert(err == nil, "the icon decodes as PNG")
	assert(cfg.Width == iconSize && cfg.Height == iconSize, "the icon has the requested size")
	ico := toICO(raw)
	assert(len(ico) == 22+len(raw), "an ICO header is 22 bytes")
	assert(bytes.Equal(ico[22:], raw), "the ICO carries the whole PNG")

	// Multi-image ICO: 6-byte header plus 16 bytes per entry, then the payloads in order.
	a16, a32 := appIcon(16), appIcon(32)
	multi := toICO(a16, a32)
	assert(len(multi) == 6+2*16+len(a16)+len(a32), "a multi-size ICO has the right length")
	assert(multi[4] == 2 && multi[5] == 0, "the ICO declares two images")
	assert(multi[6] == 16 && multi[6+16] == 32, "the ICO entries carry the right dimensions")
	assert(bytes.Equal(multi[6+2*16:6+2*16+len(a16)], a16), "the first image sits at its offset")

	// Application icon: 256 px is written as 0 in an ICO.
	big := appIcon(256)
	bigCfg, err := png.DecodeConfig(bytes.NewReader(big))
	assert(err == nil && bigCfg.Width == 256, "the 256 px icon decodes")
	assert(toICO(big)[6] == 0, "a dimension of 256 is stored as 0")

	// The rounded square must be transparent at the corner and solid in the middle.
	corner, _ := png.Decode(bytes.NewReader(appIcon(64)))
	_, _, _, cornerA := corner.At(0, 0).RGBA()
	_, _, _, centerA := corner.At(32, 32).RGBA()
	assert(cornerA == 0, "the icon corner is transparent")
	assert(centerA == 0xffff, "the icon centre is solid")

	// Extreme values must not break at the angle boundaries.
	assert(len(drawIcon(0, iconColor)) > 0 && len(drawIcon(100, iconColor)) > 0, "extreme values")

	// A claude-reset config, webhook and all, must still parse.
	var parsed Config
	err = json.Unmarshal([]byte(`{"accounts":[{"name":"a","session_key":"k","org_id":"o"}],`+
		`"slack_webhook_url":"https://x","check_interval_minutes":5,"language":"pl"}`), &parsed)
	assert(err == nil && len(parsed.Accounts) == 1 && parsed.CheckIntervalMinutes == 5,
		"a claude-reset config parses")
	assert(parsed.Language == "pl", "the language setting is read")

	// The token is found in the credentials layout, and absent when the section is missing.
	assert(tokenFromJSON([]byte(`{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x"}}`)) == "sk-ant-oat01-x",
		"the token is read from JSON")
	assert(tokenFromJSON([]byte(`{"mcpOAuth":{}}`)) == "", "no token when the section is missing")

	fmt.Println("self-check OK")
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--test" {
		runSelfCheck()
		return
	}
	currentLang = resolveLanguage(loadConfig().Language)

	// Generates the application icon set for the repository and release packages.
	if len(os.Args) > 2 && os.Args[1] == "--icons" {
		if err := writeIcons(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, "could not write icons:", err)
			os.Exit(1)
		}
		fmt.Println("icons written to", os.Args[2])
		return
	}
	// Checks whether notifications get through on this system at all, without waiting for
	// a real reset. On Linux this needs a running notification daemon.
	if len(os.Args) > 1 && os.Args[1] == "--notify" {
		if err := beeep.Notify("ClaudeResetBar", T().notifyWorks, ""); err != nil {
			fmt.Fprintln(os.Stderr, "the notification did not get through:", err)
			os.Exit(1)
		}
		fmt.Println("notification sent")
		return
	}

	systray.Run(onReady, func() {})
}
