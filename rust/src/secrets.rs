//! Keys of added accounts, kept in the system's own store: the login Keychain on macOS,
//! Credential Manager on Windows, the Secret Service (GNOME Keyring, KWallet) on Linux.

use keyring::Entry;

/// The service every key is filed under. The native macOS app used the same one, so the
/// keys it stored are found here.
const SERVICE: &str = "ClaudeResetBar";

/// Lets a test run against items of its own instead of the real ones.
const SERVICE_OVERRIDE: &str = "CLAUDE_RESET_BAR_KEY_SERVICE";

fn service() -> String {
    std::env::var(SERVICE_OVERRIDE).ok().filter(|s| !s.is_empty()).unwrap_or_else(|| SERVICE.to_string())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyKind {
    SessionKey,
    Token,
}

/// The name a key is stored under: the kind and the account's name.
pub fn key_account(kind: KeyKind, name: &str) -> String {
    match kind {
        KeyKind::SessionKey => format!("sessionKey:{name}"),
        KeyKind::Token => format!("token:{name}"),
    }
}

fn entry(account: &str) -> Result<Entry, String> {
    Entry::new(&service(), account).map_err(|e| e.to_string())
}

/// Stores the key, replacing any earlier one under the same account. The key is read back
/// before this reports success, so the caller may drop its own copy.
pub fn store(account: &str, value: &str) -> Result<(), String> {
    entry(account)?.set_password(value).map_err(|e| e.to_string())?;
    match read(account) {
        Some(stored) if stored == value => Ok(()),
        _ => Err("the key could not be read back".to_string()),
    }
}

pub fn read(account: &str) -> Option<String> {
    entry(account).ok()?.get_password().ok().filter(|value| !value.is_empty())
}

pub fn delete(account: &str) {
    let deleted = entry(account).is_ok_and(|entry| entry.delete_credential().is_ok());
    if !deleted && read(account).is_some() {
        delete_with_system_tool(account);
    }
}

/// A key stored by an earlier build of the app — the native one, or the release before an
/// update — can be read and replaced by this one, but the Keychain refuses to let it
/// delete the item ("invalid attempt to change the owner"). The system's own tool may.
#[cfg(target_os = "macos")]
fn delete_with_system_tool(account: &str) {
    let _ = std::process::Command::new("/usr/bin/security")
        .args(["delete-generic-password", "-s", &service(), "-a", account])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

#[cfg(not(target_os = "macos"))]
fn delete_with_system_tool(_account: &str) {}
