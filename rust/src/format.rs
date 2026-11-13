//! How durations, clock times, percentages and gauges are written in the menu.

use chrono::{Datelike, Local, Utc};

use crate::i18n::{fill, t};
use crate::model::{Stamp, Window};

/// Renders a duration as "2h 14m" / "3d 4h" / "now".
pub fn remaining(seconds: i64) -> String {
    if seconds <= 0 {
        return t().now.to_string();
    }
    let (d, h, m) = (seconds / 86400, (seconds % 86400) / 3600, (seconds % 3600) / 60);
    if d > 0 {
        format!("{d}d {h}h")
    } else if h > 0 {
        format!("{h}h {m}m")
    } else {
        format!("{m}m")
    }
}

pub fn remaining_until(at: Stamp) -> String {
    let millis = (at - Utc::now()).num_milliseconds();
    remaining((millis as f64 / 1000.0).round() as i64)
}

/// The weekday and the time of day, in local time.
pub fn clock(at: Stamp) -> String {
    let local = at.with_timezone(&Local);
    let day = t().days[local.weekday().num_days_from_sunday() as usize];
    format!("{day} {}", local.format("%H:%M"))
}

/// The time of day alone, without the weekday that `clock` prepends.
pub fn time_of_day(at: Stamp) -> String {
    at.with_timezone(&Local).format("%H:%M").to_string()
}

pub fn pct(v: f64) -> String {
    format!("{}%", v.round() as i64)
}

// A gauge is easier to read at a glance than a number: you see how full the window is
// without parsing digits, and several accounts line up for comparison.
pub const BAR_CELLS: usize = 12;

// Filled and hollow squares rather than block-and-shade characters: at menu size the light
// shade (U+2591) anti-aliases into a solid block, which made an almost-empty gauge look
// full. These two stay distinguishable, and both are present in the default UI font on all
// three platforms.
const BAR_FILLED: &str = "■";
const BAR_EMPTY: &str = "□";

pub fn bar(percent: f64) -> String {
    let frac = (percent / 100.0).clamp(0.0, 1.0);
    let mut full = (frac * BAR_CELLS as f64).round() as usize;
    // Any usage at all lights the first cell, so "a little" never looks like "none".
    if full == 0 && percent > 0.0 {
        full = 1;
    }
    BAR_FILLED.repeat(full) + &BAR_EMPTY.repeat(BAR_CELLS - full)
}

/// The percentage column is four characters wide so the text after it lines up.
fn column(text: &str) -> String {
    format!("{text:<4}")
}

/// One window's menu line, or the "no active window" line when the API reported none.
pub fn window_line(template: &str, tag: &str, w: Option<&Window>) -> String {
    match w {
        None => fill(t().idle_line, &[tag, &bar(0.0), &column("—")]),
        Some(w) => fill(
            template,
            &[&bar(w.pct), &column(&pct(w.pct)), &remaining_until(w.resets_at), &clock(w.resets_at)],
        ),
    }
}

pub fn model_line(percent: f64, label: &str) -> String {
    fill(t().model_line, &[&bar(percent), &column(&pct(percent)), label])
}

pub fn reset_line(count: i64, kind: &str) -> String {
    fill(t().reset_line, &[&count.to_string(), kind])
}
