//! What the tray shows, worked out from the readings on hand. Tray backends draw a `View`
//! and hold no logic of their own.

use crate::format::{model_line, pct, remaining_until, reset_line, time_of_day, window_line};
use crate::i18n::{self, fill, t, LANGUAGES};
use crate::model::{menu_bar_reading, Reading, RowKind, MOST_USED_CHOICE};

/// One entry of the "Menu bar shows" submenu.
#[derive(Debug, Clone, PartialEq)]
pub struct MenuBarChoice {
    pub label: String,
    /// The values stored as `menu_bar_account_kind` and `menu_bar_account`; `None` for the
    /// default.
    pub value: Option<(Option<RowKind>, String)>,
    pub checked: bool,
}

#[derive(Debug, Clone, Default)]
pub struct View {
    /// The read-only rows: accounts, their windows, errors.
    pub lines: Vec<String>,
    /// Text beside the icon, which only macOS shows.
    pub title: String,
    /// Carries the figure where there is no text beside the icon.
    pub tooltip: String,
    /// How full the dial is drawn.
    pub percent: f64,
    pub refresh_now: String,
    pub add_account: String,
    pub manage_accounts: String,
    pub open_config: String,
    pub menu_bar_shows: String,
    /// The default and the most used account first, then every account that can be followed.
    pub menu_bar_choices: Vec<MenuBarChoice>,
    pub language: String,
    pub quit: String,
    /// Index into `LANGUAGES` of the active language.
    pub language_index: usize,
}

/// How many entries of `menu_bar_choices` are fixed; accounts follow after a separator.
pub const FIXED_MENU_BAR_CHOICES: usize = 2;

/// The title before anything is known, and when there is no account at all.
pub const IDLE_TITLE: &str = "Claude ⚙︎";
/// There are accounts, but none of them can be read right now.
const UNREADABLE_TITLE: &str = "Claude ⚠︎";

/// The name a row is shown under. Two accounts of different kinds may share a name — a key
/// named by a login's email while Claude Code is signed into another profile, say — and
/// then each says what kind it is.
fn label(r: &Reading, readings: &[Reading]) -> String {
    let shared = readings.iter().filter(|o| o.name == r.name && o.last_seen.is_none()).count() > 1;
    if shared && r.last_seen.is_none() {
        format!("{} · {}", r.name, r.kind.type_text())
    } else {
        r.name.clone()
    }
}

/// Frames the block of accounts Claude Code is signed into, in a menu that has no other way
/// to set rows apart.
const RULE: &str = "──────────────────────";

/// One account's rows.
fn account_lines(r: &Reading, readings: &[Reading], lines: &mut Vec<String>) {
    if let Some(err) = &r.err {
        lines.push(format!("{} — {}", label(r, readings), t().error_word));
        lines.push(format!("   {err}"));
        return;
    }
    let dot = if r.active && r.last_seen.is_none() { "●" } else { "○" };
    let mut name = label(r, readings);
    if let Some(seen) = r.last_seen {
        name += &fill(t().last_seen, &[&time_of_day(seen)]);
    }
    lines.push(format!("{dot} {name}"));
    lines.push(window_line(t().five_hour_line, "5h", r.five_hour.as_ref()));
    lines.push(window_line(t().seven_day_line, "7d", r.seven_day.as_ref()));
    lines.extend(r.models.iter().map(|m| model_line(m.pct, &m.label)));
    lines.extend(r.resets.iter().map(|c| reset_line(c.count, &c.kind)));
}

/// The rows for the readings on hand, one menu item per line. The accounts Claude Code is
/// signed into come first, framed under a heading; the rest follow below a rule.
pub fn reading_lines(readings: &[Reading]) -> Vec<String> {
    let signed_in = |r: &&Reading| r.kind == RowKind::ClaudeCode && r.last_seen.is_none();
    let (logins, others): (Vec<&Reading>, Vec<&Reading>) = readings.iter().partition(signed_in);
    let mut lines = Vec::new();
    if !logins.is_empty() {
        let heading = t().signed_in_heading;
        let tail = RULE.chars().count().saturating_sub(heading.chars().count() + 4).max(2);
        lines.push(format!("── {heading} {}", "─".repeat(tail)));
        logins.iter().for_each(|r| account_lines(r, readings, &mut lines));
        if !others.is_empty() {
            lines.push(RULE.to_string());
        }
    }
    others.iter().for_each(|r| account_lines(r, readings, &mut lines));
    lines
}

/// The text beside the icon: the figure of the account the menu bar follows.
pub fn title(choice: &str, choice_kind: Option<RowKind>, logins: &[String], readings: &[Reading]) -> (String, f64) {
    if readings.is_empty() {
        return (IDLE_TITLE.to_string(), 0.0);
    }
    match menu_bar_reading(choice, choice_kind, logins, readings).and_then(Reading::bar_window) {
        None => (UNREADABLE_TITLE.to_string(), 0.0),
        // Once a window is exhausted the only thing that matters is when it returns.
        Some(w) if w.pct >= 100.0 => {
            (format!("Claude {} · {}", pct(w.pct), remaining_until(w.resets_at)), w.pct)
        }
        Some(w) => (format!("Claude {}", pct(w.pct)), w.pct.max(0.0)),
    }
}

/// Which account the menu bar figure follows. Only accounts that are still polled are
/// offered; a chosen account that disappears falls back to the default without losing the
/// setting.
pub fn menu_bar_choices(choice: &str, choice_kind: Option<RowKind>, readings: &[Reading]) -> Vec<MenuBarChoice> {
    let fixed = |label: &str, value: Option<&str>| MenuBarChoice {
        label: label.to_string(),
        value: value.map(|v| (None, v.to_string())),
        checked: value.unwrap_or("") == choice,
    };
    let mut choices =
        vec![fixed(t().menu_bar_default, None), fixed(t().menu_bar_most_used, Some(MOST_USED_CHOICE))];
    let offered: Vec<&Reading> = readings.iter().filter(|r| r.last_seen.is_none()).collect();
    // The account saved, or the one of its name standing in for it while it is left out.
    let exact = offered.iter().any(|r| r.name == choice && Some(r.kind) == choice_kind);
    let ticked = |r: &Reading| r.name == choice && (!exact || Some(r.kind) == choice_kind);
    choices.extend(offered.iter().map(|r| MenuBarChoice {
        label: label(r, readings),
        value: Some((Some(r.kind), r.name.clone())),
        checked: ticked(r),
    }));
    choices
}

pub fn render(readings: &[Reading], logins: &[String], polled: bool, choice: &str, choice_kind: Option<RowKind>) -> View {
    let mut lines = reading_lines(readings);
    if readings.is_empty() {
        // Before the first poll returns there is nothing to say — and claiming there are
        // no accounts would be wrong for the second it takes.
        lines.push(if polled { t().no_accounts.to_string() } else { t().loading.to_string() });
    }
    let (title, percent) = title(choice, choice_kind, logins, readings);
    View {
        lines,
        tooltip: if polled { title.clone() } else { t().tooltip_idle.to_string() },
        title,
        percent,
        refresh_now: t().refresh_now.to_string(),
        add_account: t().add_account.to_string(),
        manage_accounts: t().manage_accounts.to_string(),
        open_config: t().open_config.to_string(),
        menu_bar_shows: t().menu_bar_shows.to_string(),
        menu_bar_choices: menu_bar_choices(choice, choice_kind, readings),
        language: t().language.to_string(),
        quit: t().quit.to_string(),
        language_index: LANGUAGES.iter().position(|l| l.code == i18n::current_language()).unwrap_or(0),
    }
}
