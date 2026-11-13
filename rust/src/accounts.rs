//! Everything the accounts window can do to an account: add, rename, replace its key,
//! remove, hide. Runs on the worker; the window only shows rows and sends requests.

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::app;
use crate::config::{self, Config, SESSION_LIST, TOKEN_LIST};
use crate::credentials::is_oauth_token;
use crate::format::pct;
use crate::http::{self, FetchError};
use crate::i18n::{fill, t};
use crate::model::{to_reading, Reading};
use crate::secrets::{self, key_account, KeyKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RowKind {
    ClaudeCode,
    SessionKey,
    Token,
}

/// One row of the accounts window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AccountRow {
    pub name: String,
    pub kind: RowKind,
    /// Whether the key sits in the system's key store rather than in the config file.
    pub in_store: bool,
    /// A Claude Code login hidden from the menu.
    pub hidden: bool,
    pub status: String,
}

impl AccountRow {
    /// Only accounts added to the app have a name and a key of their own to change.
    /// Claude Code logins belong to Claude Code; they can only be hidden.
    pub fn editable(&self) -> bool {
        self.kind != RowKind::ClaudeCode
    }

    pub fn type_text(&self) -> &'static str {
        match self.kind {
            RowKind::ClaudeCode => t().type_claude_code,
            RowKind::SessionKey => t().type_session_key,
            RowKind::Token => t().type_token,
        }
    }

    /// Where the key is kept. The key itself is never shown.
    pub fn key_text(&self) -> &'static str {
        match self.kind {
            RowKind::ClaudeCode => t().key_claude_code,
            _ if self.in_store => t().key_in_keychain,
            _ => t().key_in_config,
        }
    }
}

/// An edit the accounts window asks for.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum EditRequest {
    Add { name: String, key: String },
    Rename { name: String, kind: RowKind, to: String },
    ReplaceKey { name: String, kind: RowKind, key: String },
    Remove { name: String },
    SetHidden { name: String, hidden: bool },
}

/// How an edit went, in words the window shows as they are.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EditResult {
    pub text: String,
    pub error: bool,
    /// The add form's fields were used up and should be emptied.
    pub clear_form: bool,
}

type Edit = Result<String, String>;

fn status_text(readings: &[Reading], name: &str) -> String {
    let Some(r) = readings.iter().find(|r| r.name == name) else { return t().loading.to_string() };
    if let Some(err) = &r.err {
        return err.clone();
    }
    let figure = |w: Option<crate::model::Window>| w.map_or("—".to_string(), |w| pct(w.pct));
    fill(t().status_line, &[&figure(r.five_hour), &figure(r.seven_day)])
}

/// Every account, in the order the window lists them: Claude Code logins, the hidden ones,
/// then accounts added by sessionKey and by token.
pub fn rows() -> Vec<AccountRow> {
    let cfg = config::load_config();
    let (readings, logins) = app::snapshot();
    let row = |name: &str, kind, in_store, hidden| AccountRow {
        name: name.to_string(),
        kind,
        in_store,
        hidden,
        status: if hidden { t().status_hidden.to_string() } else { status_text(&readings, name) },
    };
    let mut rows: Vec<AccountRow> = logins.iter().map(|n| row(n, RowKind::ClaudeCode, true, false)).collect();
    rows.extend(cfg.hidden_logins.iter().map(|n| row(n, RowKind::ClaudeCode, true, true)));
    let sessions = cfg.accounts.iter().filter(|a| !a.name.is_empty() && (a.keychain || !a.session_key.is_empty()));
    rows.extend(sessions.map(|a| row(&a.name, RowKind::SessionKey, a.keychain, false)));
    let tokens = cfg.oauth_accounts.iter().filter(|a| !a.name.is_empty() && (a.keychain || !a.token.is_empty()));
    rows.extend(tokens.map(|a| row(&a.name, RowKind::Token, a.keychain, false)));
    rows
}

/// A name already on screen or in the config — two rows under one name would share their
/// state.
fn is_taken(name: &str) -> bool {
    let cfg = config::load_config();
    let (readings, _) = app::snapshot();
    readings.iter().any(|r| r.name == name)
        || cfg.configured_names().iter().any(|n| n == name)
        || cfg.hidden_logins.iter().any(|n| n == name)
}

/// What checking a key found out about its account.
#[derive(Default)]
struct VerifiedKey {
    org_id: Option<String>,
    email: Option<String>,
}

/// Checks a key before anything is saved: a token must be able to read usage limits, a
/// sessionKey must lead to an organization.
fn verify(key: &str) -> Result<VerifiedKey, String> {
    if !is_oauth_token(key) {
        let org_id = http::discover_org_id(key).map_err(|e| e.to_string())?;
        return Ok(VerifiedKey { org_id: Some(org_id), email: None });
    }
    let usage = http::fetch_usage_for_token(key).map_err(|e| match e {
        FetchError::Status(code @ (401 | 403)) => fill(t().token_rejected, &[&code.to_string()]),
        other => other.to_string(),
    })?;
    if to_reading("", Ok(usage)).err.is_some() {
        return Err(t().shape_error.to_string());
    }
    let email = Some(http::fetch_oauth_label(key)).filter(|email| !email.is_empty());
    Ok(VerifiedKey { org_id: None, email })
}

fn list_of(kind: KeyKind) -> &'static str {
    match kind {
        KeyKind::SessionKey => SESSION_LIST,
        KeyKind::Token => TOKEN_LIST,
    }
}

fn key_field(kind: KeyKind) -> &'static str {
    match kind {
        KeyKind::SessionKey => "session_key",
        KeyKind::Token => "token",
    }
}

fn key_kind(kind: RowKind) -> KeyKind {
    if kind == RowKind::Token {
        KeyKind::Token
    } else {
        KeyKind::SessionKey
    }
}

fn save(edit: impl FnOnce(&mut serde_json::Map<String, serde_json::Value>)) -> Result<(), String> {
    config::edit_config(edit).map_err(|e| fill(t().save_failed, &[&e.to_string()]))
}

/// Puts the key into the key store. Returns whether it is there: on macOS a failure is
/// final; elsewhere a system without a key store keeps the key in the config file, as the
/// file has always held it.
fn store_key(kind: KeyKind, name: &str, key: &str) -> Result<bool, String> {
    match secrets::store(&key_account(kind, name), key) {
        Ok(()) => Ok(true),
        Err(e) if cfg!(target_os = "macos") => Err(fill(t().keychain_failed, &[&e])),
        Err(_) => Ok(false),
    }
}

fn add(raw_name: &str, raw_key: &str) -> Edit {
    let (name, key) = (raw_name.trim(), raw_key.trim());
    if key.is_empty() {
        return Err(t().key_required.to_string());
    }
    let kind = if is_oauth_token(key) { KeyKind::Token } else { KeyKind::SessionKey };
    if kind == KeyKind::SessionKey && name.is_empty() {
        return Err(t().name_required.to_string());
    }
    if !name.is_empty() && is_taken(name) {
        return Err(fill(t().account_exists, &[name]));
    }
    let found = verify(key)?;
    // A token's account is named by its email when no name was given.
    let name = match (name.is_empty(), found.email) {
        (false, _) => name.to_string(),
        (true, Some(email)) if !is_taken(&email) => email,
        (true, Some(email)) => return Err(fill(t().account_exists, &[&email])),
        (true, None) => return Err(t().token_needs_name.to_string()),
    };
    let in_store = store_key(kind, &name, key)?;
    let mut entry = json!({ "name": name, key_field(kind): if in_store { "" } else { key } });
    if in_store {
        entry["keychain"] = json!(true);
    }
    if kind == KeyKind::SessionKey {
        entry["org_id"] = json!(found.org_id.unwrap_or_default());
    }
    save(|doc| config::push_entry(doc, list_of(kind), entry))?;
    Ok(fill(t().msg_added, &[&name]))
}

/// Checks the new key the same way adding an account does, and only then replaces the old
/// one.
fn replace_key(name: &str, row_kind: RowKind, raw_key: &str) -> Edit {
    let key = raw_key.trim();
    if key.is_empty() {
        return Err(t().key_required.to_string());
    }
    let kind = key_kind(row_kind);
    if is_oauth_token(key) != (kind == KeyKind::Token) {
        let expected = if kind == KeyKind::Token { t().type_token } else { t().type_session_key };
        return Err(fill(t().wrong_key_kind, &[expected]));
    }
    let found = verify(key)?;
    let in_store = store_key(kind, name, key)?;
    save(|doc| {
        config::edit_entry(doc, list_of(kind), name, |entry| {
            entry.insert(key_field(kind).into(), json!(if in_store { "" } else { key }));
            entry.insert("keychain".into(), json!(in_store));
            if let Some(org_id) = &found.org_id {
                entry.insert("org_id".into(), json!(org_id));
            }
        })
    })?;
    app::drop_baseline(name);
    Ok(fill(t().msg_key_replaced, &[name]))
}

/// Renames an added account, carrying its key and its state over to the new name.
fn rename(from: &str, row_kind: RowKind, raw_to: &str) -> Edit {
    let to = raw_to.trim();
    if to.is_empty() {
        return Err(t().name_required.to_string());
    }
    if is_taken(to) {
        return Err(fill(t().account_exists, &[to]));
    }
    let kind = key_kind(row_kind);
    let (old_key, new_key) = (key_account(kind, from), key_account(kind, to));
    let in_store = rows().iter().any(|r| r.name == from && r.kind == row_kind && r.in_store);
    if in_store {
        let key = secrets::read(&old_key).ok_or_else(|| t().key_missing.to_string())?;
        secrets::store(&new_key, &key).map_err(|e| fill(t().keychain_failed, &[&e]))?;
    }
    let saved = save(|doc| {
        config::edit_entry(doc, list_of(kind), from, |entry| {
            entry.insert("name".into(), json!(to));
        })
    });
    if in_store {
        // Whichever name lost holds a copy of the key that nothing points at any more.
        secrets::delete(if saved.is_ok() { &old_key } else { &new_key });
    }
    saved?;
    app::rename_state(from, to);
    Ok(fill(t().msg_renamed, &[to]))
}

fn remove(name: &str) -> Edit {
    save(|doc| {
        config::remove_entry(doc, SESSION_LIST, name);
        config::remove_entry(doc, TOKEN_LIST, name);
    })?;
    secrets::delete(&key_account(KeyKind::SessionKey, name));
    secrets::delete(&key_account(KeyKind::Token, name));
    app::forget(name);
    Ok(fill(t().msg_removed, &[name]))
}

/// Hides a Claude Code login from the menu, or shows it again. The login itself — its
/// stored credentials, Claude Code's session — is never touched.
fn set_hidden(name: &str, hidden: bool) -> Edit {
    let mut list: Vec<String> = config::load_config().hidden_logins.into_iter().filter(|n| n != name).collect();
    if hidden {
        list.push(name.to_string());
    }
    save(|doc| config::set_field(doc, "hidden_logins", (!list.is_empty()).then(|| json!(list))))?;
    if hidden {
        app::forget(name);
    }
    Ok(fill(if hidden { t().msg_hidden } else { t().msg_shown }, &[name]))
}

pub fn apply(request: EditRequest) -> EditResult {
    let clear_form = matches!(request, EditRequest::Add { .. });
    let outcome = match &request {
        EditRequest::Add { name, key } => add(name, key),
        EditRequest::Rename { name, kind, to } => rename(name, *kind, to),
        EditRequest::ReplaceKey { name, kind, key } => replace_key(name, *kind, key),
        EditRequest::Remove { name } => remove(name),
        EditRequest::SetHidden { name, hidden } => set_hidden(name, *hidden),
    };
    match outcome {
        Ok(text) => EditResult { text, error: false, clear_form },
        Err(text) => EditResult { text, error: true, clear_form: false },
    }
}

/// Moves every key still written in plain text in the config into the key store and blanks
/// it in the file. An entry whose key cannot be stored stays as it is. Returns the config
/// as it now stands.
///
/// macOS only, where the native app has always done this. Elsewhere a hand-written key
/// stays in the file, which the claude-reset CLI reads too.
pub fn move_keys_to_store(cfg: Config) -> Config {
    if !cfg!(target_os = "macos") {
        return cfg;
    }
    let sessions = cfg.accounts.iter().filter(|a| !a.keychain && !a.name.is_empty() && !a.session_key.is_empty());
    let tokens = cfg.oauth_accounts.iter().filter(|a| !a.keychain && !a.name.is_empty() && !a.token.is_empty());
    let moved: Vec<(KeyKind, String)> = sessions
        .map(|a| (KeyKind::SessionKey, &a.name, &a.session_key))
        .chain(tokens.map(|a| (KeyKind::Token, &a.name, &a.token)))
        .filter(|(kind, name, key)| secrets::store(&key_account(*kind, name), key).is_ok())
        .map(|(kind, name, _)| (kind, name.clone()))
        .collect();
    if moved.is_empty() {
        return cfg;
    }
    let saved = config::edit_config(|doc| {
        for (kind, name) in &moved {
            config::edit_entry(doc, list_of(*kind), name, |entry| {
                entry.insert(key_field(*kind).into(), json!(""));
                entry.insert("keychain".into(), json!(true));
            });
        }
    });
    match saved {
        Ok(()) => config::load_config(),
        Err(_) => cfg,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Walks an added account through every edit that needs no network. It writes to the
    /// config file and the key store, so it only runs when pointed at a scratch file and a
    /// key service of its own:
    /// `CLAUDE_RESET_BAR_CONFIG=<file> CLAUDE_RESET_BAR_KEY_SERVICE=<name> cargo test -- --ignored`
    #[test]
    #[ignore]
    fn edits_on_a_scratch_account() {
        assert!(std::env::var("CLAUDE_RESET_BAR_KEY_SERVICE").is_ok_and(|s| !s.is_empty()), "scratch service needed");
        assert!(std::env::var_os("CLAUDE_RESET_BAR_CONFIG").is_some(), "scratch config needed");
        let path = config::config_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            r#"{"slack_webhook_url":"https://x","oauth_accounts":[{"name":"plain","token":"sk-ant-oat01-scratch"}],"accounts":[]}"#,
        )
        .unwrap();

        // The plain-text key moves into the store and leaves the file.
        let cfg = move_keys_to_store(config::load_config());
        assert!(cfg.oauth_accounts[0].keychain && cfg.oauth_accounts[0].token.is_empty());
        assert_eq!(secrets::read("token:plain").as_deref(), Some("sk-ant-oat01-scratch"));

        // Renaming carries the key over and leaves nothing under the old name.
        let renamed = apply(EditRequest::Rename { name: "plain".into(), kind: RowKind::Token, to: " work ".into() });
        assert!(!renamed.error, "{}", renamed.text);
        assert_eq!(secrets::read("token:work").as_deref(), Some("sk-ant-oat01-scratch"));
        assert_eq!(secrets::read("token:plain"), None);
        assert_eq!(config::load_config().oauth_accounts[0].name, "work");

        // A taken name is refused, as is a key of the other kind — both before any request.
        assert!(apply(EditRequest::Rename { name: "work".into(), kind: RowKind::Token, to: "work".into() }).error);
        let wrong = EditRequest::ReplaceKey { name: "work".into(), kind: RowKind::Token, key: "sk-ant-sid01-x".into() };
        assert!(apply(wrong).error);
        assert!(apply(EditRequest::Add { name: "work".into(), key: "sk-ant-oat01-other".into() }).error);
        assert_eq!(secrets::read("token:work").as_deref(), Some("sk-ant-oat01-scratch"));

        // Hiding and showing a login only touches the list of hidden names.
        assert!(!apply(EditRequest::SetHidden { name: "a@b.c".into(), hidden: true }).error);
        assert_eq!(config::load_config().hidden_logins, ["a@b.c"]);
        assert!(!apply(EditRequest::SetHidden { name: "a@b.c".into(), hidden: false }).error);
        assert!(config::load_config().hidden_logins.is_empty());

        // Removing takes the entry and its key, and keeps what this build does not model.
        assert!(!apply(EditRequest::Remove { name: "work".into() }).error);
        assert_eq!(secrets::read("token:work"), None);
        let left = std::fs::read_to_string(&path).unwrap();
        assert!(left.contains("slack_webhook_url") && !left.contains("work"), "{left}");
    }
}
