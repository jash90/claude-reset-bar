//! The self-check behind `--test`: reset detection, formatting, icon generation, language
//! resolution, config and payload parsing. The build scripts run it before packaging.

use std::collections::{HashMap, HashSet};
use std::io::Cursor;

use chrono::{Duration, TimeZone, Utc};
use serde_json::Value;

use crate::config::{parse_config, patch_org_id};
use crate::credentials::{is_oauth_token, live_tokens, name_claude_code_logins, parse_credential, StoredCredential};
use crate::format::{bar, remaining, reset_line, window_line, BAR_CELLS};
use crate::i18n::{fill, resolve_language, set_language, t, LANGUAGES};
use crate::icon::{app_icon, draw_icon, encode_png, png_size, to_ico, ICON_COLOR, ICON_SIZE};
use crate::model::{
    detect_reset, menu_bar_reading, merge_stale, parse_iso, reset_counts, to_reading, Reading, ResetCount,
    UsageLimit, UsageResponse, UsageWindow, Window, MOST_USED_CHOICE,
};

pub fn check(cond: bool, what: &str) {
    if !cond {
        eprintln!("self-check FAILED: {what}");
        std::process::exit(1);
    }
}

/// Builds a dedicated usage window.
fn win(pct: f64, resets_at: &str) -> Option<UsageWindow> {
    Some(UsageWindow { utilization: Some(pct), resets_at: Some(resets_at.to_string()) })
}

fn limit(kind: &str, group: &str, percent: Option<f64>, is_active: bool, resets_at: Option<&str>) -> UsageLimit {
    UsageLimit {
        kind: kind.into(),
        group: group.into(),
        percent,
        is_active,
        resets_at: resets_at.map(str::to_string),
        scope: None,
    }
}

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn cred(token: &str, expires_at: f64) -> StoredCredential {
    StoredCredential { token: token.into(), expires_at }
}

pub fn headers(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

fn decode_rgba(png_bytes: &[u8]) -> Option<Vec<u8>> {
    let mut reader = png::Decoder::new(Cursor::new(png_bytes)).read_info().ok()?;
    let mut pixels = vec![0; reader.output_buffer_size()?];
    reader.next_frame(&mut pixels).ok()?;
    Some(pixels)
}

pub fn run() {
    reset_detection();
    formatting_and_languages();
    icons();
    configs_and_credentials();
    payloads();
    crate::selfcheck_headers::header_readings();
    menu_bar_choice();
    limit_resets();
    gauges_and_snapshots();
    println!("self-check OK");
}

fn reset_detection() {
    let now = Utc::now();
    let plus5h = now + Duration::hours(5);

    // The first reading only records a baseline.
    let (fired, base) = detect_reset(None, now, 80.0);
    check(!fired, "first reading does not notify");
    check(base.resets_at == now, "first reading stores the timestamp");

    // The same timestamp is not a reset.
    check(!detect_reset(Some(base), now, 95.0).0, "an unchanged timestamp is not a reset");

    // A 5-hour jump is a reset.
    let (fired, next) = detect_reset(Some(base), plus5h, 0.0);
    check(fired, "a 5-hour jump is a reset");
    check(next.resets_at == plus5h, "a reset stores the new timestamp");

    // Drift below the 1-hour threshold is not a reset.
    check(!detect_reset(Some(base), now + Duration::minutes(10), 81.0).0, "a 10-minute shift is not a reset");

    // An epoch timestamp must not poison the baseline.
    let (_, kept) = detect_reset(Some(base), Utc.timestamp_opt(0, 0).unwrap(), 0.0);
    check(kept.resets_at == base.resets_at, "the epoch does not overwrite the baseline");
}

fn formatting_and_languages() {
    // Duration formatting, in whichever language is active.
    set_language("en");
    check(remaining(-5) == "now", "negative duration");
    check(remaining(3 * 3600 + 120) == "3h 2m", "hours and minutes");
    check(remaining(45 * 60) == "45m", "minutes only");
    check(remaining(3 * 86400 + 4 * 3600) == "3d 4h", "days and hours");
    set_language("pl");
    check(remaining(-5) == "teraz", "negative duration translates");
    set_language("en");

    // Language resolution: config wins, then the locale, then English. The environment is
    // passed in, so the result does not depend on the developer's shell.
    let none = |_: &str| None;
    let lc_all = |value: &'static str| move |name: &str| (name == "LC_ALL").then(|| value.to_string());
    check(resolve_language("pl", none) == "pl", "explicit language from the config");
    check(resolve_language("de", none) == "en", "unknown code falls back to English");
    check(resolve_language("", none) == "en", "no locale at all falls back to English");
    check(resolve_language("", lc_all("pl_PL.UTF-8")) == "pl", "locale is honoured");
    check(resolve_language("en", lc_all("pl_PL.UTF-8")) == "en", "config overrides the locale");
    check(resolve_language("auto", lc_all("de_DE.UTF-8")) == "en", "unsupported locale falls back to English");

    // Every language must define every string, or the menu shows blanks.
    for l in &LANGUAGES {
        let code = l.code;
        let menu = [l.refresh_now, l.open_config, l.quit, l.language, l.now, l.loading, l.error_word];
        check(menu.iter().all(|s| !s.is_empty()), &format!("language {code} defines its menu strings"));
        let templates = [
            l.reset_title, l.reset_body, l.five_hour_line, l.seven_day_line, l.model_line, l.reset_line,
            l.last_seen, l.idle_line, l.auth_rejected, l.network_error, l.bad_shape,
        ];
        check(
            templates.iter().all(|s| s.contains("{}")),
            &format!("language {code} defines its message templates"),
        );
        check(fill(l.last_seen, &["12:03"]).contains("12:03"), &format!("language {code} renders the last-seen stamp"));
        check(l.days.iter().all(|d| !d.is_empty()), &format!("language {code} defines all weekday names"));
    }
    check(fill("{} a {} b", &["1", "2"]) == "1 a 2 b", "template slots are filled in order");
    check(fill("{} a {}", &["1"]) == "1 a ", "a missing argument leaves its slot empty");
}

fn icons() {
    // The tray icon must be a valid PNG, and the ICO container must point at it.
    let raw = encode_png(&draw_icon(42.0, ICON_COLOR), ICON_SIZE, ICON_SIZE);
    check(decode_rgba(&raw).is_some(), "the icon decodes as PNG");
    check(png_size(&raw) == Some((ICON_SIZE as u32, ICON_SIZE as u32)), "the icon has the requested size");
    let ico = to_ico(&[&raw]);
    check(ico.len() == 22 + raw.len(), "an ICO header is 22 bytes");
    check(ico[22..] == raw[..], "the ICO carries the whole PNG");

    // Multi-image ICO: 6-byte header plus 16 bytes per entry, then the payloads in order.
    let (a16, a32) = (app_icon(16), app_icon(32));
    let multi = to_ico(&[&a16, &a32]);
    check(multi.len() == 6 + 2 * 16 + a16.len() + a32.len(), "a multi-size ICO has the right length");
    check(multi[4] == 2 && multi[5] == 0, "the ICO declares two images");
    check(multi[6] == 16 && multi[6 + 16] == 32, "the ICO entries carry the right dimensions");
    check(multi[6 + 2 * 16..6 + 2 * 16 + a16.len()] == a16[..], "the first image sits at its offset");

    // Application icon: 256 px is written as 0 in an ICO.
    let big = app_icon(256);
    check(png_size(&big) == Some((256, 256)), "the 256 px icon decodes");
    check(to_ico(&[&big])[6] == 0, "a dimension of 256 is stored as 0");

    // The rounded square must be transparent at the corner and solid in the middle.
    let pixels = decode_rgba(&app_icon(64)).unwrap_or_default();
    check(pixels.len() == 64 * 64 * 4, "the application icon decodes");
    check(pixels[3] == 0, "the icon corner is transparent");
    check(pixels[(32 * 64 + 32) * 4 + 3] == 255, "the icon centre is solid");

    // Extreme values must not break at the angle boundaries.
    let solid = |percent: f64| draw_icon(percent, ICON_COLOR).chunks_exact(4).filter(|p| p[3] == 255).count();
    check(solid(0.0) > 0 && solid(100.0) > solid(0.0), "extreme values");
}

fn configs_and_credentials() {
    // A partial config must survive decoding — a fresh install writes nothing but the
    // language, and losing the whole file over a missing "accounts" key would silently
    // revert the interface to the system locale.
    let partial = parse_config(r#"{"language":"en"}"#);
    check(partial.language == "en" && partial.accounts.is_empty(), "a language-only config keeps its setting");

    // A claude-reset config, webhook and all, must still parse.
    let parsed = parse_config(
        r#"{"accounts":[{"name":"a","session_key":"k","org_id":"o"}],"slack_webhook_url":"https://x","check_interval_minutes":5,"language":"pl"}"#,
    );
    check(parsed.accounts.len() == 1 && parsed.check_interval_minutes == 5, "a claude-reset config parses");
    check(parsed.language == "pl", "the language setting is read");
    // Nulls and a byte order mark are what hand-edited files carry.
    let loose = parse_config("\u{feff}{\"accounts\":null,\"language\":null,\"oauth_accounts\":[{\"name\":\"t\",\"token\":null}]}");
    check(loose.accounts.is_empty() && loose.oauth_accounts.len() == 1, "nulls and a byte order mark are tolerated");
    // One value of the wrong type costs that value, not the accounts next to it.
    let mistyped = parse_config(
        r#"{"accounts":[{"name":"a","session_key":"k","org_id":7},"stray"],"check_interval_minutes":"15","language":"pl"}"#,
    );
    check(
        mistyped.accounts.len() == 1 && mistyped.accounts[0].session_key == "k" && mistyped.accounts[0].org_id.is_empty(),
        "a mistyped field is dropped on its own",
    );
    check(mistyped.check_interval_minutes == 0 && mistyped.language == "pl", "a mistyped setting falls back to its default");

    // The token is found in the credentials layout, and absent when the section is missing.
    let found = parse_credential(r#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":1793743818844}}"#);
    check(found == Some(cred("sk-ant-oat01-x", 1793743818844.0)), "the token is read from JSON");
    check(parse_credential(r#"{"mcpOAuth":{}}"#).is_none(), "no token when the section is missing");

    // Several Claude Code logins: expired ones are dropped, the rest come freshest first,
    // and a token stored twice (Keychain and file) is polled once.
    let now = Utc::now();
    let now_ms = now.timestamp_millis() as f64;
    let live = live_tokens(
        &[cred("old", now_ms - 1000.0), cred("b", now_ms + 1000.0), cred("a", now_ms + 9000.0), cred("b", now_ms + 1000.0)],
        now,
    );
    check(live == ["a", "b"], "live tokens, freshest first, each once");
    check(live_tokens(&[cred("x", 0.0)], now) == ["x"], "a token without an expiry is kept");
    check(
        live_tokens(&[cred("old", now_ms - 1000.0), cred("older", now_ms - 9000.0)], now) == ["old"],
        "with every token expired the freshest stays, so the row can say why",
    );
    check(live_tokens(&[], now).is_empty(), "no credentials, no tokens");

    let no_names = HashMap::new();
    let nothing = HashSet::new();
    let named = name_claude_code_logins(
        &strings(&["t1", "t2", "t3", "t4"]),
        &strings(&["a@x", "", "a@x", "cfg@x"]),
        &HashMap::from([("t2".to_string(), "b@x".to_string())]),
        &[],
        &HashSet::from(["cfg@x".to_string()]),
    );
    check(
        named.len() == 2 && named[0].name == "a@x" && named[1].name == "b@x",
        "emails name logins, a known token keeps its name, duplicates and configured names are skipped",
    );
    let kept = name_claude_code_logins(&strings(&["new"]), &strings(&[""]), &no_names, &strings(&["me@x"]), &nothing);
    check(kept[0].name == "me@x", "a single login whose email is unavailable keeps the previous name");
    let unnamed = name_claude_code_logins(&strings(&["t1", "t2"]), &strings(&["", ""]), &no_names, &[], &nothing);
    check(
        unnamed[0].name == "Claude Code" && unnamed[1].name == "Claude Code 2",
        "unnamed logins get distinct names",
    );

    // Config accounts: both kinds are listed, an unfilled skeleton entry is not an account,
    // and a discovered org_id is written back without disturbing anything else in the file.
    let multi = parse_config(
        r#"{"accounts":[{"name":"s","session_key":"k"},{"name":"","session_key":""}],"oauth_accounts":[{"name":"t","token":"sk-ant-oat1"}]}"#,
    );
    check(multi.configured_names() == ["s", "t"], "both kinds of account, in order");
    let keychain = parse_config(
        r#"{"accounts":[{"name":"s","session_key":"","keychain":true}],"oauth_accounts":[{"name":"t","token":"","keychain":true}]}"#,
    );
    check(keychain.configured_names() == ["s", "t"], "Keychain-backed entries count as accounts");
    check(is_oauth_token("sk-ant-oat01-abc") && !is_oauth_token("sk-ant-sid01-abc"), "token kinds");

    let patched = patch_org_id(
        r#"{"accounts":[{"name":"s","session_key":"k"},{"name":"o","session_key":"k2","org_id":"keep"}],"slack_webhook_url":"https://x","extra":1}"#,
        "s",
        "uuid-1",
    );
    let back: Value = patched.ok().and_then(|raw| serde_json::from_slice(&raw).ok()).unwrap_or_default();
    check(back["accounts"].as_array().is_some_and(|a| a.len() == 2), "the account list survives the patch");
    check(back["accounts"][0]["org_id"] == "uuid-1", "the discovered org_id is written");
    check(back["accounts"][1]["org_id"] == "keep", "another account's org_id is untouched");
    check(back["slack_webhook_url"] == "https://x" && back["extra"] == 1, "unknown keys survive");
}

/// The payload most checks start from: both windows, with their limits[] twins.
fn scoped_payload() -> UsageResponse {
    UsageResponse {
        five_hour: win(9.0, "2026-08-17T14:29:59Z"),
        seven_day: win(25.0, "2026-08-22T22:59:59Z"),
        limits: vec![
            limit("session", "session", Some(9.0), true, None),
            limit("weekly_all", "weekly", Some(25.0), false, None),
            UsageLimit::scoped("Fable", 3.0, None),
            UsageLimit::scoped("Opus", 40.0, None),
        ],
        ..Default::default()
    }
}

fn payloads() {
    // Per-model weekly caps: read from the scoped entries in limits[], which is where the
    // API reports them now that seven_day_opus and seven_day_sonnet come back null.
    let scoped = scoped_payload();
    let got = to_reading("acc", Ok(scoped.clone()));
    check(got.err.is_none(), "a scoped payload decodes");
    check(got.active, "the session entry still sets the active flag");
    check(got.models.len() == 2, "both scoped models produce a row");
    check(got.models[0].label == "Fable" && got.models[1].label == "Opus", "model rows keep a stable, sorted order");
    check(got.models[1].pct == 40.0, "the scoped percentage is carried through");

    // The legacy fields still work, and must not duplicate a scoped entry of the same name.
    let legacy = UsageResponse { seven_day_opus: win(77.0, ""), ..scoped.clone() };
    let dedup = to_reading("acc", Ok(legacy));
    check(dedup.models.len() == 2, "a model reported twice yields one row");
    check(dedup.models[1].label == "Opus" && dedup.models[1].pct == 77.0, "the legacy field wins when both are present");

    // An account reporting no per-model caps simply has no such rows.
    let plain = to_reading(
        "acc",
        Ok(UsageResponse {
            five_hour: scoped.five_hour.clone(),
            seven_day: scoped.seven_day.clone(),
            limits: vec![limit("session", "session", None, false, None)],
            ..Default::default()
        }),
    );
    check(plain.models.is_empty(), "no scoped caps, no model rows");

    // A window whose dedicated field went null is read from limits[] instead — the same
    // move the per-model caps already made, and the shape that left the app reporting an
    // unexpected response while Claude Code itself was fine.
    let nulled = to_reading(
        "acc",
        Ok(UsageResponse {
            five_hour: None,
            seven_day: Some(UsageWindow::default()),
            limits: vec![
                limit("session", "session", Some(9.0), true, Some("2026-08-17T14:29:59Z")),
                limit("weekly_all", "weekly", Some(25.0), false, Some("2026-08-22T22:59:59Z")),
            ],
            ..Default::default()
        }),
    );
    check(nulled.err.is_none(), "null windows fall back to limits[] rather than failing");
    check(
        nulled.five_hour.is_some_and(|w| w.pct == 9.0) && nulled.seven_day.is_some_and(|w| w.pct == 25.0),
        "the percentages come from the limits entries",
    );
    check(
        nulled.five_hour.map(|w| w.resets_at) == parse_iso("2026-08-17T14:29:59Z"),
        "the reset time comes along with the percentage",
    );

    // The shape the API sends since 2026-11 while no 5-hour window is running: five_hour
    // is null and limits[] has no session entry at all. The account stays readable, with
    // the weekly window on show and the 5-hour one marked idle — this used to fail the
    // whole Claude Code account. Decoded from JSON, as it arrives.
    let idle_payload: Result<UsageResponse, _> = serde_json::from_str(
        r#"{"five_hour":null,"seven_day":{"utilization":58,"resets_at":"2026-11-08T00:59:59.858545+00:00"},
            "seven_day_opus":null,"limits":[
            {"kind":"weekly_all","group":"weekly","percent":58,"is_active":true,"resets_at":"2026-11-08T00:59:59.858545+00:00"},
            {"kind":"weekly_scoped","group":"weekly","percent":0,"scope":{"model":{"display_name":"Fable"}}}]}"#,
    );
    check(idle_payload.is_ok(), "the idle payload decodes");
    let idle = to_reading("acc", idle_payload.map_err(|e| e.to_string()));
    check(idle.err.is_none(), "a missing 5-hour window does not fail the account");
    check(idle.five_hour.is_none(), "an idle 5-hour window is reported as absent, not as 0%");
    check(idle.seven_day.is_some_and(|w| w.pct == 58.0), "the weekly window still comes through");
    check(idle.headline().is_some_and(|w| w.pct == 58.0), "the menu bar falls back to the weekly figure");
    check(idle.models.len() == 1 && idle.models[0].label == "Fable", "per-model caps still come through");
    check(window_line(t().five_hour_line, "5h", None).contains("5h"), "the idle line names its window");
    let shown = Window { pct: 39.0, resets_at: Utc::now() + Duration::minutes(15) + Duration::seconds(20) };
    let line = window_line(t().five_hour_line, "5h", Some(&shown));
    check(
        line.starts_with("   5h  ■■■■■□□□□□□□  39%   resets in 15m ("),
        "a window line keeps its columns",
    );

    // Nothing to read anywhere is still an error rather than a row of zeros.
    check(
        to_reading("acc", Ok(UsageResponse::default())).err.is_some(),
        "an empty response reports failure, it does not invent a reading",
    );
    check(
        to_reading("acc", Err("boom".into())).err.as_deref() == Some("boom"),
        "a failed request carries its message",
    );
}

fn menu_bar_choice() {
    // The tray follows the Claude Code login by default, a chosen account while it is
    // readable, and the fullest account when asked to or when nothing else can be read.
    let at = Utc::now();
    let mk = |name: &str, pct: f64| Reading {
        name: name.into(),
        seven_day: Some(Window { pct, resets_at: at }),
        ..Default::default()
    };
    let rs = vec![
        mk("cc@x", 59.0),
        mk("tok", 100.0),
        mk("low", 16.0),
        Reading::failed("bad", "x"),
        Reading { last_seen: Some(at), ..mk("old", 95.0) },
    ];
    let cc = strings(&["cc@x"]);
    let figure = |choice: &str, logins: &[String], rs: &[Reading]| {
        menu_bar_reading(choice, logins, rs).and_then(Reading::headline).map(|w| w.pct)
    };
    check(figure("", &cc, &rs) == Some(59.0), "the Claude Code login by default");
    check(figure(MOST_USED_CHOICE, &cc, &rs) == Some(100.0), "the fullest live account when asked for");
    check(figure("low", &cc, &rs) == Some(16.0), "a chosen account");
    check(figure("bad", &cc, &rs) == Some(59.0), "a chosen account without a reading falls back");
    check(figure("", &[], &rs) == Some(100.0), "no Claude Code login: the fullest account stands in");
    check(figure("", &[], &rs[3..4]).is_none(), "nothing readable");

    let spent = Reading {
        five_hour: Some(Window { pct: 0.0, resets_at: at }),
        seven_day: Some(Window { pct: 100.0, resets_at: at }),
        ..Default::default()
    };
    check(
        spent.headline().is_some_and(|w| w.pct == 100.0),
        "a spent weekly limit is not hidden behind an empty 5-hour window",
    );
}

fn limit_resets() {
    // Limit resets: counted per kind from the limits each grant clears. The first two
    // grants are the ones a real response carried; the rest cover what must not count.
    let usage: Result<UsageResponse, _> = serde_json::from_str(
        r#"{"five_hour":null,
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
           "not a grant"]}}"#,
    );
    check(usage.is_ok(), "a payload with limit resets decodes");
    let usage = usage.unwrap_or_default();
    let now = parse_iso("2026-11-13T20:00:00+00:00").unwrap_or_default();
    let count = |kind: &str, count: i64| ResetCount { kind: kind.into(), count };
    check(
        reset_counts(usage.cedar_ember.as_ref(), now)
            == [count("full", 1), count("session", 1), count("fable", 2), count("opus", 3)],
        "resets are added up per kind; spent, expired and malformed grants count for nothing",
    );
    let odd: Result<UsageResponse, _> = serde_json::from_str(
        r#"{"seven_day":{"utilization":1,"resets_at":"2026-11-15T01:00:00+00:00"},"cedar_ember":"soon"}"#,
    );
    let odd = to_reading("acc", odd.map_err(|e| e.to_string()));
    check(
        odd.seven_day.is_some() && odd.resets.is_empty(),
        "an unreadable resets block does not cost the reading",
    );
    check(reset_line(2, "fable").contains("2 x fable reset"), "the line reads as a count of a kind");
}

fn gauges_and_snapshots() {
    // The gauge must always occupy the same width, or the rows stop lining up.
    for v in [-5.0, 0.0, 0.4, 12.5, 50.0, 99.9, 100.0, 150.0] {
        check(bar(v).chars().count() == BAR_CELLS, &format!("gauge width at {v:.1}%"));
    }
    check(bar(0.0) == "□".repeat(BAR_CELLS), "an empty window draws an empty gauge");
    check(bar(100.0) == "■".repeat(BAR_CELLS), "a full window draws a full gauge");
    check(bar(150.0) == bar(100.0), "over 100% cannot overflow the gauge");
    check(bar(-5.0) == bar(0.0), "a negative value cannot underflow the gauge");
    check(
        bar(50.0) == "■".repeat(BAR_CELLS / 2) + &"□".repeat(BAR_CELLS / 2),
        "half a window draws half a gauge",
    );
    // Barely-used must still differ from unused, or a low reading reads as zero.
    check(bar(1.0) != bar(0.0), "any usage lights the first cell");

    // Snapshots of unreachable accounts: appended after the live rows, in a stable order,
    // and dropped as soon as a live row carries the same name.
    let seen = Some(Utc::now());
    let named = |name: &str| Reading { name: name.into(), ..Default::default() };
    let stale: HashMap<String, Reading> = ["zoe@example.com", "amy@example.com"]
        .into_iter()
        .map(|name| (name.to_string(), Reading { last_seen: seen, ..named(name) }))
        .collect();
    let merged = merge_stale(vec![named("live@example.com")], &stale);
    check(merged.len() == 3, "snapshots are appended to the live rows");
    check(merged[0].name == "live@example.com", "live rows come first");
    check(
        merged[1].name == "amy@example.com" && merged[2].name == "zoe@example.com",
        "snapshots keep a stable, sorted order",
    );
    let shadowed = merge_stale(vec![named("amy@example.com")], &stale);
    check(
        shadowed.len() == 2 && shadowed[1].name == "zoe@example.com",
        "a snapshot is skipped once the account is live again",
    );
    check(merge_stale(Vec::new(), &HashMap::new()).is_empty(), "no snapshots, no rows");
}

#[cfg(test)]
mod tests {
    #[test]
    fn self_check_passes() {
        super::run();
    }
}
