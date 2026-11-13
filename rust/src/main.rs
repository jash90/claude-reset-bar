//! Claude Reset Bar — a tray icon showing Claude usage limits that notifies you the moment a
//! 5-hour or 7-day window resets. macOS, Windows, Linux.
//!
//! Shares its reset-detection logic and config file with the native macOS app
//! (../src/main.swift). Accounts are added by editing the config file.

// Without this Windows opens a console window next to the tray icon.
#![cfg_attr(windows, windows_subsystem = "windows")]

mod accounts;
mod accounts_window;
mod app;
mod config;
mod credentials;
mod format;
mod http;
mod i18n;
mod icon;
mod model;
mod secrets;
mod selfcheck;
mod selfcheck_headers;
mod view;
mod window_host;
#[cfg(not(target_os = "linux"))]
mod tray_desktop;
#[cfg(target_os = "linux")]
mod tray_linux;

use std::path::Path;
use std::process::exit;
use std::sync::mpsc;

/// A program built for the windows subsystem starts with no console, so the output of the
/// command-line flags would go nowhere. Attach to the console it was started from.
#[cfg(windows)]
fn attach_console() {
    use windows_sys::Win32::System::Console::{AttachConsole, ATTACH_PARENT_PROCESS};
    unsafe {
        AttachConsole(ATTACH_PARENT_PROCESS);
    }
}

#[cfg(not(windows))]
fn attach_console() {}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if !args.is_empty() {
        attach_console();
    }
    if args.first().map(String::as_str) == Some("--test") {
        selfcheck::run();
        return;
    }

    // A program started from the desktop on macOS or Windows has no locale variables, so
    // there the system's own language list is asked first.
    #[cfg(not(target_os = "linux"))]
    let env = |name: &str| match name {
        "LC_ALL" => sys_locale::get_locale(),
        _ => std::env::var(name).ok(),
    };
    #[cfg(target_os = "linux")]
    let env = |name: &str| std::env::var(name).ok();
    i18n::set_language(i18n::resolve_language(&config::load_config().language, env));

    match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        // Generates the application icon set for the repository and release packages.
        ["--icons", dir, ..] => {
            if let Err(e) = icon::write_icons(Path::new(dir)) {
                eprintln!("could not write icons: {e}");
                exit(1);
            }
            println!("icons written to {dir}");
            return;
        }
        // Checks whether notifications get through on this system at all, without waiting
        // for a real reset. On Linux this needs a running notification daemon.
        ["--notify", ..] => {
            if let Err(e) = app::notify("Claude Reset Bar", i18n::t().notify_works) {
                eprintln!("the notification did not get through: {e}");
                exit(1);
            }
            println!("notification sent");
            return;
        }
        // Reads every account once and prints the menu rows, without a tray.
        ["--once", ..] => {
            app::poll();
            let view = app::render();
            println!("{}", view.title);
            view.lines.iter().for_each(|line| println!("{line}"));
            return;
        }
        // The accounts window, started by the tray as a process of its own.
        [window_host::WINDOW_FLAG, ..] => exit(accounts_window::run()),
        _ => {}
    }

    let (commands, inbox) = mpsc::channel();
    window_host::init(commands.clone());
    let start = |show: app::ViewSink| {
        std::thread::spawn(move || app::run_worker(inbox, show));
    };
    #[cfg(not(target_os = "linux"))]
    tray_desktop::run(commands, start);
    #[cfg(target_os = "linux")]
    tray_linux::run(commands, start);
}
