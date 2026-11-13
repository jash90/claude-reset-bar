//! Polling and the state it keeps between polls. The worker thread is the only poller and
//! the only writer of the config file and the key store.

use std::collections::{HashMap, HashSet};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::Utc;
use rayon::prelude::*;

use crate::accounts::{self, EditRequest};
use crate::config::{self, Account, Config};
use crate::credentials::{claude_code_tokens, name_claude_code_logins, Login};
use crate::format::{clock, pct};
use crate::http::{self, FetchError};
use crate::i18n::{self, fill, t, LANGUAGES};
use crate::model::{detect_reset, merge_stale, to_reading, Reading, Stamp, UsageResponse, Window, WindowState};
use crate::secrets::{self, key_account, KeyKind};
use crate::view::{self, View};
use crate::window_host;

/// What the menu and the accounts window ask the worker to do.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    Poll,
    OpenConfig,
    SetLanguage(usize),
    /// Which account the menu bar figure follows; `None` for the default.
    SetMenuBarAccount(Option<String>),
    /// Opens the accounts window, or brings it forward; optionally with the cursor in the
    /// form that adds an account.
    ShowAccounts { add_form: bool },
    /// An edit made in the accounts window.
    Edit(EditRequest),
}

/// Where the worker hands a finished view. The backend moves it onto its own thread.
pub type ViewSink = Box<dyn Fn(View) + Send>;

#[derive(Default)]
struct State {
    readings: Vec<Reading>,
    baselines: HashMap<String, HashMap<&'static str, WindowState>>,
    fast_polled: HashMap<String, Stamp>,
    /// The names of the Claude Code logins seen on the last poll.
    claude_code_names: Vec<String>,
    /// The name each token was last shown under, for a poll where its email cannot be
    /// fetched.
    token_names: HashMap<String, String>,
    /// Accounts that dropped out of reach, keyed by name, keeping their last reading so
    /// the row does not simply vanish. Memory only — a restart forgets them.
    stale: HashMap<String, Reading>,
    /// Set once the first poll returns, so the menu can say "loading" until then.
    polled: bool,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn with_state<R>(f: impl FnOnce(&mut State) -> R) -> R {
    let mut guard = STATE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    f(guard.get_or_insert_with(State::default))
}

/// The readings on show and the names of the Claude Code logins among them.
pub fn snapshot() -> (Vec<Reading>, Vec<String>) {
    with_state(|s| (s.readings.clone(), s.claude_code_names.clone()))
}

/// Forgets an account outright — a removed account should not linger as a snapshot.
pub fn forget(name: &str) {
    with_state(|s| {
        s.readings.retain(|r| r.name != name);
        s.claude_code_names.retain(|n| n != name);
        s.baselines.remove(name);
        s.fast_polled.remove(name);
        s.stale.remove(name);
    })
}

/// Drops what is remembered about an account's limit windows. Its key may now belong to a
/// different account, so the old baseline cannot tell a reset from a switch.
pub fn drop_baseline(name: &str) {
    with_state(|s| {
        s.baselines.remove(name);
        s.fast_polled.remove(name);
    })
}

/// Carries an account's state over to its new name.
pub fn rename_state(from: &str, to: &str) {
    with_state(|s| {
        if let Some(reading) = s.readings.iter_mut().find(|r| r.name == from) {
            reading.name = to.to_string();
        }
        if let Some(baseline) = s.baselines.remove(from) {
            s.baselines.insert(to.to_string(), baseline);
        }
        if let Some(done) = s.fast_polled.remove(from) {
            s.fast_polled.insert(to.to_string(), done);
        }
    })
}

/// macOS: posted through osascript, which needs no notification entitlement and no
/// bundle of its own.
#[cfg(target_os = "macos")]
pub fn notify(title: &str, body: &str) -> Result<(), String> {
    let quoted = |text: &str| text.replace('\\', "").replace('"', "'");
    let script =
        format!("display notification \"{}\" with title \"{}\" sound name \"Glass\"", quoted(body), quoted(title));
    let status = std::process::Command::new("/usr/bin/osascript").args(["-e", &script]).status();
    match status {
        Ok(status) if status.success() => Ok(()),
        Ok(status) => Err(format!("osascript: {status}")),
        Err(e) => Err(e.to_string()),
    }
}

#[cfg(not(target_os = "macos"))]
pub fn notify(title: &str, body: &str) -> Result<(), String> {
    notify_rust::Notification::new()
        .appname("Claude Reset Bar")
        .summary(title)
        .body(body)
        .show()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// A reset notification waiting to be sent once the state lock is released.
struct ResetNotice {
    title: String,
    body: String,
}

fn check_reset(state: &mut State, name: &str, key: &'static str, label: &str, w: Window) -> Option<ResetNotice> {
    let windows = state.baselines.entry(name.to_string()).or_default();
    let prev = windows.get(key).copied();
    let (fired, next) = detect_reset(prev, w.resets_at, w.pct);
    windows.insert(key, next);
    let prev = prev.filter(|_| fired)?;
    Some(ResetNotice {
        title: fill(t().reset_title, &[name]),
        body: fill(t().reset_body, &[label, &pct(prev.utilization), &pct(w.pct), &clock(w.resets_at)]),
    })
}

/// Handles Claude Code logins that are gone — signed out, or swapped by /login. Their old
/// baseline describes a limit window that can no longer be followed, so it is dropped, and
/// the final reading is kept as a snapshot: resets_at does not move until the window
/// actually resets, so its countdown stays truthful even though nothing refreshes it.
fn retire(state: &mut State, names: &[String]) {
    for name in names {
        let snapshot = state
            .readings
            .iter()
            .find(|r| &r.name == name && r.err.is_none() && r.last_seen.is_none())
            .cloned();
        if let Some(mut reading) = snapshot {
            reading.last_seen = Some(Utc::now());
            state.stale.insert(name.clone(), reading);
        }
        state.baselines.remove(name);
        state.fast_polled.remove(name);
    }
}

/// One account to read this poll. Reading them is independent, so they run in parallel.
enum Job {
    Login(Login),
    Session(Account),
    Token { name: String, token: String },
    /// Known to fail before any request goes out: the account's key is not where the
    /// config says it is.
    Failed { name: String, error: String },
}

/// A job's reading, plus what it learned along the way.
struct Outcome {
    reading: Reading,
    /// An org_id discovered from the session key, to be written back.
    discovered_org: Option<(String, String)>,
    /// The API turned the request away for its rate, not for the key.
    rate_limited: bool,
}

fn outcome(name: &str, usage: Result<UsageResponse, FetchError>) -> Outcome {
    Outcome {
        rate_limited: matches!(usage, Err(FetchError::Status(429))),
        reading: to_reading(name, usage.map_err(|e| e.to_string())),
        discovered_org: None,
    }
}

fn run_job(job: &Job) -> Outcome {
    match job {
        Job::Login(login) => outcome(&login.name, http::fetch_usage_oauth(&login.token)),
        Job::Token { name, token } => outcome(name, http::fetch_usage_for_token(token)),
        Job::Failed { name, error } => outcome(name, Err(FetchError::Other(error.clone()))),
        Job::Session(account) => {
            let mut account = account.clone();
            let mut discovered_org = None;
            if account.org_id.is_empty() {
                match http::discover_org_id(&account.session_key) {
                    Ok(id) => {
                        discovered_org = Some((account.name.clone(), id.clone()));
                        account.org_id = id;
                    }
                    Err(e) => return outcome(&account.name, Err(e)),
                }
            }
            Outcome { discovered_org, ..outcome(&account.name, http::fetch_usage_session(&account)) }
        }
    }
}

/// The key of an added account: from the key store when the config says it is there,
/// from the config itself otherwise.
fn stored_key(in_store: bool, kind: KeyKind, name: &str, in_config: &str) -> Result<String, String> {
    if !in_store {
        return Ok(in_config.to_string());
    }
    secrets::read(&key_account(kind, name)).ok_or_else(|| t().key_missing.to_string())
}

fn config_jobs(cfg: &Config) -> Vec<Job> {
    let failed = |name: &str, error| Job::Failed { name: name.to_string(), error };
    let mut jobs = Vec::new();
    // Anything not filled in is the skeleton written by ensure_config.
    for a in cfg.accounts.iter().filter(|a| !a.name.is_empty() && (a.keychain || !a.session_key.is_empty())) {
        jobs.push(match stored_key(a.keychain, KeyKind::SessionKey, &a.name, &a.session_key) {
            Ok(session_key) => Job::Session(Account { session_key, ..a.clone() }),
            Err(error) => failed(&a.name, error),
        });
    }
    for a in cfg.oauth_accounts.iter().filter(|a| !a.name.is_empty() && (a.keychain || !a.token.is_empty())) {
        jobs.push(match stored_key(a.keychain, KeyKind::Token, &a.name, &a.token) {
            Ok(token) => Job::Token { name: a.name.clone(), token },
            Err(error) => failed(&a.name, error),
        });
    }
    jobs
}

pub fn poll() {
    let cfg = accounts::move_keys_to_store(config::load_config());
    let configured: HashSet<String> =
        cfg.configured_names().into_iter().chain(cfg.hidden_logins.iter().cloned()).collect();

    // Every Claude Code login — no configuration needed. The email is fetched on every poll
    // because /login swaps the account behind the same credentials, and the name keys the
    // state: without it a new account would be compared against the previous baseline.
    let tokens = claude_code_tokens();
    let emails: Vec<String> = tokens.par_iter().map(|token| http::fetch_oauth_label(token)).collect();

    let logins = with_state(|state| {
        let logins =
            name_claude_code_logins(&tokens, &emails, &state.token_names, &state.claude_code_names, &configured);
        state.token_names = logins.iter().map(|l| (l.token.clone(), l.name.clone())).collect();
        let current: Vec<String> = logins.iter().map(|l| l.name.clone()).collect();
        let gone: Vec<String> =
            state.claude_code_names.iter().filter(|n| !current.contains(n)).cloned().collect();
        retire(state, &gone);
        state.claude_code_names = current;
        logins
    });

    // Isolated from one another: an expired key on one account must not block the others.
    // The indexed collect keeps the rows in their display order.
    let jobs: Vec<Job> = logins.into_iter().map(Job::Login).chain(config_jobs(&cfg)).collect();
    let outcomes: Vec<Outcome> = jobs.par_iter().map(run_job).collect();

    // Written one at a time, after the parallel part: two accounts must not race on the file.
    for (name, org_id) in outcomes.iter().filter_map(|o| o.discovered_org.as_ref()) {
        if let Err(e) = config::save_org_id(name, org_id) {
            eprintln!("could not save org_id for {name}: {e}");
        }
    }

    let notices = with_state(|state| {
        let out: Vec<Reading> = outcomes
            .into_iter()
            .map(|o| {
                // Rate limited: the last reading is minutes old at most and resets_at has
                // not moved, so it stays on show until the next poll gets through.
                let last = state.readings.iter().find(|r| r.name == o.reading.name);
                match last.filter(|r| o.rate_limited && r.err.is_none() && r.last_seen.is_none()) {
                    Some(last) => last.clone(),
                    None => o.reading,
                }
            })
            .collect();
        // A stale account that came back within reach — signed into again, or added by
        // key — is live now, so its snapshot is discarded for good.
        for r in &out {
            state.stale.remove(&r.name);
        }
        let mut notices = Vec::new();
        for r in out.iter().filter(|r| r.err.is_none()) {
            if let Some(w) = r.five_hour {
                notices.extend(check_reset(state, &r.name, "five_hour", t().five_hour_window, w));
            }
            if let Some(w) = r.seven_day {
                notices.extend(check_reset(state, &r.name, "seven_day", t().seven_day_window, w));
            }
        }
        state.readings = merge_stale(out, &state.stale);
        state.polled = true;
        notices
    });
    for notice in notices {
        if let Err(e) = notify(&notice.title, &notice.body) {
            eprintln!("the notification did not get through: {e}");
        }
    }
}

/// A remembered reset time has passed, so a poll is due straight away instead of after the
/// interval. Each resets_at value triggers this exactly once — otherwise an account whose
/// API keeps returning a stale past date would be polled every minute forever.
fn reset_is_due() -> bool {
    with_state(|state| {
        let now = Utc::now();
        for r in &state.readings {
            let Some(headline) = r.headline() else { continue };
            if r.err.is_some() || r.last_seen.is_some() || headline.resets_at > now {
                continue;
            }
            if state.fast_polled.get(&r.name) == Some(&headline.resets_at) {
                continue;
            }
            state.fast_polled.insert(r.name.clone(), headline.resets_at);
            return true;
        }
        false
    })
}

pub fn render() -> View {
    let (readings, logins, polled) =
        with_state(|s| (s.readings.clone(), s.claude_code_names.clone(), s.polled));
    view::render(&readings, &logins, polled, &config::load_config().menu_bar_account)
}

fn report(what: &str, result: std::io::Result<()>) {
    if let Err(e) = result {
        eprintln!("could not {what}: {e}");
    }
}

/// The worker: polls on the interval and on request, and re-renders every minute. Polling
/// the API is infrequent because limits move slowly; the frequent tick only recomputes
/// countdowns from the cached resets_at so the menu never goes stale.
pub fn run_worker(commands: Receiver<Command>, show: ViewSink) {
    let minutes = config::load_config().check_interval_minutes;
    let api_interval = Duration::from_secs(60 * if minutes < 1 { 15 } else { minutes as u64 });
    let ui_interval = Duration::from_secs(60);

    // Everything on screen follows the state: the tray, and the accounts window if open.
    let refresh = |show: &ViewSink| {
        show(render());
        window_host::show_rows(accounts::rows());
    };
    let poll_and_refresh = |show: &ViewSink| {
        poll();
        refresh(show);
    };
    poll_and_refresh(&show);
    let mut next_api = Instant::now() + api_interval;
    let mut next_ui = Instant::now() + ui_interval;

    loop {
        let wait = next_api.min(next_ui).saturating_duration_since(Instant::now());
        match commands.recv_timeout(wait) {
            Ok(Command::Poll) => poll_and_refresh(&show),
            Ok(Command::OpenConfig) => {
                report("create the config file", config::ensure_config());
                config::open_in_editor(&config::config_path());
            }
            Ok(Command::SetLanguage(index)) => {
                let Some(language) = LANGUAGES.get(index) else { continue };
                i18n::set_language(language.code);
                report("save the language", config::save_language(language.code));
                refresh(&show);
            }
            Ok(Command::SetMenuBarAccount(choice)) => {
                let saved = config::edit_config(|doc| {
                    config::set_field(doc, "menu_bar_account", choice.clone().map(Into::into))
                });
                report("save the menu bar account", saved);
                refresh(&show);
            }
            Ok(Command::ShowAccounts { add_form }) => window_host::open(add_form, accounts::rows()),
            Ok(Command::Edit(request)) => {
                let result = accounts::apply(request);
                window_host::show_result(result);
                poll_and_refresh(&show);
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {
                let now = Instant::now();
                if now >= next_api {
                    next_api = now + api_interval;
                    poll_and_refresh(&show);
                }
                if now >= next_ui {
                    next_ui = now + ui_interval;
                    refresh(&show);
                    if reset_is_due() {
                        poll_and_refresh(&show);
                    }
                }
            }
        }
    }
}
