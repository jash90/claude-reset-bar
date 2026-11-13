//! The logins Claude Code stored on this machine.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;

use serde::Deserialize;

use crate::config::home_file;
use crate::model::{lenient, Stamp};

/// One login Claude Code stored: the access token and when it stops working (Unix ms, 0
/// when the item does not say).
#[derive(Debug, Clone, PartialEq)]
pub struct StoredCredential {
    pub token: String,
    pub expires_at: f64,
}

pub fn parse_credential(raw: &str) -> Option<StoredCredential> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct OAuth {
        #[serde(default, deserialize_with = "lenient")]
        access_token: String,
        #[serde(default, deserialize_with = "lenient")]
        expires_at: f64,
    }
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Doc {
        claude_ai_oauth: Option<OAuth>,
    }
    let oauth = serde_json::from_str::<Doc>(raw.trim()).ok()?.claude_ai_oauth?;
    (!oauth.access_token.is_empty())
        .then_some(StoredCredential { token: oauth.access_token, expires_at: oauth.expires_at })
}

/// Returns the tokens worth polling, freshest first, each once. An expired token is
/// dropped: it belongs to a profile nobody has used lately, and only Claude Code may
/// refresh it. When every token has expired the freshest one is still returned, so the row
/// says "run Claude Code" instead of the account silently disappearing.
pub fn live_tokens(creds: &[StoredCredential], now: Stamp) -> Vec<String> {
    let now_ms = now.timestamp_millis() as f64;
    let mut sorted = creds.to_vec();
    sorted.sort_by(|a, b| b.expires_at.total_cmp(&a.expires_at));
    let mut live: Vec<&StoredCredential> =
        sorted.iter().filter(|c| c.expires_at == 0.0 || c.expires_at > now_ms).collect();
    if live.is_empty() {
        live.extend(sorted.first());
    }
    let mut seen = HashSet::new();
    live.into_iter().filter(|c| seen.insert(&c.token)).map(|c| c.token.clone()).collect()
}

/// Lists the files Claude Code may have written: the default profile, the one
/// CLAUDE_CONFIG_DIR points at, and the common habit of keeping extra profiles in
/// ~/.claude-<name>.
fn credential_files() -> Vec<PathBuf> {
    let mut dirs = vec![home_file(&[".claude"])];
    if let Some(custom) = std::env::var_os("CLAUDE_CONFIG_DIR").filter(|v| !v.is_empty()) {
        let custom = PathBuf::from(custom);
        dirs.push(match custom.strip_prefix("~") {
            Ok(rest) => home_file(&[]).join(rest),
            Err(_) => custom,
        });
    }
    if let Ok(entries) = fs::read_dir(home_file(&[])) {
        let mut profiles: Vec<PathBuf> = entries
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with(".claude-"))
            .map(|e| e.path())
            .collect();
        profiles.sort();
        dirs.extend(profiles);
    }
    dirs.into_iter().map(|d| d.join(".credentials.json")).collect()
}

/// Returns every Claude Code login on this machine that can be polled. On Windows and
/// Linux they live in credential files; on macOS Claude Code keeps them in the Keychain,
/// one item per profile, so every item is read — an MCP OAuth flow also writes one under
/// the same service name holding no subscription token at all.
///
/// The refresh token is deliberately not used — refreshing it here would invalidate
/// Claude Code's own session. Tokens are re-read on every poll, so a refresh performed by
/// Claude Code is picked up immediately.
pub fn claude_code_tokens() -> Vec<String> {
    let files = credential_files().into_iter().filter_map(|f| fs::read_to_string(f).ok());
    let creds: Vec<StoredCredential> = files.filter_map(|raw| parse_credential(&raw)).collect();
    #[cfg(target_os = "macos")]
    let creds = [creds, keychain::credentials()].concat();
    live_tokens(&creds, chrono::Utc::now())
}

/// One Claude Code login and the name its row is shown under.
#[derive(Debug, Clone, PartialEq)]
pub struct Login {
    pub name: String,
    pub token: String,
}

/// Names the logins found this poll. A login whose email could not be fetched keeps the
/// name it had before; failing that it gets a numbered "Claude Code" name. A name the
/// config already uses is skipped — that account is on screen already — and so is a second
/// login into the same account.
pub fn name_claude_code_logins(
    tokens: &[String],
    emails: &[String],
    known: &HashMap<String, String>,
    previous: &[String],
    configured: &HashSet<String>,
) -> Vec<Login> {
    let mut out: Vec<Login> = Vec::new();
    for (i, token) in tokens.iter().enumerate() {
        let mut name = emails.get(i).cloned().unwrap_or_default();
        if name.is_empty() {
            name = known.get(token).cloned().unwrap_or_default();
        }
        if name.is_empty() {
            name = if tokens.len() == 1 && previous.len() == 1 {
                previous[0].clone()
            } else if i == 0 {
                "Claude Code".to_string()
            } else {
                format!("Claude Code {}", i + 1)
            };
        }
        if configured.contains(&name) || out.iter().any(|l| l.name == name) {
            continue;
        }
        out.push(Login { name, token: token.clone() });
    }
    out
}

/// Tells a token Claude Code issues from a claude.ai sessionKey.
pub fn is_oauth_token(key: &str) -> bool {
    key.starts_with("sk-ant-oat")
}

#[cfg(target_os = "macos")]
mod keychain {
    use std::process::Command;

    use super::{parse_credential, StoredCredential};

    const SECURITY: &str = "/usr/bin/security";
    const BASE_SERVICE: &str = "Claude Code-credentials";

    fn output(args: &[&str]) -> Option<String> {
        let out = Command::new(SECURITY).args(args).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
    }

    /// Lists the "Claude Code-credentials" services present. The dump reads attributes
    /// only, never a secret, so it prompts for nothing.
    fn services() -> Vec<String> {
        let mut services = vec![BASE_SERVICE.to_string()];
        let Some(dump) = output(&["dump-keychain"]) else { return services };
        for line in dump.lines().filter(|l| l.contains("\"svce\"")) {
            let (Some(start), Some(end)) = (line.find("=\""), line.rfind('"')) else { continue };
            if end <= start + 2 {
                continue;
            }
            let name = &line[start + 2..end];
            if name.starts_with(BASE_SERVICE) && !services.iter().any(|s| s == name) {
                services.push(name.to_string());
            }
        }
        services
    }

    pub fn credentials() -> Vec<StoredCredential> {
        let user = std::env::var("USER").or_else(|_| std::env::var("LOGNAME")).unwrap_or_default();
        let mut creds = Vec::new();
        for service in services() {
            for account in [user.as_str(), ""] {
                let mut args = vec!["find-generic-password", "-s", service.as_str()];
                if !account.is_empty() {
                    args.extend(["-a", account]);
                }
                args.push("-w");
                if let Some(cred) = output(&args).and_then(|raw| parse_credential(&raw)) {
                    creds.push(cred);
                }
            }
        }
        creds
    }
}
