//! The config file, shared with the claude-reset CLI and the native macOS app.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;
use serde_json::{Map, Value};

use crate::model::{lenient, lenient_list};

/// An extra account read with a claude.ai sessionKey — the shape the claude-reset CLI
/// reads too. `org_id` may be left empty: it is discovered from the session key on the
/// next poll and written back.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Account {
    #[serde(default, deserialize_with = "lenient")]
    pub name: String,
    #[serde(default, deserialize_with = "lenient")]
    pub session_key: String,
    #[serde(default, deserialize_with = "lenient")]
    pub org_id: String,
    /// Set by the macOS app once it moved the key into the login Keychain.
    #[serde(default, deserialize_with = "lenient")]
    pub keychain: bool,
}

/// An extra account read with an OAuth token, such as one from `claude setup-token`. Kept
/// apart from accounts, whose shape the claude-reset CLI relies on.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct OAuthAccount {
    #[serde(default, deserialize_with = "lenient")]
    pub name: String,
    #[serde(default, deserialize_with = "lenient")]
    pub token: String,
    #[serde(default, deserialize_with = "lenient")]
    pub keychain: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Config {
    #[serde(default, deserialize_with = "lenient_list")]
    pub accounts: Vec<Account>,
    #[serde(default, deserialize_with = "lenient_list")]
    pub oauth_accounts: Vec<OAuthAccount>,
    /// Emails of Claude Code logins hidden from the menu by the macOS app's accounts
    /// window. Hiding never touches the login itself.
    #[serde(default, deserialize_with = "lenient")]
    pub hidden_logins: Vec<String>,
    /// The account the tray figure follows: empty for the Claude Code login,
    /// `MOST_USED_CHOICE` for the fullest account, or an account's name.
    #[serde(default, deserialize_with = "lenient")]
    pub menu_bar_account: String,
    #[serde(default, deserialize_with = "lenient")]
    pub check_interval_minutes: i64,
    #[serde(default, deserialize_with = "lenient")]
    pub language: String,
}

impl Config {
    /// Every account the config names, in display order. An unfilled skeleton entry is not
    /// an account.
    pub fn configured_names(&self) -> Vec<String> {
        let sessions = self
            .accounts
            .iter()
            .filter(|a| !a.name.is_empty() && (!a.session_key.is_empty() || a.keychain))
            .map(|a| a.name.clone());
        let tokens = self
            .oauth_accounts
            .iter()
            .filter(|a| !a.name.is_empty() && (!a.token.is_empty() || a.keychain))
            .map(|a| a.name.clone());
        sessions.chain(tokens).collect()
    }
}

pub fn home_file(parts: &[&str]) -> PathBuf {
    let mut path = std::env::home_dir().unwrap_or_default();
    path.extend(parts);
    path
}

pub fn config_path() -> PathBuf {
    // Lets a test work on a file of its own instead of the real one.
    if let Some(path) = std::env::var_os("CLAUDE_RESET_BAR_CONFIG").filter(|p| !p.is_empty()) {
        return PathBuf::from(path);
    }
    home_file(&[".config", "claude-reset", "config.json"])
}

/// Some editors on Windows save UTF-8 with a byte order mark, which is not JSON.
fn without_bom(raw: &str) -> &str {
    raw.strip_prefix('\u{feff}').unwrap_or(raw)
}

pub fn parse_config(raw: &str) -> Config {
    serde_json::from_str(without_bom(raw)).unwrap_or_default()
}

pub fn load_config() -> Config {
    fs::read_to_string(config_path()).map(|raw| parse_config(&raw)).unwrap_or_default()
}

/// Writes the file readable by its owner only — it holds session keys.
fn write_private(path: &Path, content: &[u8]) -> io::Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)?.write_all(content)?;
    // The mode above only applies to a file this call created; one that was already
    // there may hold keys too.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

fn create_config_dir() -> io::Result<()> {
    let Some(dir) = config_path().parent().map(Path::to_path_buf) else { return Ok(()) };
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(dir)
}

/// Writes an empty skeleton so "Open config file" has something to open.
pub fn ensure_config() -> io::Result<()> {
    if config_path().exists() {
        return Ok(());
    }
    create_config_dir()?;
    // org_id is left out: it is discovered from the session key and written back.
    let skeleton = "{\n  \"accounts\": [\n    { \"name\": \"\", \"session_key\": \"\" }\n  ],\n  \
                    \"oauth_accounts\": [\n    { \"name\": \"\", \"token\": \"\" }\n  ],\n  \
                    \"check_interval_minutes\": 15\n}\n";
    write_private(&config_path(), skeleton.as_bytes())
}

fn pretty(doc: &Value) -> io::Result<Vec<u8>> {
    let mut out = serde_json::to_vec_pretty(doc)?;
    out.push(b'\n');
    Ok(out)
}

/// Sets `org_id` on the named account when it has none. Edits the file as generic JSON so
/// every key this build does not know about survives untouched.
pub fn patch_org_id(raw: &str, name: &str, org_id: &str) -> io::Result<Vec<u8>> {
    let mut doc: Value = serde_json::from_str(without_bom(raw))?;
    if let Some(accounts) = doc.get_mut("accounts").and_then(Value::as_array_mut) {
        for entry in accounts.iter_mut().filter_map(Value::as_object_mut) {
            let named = entry.get("name").and_then(Value::as_str) == Some(name);
            let has_id = entry.get("org_id").and_then(Value::as_str).is_some_and(|id| !id.is_empty());
            if named && !has_id {
                entry.insert("org_id".into(), Value::String(org_id.into()));
            }
        }
    }
    pretty(&doc)
}

/// Writes a discovered org_id into the named account's entry.
pub fn save_org_id(name: &str, org_id: &str) -> io::Result<()> {
    let raw = fs::read_to_string(config_path())?;
    write_private(&config_path(), &patch_org_id(&raw, name, org_id)?)
}

/// Applies an edit to the config file as generic JSON, so every key this build does not
/// model — anything the claude-reset CLI keeps there — survives the write untouched. A file
/// that exists but is not a JSON object is left alone rather than overwritten: it may hold
/// keys worth more than the edit.
pub fn edit_config(edit: impl FnOnce(&mut Map<String, Value>)) -> io::Result<()> {
    let mut doc = match fs::read_to_string(config_path()) {
        Ok(raw) => serde_json::from_str::<Map<String, Value>>(without_bom(&raw))?,
        Err(_) => Map::new(),
    };
    edit(&mut doc);
    create_config_dir()?;
    write_private(&config_path(), &pretty(&Value::Object(doc))?)
}

/// Writes the chosen language back to the config file.
pub fn save_language(code: &str) -> io::Result<()> {
    edit_config(|doc| set_field(doc, "language", Some(code.into())))
}

/// The config lists accounts are kept in: by sessionKey, and by OAuth token.
pub const SESSION_LIST: &str = "accounts";
pub const TOKEN_LIST: &str = "oauth_accounts";

/// Sets a top-level key, or removes it when there is nothing to set.
pub fn set_field(doc: &mut Map<String, Value>, key: &str, value: Option<Value>) {
    match value {
        Some(value) => doc.insert(key.to_string(), value),
        None => doc.remove(key),
    };
}

fn list_mut<'a>(doc: &'a mut Map<String, Value>, list: &str) -> Option<&'a mut Vec<Value>> {
    doc.get_mut(list).and_then(Value::as_array_mut)
}

fn is_named(entry: &Value, name: &str) -> bool {
    entry.get("name").and_then(Value::as_str) == Some(name)
}

/// Appends an account entry to one of the lists, creating the list when it is missing.
pub fn push_entry(doc: &mut Map<String, Value>, list: &str, entry: Value) {
    match list_mut(doc, list) {
        Some(entries) => entries.push(entry),
        None => {
            doc.insert(list.to_string(), Value::Array(vec![entry]));
        }
    }
}

/// Edits the fields of the named account's entry, leaving its other fields as they were.
pub fn edit_entry(doc: &mut Map<String, Value>, list: &str, name: &str, edit: impl Fn(&mut Map<String, Value>)) {
    let entries = list_mut(doc, list).into_iter().flatten();
    entries.filter(|e| is_named(e, name)).filter_map(Value::as_object_mut).for_each(edit);
}

pub fn remove_entry(doc: &mut Map<String, Value>, list: &str, name: &str) {
    if let Some(entries) = list_mut(doc, list) {
        entries.retain(|e| !is_named(e, name));
    }
}

pub fn open_in_editor(path: &Path) {
    let spawned = if cfg!(target_os = "macos") {
        Command::new("open").arg(path).spawn()
    } else if cfg!(windows) {
        let mut start = Command::new("cmd");
        start.args(["/c", "start", ""]).arg(path);
        // This program has no console of its own, so without the flag cmd opens one for
        // the moment it runs.
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            start.creation_flags(CREATE_NO_WINDOW);
        }
        start.spawn()
    } else {
        Command::new("xdg-open").arg(path).spawn()
    };
    if let Err(e) = spawned {
        eprintln!("could not open {}: {e}", path.display());
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// The writes that only a click in the menu reaches, against a scratch home directory.
    #[test]
    fn config_writes_keep_the_rest_of_the_file() {
        let home = std::env::temp_dir().join(format!("claude-reset-bar-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(&home).unwrap();
        std::env::set_var("HOME", &home);

        // Nothing there yet: the skeleton is written, private, and is not an account.
        ensure_config().unwrap();
        let mode = fs::metadata(config_path()).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert!(load_config().configured_names().is_empty());
        assert_eq!(load_config().check_interval_minutes, 15);

        // A language choice and a discovered org_id are added; nothing else is lost.
        fs::write(
            config_path(),
            "\u{feff}{\"accounts\":[{\"name\":\"s\",\"session_key\":\"k\"}],\"slack_webhook_url\":\"https://x\"}",
        )
        .unwrap();
        save_language("pl").unwrap();
        save_org_id("s", "uuid-1").unwrap();
        let doc: Value = serde_json::from_str(&fs::read_to_string(config_path()).unwrap()).unwrap();
        assert_eq!(doc["language"], "pl");
        assert_eq!(doc["accounts"][0]["org_id"], "uuid-1");
        assert_eq!(doc["accounts"][0]["session_key"], "k");
        assert_eq!(doc["slack_webhook_url"], "https://x");

        // A file that is not JSON is left as it is rather than replaced by the language alone.
        fs::write(config_path(), "{ not json").unwrap();
        assert!(save_language("en").is_err());
        assert_eq!(fs::read_to_string(config_path()).unwrap(), "{ not json");

        let _ = fs::remove_dir_all(&home);
    }
}
