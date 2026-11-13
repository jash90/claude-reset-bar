//! The tray's side of the accounts window. The window is this same program started a
//! second time with `--accounts`: the tray owns the main thread's event loop, so a window
//! cannot share the process. Rows go to it as JSON lines on its stdin and edit requests
//! come back on its stdout — keys never travel in arguments or the environment.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command as Process, Stdio};
use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};

use crate::accounts::{AccountRow, EditRequest, EditResult};
use crate::app::Command;
use crate::i18n;

/// What the tray tells the window.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "msg", rename_all = "snake_case")]
pub enum ToWindow {
    Rows { language: String, rows: Vec<AccountRow> },
    Result { result: EditResult },
    /// Come to the front; optionally put the cursor in the form that adds an account.
    Focus { add_form: bool },
}

pub const WINDOW_FLAG: &str = "--accounts";

struct Host {
    child: Child,
    stdin: ChildStdin,
}

static HOST: Mutex<Option<Host>> = Mutex::new(None);
static COMMANDS: OnceLock<Mutex<Sender<Command>>> = OnceLock::new();

/// Tells the host where the window's edit requests go.
pub fn init(commands: Sender<Command>) {
    let _ = COMMANDS.set(Mutex::new(commands));
}

fn host() -> std::sync::MutexGuard<'static, Option<Host>> {
    HOST.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Sends a message to the window if one is open. A window that has gone away is forgotten.
fn send(slot: &mut Option<Host>, message: &ToWindow) {
    let Some(open) = slot.as_mut() else { return };
    let delivered = serde_json::to_string(message)
        .ok()
        .and_then(|line| writeln!(open.stdin, "{line}").and_then(|_| open.stdin.flush()).ok());
    let running = matches!(open.child.try_wait(), Ok(None));
    if delivered.is_none() || !running {
        let _ = open.child.kill();
        let _ = open.child.wait();
        *slot = None;
    }
}

fn rows_message(rows: Vec<AccountRow>) -> ToWindow {
    ToWindow::Rows { language: i18n::current_language().to_string(), rows }
}

fn spawn() -> std::io::Result<Host> {
    let mut child = Process::new(std::env::current_exe()?)
        .arg(WINDOW_FLAG)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let stdin = child.stdin.take().ok_or_else(|| std::io::Error::other("no stdin"))?;
    let stdout = child.stdout.take().ok_or_else(|| std::io::Error::other("no stdout"))?;
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let Ok(request) = serde_json::from_str::<EditRequest>(&line) else { continue };
            if let Some(commands) = COMMANDS.get() {
                let _ = commands.lock().unwrap_or_else(|p| p.into_inner()).send(Command::Edit(request));
            }
        }
    });
    Ok(Host { child, stdin })
}

/// Opens the window, or brings the open one to the front. A window that cannot start is
/// reported and otherwise ignored: the tray must not go down with it.
pub fn open(add_form: bool, rows: Vec<AccountRow>) {
    let mut slot = host();
    // Finds out whether a window opened earlier is still there.
    send(&mut slot, &rows_message(rows.clone()));
    if slot.is_none() {
        match spawn() {
            Ok(started) => *slot = Some(started),
            Err(e) => return eprintln!("could not open the accounts window: {e}"),
        }
        send(&mut slot, &rows_message(rows));
    }
    send(&mut slot, &ToWindow::Focus { add_form });
    if let Some(open) = slot.as_ref() {
        bring_forward(open.child.id());
    }
}

/// macOS does not let a process started in the background bring itself to the front; the
/// tray, which the user has just clicked, has to do it. A window started a moment ago is
/// not yet known to the system as an application, so it is waited for briefly.
#[cfg(target_os = "macos")]
fn bring_forward(pid: u32) {
    use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication};
    std::thread::spawn(move || {
        for _ in 0..40 {
            let app = NSRunningApplication::runningApplicationWithProcessIdentifier(pid as i32);
            let options = NSApplicationActivationOptions::ActivateAllWindows;
            if app.is_some_and(|app| app.activateWithOptions(options)) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    });
}

#[cfg(not(target_os = "macos"))]
fn bring_forward(_pid: u32) {}

/// Refreshes the rows of the window, if it is open.
pub fn show_rows(rows: Vec<AccountRow>) {
    send(&mut host(), &rows_message(rows));
}

pub fn show_result(result: EditResult) {
    send(&mut host(), &ToWindow::Result { result });
}

/// Closes the window with the tray.
pub fn close() {
    if let Some(mut open) = host().take() {
        let _ = open.child.kill();
        let _ = open.child.wait();
    }
}
