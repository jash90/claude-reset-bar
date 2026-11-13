//! The tray on Linux: a StatusNotifierItem spoken over D-Bus directly, so the binary needs
//! no GTK and no libappindicator at run time.

use std::sync::mpsc::Sender;

use ksni::blocking::TrayMethods;
use ksni::menu::{CheckmarkItem, StandardItem, SubMenu};
use ksni::MenuItem;

use crate::app::{Command, ViewSink};
use crate::view::{View, FIXED_MENU_BAR_CHOICES};
use crate::window_host;
use crate::i18n::LANGUAGES;
use crate::icon::{draw_icon, tray_color, ICON_SIZE};

struct LinuxTray {
    view: View,
    commands: Sender<Command>,
}

impl LinuxTray {
    fn action(label: &str, command: Command) -> MenuItem<Self> {
        StandardItem {
            label: label.to_string(),
            activate: Box::new(move |tray: &mut Self| {
                let _ = tray.commands.send(command.clone());
            }),
            ..Default::default()
        }
        .into()
    }
}

impl ksni::Tray for LinuxTray {
    fn id(&self) -> String {
        "claude-reset-bar".into()
    }

    fn title(&self) -> String {
        self.view.title.clone()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        // The protocol wants ARGB, most significant byte first.
        let mut data = draw_icon(self.view.percent, tray_color());
        for pixel in data.chunks_exact_mut(4) {
            pixel.rotate_right(1);
        }
        vec![ksni::Icon { width: ICON_SIZE as i32, height: ICON_SIZE as i32, data }]
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        // There is no text next to the icon here, so the tooltip carries the figure.
        ksni::ToolTip { title: self.view.tooltip.clone(), ..Default::default() }
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let mut items: Vec<MenuItem<Self>> = self
            .view
            .lines
            .iter()
            .map(|line| StandardItem { label: line.clone(), enabled: false, ..Default::default() }.into())
            .collect();
        let languages = LANGUAGES
            .iter()
            .enumerate()
            .map(|(index, language)| {
                CheckmarkItem {
                    label: language.name.to_string(),
                    checked: index == self.view.language_index,
                    activate: Box::new(move |tray: &mut Self| {
                        let _ = tray.commands.send(Command::SetLanguage(index));
                    }),
                    ..Default::default()
                }
                .into()
            })
            .collect();
        let mut menu_bar: Vec<MenuItem<Self>> = Vec::new();
        for (index, choice) in self.view.menu_bar_choices.iter().enumerate() {
            if index == FIXED_MENU_BAR_CHOICES {
                menu_bar.push(MenuItem::Separator);
            }
            let value = choice.value.clone();
            menu_bar.push(
                CheckmarkItem {
                    label: choice.label.clone(),
                    checked: choice.checked,
                    activate: Box::new(move |tray: &mut Self| {
                        let _ = tray.commands.send(Command::SetMenuBarAccount(value.clone()));
                    }),
                    ..Default::default()
                }
                .into(),
            );
        }
        items.extend([
            MenuItem::Separator,
            Self::action(&self.view.refresh_now, Command::Poll),
            Self::action(&self.view.add_account, Command::ShowAccounts { add_form: true }),
            Self::action(&self.view.manage_accounts, Command::ShowAccounts { add_form: false }),
            Self::action(&self.view.open_config, Command::OpenConfig),
            MenuItem::Separator,
            SubMenu { label: self.view.menu_bar_shows.clone(), submenu: menu_bar, ..Default::default() }.into(),
            SubMenu { label: self.view.language.clone(), submenu: languages, ..Default::default() }.into(),
            MenuItem::Separator,
            StandardItem {
                label: self.view.quit.clone(),
                activate: Box::new(|_| {
                    window_host::close();
                    std::process::exit(0)
                }),
                ..Default::default()
            }
            .into(),
        ]);
        items
    }
}

/// Runs the tray until Quit. `start` receives the sink the worker posts its views to.
pub fn run(commands: Sender<Command>, start: impl FnOnce(ViewSink)) -> ! {
    let tray = LinuxTray { view: crate::app::render(), commands };
    // The tray host may start after this program does at login — GNOME's AppIndicator
    // extension for one — so a missing host is waited for rather than treated as fatal.
    let handle = match tray.assume_sni_available(true).spawn() {
        Ok(handle) => handle,
        Err(e) => {
            eprintln!("could not create the tray icon: {e}");
            std::process::exit(1);
        }
    };
    start(Box::new(move |view| {
        let _ = handle.update(|tray| tray.view = view);
    }));
    loop {
        std::thread::park();
    }
}
