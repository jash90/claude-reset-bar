//! The usage payload, the reading the menu shows, and the pure logic between the two.

use std::collections::{BTreeMap, HashMap, HashSet};

use chrono::{DateTime, Duration, TimeZone, Utc};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer};
use serde_json::Value;

use crate::i18n::t;

pub type Stamp = DateTime<Utc>;

/// Reads a field that is missing, null or of the wrong type as its default. A hand-edited
/// config with one bad value — a number written as a string — must cost that value only,
/// not every account in the file.
pub fn lenient<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Default + DeserializeOwned,
{
    Ok(T::deserialize(Value::deserialize(d)?).unwrap_or_default())
}

/// Reads a list the same way, entry by entry: one that cannot be read is left out and the
/// rest are kept.
pub fn lenient_list<'de, D, T>(d: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: DeserializeOwned,
{
    let entries: Vec<Value> = lenient(d)?;
    Ok(entries.into_iter().filter_map(|entry| T::deserialize(entry).ok()).collect())
}

pub fn parse_iso(s: &str) -> Option<Stamp> {
    DateTime::parse_from_rfc3339(s).ok().map(|t| t.with_timezone(&Utc))
}

// Every field is optional. The API has already moved one reading out of its dedicated
// field once (the per-model caps), and a null arriving where a number used to be must be
// told apart from a real zero so the other shape can be read instead.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct UsageWindow {
    #[serde(default)]
    pub utilization: Option<f64>,
    #[serde(default)]
    pub resets_at: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ScopeModel {
    #[serde(default, deserialize_with = "lenient")]
    pub display_name: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Scope {
    #[serde(default)]
    pub model: Option<ScopeModel>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct UsageLimit {
    #[serde(default, deserialize_with = "lenient")]
    pub kind: String,
    #[serde(default, deserialize_with = "lenient")]
    pub group: String,
    #[serde(default)]
    pub percent: Option<f64>,
    #[serde(default, deserialize_with = "lenient")]
    pub is_active: bool,
    #[serde(default)]
    pub resets_at: Option<String>,
    // Set on a "weekly_scoped" entry: the weekly cap that applies to one model only.
    // This is where per-model limits are reported now; the seven_day_opus and
    // seven_day_sonnet fields come back null.
    #[serde(default)]
    pub scope: Option<Scope>,
}

impl UsageLimit {
    /// A weekly limit scoped to one model.
    pub fn scoped(model: &str, percent: f64, resets_at: Option<String>) -> Self {
        UsageLimit {
            kind: "weekly_scoped".into(),
            group: "weekly".into(),
            percent: Some(percent),
            resets_at,
            scope: Some(Scope { model: Some(ScopeModel { display_name: model.into() }) }),
            ..Default::default()
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct UsageResponse {
    #[serde(default)]
    pub five_hour: Option<UsageWindow>,
    #[serde(default)]
    pub seven_day: Option<UsageWindow>,
    #[serde(default)]
    pub seven_day_opus: Option<UsageWindow>,
    #[serde(default)]
    pub seven_day_sonnet: Option<UsageWindow>,
    #[serde(default, deserialize_with = "lenient_list")]
    pub limits: Vec<UsageLimit>,
    // The limit resets the account holds. Only sent when the request asks for it. Kept
    // raw: the block is undocumented, and one that has changed shape should cost its own
    // lines, not the account's whole reading.
    #[serde(default)]
    pub cedar_ember: Option<Value>,
}

/// How many resets of one kind an account still holds. `kind` is "full", "session", or a
/// model's name in lower case.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResetCount {
    pub kind: String,
    pub count: i64,
}

/// Names a reset from the limits it clears. One that clears the weekly limit is a full
/// reset, whatever else it clears with it; one for the 5-hour window alone is a session
/// reset; anything else clears one model's weekly cap and carries that model's name.
pub fn reset_kind(clears: &[String]) -> String {
    let has = |name: &str| clears.iter().any(|c| c == name);
    if has("seven_day") {
        return "full".into();
    }
    if has("five_hour") {
        return "session".into();
    }
    match clears.first().map(String::as_str) {
        None => String::new(),
        // The models billed against the plan beyond its base allowance — today that is Fable.
        Some("seven_day_overage_included") => "fable".into(),
        Some(first) => first.strip_prefix("seven_day_").unwrap_or(first).to_string(),
    }
}

#[derive(Deserialize)]
struct Grant {
    #[serde(default, deserialize_with = "lenient")]
    clears: Vec<String>,
    #[serde(default, deserialize_with = "lenient")]
    resets_left: i64,
    #[serde(default)]
    ends_at: Option<String>,
}

/// Adds up the resets still to be used per kind: the full one first, then the rest by
/// name. A grant that is spent or past its end date counts for nothing, and a malformed
/// one is skipped on its own.
pub fn reset_counts(block: Option<&Value>, now: Stamp) -> Vec<ResetCount> {
    let grants = match block.and_then(|b| b.get("grants")).and_then(Value::as_array) {
        Some(g) => g,
        None => return Vec::new(),
    };
    let mut totals: BTreeMap<String, i64> = BTreeMap::new();
    for raw in grants {
        let Ok(grant) = Grant::deserialize(raw) else { continue };
        let kind = reset_kind(&grant.clears);
        if kind.is_empty() || grant.resets_left <= 0 {
            continue;
        }
        if let Some(end) = grant.ends_at.as_deref().and_then(parse_iso) {
            if end <= now {
                continue;
            }
        }
        *totals.entry(kind).or_insert(0) += grant.resets_left;
    }
    let rank = |kind: &str| match kind {
        "full" => 0,
        "session" => 1,
        _ => 2,
    };
    let mut out: Vec<ResetCount> =
        totals.into_iter().map(|(kind, count)| ResetCount { kind, count }).collect();
    out.sort_by(|a, b| rank(&a.kind).cmp(&rank(&b.kind)).then_with(|| a.kind.cmp(&b.kind)));
    out
}

/// One limit window: how much of it is used and when it starts over.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Window {
    pub pct: f64,
    pub resets_at: Stamp,
}

/// A weekly cap that applies to a single model.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelWindow {
    pub label: String,
    pub pct: f64,
}

#[derive(Debug, Clone, Default)]
pub struct Reading {
    pub name: String,
    // None when the API reports no such window. A 5-hour window only exists while one is
    // running, and since 2026-11 the API answers an idle one with "five_hour": null and no
    // session entry in limits[] at all, so its absence is a normal state, not an error.
    pub five_hour: Option<Window>,
    pub seven_day: Option<Window>,
    pub models: Vec<ModelWindow>,
    pub resets: Vec<ResetCount>,
    pub active: bool,
    pub err: Option<String>,
    // None for a live account. Set when the account can no longer be polled — Claude Code
    // was signed into a different one — and the row becomes a read-only snapshot of the
    // final reading.
    pub last_seen: Option<Stamp>,
}

impl Reading {
    pub fn failed(name: &str, err: impl Into<String>) -> Self {
        Reading { name: name.to_string(), err: Some(err.into()), ..Default::default() }
    }

    /// The window that limits you right now: the fuller of the two. A spent weekly limit
    /// blocks the account however empty the 5-hour window is. This is what the menu bar
    /// figure shows.
    pub fn headline(&self) -> Option<Window> {
        match (self.five_hour, self.seven_day) {
            (None, week) => week,
            (session, None) => session,
            (Some(session), Some(week)) => Some(if week.pct > session.pct { week } else { session }),
        }
    }

    fn is_live(&self) -> bool {
        self.err.is_none() && self.last_seen.is_none() && self.headline().is_some()
    }
}

/// Returns one window as the menu needs it, taken from whichever shape carried it this
/// time. The API reports each reading twice: as a dedicated five_hour / seven_day object
/// and as an entry in limits[] with the same percentage and reset time. It has already
/// retired one of those shapes once, so neither is treated as the one that must be there.
/// A window is only lost when both come back empty.
pub fn window_reading(w: Option<&UsageWindow>, limits: &[UsageLimit], kind: &str) -> Option<Window> {
    let mut pct = w.and_then(|w| w.utilization);
    let mut stamp = w.and_then(|w| w.resets_at.clone());
    if let Some(limit) = limits.iter().find(|l| l.kind == kind) {
        pct = pct.or(limit.percent);
        stamp = stamp.or_else(|| limit.resets_at.clone());
    }
    Some(Window { pct: pct?, resets_at: parse_iso(&stamp?)? })
}

pub fn to_reading(name: &str, usage: Result<UsageResponse, String>) -> Reading {
    to_reading_at(name, usage, Utc::now())
}

pub fn to_reading_at(name: &str, usage: Result<UsageResponse, String>, now: Stamp) -> Reading {
    let u = match usage {
        Ok(u) => u,
        Err(e) => return Reading::failed(name, e),
    };
    // Each window is optional; the account only counts as unreadable when neither the
    // 5-hour nor the 7-day window can be found anywhere.
    let mut r = Reading {
        name: name.to_string(),
        five_hour: window_reading(u.five_hour.as_ref(), &u.limits, "session"),
        seven_day: window_reading(u.seven_day.as_ref(), &u.limits, "weekly_all"),
        ..Default::default()
    };
    if r.five_hour.is_none() && r.seven_day.is_none() {
        return Reading::failed(name, t().shape_error);
    }
    r.resets = reset_counts(u.cedar_ember.as_ref(), now);
    // Per-model weekly caps arrive two ways depending on the account. The dedicated fields
    // are the older shape and now usually null; the scoped entries in limits[] are the
    // current one, and reading them means new model tiers appear without a code change.
    let mut seen = HashSet::new();
    let mut add_model = |models: &mut Vec<ModelWindow>, label: &str, pct: f64| {
        if !label.is_empty() && seen.insert(label.to_string()) {
            models.push(ModelWindow { label: label.to_string(), pct });
        }
    };
    if let Some(pct) = u.seven_day_opus.as_ref().and_then(|w| w.utilization) {
        add_model(&mut r.models, "Opus", pct);
    }
    if let Some(pct) = u.seven_day_sonnet.as_ref().and_then(|w| w.utilization) {
        add_model(&mut r.models, "Sonnet", pct);
    }
    // The first session entry says whether a window is running.
    r.active = u.limits.iter().find(|l| l.group == "session" || l.kind == "session").is_some_and(|l| l.is_active);
    for l in &u.limits {
        if l.group == "weekly" {
            if let (Some(model), Some(pct)) = (l.scope.as_ref().and_then(|s| s.model.as_ref()), l.percent) {
                add_model(&mut r.models, &model.display_name, pct);
            }
        }
    }
    r.models.sort_by(|a, b| a.label.cmp(&b.label));
    r
}

// ─── Reset detection (pure logic, no I/O) ─────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WindowState {
    pub resets_at: Stamp,
    pub utilization: f64,
}

/// Reports whether a reset just happened and returns the baseline to persist. The first
/// reading only records a baseline — it never fires.
///
/// A real reset pushes resets_at forward by 5 hours or 7 days. A 1-hour threshold ignores
/// minor timestamp jitter from the API while still catching every legitimate reset.
pub fn detect_reset(prev: Option<WindowState>, resets_at: Stamp, utilization: f64) -> (bool, WindowState) {
    let fresh = WindowState { resets_at, utilization };
    let Some(prev) = prev else { return (false, fresh) };
    let fired = resets_at - prev.resets_at > Duration::hours(1);
    // The API occasionally returns the epoch (1970) for resets_at. Storing that as the
    // baseline would make the next valid timestamp look like a ~56-year jump and fire a
    // bogus alert, so an implausible timestamp is discarded.
    if resets_at < Utc.with_ymd_and_hms(2020, 1, 1, 0, 0, 0).unwrap() {
        return (fired, prev);
    }
    (fired, fresh)
}

/// Appends snapshots of unreachable accounts after the live rows, skipping any name a live
/// row already covers. Sorted by name so the menu keeps a stable order.
pub fn merge_stale(mut live: Vec<Reading>, stale: &HashMap<String, Reading>) -> Vec<Reading> {
    let covered: HashSet<String> = live.iter().map(|r| r.name.clone()).collect();
    let mut names: Vec<&String> = stale.keys().filter(|n| !covered.contains(*n)).collect();
    names.sort();
    live.extend(names.into_iter().map(|n| stale[n].clone()));
    live
}

/// The menu_bar_account value that makes the tray follow the fullest account.
pub const MOST_USED_CHOICE: &str = "*most-used";

/// Picks the reading the tray figure follows. By default that is the account signed into
/// Claude Code. A chosen account wins while it has a live reading; otherwise, and when no
/// Claude Code login is readable either, the fullest account stands in, so the figure
/// never goes blank while some account can be read.
pub fn menu_bar_reading<'a>(choice: &str, claude_code: &[String], rs: &'a [Reading]) -> Option<&'a Reading> {
    let live = |name: &str| rs.iter().find(|r| r.name == name && r.is_live());
    let pct = |r: &Reading| r.headline().map_or(0.0, |w| w.pct);
    let mut most_used: Option<&Reading> = None;
    for r in rs {
        if let Some(r) = live(&r.name) {
            if most_used.map_or(true, |m| pct(r) > pct(m)) {
                most_used = Some(r);
            }
        }
    }
    if choice == MOST_USED_CHOICE {
        return most_used;
    }
    if !choice.is_empty() {
        if let Some(r) = live(choice) {
            return Some(r);
        }
    }
    claude_code.iter().find_map(|name| live(name)).or(most_used)
}
