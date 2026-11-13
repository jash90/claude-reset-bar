//! The part of the self-check that covers what comes back over HTTP: limits read from
//! response headers, error messages, and the strings the accounts window shows.

use std::collections::HashMap;

use chrono::{TimeZone, Utc};

use crate::http::{api_error_message, model_is_refused, usage_from_headers, FetchError};
use crate::i18n::{fill, t, LANGUAGES};
use crate::model::to_reading;
use crate::secrets::{key_account, KeyKind};
use crate::selfcheck::{check, headers};

pub fn header_readings() {
    // Limits read from inference headers — the route for setup-token tokens, which the usage
    // endpoint refuses. Values are the ones a real response carried.
    let weekly = headers(&[
        ("anthropic-ratelimit-unified-7d-utilization", "0.16"),
        ("anthropic-ratelimit-unified-7d-reset", "1794092400"),
    ]);
    let usage = usage_from_headers(&weekly, "");
    check(usage.is_some(), "limit headers yield a reading");
    let reading = to_reading("acc", usage.ok_or_else(String::new));
    check(
        reading.err.is_none() && reading.seven_day.is_some_and(|w| (w.pct - 16.0).abs() < 1e-9),
        "the fraction becomes a percentage",
    );
    check(
        reading.seven_day.map(|w| w.resets_at) == Utc.timestamp_opt(1794092400, 0).single(),
        "the reset time is carried",
    );
    check(reading.five_hour.is_none(), "no 5-hour header, no 5-hour window");
    check(
        usage_from_headers(&headers(&[("content-type", "application/json")]), "").is_none(),
        "no limit headers, no reading",
    );

    // A request to a model with a weekly cap of its own reports that cap as a second weekly
    // claim. Headers are the ones a real response to such a request carried.
    let scoped = headers(&[
        ("anthropic-ratelimit-unified-7d-utilization", "0.24"),
        ("anthropic-ratelimit-unified-7d-reset", "1794704400"),
        ("anthropic-ratelimit-unified-7d-status", "allowed"),
        ("anthropic-ratelimit-unified-7d_oi-utilization", "0.21"),
        ("anthropic-ratelimit-unified-7d_oi-reset", "1794704400"),
        ("anthropic-ratelimit-unified-7d_oi-status", "allowed"),
        ("anthropic-ratelimit-unified-reset", "1794704400"),
    ]);
    let reading = to_reading("acc", usage_from_headers(&scoped, "Fable").ok_or_else(String::new));
    check(
        reading.seven_day.is_some_and(|w| (w.pct - 24.0).abs() < 1e-9),
        "the scoped claim is not taken for the weekly window",
    );
    check(
        reading.models.len() == 1 && reading.models[0].label == "Fable" && (reading.models[0].pct - 21.0).abs() < 1e-9,
        "the scoped claim becomes the model's weekly cap",
    );
    let unscoped = to_reading("acc", usage_from_headers(&scoped, "").ok_or_else(String::new));
    check(unscoped.models.is_empty(), "a probe to a model without a cap of its own names no model");

    check(
        model_is_refused(&FetchError::Status(404)) && model_is_refused(&FetchError::Status(403)),
        "an account without the capped model is remembered",
    );
    check(
        !model_is_refused(&FetchError::Status(529))
            && !model_is_refused(&FetchError::Status(429))
            && !model_is_refused(&FetchError::Other("x".into())),
        "a passing failure does not hide the model's cap for a day",
    );
    check(
        FetchError::Status(403).to_string() == fill(t().auth_rejected, &["403"])
            && FetchError::Status(429).to_string() == t().rate_limited
            && FetchError::Status(500).to_string() == "HTTP 500",
        "status errors keep the messages they had",
    );
    check(
        api_error_message(r#"{"error":{"type":"x","message":"Rate limited. Please try again later."}}"#)
            == "Rate limited. Please try again later."
            && api_error_message("{\n  \"oops\": 1\n}") == r#"{ "oops": 1 }"#,
        "an error response is shown by its own message, or on one line",
    );
    check(
        key_account(KeyKind::SessionKey, "a") == "sessionKey:a" && key_account(KeyKind::Token, "a") == "token:a",
        "keys are filed under the names the native app used",
    );
    let fractional: HashMap<String, String> = [
        ("anthropic-ratelimit-unified-5h-utilization", "0.5"),
        ("anthropic-ratelimit-unified-5h-reset", "1794000000.5"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect();
    let five_hour = usage_from_headers(&fractional, "").and_then(|u| u.five_hour);
    check(
        five_hour.as_ref().is_some_and(|w| w.utilization == Some(50.0) && w.resets_at.is_some()),
        "a reset header with a fraction of a second still gives the window",
    );
    for s in LANGUAGES.iter() {
        let filled = [s.msg_added, s.msg_key_replaced, s.msg_removed, s.msg_renamed, s.msg_hidden, s.msg_shown];
        check(
            s.status_line.matches("{}").count() == 2
                && s.wrong_key_kind.matches("{}").count() == 1
                && filled.iter().chain(&[s.token_rejected, s.keychain_failed, s.account_exists]).all(|m| m.contains("{}"))
                && [s.manage_accounts, s.confirm_remove, s.key_in_keychain, s.edit_hint, s.key_missing]
                    .iter()
                    .all(|m| !m.is_empty()),
            "the accounts window has its strings in every language",
        );
    }
}
