//! What the tray shows, worked out from the readings on hand. Tray backends draw a `View`
//! and hold no logic of their own.

use crate::format::{model_line, pct, remaining_until, reset_line, time_of_day, window_line};
use crate::i18n::{self, fill, t, LANGUAGES};
use crate::model::{menu_bar_reading, Reading, MOST_USED_CHOICE};

/// One entry of the "Menu bar shows" submenu.
#[derive(Debug, Clone, PartialEq)]
pub struct MenuBarChoice {
    pub label: String,
    /// The value stored as `menu_bar_account`; `None` for the default.
    pub value: Option<String>,
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

/// The rows for the readings on hand. One menu item per line.
pub fn reading_lines(readings: &[Reading]) -> Vec<String> {
    let mut lines = Vec::new();
    for r in readings {
        if let Some(err) = &r.err {
            lines.push(format!("{} — {}", r.name, t().error_word));
            lines.push(format!("   {err}"));
            continue;
        }
        let dot = if r.active && r.last_seen.is_none() { "●" } else { "○" };
        let mut name = r.name.clone();
        if let Some(seen) = r.last_seen {
            name += &fill(t().last_seen, &[&time_of_day(seen)]);
        }
        lines.push(format!("{dot} {name}"));
        lines.push(window_line(t().five_hour_line, "5h", r.five_hour.as_ref()));
        lines.push(window_line(t().seven_day_line, "7d", r.seven_day.as_ref()));
        lines.extend(r.models.iter().map(|m| model_line(m.pct, &m.label)));
        lines.extend(r.resets.iter().map(|c| reset_line(c.count, &c.kind)));
    }
    lines
}

/// The text beside the icon: the figure of the account the menu bar follows.
pub fn title(choice: &str, logins: &[String], readings: &[Reading]) -> (String, f64) {
    if readings.is_empty() {
        return (IDLE_TITLE.to_string(), 0.0);
    }
    match menu_bar_reading(choice, logins, readings).and_then(Reading::headline) {
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
pub fn menu_bar_choices(choice: &str, readings: &[Reading]) -> Vec<MenuBarChoice> {
    let entry = |label: &str, value: Option<&str>| MenuBarChoice {
        label: label.to_string(),
        value: value.map(str::to_string),
        checked: value.unwrap_or("") == choice,
    };
    let mut choices = vec![entry(t().menu_bar_default, None), entry(t().menu_bar_most_used, Some(MOST_USED_CHOICE))];
    choices.extend(readings.iter().filter(|r| r.last_seen.is_none()).map(|r| entry(&r.name, Some(&r.name))));
    choices
}

pub fn render(readings: &[Reading], logins: &[String], polled: bool, choice: &str) -> View {
    let mut lines = reading_lines(readings);
    if readings.is_empty() {
        // Before the first poll returns there is nothing to say — and claiming there are
        // no accounts would be wrong for the second it takes.
        lines.push(if polled { t().no_accounts.to_string() } else { t().loading.to_string() });
    }
    let (title, percent) = title(choice, logins, readings);
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
        menu_bar_choices: menu_bar_choices(choice, readings),
        language: t().language.to_string(),
        quit: t().quit.to_string(),
        language_index: LANGUAGES.iter().position(|l| l.code == i18n::current_language()).unwrap_or(0),
    }
}
