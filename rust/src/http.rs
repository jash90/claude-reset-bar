//! The requests: the usage endpoint, the inference probe that stands in for it, and the
//! claude.ai dashboard endpoint for sessionKey accounts.

use std::collections::HashMap;
use std::fmt;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use chrono::{TimeZone, Utc};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use ureq::Agent;

use crate::config::Account;
use crate::i18n::{fill, t};
use crate::model::{lenient, UsageLimit, UsageResponse, UsageWindow};

/// A failed request. An HTTP failure keeps its code, so a caller can tell a refused token
/// (403) or a rate limit (429) from the rest.
#[derive(Debug, Clone, PartialEq)]
pub enum FetchError {
    Status(u16),
    Other(String),
}

impl fmt::Display for FetchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FetchError::Status(code @ (401 | 403)) => {
                f.write_str(&fill(t().auth_rejected, &[&code.to_string()]))
            }
            FetchError::Status(429) => f.write_str(t().rate_limited),
            FetchError::Status(code) => write!(f, "HTTP {code}"),
            FetchError::Other(message) => f.write_str(message),
        }
    }
}

fn network_error(e: impl fmt::Display) -> FetchError {
    FetchError::Other(fill(t().network_error, &[&e.to_string()]))
}

fn bad_shape(e: impl fmt::Display) -> FetchError {
    FetchError::Other(fill(t().bad_shape, &[&e.to_string()]))
}

/// What an error response says, short enough for a menu row: the API's own message when
/// the body carries one, otherwise the body on one line, cut to 120 characters.
pub fn api_error_message(body: &str) -> String {
    let message = serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|doc| doc.get("error")?.get("message")?.as_str().map(str::to_string))
        .filter(|message| !message.is_empty());
    message.unwrap_or_else(|| body.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(120).collect())
}

type Headers<'a> = &'a [(&'a str, &'a str)];

fn agent() -> &'static Agent {
    static AGENT: OnceLock<Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(20)))
            // A 429 from inference still carries the limit headers, so a failing status
            // must arrive as a response, not as an error that drops them.
            .http_status_as_error(false)
            .build()
            .into()
    })
}

fn get_json<T: DeserializeOwned>(url: &str, headers: Headers) -> Result<T, FetchError> {
    let mut request = agent().get(url);
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    let mut response = request.call().map_err(network_error)?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        // The codes the callers act on stay bare; any other carries what the API said.
        if matches!(status, 400 | 401 | 403 | 404 | 429) {
            return Err(FetchError::Status(status));
        }
        let body = response.body_mut().read_to_string().unwrap_or_default();
        return Err(match api_error_message(&body) {
            message if message.is_empty() => FetchError::Status(status),
            message => FetchError::Other(format!("HTTP {status}: {message}")),
        });
    }
    let body = response.body_mut().read_to_string().map_err(bad_shape)?;
    serde_json::from_str(&body).map_err(|e| {
        record_unexpected(&body);
        bad_shape(e)
    })
}

/// Keeps the last response that could not be read, next to the config file. The API is
/// private and changes without notice; this is what shows how.
fn record_unexpected(body: &str) {
    let path = crate::config::config_path().with_file_name("last-unexpected-response.json");
    let _ = std::fs::write(path, body);
}

// The usage endpoint lists an account's limit resets only for a request that names the
// Claude Code CLI; any other client is told the account is not eligible.
const CLAUDE_CODE_USER_AGENT: &str = "claude-cli/2.1.323 (external, cli)";
const ANTHROPIC_API: &str = "https://api.anthropic.com";

fn anthropic_headers(bearer: &str) -> [(&'static str, &str); 4] {
    [
        ("Authorization", bearer),
        ("anthropic-version", "2023-06-01"),
        ("anthropic-beta", "oauth-2025-04-20"),
        ("User-Agent", CLAUDE_CODE_USER_AGENT),
    ]
}

pub fn fetch_usage_oauth(token: &str) -> Result<UsageResponse, FetchError> {
    // cedar_ember=1 asks for the limit resets on top of the usual reading.
    let url = format!("{ANTHROPIC_API}/api/oauth/usage?cedar_ember=1");
    get_json(&url, &anthropic_headers(&format!("Bearer {token}")))
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

/// One model the probe can be sent to. `scoped_label` names the per-model weekly cap its
/// response reports; empty when the model has none.
struct ProbeModel {
    id: &'static str,
    scoped_label: &'static str,
}

/// The model with a weekly cap of its own.
const SCOPED_PROBE: ProbeModel = ProbeModel { id: "claude-fable-5-2", scoped_label: "Fable" };
/// The smallest current model: the probe for accounts the capped model turns away.
const PLAIN_PROBE: ProbeModel = ProbeModel { id: "claude-haiku-5-5", scoped_label: "" };

const LIMIT_HEADER_PREFIX: &str = "anthropic-ratelimit-unified-";

/// Turns the unified rate-limit headers into the shape the usage endpoint returns. Header
/// names are expected in lower case. Utilization comes as a fraction (0.16), the reset as
/// Unix seconds. A scoped weekly claim becomes a "weekly_scoped" entry under
/// `scoped_label`, the model the request went to.
pub fn usage_from_headers(headers: &HashMap<String, String>, scoped_label: &str) -> Option<UsageResponse> {
    let window = |tag: &str| -> Option<UsageWindow> {
        let fraction: f64 =
            headers.get(&format!("{LIMIT_HEADER_PREFIX}{tag}-utilization"))?.trim().parse().ok()?;
        let resets_at = headers
            .get(&format!("{LIMIT_HEADER_PREFIX}{tag}-reset"))
            .and_then(|raw| raw.trim().parse::<f64>().ok())
            .and_then(|seconds| Utc.timestamp_opt(seconds as i64, 0).single())
            .map(|at| at.to_rfc3339());
        Some(UsageWindow { utilization: Some(fraction * 100.0), resets_at })
    };
    let mut usage =
        UsageResponse { five_hour: window("5h"), seven_day: window("7d"), ..Default::default() };
    if usage.five_hour.is_none() && usage.seven_day.is_none() {
        return None;
    }
    if scoped_label.is_empty() {
        return Some(usage);
    }
    // The claim's own name ("7d_oi") is opaque, so any scoped weekly claim is taken; should
    // a response carry several, the fullest one is the one that limits the model.
    let scoped = headers
        .keys()
        .filter_map(|key| key.strip_prefix(LIMIT_HEADER_PREFIX)?.strip_suffix("-utilization"))
        .filter(|tag| tag.starts_with("7d_"))
        .filter_map(window)
        .max_by(|a, b| a.utilization.unwrap_or(0.0).total_cmp(&b.utilization.unwrap_or(0.0)));
    if let Some(scoped) = scoped {
        usage.limits =
            vec![UsageLimit::scoped(scoped_label, scoped.utilization.unwrap_or(0.0), scoped.resets_at)];
    }
    Some(usage)
}

/// Tokens an endpoint or a model turned away, and until when to leave it alone for them.
/// Accounts are polled in parallel, so the memory sits behind a lock.
#[derive(Default)]
struct Refusals(Mutex<HashMap<String, Instant>>);

impl Refusals {
    fn active(&self, token: &str) -> bool {
        self.0.lock().unwrap().get(token).is_some_and(|until| Instant::now() < *until)
    }

    fn remember(&self, token: &str, wait: Duration) {
        self.0.lock().unwrap().insert(token.to_string(), Instant::now() + wait);
    }
}

fn scoped_probe_refusals() -> &'static Refusals {
    static REFUSALS: OnceLock<Refusals> = OnceLock::new();
    REFUSALS.get_or_init(Refusals::default)
}

fn usage_refusals() -> &'static Refusals {
    static REFUSALS: OnceLock<Refusals> = OnceLock::new();
    REFUSALS.get_or_init(Refusals::default)
}

const HOUR: Duration = Duration::from_secs(3600);
const DAY: Duration = Duration::from_secs(24 * 3600);

/// Tells whether a failed probe says the account may not use the model at all, as opposed
/// to the API having a bad moment: 403 for no access, 404 or 400 for a model it does not
/// offer.
pub fn model_is_refused(err: &FetchError) -> bool {
    matches!(err, FetchError::Status(400 | 403 | 404))
}

/// The outcome of one probe. `retry` reports that the API answered without limit headers
/// and without rejecting the token outright, so another model may fare better.
struct Probe {
    result: Result<UsageResponse, FetchError>,
    retry: bool,
}

/// Sends the one-token request.
fn probe_usage_once(token: &str, model: &ProbeModel) -> Probe {
    let body = format!(
        // OAuth tokens are only accepted for requests that present themselves as Claude Code.
        r#"{{"model":"{}","max_tokens":1,"system":"You are Claude Code, Anthropic's official CLI for Claude.","messages":[{{"role":"user","content":"hi"}}]}}"#,
        model.id
    );
    let bearer = format!("Bearer {token}");
    let mut request = agent().post(format!("{ANTHROPIC_API}/v1/messages"));
    for (name, value) in anthropic_headers(&bearer) {
        request = request.header(name, value);
    }
    let response = match request.header("content-type", "application/json").send(body.as_str()) {
        Ok(response) => response,
        Err(e) => return Probe { result: Err(network_error(e)), retry: false },
    };
    let status = response.status().as_u16();
    if status == 401 || status == 403 {
        return Probe { result: Err(FetchError::Status(status)), retry: status == 403 };
    }
    let headers: HashMap<String, String> = response
        .headers()
        .iter()
        .filter_map(|(name, value)| Some((name.as_str().to_lowercase(), value.to_str().ok()?.to_string())))
        .collect();
    // A 429 from inference still carries the headers — and then they matter most.
    if let Some(usage) = usage_from_headers(&headers, model.scoped_label) {
        return Probe { result: Ok(usage), retry: false };
    }
    if !(200..300).contains(&status) {
        return Probe { result: Err(FetchError::Status(status)), retry: true };
    }
    Probe { result: Err(bad_shape("no limit headers")), retry: true }
}

/// Reads limits for a token the usage endpoint refuses. The capped model is asked first,
/// because only its response carries the per-model weekly cap. When it answers without
/// limit headers the smallest model is asked instead; when the answer was that the account
/// may not use the capped model, for the next day directly.
fn fetch_usage_from_headers(token: &str) -> Result<UsageResponse, FetchError> {
    if scoped_probe_refusals().active(token) {
        return probe_usage_once(token, &PLAIN_PROBE).result;
    }
    let first = probe_usage_once(token, &SCOPED_PROBE);
    if !first.retry {
        return first.result;
    }
    let second = probe_usage_once(token, &PLAIN_PROBE).result;
    if second.is_ok() && first.result.as_ref().is_err_and(model_is_refused) {
        scoped_probe_refusals().remember(token, DAY);
    }
    second
}

/// Reads usage for a token added to the config: the usage endpoint while it answers, the
/// inference headers when it refuses the token (403 for a missing scope, 429 for its
/// hourly cap).
pub fn fetch_usage_for_token(token: &str) -> Result<UsageResponse, FetchError> {
    if usage_refusals().active(token) {
        return fetch_usage_from_headers(token);
    }
    match fetch_usage_oauth(token) {
        Err(FetchError::Status(code @ (429 | 403))) => {
            usage_refusals().remember(token, if code == 403 { DAY } else { HOUR });
            fetch_usage_from_headers(token)
        }
        other => other,
    }
}

/// Names the account by its email so several accounts stay distinguishable. Empty when the
/// profile cannot be read.
pub fn fetch_oauth_label(token: &str) -> String {
    #[derive(Deserialize, Default)]
    struct Profile {
        #[serde(default, deserialize_with = "lenient")]
        email: String,
        #[serde(default, deserialize_with = "lenient")]
        display_name: String,
    }
    #[derive(Deserialize)]
    struct Doc {
        #[serde(default, deserialize_with = "lenient")]
        account: Profile,
    }
    let url = format!("{ANTHROPIC_API}/api/oauth/profile");
    match get_json::<Doc>(&url, &anthropic_headers(&format!("Bearer {token}"))) {
        Ok(doc) if !doc.account.email.is_empty() => doc.account.email,
        Ok(doc) => doc.account.display_name,
        Err(_) => String::new(),
    }
}

// These headers mimic the request the claude.ai/settings/limits dashboard fires. A missing
// or wrong User-Agent / Referer triggers a Cloudflare bot challenge.
const BROWSER_HEADERS: [(&str, &str); 9] = [
    ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"),
    ("Accept", "application/json, text/plain, */*"),
    ("Accept-Language", "en-US,en;q=0.9"),
    ("Cache-Control", "no-cache"),
    ("Pragma", "no-cache"),
    ("Referer", "https://claude.ai/settings/limits"),
    ("sec-fetch-dest", "empty"),
    ("sec-fetch-mode", "cors"),
    ("sec-fetch-site", "same-origin"),
];

fn get_claude_ai<T: DeserializeOwned>(path: &str, session_key: &str) -> Result<T, FetchError> {
    let cookie = format!("sessionKey={session_key}");
    let mut headers = BROWSER_HEADERS.to_vec();
    headers.push(("Cookie", &cookie));
    get_json(&format!("https://claude.ai/api/{path}"), &headers)
}

pub fn fetch_usage_session(account: &Account) -> Result<UsageResponse, FetchError> {
    get_claude_ai(&format!("organizations/{}/usage", account.org_id), &account.session_key)
}

/// Finds the account's organization UUID with nothing but the session key. Every claude.ai
/// account belongs to exactly one, and it appears nowhere in the UI.
pub fn discover_org_id(session_key: &str) -> Result<String, FetchError> {
    #[derive(Deserialize)]
    struct Org {
        #[serde(default, deserialize_with = "lenient")]
        uuid: String,
    }
    let orgs: Vec<Org> = get_claude_ai("organizations", session_key)?;
    match orgs.into_iter().next() {
        Some(org) if !org.uuid.is_empty() => Ok(org.uuid),
        _ => Err(bad_shape("no organization")),
    }
}
