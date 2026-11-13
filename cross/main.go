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
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"net/http"
	"os"
	"os/exec"
	osuser "os/user"
	"path/filepath"
	"runtime"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/gen2brain/beeep"
)

// ─── Model ────────────────────────────────────────────────────────────────────

// Every field is a pointer. The API has already moved one reading out of its dedicated
// field once (the per-model caps), and a null arriving where a number used to be must be
// told apart from a real zero so the other shape can be read instead.
type UsageWindow struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    *string  `json:"resets_at"`
}

type UsageLimit struct {
	Kind     string   `json:"kind"`
	Group    string   `json:"group"`
	Percent  *float64 `json:"percent"`
	IsActive bool     `json:"is_active"`
	ResetsAt *string  `json:"resets_at"`
	// Set on a "weekly_scoped" entry: the weekly cap that applies to one model only.
	// This is where per-model limits are reported now; the seven_day_opus and
	// seven_day_sonnet fields come back null.
	Scope *struct {
		Model *struct {
			DisplayName string `json:"display_name"`
		} `json:"model"`
	} `json:"scope"`
}

// A weekly cap that applies to a single model.
type modelWindow struct {
	label string
	pct   float64
}

type UsageResponse struct {
	FiveHour       *UsageWindow `json:"five_hour"`
	SevenDay       *UsageWindow `json:"seven_day"`
	SevenDayOpus   *UsageWindow `json:"seven_day_opus"`
	SevenDaySonnet *UsageWindow `json:"seven_day_sonnet"`
	Limits         []UsageLimit `json:"limits"`
	// The limit resets the account holds. Only sent when the request asks for it. Kept
	// raw: the block is undocumented, and one that has changed shape should cost its own
	// lines, not the account's whole reading.
	CedarEmber json.RawMessage `json:"cedar_ember"`
}

// resetCount is how many resets of one kind an account still holds. kind is "full",
// "session", or a model's name in lower case.
type resetCount struct {
	kind  string
	count int
}

// resetKind names a reset from the limits it clears. One that clears the weekly limit is a
// full reset, whatever else it clears with it; one for the 5-hour window alone is a session
// reset; anything else clears one model's weekly cap and carries that model's name.
func resetKind(clears []string) string {
	has := func(name string) bool {
		for _, c := range clears {
			if c == name {
				return true
			}
		}
		return false
	}
	switch {
	case has("seven_day"):
		return "full"
	case has("five_hour"):
		return "session"
	case len(clears) == 0:
		return ""
	// The models billed against the plan beyond its base allowance — today that is Fable.
	case clears[0] == "seven_day_overage_included":
		return "fable"
	}
	return strings.TrimPrefix(clears[0], "seven_day_")
}

// resetCounts adds up the resets still to be used per kind: the full one first, then the
// rest by name. A grant that is spent or past its end date counts for nothing.
func resetCounts(block json.RawMessage, now time.Time) []resetCount {
	var status struct {
		Grants []json.RawMessage `json:"grants"`
	}
	if json.Unmarshal(block, &status) != nil {
		return nil
	}
	totals := map[string]int{}
	for _, raw := range status.Grants {
		var g struct {
			Clears     []string `json:"clears"`
			ResetsLeft int      `json:"resets_left"`
			EndsAt     *string  `json:"ends_at"`
		}
		kind := ""
		if json.Unmarshal(raw, &g) == nil {
			kind = resetKind(g.Clears)
		}
		if kind == "" || g.ResetsLeft <= 0 {
			continue
		}
		if g.EndsAt != nil {
			if end, ok := parseISO(*g.EndsAt); ok && !end.After(now) {
				continue
			}
		}
		totals[kind] += g.ResetsLeft
	}
	rank := func(kind string) int {
		switch kind {
		case "full":
			return 0
		case "session":
			return 1
		}
		return 2
	}
	out := make([]resetCount, 0, len(totals))
	for kind, count := range totals {
		out = append(out, resetCount{kind, count})
	}
	sort.Slice(out, func(i, j int) bool {
		if ri, rj := rank(out[i].kind), rank(out[j].kind); ri != rj {
			return ri < rj
		}
		return out[i].kind < out[j].kind
	})
	return out
}

// Account is an extra account read with a claude.ai sessionKey — the shape the
// claude-reset CLI reads too. OrgID may be left empty: it is discovered from the session
// key on the next poll and written back.
type Account struct {
	Name       string `json:"name"`
	SessionKey string `json:"session_key"`
	OrgID      string `json:"org_id"`
	// Keychain is set by the macOS app once it moved the key into the login Keychain.
	Keychain bool `json:"keychain,omitempty"`
}

// OAuthAccount is an extra account read with an OAuth token, such as one from
// `claude setup-token`. Kept apart from accounts, whose shape the claude-reset CLI relies on.
type OAuthAccount struct {
	Name     string `json:"name"`
	Token    string `json:"token"`
	Keychain bool   `json:"keychain,omitempty"`
}

type Config struct {
	Accounts      []Account      `json:"accounts"`
	OAuthAccounts []OAuthAccount `json:"oauth_accounts,omitempty"`
	// HiddenLogins are emails of Claude Code logins hidden from the menu by the macOS app's
	// accounts window. Hiding never touches the login itself.
	HiddenLogins []string `json:"hidden_logins,omitempty"`
	// MenuBarAccount is the account the tray figure follows: empty for the Claude Code
	// login, mostUsedChoice for the fullest account, or an account's name.
	MenuBarAccount       string `json:"menu_bar_account,omitempty"`
	CheckIntervalMinutes int    `json:"check_interval_minutes,omitempty"`
	SlackWebhookURL      string `json:"slack_webhook_url,omitempty"`
	Language             string `json:"language,omitempty"`
}

// window is one limit window: how much of it is used and when it starts over.
type window struct {
	pct      float64
	resetsAt time.Time
}

type reading struct {
	name string
	// nil when the API reports no such window. A 5-hour window only exists while one is
	// running, and since 2026-11 the API answers an idle one with "five_hour": null and no
	// session entry in limits[] at all, so its absence is a normal state, not an error.
	fiveHour *window
	sevenDay *window
	models   []modelWindow
	resets   []resetCount
	active   bool
	err      string
	// lastSeen is zero for a live account. It is set when the account can no longer be
	// polled — Claude Code was signed into a different one — and the row becomes a
	// read-only snapshot of the final reading.
	lastSeen time.Time
}

// headline is the window that limits you right now: the fuller of the two. A spent weekly
// limit blocks the account however empty the 5-hour window is. This is what the menu bar
// figure shows.
func (r reading) headline() *window {
	switch {
	case r.fiveHour == nil:
		return r.sevenDay
	case r.sevenDay == nil:
		return r.fiveHour
	case r.sevenDay.pct > r.fiveHour.pct:
		return r.sevenDay
	}
	return r.fiveHour
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

// A gauge is easier to read at a glance than a number: you see how full the window is
// without parsing digits, and several accounts line up for comparison.
const barCells = 12

// Filled and hollow squares rather than block-and-shade characters: at menu size the light
// shade (U+2591) anti-aliases into a solid block, which made an almost-empty gauge look
// full. These two stay distinguishable, and both are present in the default UI font on all
// three platforms.
const (
	barFilled = '■'
	barEmpty  = '□'
)

func bar(percent float64) string {
	frac := math.Max(0, math.Min(1, percent/100))
	full := int(math.Round(frac * barCells))
	// Any usage at all lights the first cell, so "a little" never looks like "none".
	if full == 0 && percent > 0 {
		full = 1
	}

	return strings.Repeat(string(barFilled), full) +
		strings.Repeat(string(barEmpty), barCells-full)
}

// timeOfDay renders the time of day alone, without the weekday that clock() prepends.
func timeOfDay(t time.Time) string { return t.Local().Format("15:04") }

// ─── Credentials ──────────────────────────────────────────────────────────────

func homeFile(parts ...string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(append([]string{home}, parts...)...)
}

// storedCredential is one login Claude Code stored: the access token and when it stops
// working (Unix ms, 0 when the item does not say).
type storedCredential struct {
	token     string
	expiresAt float64
}

func parseCredential(raw []byte) (storedCredential, bool) {
	var doc struct {
		ClaudeAiOauth struct {
			AccessToken string  `json:"accessToken"`
			ExpiresAt   float64 `json:"expiresAt"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(raw, &doc) != nil || doc.ClaudeAiOauth.AccessToken == "" {
		return storedCredential{}, false
	}
	return storedCredential{doc.ClaudeAiOauth.AccessToken, doc.ClaudeAiOauth.ExpiresAt}, true
}

// liveTokens returns the tokens worth polling, freshest first, each once. An expired token
// is dropped: it belongs to a profile nobody has used lately, and only Claude Code may
// refresh it. When every token has expired the freshest one is still returned, so the row
// says "run Claude Code" instead of the account silently disappearing.
func liveTokens(creds []storedCredential, now time.Time) []string {
	nowMs := float64(now.UnixMilli())
	sorted := append([]storedCredential(nil), creds...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].expiresAt > sorted[j].expiresAt })
	var live []storedCredential
	for _, c := range sorted {
		if c.expiresAt == 0 || c.expiresAt > nowMs {
			live = append(live, c)
		}
	}
	if len(live) == 0 && len(sorted) > 0 {
		live = sorted[:1]
	}
	var out []string
	for _, c := range live {
		if !slices.Contains(out, c.token) {
			out = append(out, c.token)
		}
	}
	return out
}

// credentialFiles lists the files Claude Code may have written: the default profile, the
// one CLAUDE_CONFIG_DIR points at, and the common habit of keeping extra profiles in
// ~/.claude-<name>.
func credentialFiles() []string {
	dirs := []string{homeFile(".claude")}
	if custom := os.Getenv("CLAUDE_CONFIG_DIR"); custom != "" {
		dirs = append(dirs, custom)
	}
	if matches, err := filepath.Glob(homeFile(".claude-*")); err == nil {
		sort.Strings(matches)
		dirs = append(dirs, matches...)
	}
	files := make([]string, len(dirs))
	for i, d := range dirs {
		files[i] = filepath.Join(d, ".credentials.json")
	}
	return files
}

// claudeCodeTokens returns every Claude Code login on this machine that can be polled. On
// Windows and Linux they live in credential files; on macOS Claude Code keeps them in the
// Keychain, one item per profile, so every item is read — an MCP OAuth flow also writes one
// under the same service name holding no subscription token at all.
//
// We deliberately do NOT use the refresh token — refreshing it ourselves would invalidate
// Claude Code's own session. Tokens are re-read on every poll, so a refresh performed by
// Claude Code is picked up immediately.
func claudeCodeTokens() []string {
	var creds []storedCredential
	for _, f := range credentialFiles() {
		if raw, err := os.ReadFile(f); err == nil {
			if c, ok := parseCredential(raw); ok {
				creds = append(creds, c)
			}
		}
	}
	if runtime.GOOS == "darwin" {
		creds = append(creds, keychainCredentials()...)
	}
	return liveTokens(creds, time.Now())
}

func keychainCredentials() []storedCredential {
	username := ""
	if u, err := osuser.Current(); err == nil {
		username = u.Username
	}
	var creds []storedCredential
	for _, service := range keychainCredentialServices() {
		for _, account := range []string{username, ""} {
			args := []string{"find-generic-password", "-s", service}
			if account != "" {
				args = append(args, "-a", account)
			}
			out, err := exec.Command("/usr/bin/security", append(args, "-w")...).Output()
			if err != nil {
				continue
			}
			if c, ok := parseCredential(bytes.TrimSpace(out)); ok {
				creds = append(creds, c)
			}
		}
	}
	return creds
}

// login is one Claude Code login and the name its row is shown under.
type login struct{ name, token string }

// nameClaudeCodeLogins names the logins found this poll. A login whose email could not be
// fetched keeps the name it had before; failing that it gets a numbered "Claude Code" name.
// A name the config already uses is skipped — that account is on screen already — and so is
// a second login into the same account.
func nameClaudeCodeLogins(tokens, emails []string, known map[string]string,
	previous []string, configured map[string]bool) []login {
	var out []login
	for i, token := range tokens {
		name := emails[i]
		if name == "" {
			name = known[token]
		}
		if name == "" {
			switch {
			case len(tokens) == 1 && len(previous) == 1:
				name = previous[0]
			case i == 0:
				name = "Claude Code"
			default:
				name = fmt.Sprintf("Claude Code %d", i+1)
			}
		}
		if configured[name] || slices.ContainsFunc(out, func(l login) bool { return l.name == name }) {
			continue
		}
		out = append(out, login{name, token})
	}
	return out
}

// isOAuthToken tells a token Claude Code issues from a claude.ai sessionKey.
func isOAuthToken(key string) bool { return strings.HasPrefix(key, "sk-ant-oat") }

// keychainCredentialServices lists the "Claude Code-credentials" services present. The dump
// reads attributes only, never a secret, so it prompts for nothing.
func keychainCredentialServices() []string {
	const base = "Claude Code-credentials"
	services := []string{base}
	out, err := exec.Command("/usr/bin/security", "dump-keychain").Output()
	if err != nil {
		return services
	}
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.Contains(line, `"svce"`) {
			continue
		}
		start := strings.Index(line, `="`)
		end := strings.LastIndex(line, `"`)
		if start < 0 || end <= start+2 {
			continue
		}
		name := line[start+2 : end]
		if strings.HasPrefix(name, base) && !slices.Contains(services, name) {
			services = append(services, name)
		}
	}
	return services
}

// ─── HTTP clients ─────────────────────────────────────────────────────────────

var httpClient = &http.Client{Timeout: 20 * time.Second}

func doJSON(req *http.Request, out any) error {
	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf(T().networkError, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return statusError(resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf(T().badShape, err)
	}
	return nil
}

// statusError is an HTTP failure that keeps its code, so a caller can tell a refused token
// (403) or a rate limit (429) from the rest.
type statusError int

func (e statusError) Error() string {
	if e == 401 || e == 403 {
		return fmt.Sprintf(T().authRejected, int(e))
	}
	return fmt.Sprintf("HTTP %d", int(e))
}

// The usage endpoint lists an account's limit resets only for a request that names the
// Claude Code CLI; any other client is told the account is not eligible.
const claudeCodeUserAgent = "claude-cli/2.1.323 (external, cli)"

func anthropicReq(path, token string) *http.Request {
	req, _ := http.NewRequest("GET", "https://api.anthropic.com"+path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("User-Agent", claudeCodeUserAgent)
	return req
}

func fetchUsageOAuth(token string) (UsageResponse, error) {
	var u UsageResponse
	// cedar_ember=1 asks for the limit resets on top of the usual reading.
	return u, doJSON(anthropicReq("/api/oauth/usage?cedar_ember=1", token), &u)
}

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

// probeModel is one model the probe can be sent to. scopedLabel names the per-model weekly
// cap its response reports; empty when the model has none.
type probeModel struct {
	id          string
	scopedLabel string
}

var (
	// scopedProbe is the model with a weekly cap of its own.
	scopedProbe = probeModel{id: "claude-fable-5-2", scopedLabel: "Fable"}
	// plainProbe is the smallest current model: the probe for accounts the capped model
	// turns away.
	plainProbe = probeModel{id: "claude-haiku-5-5"}
)

const limitHeaderPrefix = "Anthropic-Ratelimit-Unified-"

// usageFromHeaders turns the unified rate-limit headers into the shape the usage endpoint
// returns. Utilization comes as a fraction (0.16), the reset as Unix seconds. A scoped
// weekly claim becomes a "weekly_scoped" entry under scopedLabel, the model the request
// went to.
func usageFromHeaders(h http.Header, scopedLabel string) (UsageResponse, bool) {
	window := func(tag string) *UsageWindow {
		raw := h.Get(limitHeaderPrefix + tag + "-utilization")
		var fraction float64
		if _, err := fmt.Sscanf(raw, "%g", &fraction); raw == "" || err != nil {
			return nil
		}
		w := &UsageWindow{Utilization: ptr(fraction * 100)}
		var reset int64
		if _, err := fmt.Sscanf(h.Get(limitHeaderPrefix+tag+"-reset"), "%d", &reset); err == nil {
			w.ResetsAt = ptr(time.Unix(reset, 0).UTC().Format(time.RFC3339))
		}
		return w
	}
	u := UsageResponse{FiveHour: window("5h"), SevenDay: window("7d")}
	if u.FiveHour == nil && u.SevenDay == nil {
		return u, false
	}
	if scopedLabel == "" {
		return u, true
	}
	// The claim's own name ("7d_oi") is opaque, so any scoped weekly claim is taken; should
	// a response carry several, the fullest one is the one that limits the model.
	var scoped *UsageWindow
	for key := range h {
		tag, ok := strings.CutPrefix(strings.ToLower(key), strings.ToLower(limitHeaderPrefix))
		if !ok || !strings.HasPrefix(tag, "7d_") || !strings.HasSuffix(tag, "-utilization") {
			continue
		}
		if w := window(strings.TrimSuffix(tag, "-utilization")); w != nil &&
			(scoped == nil || *w.Utilization > *scoped.Utilization) {
			scoped = w
		}
	}
	if scoped != nil {
		l := UsageLimit{Kind: "weekly_scoped", Group: "weekly", Percent: scoped.Utilization, ResetsAt: scoped.ResetsAt}
		_ = json.Unmarshal([]byte(fmt.Sprintf(`{"model":{"display_name":%q}}`, scopedLabel)), &l.Scope)
		u.Limits = []UsageLimit{l}
	}
	return u, true
}

// scopedProbeRefusedUntil remembers tokens the capped model turned away, and until when to
// probe the smallest one for them. Only touched from poll, which runs one at a time.
var scopedProbeRefusedUntil = map[string]time.Time{}

// modelIsRefused tells whether a failed probe says the account may not use the model at
// all, as opposed to the API having a bad moment: 403 for no access, 404 or 400 for a
// model it does not offer.
func modelIsRefused(err error) bool {
	var se statusError
	return errors.As(err, &se) && (se == 400 || se == 403 || se == 404)
}

// fetchUsageFromHeaders reads limits for a token the usage endpoint refuses. The capped
// model is asked first, because only its response carries the per-model weekly cap. When
// it answers without limit headers the smallest model is asked instead; when the answer
// was that the account may not use the capped model, for the next day directly.
func fetchUsageFromHeaders(token string) (UsageResponse, error) {
	if time.Now().Before(scopedProbeRefusedUntil[token]) {
		return probeUsage(token, plainProbe)
	}
	u, retry, first := probeUsageOnce(token, scopedProbe)
	if !retry {
		return u, first
	}
	u, err := probeUsage(token, plainProbe)
	if err == nil && modelIsRefused(first) {
		scopedProbeRefusedUntil[token] = time.Now().Add(24 * time.Hour)
	}
	return u, err
}

func probeUsage(token string, model probeModel) (UsageResponse, error) {
	u, _, err := probeUsageOnce(token, model)
	return u, err
}

// probeUsageOnce sends the one-token request. retry reports that the API answered without
// limit headers and without rejecting the token outright, so another model may fare better.
func probeUsageOnce(token string, model probeModel) (u UsageResponse, retry bool, err error) {
	body := `{"model":"` + model.id + `","max_tokens":1,` +
		// OAuth tokens are only accepted for requests that present themselves as Claude Code.
		`"system":"You are Claude Code, Anthropic's official CLI for Claude.",` +
		`"messages":[{"role":"user","content":"hi"}]}`
	req, _ := http.NewRequest("POST", "https://api.anthropic.com/v1/messages", strings.NewReader(body))
	for k, v := range anthropicReq("", token).Header {
		req.Header[k] = v
	}
	req.Header.Set("content-type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return UsageResponse{}, false, fmt.Errorf(T().networkError, err)
	}
	resp.Body.Close()
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return UsageResponse{}, resp.StatusCode == 403, statusError(resp.StatusCode)
	}
	// A 429 from inference still carries the headers — and then they matter most.
	if u, ok := usageFromHeaders(resp.Header, model.scopedLabel); ok {
		return u, false, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return UsageResponse{}, true, statusError(resp.StatusCode)
	}
	return UsageResponse{}, true, fmt.Errorf(T().badShape, "no limit headers")
}

// usageRefusedUntil remembers tokens the usage endpoint turned away, and until when to
// leave it alone for them. Only touched from poll, which runs one at a time.
var usageRefusedUntil = map[string]time.Time{}

// fetchUsageForToken reads usage for a token added to the config: the usage endpoint while
// it answers, the inference headers when it refuses the token (403 for a missing scope,
// 429 for its hourly cap).
func fetchUsageForToken(token string) (UsageResponse, error) {
	if time.Now().Before(usageRefusedUntil[token]) {
		return fetchUsageFromHeaders(token)
	}
	u, err := fetchUsageOAuth(token)
	var se statusError
	if errors.As(err, &se) && (se == 429 || se == 403) {
		wait := time.Hour
		if se == 403 {
			wait = 24 * time.Hour
		}
		usageRefusedUntil[token] = time.Now().Add(wait)
		return fetchUsageFromHeaders(token)
	}
	return u, err
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

// discoverOrgID finds the account's organization UUID with nothing but the session key.
// Every claude.ai account belongs to exactly one, and it appears nowhere in the UI.
func discoverOrgID(sessionKey string) (string, error) {
	req, _ := http.NewRequest("GET", "https://claude.ai/api/organizations", nil)
	for k, v := range browserHeaders {
		req.Header.Set(k, v)
	}
	req.Header.Set("Cookie", "sessionKey="+sessionKey)
	var orgs []struct {
		UUID string `json:"uuid"`
	}
	if err := doJSON(req, &orgs); err != nil {
		return "", err
	}
	if len(orgs) == 0 || orgs[0].UUID == "" {
		return "", fmt.Errorf(T().badShape, "no organization")
	}
	return orgs[0].UUID, nil
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
	// org_id is left out: it is discovered from the session key and written back.
	skeleton := []byte("{\n  \"accounts\": [\n" +
		"    { \"name\": \"\", \"session_key\": \"\" }\n" +
		"  ],\n  \"oauth_accounts\": [\n" +
		"    { \"name\": \"\", \"token\": \"\" }\n" +
		"  ],\n  \"check_interval_minutes\": 15\n}\n")
	// 0o600 — the file holds session keys, nobody but the owner reads it.
	return os.WriteFile(configPath(), skeleton, 0o600)
}

// configuredNames lists every account the config names, in display order. An unfilled
// skeleton entry is not an account.
func (c Config) configuredNames() []string {
	var names []string
	for _, a := range c.Accounts {
		if a.Name != "" && (a.SessionKey != "" || a.Keychain) {
			names = append(names, a.Name)
		}
	}
	for _, a := range c.OAuthAccounts {
		if a.Name != "" && (a.Token != "" || a.Keychain) {
			names = append(names, a.Name)
		}
	}
	return names
}

// saveOrgID writes a discovered org_id into the named account's entry. It edits the file as
// generic JSON so every key this build does not know about survives untouched.
func saveOrgID(name, orgID string) error {
	raw, err := os.ReadFile(configPath())
	if err != nil {
		return err
	}
	patched, err := patchOrgID(bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf")), name, orgID)
	if err != nil {
		return err
	}
	return os.WriteFile(configPath(), patched, 0o600)
}

func patchOrgID(raw []byte, name, orgID string) ([]byte, error) {
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, err
	}
	accounts, _ := doc["accounts"].([]any)
	for _, entry := range accounts {
		if a, ok := entry.(map[string]any); ok && a["name"] == name {
			if id, _ := a["org_id"].(string); id == "" {
				a["org_id"] = orgID
			}
		}
	}
	out, err := json.MarshalIndent(doc, "", "  ")
	return append(out, '\n'), err
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
	// claudeCodeNames are the names of the Claude Code logins seen on the last poll, and
	// tokenNames the name each token was last shown under, for a poll where its email
	// cannot be fetched.
	claudeCodeNames []string
	tokenNames      = map[string]string{}
	// Accounts that dropped out of reach, keyed by name, keeping their last reading so the
	// row does not simply vanish. Memory only — a restart forgets them.
	staleAccounts = map[string]reading{}
	polled        = false // set once the first poll returns, so the menu can say "loading"
	pollNow       = make(chan struct{}, 1)
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

// windowReading returns one window as the menu needs it, taken from whichever shape
// carried it this time. The API reports each reading twice: as a dedicated five_hour /
// seven_day object and as an entry in limits[] with the same percentage and reset time. It
// has already retired one of those shapes once — the per-model caps went null in their own
// fields and turned up under limits[] — so neither is treated as the one that must be
// there. A window is only lost when both come back empty.
func windowReading(w *UsageWindow, limits []UsageLimit, kind string) *window {
	var pct *float64
	var stamp *string
	if w != nil {
		pct, stamp = w.Utilization, w.ResetsAt
	}
	for i := range limits {
		if limits[i].Kind != kind {
			continue
		}
		if pct == nil {
			pct = limits[i].Percent
		}
		if stamp == nil {
			stamp = limits[i].ResetsAt
		}
		break
	}
	if pct == nil || stamp == nil {
		return nil
	}
	t, ok := parseISO(*stamp)
	if !ok {
		return nil
	}
	return &window{pct: *pct, resetsAt: t}
}

func toReading(name string, u UsageResponse, err error) reading {
	if err != nil {
		return reading{name: name, err: err.Error()}
	}
	// Each window is optional; the account only counts as unreadable when neither the
	// 5-hour nor the 7-day window can be found anywhere.
	r := reading{
		name:     name,
		fiveHour: windowReading(u.FiveHour, u.Limits, "session"),
		sevenDay: windowReading(u.SevenDay, u.Limits, "weekly_all"),
	}
	if r.fiveHour == nil && r.sevenDay == nil {
		return reading{name: name, err: T().badTimestamp}
	}
	r.resets = resetCounts(u.CedarEmber, time.Now())
	// Per-model weekly caps arrive two ways depending on the account. The dedicated
	// fields are the older shape and now usually null; the scoped entries in limits[] are
	// the current one, and reading them means new model tiers appear without a code change.
	seen := map[string]bool{}
	addModel := func(label string, percent float64) {
		if label == "" || seen[label] {
			return
		}
		seen[label] = true
		r.models = append(r.models, modelWindow{label: label, pct: percent})
	}
	if u.SevenDayOpus != nil && u.SevenDayOpus.Utilization != nil {
		addModel("Opus", *u.SevenDayOpus.Utilization)
	}
	if u.SevenDaySonnet != nil && u.SevenDaySonnet.Utilization != nil {
		addModel("Sonnet", *u.SevenDaySonnet.Utilization)
	}
	for _, l := range u.Limits {
		if l.Group == "session" || l.Kind == "session" {
			r.active = l.IsActive
		}
		if l.Group == "weekly" && l.Scope != nil && l.Scope.Model != nil && l.Percent != nil {
			addModel(l.Scope.Model.DisplayName, *l.Percent)
		}
	}
	sort.Slice(r.models, func(i, j int) bool { return r.models[i].label < r.models[j].label })
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

// retire handles Claude Code logins that are gone — signed out, or swapped by /login. Their
// old baseline describes a limit window we can no longer follow, so it is dropped, and the
// final reading is kept as a snapshot: resets_at does not move until the window actually
// resets, so its countdown stays truthful even though nothing refreshes it. Call with mu held.
func retire(names []string) {
	for _, name := range names {
		for _, r := range readings {
			if r.name == name && r.err == "" && r.lastSeen.IsZero() {
				r.lastSeen = time.Now()
				staleAccounts[name] = r
			}
		}
		delete(baselines, name)
		delete(fastPolled, name)
	}
}

// mergeStale appends snapshots of unreachable accounts after the live rows, skipping any
// name a live row already covers. Sorted by name so the menu keeps a stable order — ranging
// over a map would reshuffle the rows on every poll.
func mergeStale(live []reading, stale map[string]reading) []reading {
	covered := map[string]bool{}
	for _, r := range live {
		covered[r.name] = true
	}
	names := make([]string, 0, len(stale))
	for name := range stale {
		if !covered[name] {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		live = append(live, stale[name])
	}
	return live
}

func poll() {
	cfg := loadConfig()
	configured := map[string]bool{}
	for _, name := range append(cfg.configuredNames(), cfg.HiddenLogins...) {
		configured[name] = true
	}

	// Every Claude Code login — no configuration needed. The email is fetched on every
	// poll because /login swaps the account behind the same credentials, and the name keys
	// our state: without it a new account would be compared against the previous baseline.
	tokens := claudeCodeTokens()
	emails := make([]string, len(tokens))
	for i, token := range tokens {
		emails[i] = fetchOAuthLabel(token)
	}
	mu.Lock()
	logins := nameClaudeCodeLogins(tokens, emails, tokenNames, claudeCodeNames, configured)
	tokenNames = map[string]string{}
	var current []string
	for _, l := range logins {
		tokenNames[l.token] = l.name
		current = append(current, l.name)
	}
	var gone []string
	for _, name := range claudeCodeNames {
		if !slices.Contains(current, name) {
			gone = append(gone, name)
		}
	}
	retire(gone)
	claudeCodeNames = current
	mu.Unlock()

	var out []reading
	for _, l := range logins {
		u, err := fetchUsageOAuth(l.token)
		out = append(out, toReading(l.name, u, err))
	}

	// Extra accounts from the config. Isolated: an expired key on one must not block the
	// others.
	// The macOS app keeps added keys in its own Keychain items, which only it can read
	// without a password prompt on every poll — so such an account says where its key is.
	for _, a := range cfg.Accounts {
		if a.Keychain && a.Name != "" {
			out = append(out, reading{name: a.Name, err: T().keychainOnly})
			continue
		}
		if a.Name == "" || a.SessionKey == "" {
			continue // skeleton written by ensureConfig, not filled in yet
		}
		if a.OrgID == "" {
			id, err := discoverOrgID(a.SessionKey)
			if err != nil {
				out = append(out, reading{name: a.Name, err: err.Error()})
				continue
			}
			a.OrgID = id
			saveOrgID(a.Name, id)
		}
		u, err := fetchUsageSession(a)
		out = append(out, toReading(a.Name, u, err))
	}
	for _, a := range cfg.OAuthAccounts {
		if a.Keychain && a.Name != "" {
			out = append(out, reading{name: a.Name, err: T().keychainOnly})
			continue
		}
		if a.Name == "" || a.Token == "" {
			continue
		}
		u, err := fetchUsageForToken(a.Token)
		out = append(out, toReading(a.Name, u, err))
	}

	mu.Lock()
	// A stale account that came back within reach — signed into again, or added by
	// sessionKey — is live now, so its snapshot is discarded for good.
	for _, r := range out {
		delete(staleAccounts, r.name)
	}
	readings = mergeStale(out, staleAccounts)
	polled = true
	for _, r := range out {
		if r.err != "" {
			continue
		}
		if w := r.fiveHour; w != nil {
			checkReset(r.name, "five_hour", T().fiveHourWindow, w.resetsAt, w.pct)
		}
		if w := r.sevenDay; w != nil {
			checkReset(r.name, "seven_day", T().sevenDayWindow, w.resetsAt, w.pct)
		}
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
		h := r.headline()
		if r.err != "" || !r.lastSeen.IsZero() || h == nil || h.resetsAt.After(now) {
			continue
		}
		if done, ok := fastPolled[r.name]; ok && done.Equal(h.resetsAt) {
			continue
		}
		fastPolled[r.name] = h.resetsAt
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

// mostUsedChoice is the menu_bar_account value that makes the tray follow the fullest account.
const mostUsedChoice = "*most-used"

// menuBarReading picks the reading the tray figure follows. By default that is the account
// signed into Claude Code. A chosen account wins while it has a live reading; otherwise, and
// when no Claude Code login is readable either, the fullest account stands in, so the
// figure never goes blank while some account can be read.
func menuBarReading(choice string, claudeCode []string, rs []reading) *reading {
	live := func(name string) *reading {
		for i := range rs {
			r := &rs[i]
			if r.name == name && r.err == "" && r.lastSeen.IsZero() && r.headline() != nil {
				return r
			}
		}
		return nil
	}
	var mostUsed *reading
	for i := range rs {
		if r := live(rs[i].name); r != nil && (mostUsed == nil || r.headline().pct > mostUsed.headline().pct) {
			mostUsed = r
		}
	}
	if choice == mostUsedChoice {
		return mostUsed
	}
	if r := live(choice); choice != "" && r != nil {
		return r
	}
	for _, name := range claudeCode {
		if r := live(name); r != nil {
			return r
		}
	}
	return mostUsed
}

// windowLine is one window's menu line, or the "no active window" line when the API
// reported none.
func windowLine(format, tag string, w *window) string {
	if w == nil {
		return fmt.Sprintf(T().idleLine, tag, bar(0), "—")
	}
	return fmt.Sprintf(format, bar(w.pct), pct(w.pct), remainingUntil(w.resetsAt), clock(w.resetsAt))
}

func render() {
	mu.Lock()
	snapshot := append([]reading(nil), readings...)
	logins := append([]string(nil), claudeCodeNames...)
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
		if r.active && r.lastSeen.IsZero() {
			dot = "●"
		}
		name := r.name
		if !r.lastSeen.IsZero() {
			name += fmt.Sprintf(T().lastSeen, timeOfDay(r.lastSeen))
		}
		lines = append(lines,
			fmt.Sprintf("%s %s", dot, name),
			windowLine(T().fiveHourLine, "5h", r.fiveHour),
			windowLine(T().sevenDayLine, "7d", r.sevenDay))
		for _, m := range r.models {
			lines = append(lines, fmt.Sprintf(T().modelLine, bar(m.pct), pct(m.pct), m.label))
		}
		for _, c := range r.resets {
			lines = append(lines, fmt.Sprintf(T().resetLine, c.count, c.kind))
		}
	}
	// The tray figure follows the Claude Code login unless the config picks another account.
	// A snapshot of an unreachable account never drives it.
	if r := menuBarReading(loadConfig().MenuBarAccount, logins, snapshot); r != nil {
		worst, worstReset = r.headline().pct, r.headline().resetsAt
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
		title = "Claude " + pct(worst)
		if worst >= 100 {
			// Once a window is exhausted the only thing that matters is when it returns.
			title += " · " + remainingUntil(worstReset)
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

// ptr takes the address of a literal, which the optional payload fields need.
func ptr[T any](v T) *T { return &v }

// win builds a dedicated usage window, for the self-check.
func win(pct float64, resetsAt string) *UsageWindow {
	return &UsageWindow{Utilization: ptr(pct), ResetsAt: ptr(resetsAt)}
}

// mustScoped builds a weekly limit scoped to one model, for the self-check.
func mustScoped(model string, percent float64) UsageLimit {
	l := UsageLimit{Kind: "weekly_scoped", Group: "weekly", Percent: ptr(percent)}
	l.Scope = new(struct {
		Model *struct {
			DisplayName string `json:"display_name"`
		} `json:"model"`
	})
	l.Scope.Model = &struct {
		DisplayName string `json:"display_name"`
	}{DisplayName: model}
	return l
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
		assert(l.resetTitle != "" && l.resetBody != "" && l.fiveHourLine != "" && l.lastSeen != "" && l.idleLine != "",
			"language "+code+" defines its message templates")
		assert(strings.Contains(fmt.Sprintf(l.lastSeen, "12:03"), "12:03"),
			"language "+code+" renders the last-seen stamp")
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

	// A partial config must survive decoding — a fresh install writes nothing but the
	// language, and losing the whole file over a missing "accounts" key would silently
	// revert the interface to the system locale.
	var partial Config
	assert(json.Unmarshal([]byte(`{"language":"en"}`), &partial) == nil, "a language-only config parses")
	assert(partial.Language == "en" && len(partial.Accounts) == 0, "a language-only config keeps its setting")

	// A claude-reset config, webhook and all, must still parse.
	var parsed Config
	err = json.Unmarshal([]byte(`{"accounts":[{"name":"a","session_key":"k","org_id":"o"}],`+
		`"slack_webhook_url":"https://x","check_interval_minutes":5,"language":"pl"}`), &parsed)
	assert(err == nil && len(parsed.Accounts) == 1 && parsed.CheckIntervalMinutes == 5,
		"a claude-reset config parses")
	assert(parsed.Language == "pl", "the language setting is read")

	// The token is found in the credentials layout, and absent when the section is missing.
	cred, credOK := parseCredential([]byte(`{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":1793743818844}}`))
	assert(credOK && cred.token == "sk-ant-oat01-x" && cred.expiresAt == 1793743818844,
		"the token is read from JSON")
	_, credOK = parseCredential([]byte(`{"mcpOAuth":{}}`))
	assert(!credOK, "no token when the section is missing")

	// Per-model weekly caps: read from the scoped entries in limits[], which is where the
	// API reports them now that seven_day_opus and seven_day_sonnet come back null.
	scoped := UsageResponse{
		FiveHour: win(9, "2026-08-17T14:29:59Z"),
		SevenDay: win(25, "2026-08-22T22:59:59Z"),
		Limits: []UsageLimit{
			{Kind: "session", Group: "session", Percent: ptr(9.0), IsActive: true},
			{Kind: "weekly_all", Group: "weekly", Percent: ptr(25.0)},
		},
	}
	scoped.Limits = append(scoped.Limits, mustScoped("Fable", 3), mustScoped("Opus", 40))
	got := toReading("acc", scoped, nil)
	assert(got.err == "", "a scoped payload decodes")
	assert(got.active, "the session entry still sets the active flag")
	assert(len(got.models) == 2, "both scoped models produce a row")
	assert(got.models[0].label == "Fable" && got.models[1].label == "Opus",
		"model rows keep a stable, sorted order")
	assert(got.models[1].pct == 40, "the scoped percentage is carried through")

	// The legacy fields still work, and must not duplicate a scoped entry of the same name.
	legacy := scoped
	legacy.SevenDayOpus = win(77, "")
	dedup := toReading("acc", legacy, nil)
	assert(len(dedup.models) == 2, "a model reported twice yields one row")
	assert(dedup.models[1].label == "Opus" && dedup.models[1].pct == 77,
		"the legacy field wins when both are present")

	// An account reporting no per-model caps simply has no such rows.
	plain := toReading("acc", UsageResponse{
		FiveHour: scoped.FiveHour, SevenDay: scoped.SevenDay,
		Limits: []UsageLimit{{Kind: "session", Group: "session"}},
	}, nil)
	assert(len(plain.models) == 0, "no scoped caps, no model rows")

	// A window whose dedicated field went null is read from limits[] instead — the same
	// move the per-model caps already made, and the shape that left the app reporting an
	// unexpected response while Claude Code itself was fine.
	nulled := toReading("acc", UsageResponse{
		FiveHour: nil,
		SevenDay: &UsageWindow{},
		Limits: []UsageLimit{
			{Kind: "session", Group: "session", Percent: ptr(9.0), IsActive: true,
				ResetsAt: ptr("2026-08-17T14:29:59Z")},
			{Kind: "weekly_all", Group: "weekly", Percent: ptr(25.0),
				ResetsAt: ptr("2026-08-22T22:59:59Z")},
		},
	}, nil)
	assert(nulled.err == "", "null windows fall back to limits[] rather than failing")
	assert(nulled.fiveHour != nil && nulled.sevenDay != nil &&
		nulled.fiveHour.pct == 9 && nulled.sevenDay.pct == 25,
		"the percentages come from the limits entries")
	assert(!nulled.fiveHour.resetsAt.IsZero(), "the reset time comes along with the percentage")

	// The shape the API sends since 2026-11 while no 5-hour window is running: five_hour
	// is null and limits[] has no session entry at all. The account stays readable, with
	// the weekly window on show and the 5-hour one marked idle — this used to fail the
	// whole Claude Code account.
	idle := toReading("acc", UsageResponse{
		FiveHour: nil,
		SevenDay: win(58, "2026-11-08T00:59:59.858545+00:00"),
		Limits: []UsageLimit{
			{Kind: "weekly_all", Group: "weekly", Percent: ptr(58.0), IsActive: true,
				ResetsAt: ptr("2026-11-08T00:59:59.858545+00:00")},
			mustScoped("Fable", 0),
		},
	}, nil)
	assert(idle.err == "", "a missing 5-hour window does not fail the account")
	assert(idle.fiveHour == nil, "an idle 5-hour window is reported as absent, not as 0%")
	assert(idle.sevenDay != nil && idle.sevenDay.pct == 58, "the weekly window still comes through")
	assert(idle.headline() != nil && idle.headline().pct == 58,
		"the menu bar falls back to the weekly figure")
	assert(len(idle.models) == 1 && idle.models[0].label == "Fable", "per-model caps still come through")
	assert(strings.Contains(windowLine(T().fiveHourLine, "5h", nil), "5h"), "the idle line names its window")

	// Nothing to read anywhere is still an error rather than a row of zeros.
	assert(toReading("acc", UsageResponse{}, nil).err != "",
		"an empty response reports failure, it does not invent a reading")

	// Several Claude Code logins: expired ones are dropped, the rest come freshest first,
	// and a token stored twice (Keychain and file) is polled once.
	now = time.Now()
	nowMs := float64(now.UnixMilli())
	live := liveTokens([]storedCredential{
		{"old", nowMs - 1000}, {"b", nowMs + 1000}, {"a", nowMs + 9000}, {"b", nowMs + 1000},
	}, now)
	assert(slices.Equal(live, []string{"a", "b"}), "live tokens, freshest first, each once")
	assert(slices.Equal(liveTokens([]storedCredential{{"x", 0}}, now), []string{"x"}),
		"a token without an expiry is kept")
	assert(slices.Equal(liveTokens([]storedCredential{{"old", nowMs - 1000}, {"older", nowMs - 9000}}, now),
		[]string{"old"}), "with every token expired the freshest stays, so the row can say why")
	assert(len(liveTokens(nil, now)) == 0, "no credentials, no tokens")

	named := nameClaudeCodeLogins([]string{"t1", "t2", "t3", "t4"}, []string{"a@x", "", "a@x", "cfg@x"},
		map[string]string{"t2": "b@x"}, nil, map[string]bool{"cfg@x": true})
	assert(len(named) == 2 && named[0].name == "a@x" && named[1].name == "b@x",
		"emails name logins, a known token keeps its name, duplicates and configured names are skipped")
	keptName := nameClaudeCodeLogins([]string{"new"}, []string{""}, nil, []string{"me@x"}, nil)
	assert(keptName[0].name == "me@x", "a single login whose email is unavailable keeps the previous name")
	unnamed := nameClaudeCodeLogins([]string{"t1", "t2"}, []string{"", ""}, nil, nil, nil)
	assert(unnamed[0].name == "Claude Code" && unnamed[1].name == "Claude Code 2",
		"unnamed logins get distinct names")

	// Config accounts: both kinds are listed, an unfilled skeleton entry is not an account,
	// and a discovered org_id is written back without disturbing anything else in the file.
	var multiCfg Config
	json.Unmarshal([]byte(`{"accounts":[{"name":"s","session_key":"k"},{"name":"","session_key":""}],`+
		`"oauth_accounts":[{"name":"t","token":"sk-ant-oat1"}]}`), &multiCfg)
	assert(slices.Equal(multiCfg.configuredNames(), []string{"s", "t"}), "both kinds of account, in order")
	var kcCfg Config
	json.Unmarshal([]byte(`{"accounts":[{"name":"s","session_key":"","keychain":true}],`+
		`"oauth_accounts":[{"name":"t","token":"","keychain":true}]}`), &kcCfg)
	assert(slices.Equal(kcCfg.configuredNames(), []string{"s", "t"}), "Keychain-backed entries count as accounts")
	assert(isOAuthToken("sk-ant-oat01-abc") && !isOAuthToken("sk-ant-sid01-abc"), "token kinds")
	patched, perr := patchOrgID([]byte(`{"accounts":[{"name":"s","session_key":"k"},`+
		`{"name":"o","session_key":"k2","org_id":"keep"}],"slack_webhook_url":"https://x","extra":1}`), "s", "uuid-1")
	var back map[string]any
	json.Unmarshal(patched, &back)
	accs, _ := back["accounts"].([]any)
	assert(perr == nil && len(accs) == 2, "the account list survives the patch")
	assert(accs[0].(map[string]any)["org_id"] == "uuid-1", "the discovered org_id is written")
	assert(accs[1].(map[string]any)["org_id"] == "keep", "another account's org_id is untouched")
	assert(back["slack_webhook_url"] == "https://x" && back["extra"] == 1.0, "unknown keys survive")

	// Limits read from inference headers — the route for setup-token tokens, which the usage
	// endpoint refuses. Values are the ones a real response carried.
	hdr := http.Header{}
	hdr.Set("anthropic-ratelimit-unified-7d-utilization", "0.16")
	hdr.Set("anthropic-ratelimit-unified-7d-reset", "1794092400")
	hu, hok := usageFromHeaders(hdr, "")
	hr := toReading("acc", hu, nil)
	assert(hok && hr.err == "" && hr.sevenDay != nil && math.Abs(hr.sevenDay.pct-16) < 1e-9,
		"the fraction becomes a percentage")
	assert(hr.sevenDay.resetsAt.Equal(time.Unix(1794092400, 0)), "the reset time is carried")
	assert(hr.fiveHour == nil, "no 5-hour header, no 5-hour window")
	// The tray follows the Claude Code login by default, a chosen account while it is
	// readable, and the fullest account when asked to or when nothing else can be read.
	mk := func(name string, p float64) reading { return reading{name: name, sevenDay: &window{pct: p}} }
	rs := []reading{mk("cc@x", 59), mk("tok", 100), mk("low", 16), {name: "bad", err: "x"},
		{name: "old", sevenDay: &window{pct: 95}, lastSeen: time.Now()}}
	cc := []string{"cc@x"}
	assert(menuBarReading("", cc, rs).headline().pct == 59, "the Claude Code login by default")
	assert(menuBarReading(mostUsedChoice, cc, rs).headline().pct == 100, "the fullest live account when asked for")
	assert(menuBarReading("low", cc, rs).headline().pct == 16, "a chosen account")
	assert(menuBarReading("bad", cc, rs).headline().pct == 59, "a chosen account without a reading falls back")
	assert(menuBarReading("", nil, rs).headline().pct == 100, "no Claude Code login: the fullest account stands in")
	assert(menuBarReading("", nil, rs[3:4]) == nil, "nothing readable")

	spent := reading{fiveHour: &window{pct: 0}, sevenDay: &window{pct: 100}}
	assert(spent.headline().pct == 100, "a spent weekly limit is not hidden behind an empty 5-hour window")
	_, hok = usageFromHeaders(http.Header{"Content-Type": {"application/json"}}, "")
	assert(!hok, "no limit headers, no reading")

	// A request to a model with a weekly cap of its own reports that cap as a second weekly
	// claim. Headers are the ones a real response to such a request carried.
	sh := http.Header{}
	sh.Set("anthropic-ratelimit-unified-7d-utilization", "0.24")
	sh.Set("anthropic-ratelimit-unified-7d-reset", "1794704400")
	sh.Set("anthropic-ratelimit-unified-7d-status", "allowed")
	sh.Set("anthropic-ratelimit-unified-7d_oi-utilization", "0.21")
	sh.Set("anthropic-ratelimit-unified-7d_oi-reset", "1794704400")
	sh.Set("anthropic-ratelimit-unified-7d_oi-status", "allowed")
	sh.Set("anthropic-ratelimit-unified-reset", "1794704400")
	su, _ := usageFromHeaders(sh, "Fable")
	sr := toReading("acc", su, nil)
	assert(sr.sevenDay != nil && math.Abs(sr.sevenDay.pct-24) < 1e-9, "the scoped claim is not taken for the weekly window")
	assert(len(sr.models) == 1 && sr.models[0].label == "Fable" && math.Abs(sr.models[0].pct-21) < 1e-9,
		"the scoped claim becomes the model's weekly cap")
	su, _ = usageFromHeaders(sh, "")
	assert(len(toReading("acc", su, nil).models) == 0, "a probe to a model without a cap of its own names no model")
	// Limit resets: counted per kind from the limits each grant clears. The first two
	// grants are the ones a real response carried; the rest cover what must not count.
	var ru UsageResponse
	rerr := json.Unmarshal([]byte(`{"five_hour":null,
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
	   "not a grant"]}}`), &ru)
	resetNow, _ := parseISO("2026-11-13T20:00:00+00:00")
	rc := resetCounts(ru.CedarEmber, resetNow)
	assert(rerr == nil && len(rc) == 4 && rc[0] == resetCount{"full", 1} && rc[1] == resetCount{"session", 1} &&
		rc[2] == resetCount{"fable", 2} && rc[3] == resetCount{"opus", 3},
		"resets are added up per kind; spent, expired and malformed grants count for nothing")
	var odd UsageResponse
	assert(json.Unmarshal([]byte(`{"seven_day":{"utilization":1,"resets_at":"2026-11-15T01:00:00+00:00"},"cedar_ember":"soon"}`), &odd) == nil &&
		toReading("acc", odd, nil).sevenDay != nil && len(toReading("acc", odd, nil).resets) == 0,
		"an unreadable resets block does not cost the reading")
	assert(strings.Contains(fmt.Sprintf(T().resetLine, 2, "fable"), "2 x fable reset"), "the line reads as a count of a kind")
	assert(modelIsRefused(statusError(404)) && modelIsRefused(statusError(403)), "an account without the capped model is remembered")
	assert(!modelIsRefused(statusError(529)) && !modelIsRefused(statusError(429)) && !modelIsRefused(errors.New("x")),
		"a passing failure does not hide the model's cap for a day")
	assert(statusError(403).Error() == fmt.Sprintf(T().authRejected, 403) && statusError(429).Error() == "HTTP 429",
		"status errors keep the messages they had")

	// The gauge must always occupy the same width, or the rows stop lining up.
	for _, v := range []float64{-5, 0, 0.4, 12.5, 50, 99.9, 100, 150} {
		assert(len([]rune(bar(v))) == barCells, fmt.Sprintf("gauge width at %.1f%%", v))
	}
	assert(bar(0) == strings.Repeat("□", barCells), "an empty window draws an empty gauge")
	assert(bar(100) == strings.Repeat("■", barCells), "a full window draws a full gauge")
	assert(bar(150) == bar(100), "over 100% cannot overflow the gauge")
	assert(bar(-5) == bar(0), "a negative value cannot underflow the gauge")
	assert(bar(50) == strings.Repeat("■", barCells/2)+strings.Repeat("□", barCells/2),
		"half a window draws half a gauge")
	// Barely-used must still differ from unused, or a low reading reads as zero.
	assert(bar(1) != bar(0), "any usage lights the first cell")

	// Snapshots of unreachable accounts: appended after the live rows, in a stable order,
	// and dropped as soon as a live row carries the same name.
	seen := time.Now()
	stale := map[string]reading{
		"zoe@example.com": {name: "zoe@example.com", lastSeen: seen},
		"amy@example.com": {name: "amy@example.com", lastSeen: seen},
	}
	merged := mergeStale([]reading{{name: "live@example.com"}}, stale)
	assert(len(merged) == 3, "snapshots are appended to the live rows")
	assert(merged[0].name == "live@example.com", "live rows come first")
	assert(merged[1].name == "amy@example.com" && merged[2].name == "zoe@example.com",
		"snapshots keep a stable, sorted order")
	shadowed := mergeStale([]reading{{name: "amy@example.com"}}, stale)
	assert(len(shadowed) == 2 && shadowed[1].name == "zoe@example.com",
		"a snapshot is skipped once the account is live again")
	assert(len(mergeStale(nil, map[string]reading{})) == 0, "no snapshots, no rows")

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
