//! The tray on macOS and Windows. Every call into the tray happens on the main thread,
//! inside the event loop; the worker only posts views to it.

use std::sync::mpsc::Sender;

use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

use crate::app::{Command, ViewSink};
use crate::view::{MenuBarChoice, View, FIXED_MENU_BAR_CHOICES, IDLE_TITLE};
use crate::window_host;
use crate::i18n::LANGUAGES;
use crate::icon::{draw_icon, tray_color, ICON_SIZE};

enum UiEvent {
    Show(View),
    Menu(MenuEvent),
}

struct Ui {
    tray: TrayIcon,
    menu: Menu,
    /// The read-only rows at the top of the menu, one item per line.
    info: Vec<MenuItem>,
    refresh: MenuItem,
    add_account: MenuItem,
    manage_accounts: MenuItem,
    open_config: MenuItem,
    menu_bar: Submenu,
    /// The entries of the "Menu bar shows" submenu as last built.
    menu_bar_choices: Vec<MenuBarChoice>,
    menu_bar_items: Vec<CheckMenuItem>,
    menu_bar_separator: PredefinedMenuItem,
    language: Submenu,
    languages: Vec<CheckMenuItem>,
    quit: MenuItem,
    /// The fill level the icon was last drawn at, so it is only redrawn when it moves.
    drawn_percent: Option<f64>,
}

fn dial(percent: f64) -> Option<Icon> {
    Icon::from_rgba(draw_icon(percent, tray_color()), ICON_SIZE as u32, ICON_SIZE as u32).ok()
}

/// An ampersand marks a keyboard mnemonic in a menu title; a doubled one is shown as itself.
fn literal(text: &str) -> String {
    text.replace('&', "&&")
}

impl Ui {
    fn build() -> Result<Ui, Box<dyn std::error::Error>> {
        let menu = Menu::new();
        let refresh = MenuItem::new("", true, None);
        let add_account = MenuItem::new("", true, None);
        let manage_accounts = MenuItem::new("", true, None);
        let open_config = MenuItem::new("", true, None);
        let menu_bar = Submenu::new("", true);
        let language = Submenu::new("", true);
        let languages: Vec<CheckMenuItem> =
            LANGUAGES.iter().map(|l| CheckMenuItem::new(l.name, true, false, None)).collect();
        for item in &languages {
            language.append(item)?;
        }
        let quit = MenuItem::new("", true, None);
        menu.append_items(&[
            &PredefinedMenuItem::separator(),
            &refresh,
            &add_account,
            &manage_accounts,
            &open_config,
            &PredefinedMenuItem::separator(),
            &menu_bar,
            &language,
            &PredefinedMenuItem::separator(),
            &quit,
        ])?;

        // Created with its icon: Windows shows a blank slot for a tray without one.
        let builder = TrayIconBuilder::new().with_menu(Box::new(menu.clone())).with_title(IDLE_TITLE);
        let builder = match dial(0.0) {
            #[cfg(target_os = "macos")]
            Some(icon) => builder.with_icon_templated(icon),
            #[cfg(not(target_os = "macos"))]
            Some(icon) => builder.with_icon(icon),
            None => builder,
        };
        let tray = builder.build()?;

        Ok(Ui {
            tray,
            menu,
            info: Vec::new(),
            refresh,
            add_account,
            manage_accounts,
            open_config,
            menu_bar,
            menu_bar_choices: Vec::new(),
            menu_bar_items: Vec::new(),
            menu_bar_separator: PredefinedMenuItem::separator(),
            language,
            languages,
            quit,
            drawn_percent: None,
        })
    }

    /// Rebuilds the "Menu bar shows" submenu when its entries changed.
    fn show_menu_bar_choices(&mut self, choices: &[MenuBarChoice]) {
        if self.menu_bar_choices == choices {
            return;
        }
        for item in self.menu_bar_items.drain(..) {
            let _ = self.menu_bar.remove(&item);
        }
        let _ = self.menu_bar.remove(&self.menu_bar_separator);
        for (i, choice) in choices.iter().enumerate() {
            if i == FIXED_MENU_BAR_CHOICES {
                let _ = self.menu_bar.append(&self.menu_bar_separator);
            }
            let item = CheckMenuItem::new(literal(&choice.label), true, choice.checked, None);
            if self.menu_bar.append(&item).is_ok() {
                self.menu_bar_items.push(item);
            }
        }
        self.menu_bar_choices = choices.to_vec();
    }

    fn show(&mut self, view: &View) {
        for (i, line) in view.lines.iter().enumerate() {
            match self.info.get(i) {
                Some(item) => item.set_text(literal(line)),
                None => {
                    let item = MenuItem::new(literal(line), false, None);
                    if self.menu.insert(&item, i).is_ok() {
                        self.info.push(item);
                    }
                }
            }
        }
        for item in self.info.drain(view.lines.len().min(self.info.len())..) {
            let _ = self.menu.remove(&item);
        }

        self.refresh.set_text(literal(&view.refresh_now));
        self.add_account.set_text(literal(&view.add_account));
        self.manage_accounts.set_text(literal(&view.manage_accounts));
        self.open_config.set_text(literal(&view.open_config));
        self.menu_bar.set_text(literal(&view.menu_bar_shows));
        self.show_menu_bar_choices(&view.menu_bar_choices);
        self.language.set_text(literal(&view.language));
        self.quit.set_text(literal(&view.quit));
        for (i, item) in self.languages.iter().enumerate() {
            item.set_checked(i == view.language_index);
        }

        // Only macOS shows text next to the icon; on Windows the tooltip carries it.
        self.tray.set_title(Some(&view.title));
        let _ = self.tray.set_tooltip(Some(&view.tooltip));
        if self.drawn_percent != Some(view.percent) {
            self.drawn_percent = Some(view.percent);
            #[cfg(target_os = "macos")]
            let _ = self.tray.set_icon_templated(dial(view.percent));
            #[cfg(not(target_os = "macos"))]
            let _ = self.tray.set_icon(dial(view.percent));
        }
    }

    /// The command behind a clicked menu item. `None` for Quit asks the caller to stop.
    fn command(&self, event: &MenuEvent) -> Option<Option<Command>> {
        if event.id == self.quit.id() {
            return Some(None);
        }
        if event.id == self.refresh.id() {
            return Some(Some(Command::Poll));
        }
        if event.id == self.open_config.id() {
            return Some(Some(Command::OpenConfig));
        }
        if event.id == self.add_account.id() {
            return Some(Some(Command::ShowAccounts { add_form: true }));
        }
        if event.id == self.manage_accounts.id() {
            return Some(Some(Command::ShowAccounts { add_form: false }));
        }
        if let Some(i) = self.menu_bar_items.iter().position(|item| event.id == item.id()) {
            // A check item toggles itself when clicked; the next view puts the mark back
            // where it belongs.
            let choice = self.menu_bar_choices.get(i)?;
            for (item, choice) in self.menu_bar_items.iter().zip(&self.menu_bar_choices) {
                item.set_checked(choice.checked);
            }
            return Some(Some(Command::SetMenuBarAccount(choice.value.clone())));
        }
        let index = self.languages.iter().position(|item| event.id == item.id())?;
        Some(Some(Command::SetLanguage(index)))
    }
}

/// Runs the tray until Quit. `start` receives the sink the worker posts its views to.
pub fn run(commands: Sender<Command>, start: impl FnOnce(ViewSink)) -> ! {
    #[allow(unused_mut)]
    let mut event_loop = EventLoopBuilder::<UiEvent>::with_user_event().build();
    #[cfg(target_os = "macos")]
    {
        // A menu bar app: no Dock icon, no main menu.
        use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
    }

    let proxy = event_loop.create_proxy();
    MenuEvent::set_event_handler(Some(move |event| {
        let _ = proxy.send_event(UiEvent::Menu(event));
    }));
    let proxy = event_loop.create_proxy();
    start(Box::new(move |view| {
        let _ = proxy.send_event(UiEvent::Show(view));
    }));

    let mut ui: Option<Ui> = None;
    // A view that arrives before the tray exists is shown as soon as it does.
    let mut pending: Option<View> = None;
    event_loop.run(move |event, _, flow| {
        *flow = ControlFlow::Wait;
        match event {
            // The tray can only be created once the event loop is running.
            Event::NewEvents(StartCause::Init) => match Ui::build() {
                Ok(mut built) => {
                    built.show(&pending.take().unwrap_or_else(crate::app::render));
                    ui = Some(built);
                }
                Err(e) => {
                    eprintln!("could not create the tray icon: {e}");
                    *flow = ControlFlow::ExitWithCode(1);
                }
            },
            Event::UserEvent(UiEvent::Show(view)) => match ui.as_mut() {
                Some(ui) => ui.show(&view),
                None => pending = Some(view),
            },
            Event::UserEvent(UiEvent::Menu(event)) => {
                match ui.as_ref().and_then(|ui| ui.command(&event)) {
                    Some(Some(command)) => {
                        let _ = commands.send(command);
                    }
                    Some(None) => {
                        // Dropping the tray removes the icon; left alone it lingers on
                        // Windows until the pointer passes over it.
                        ui = None;
                        window_host::close();
                        *flow = ControlFlow::Exit;
                    }
                    None => {}
                }
            }
            _ => {}
        }
    })
}
