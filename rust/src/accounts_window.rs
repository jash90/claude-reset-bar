//! The accounts window: every account in one table, edited in place. It runs as a process
//! of its own, shows the rows the tray sends on stdin, and writes the edits asked for to
//! stdout. It never reads the config file or the key store itself.

use std::io::{BufRead, Write};
use std::sync::mpsc::{channel, Receiver};

use eframe::egui::{self, Color32, Key, RichText, Sense, TextEdit, ViewportCommand};

use crate::accounts::{AccountRow, EditRequest, RowKind};
use crate::i18n::{self, t};
use crate::window_host::ToWindow;

#[derive(PartialEq, Clone, Copy)]
enum Field {
    Name,
    Key,
}

/// A cell being edited in place.
struct Editing {
    name: String,
    kind: RowKind,
    field: Field,
    text: String,
    /// The text field takes the keyboard on the first frame it is shown.
    focused: bool,
}

struct Window {
    inbox: Receiver<ToWindow>,
    rows: Vec<AccountRow>,
    form_name: String,
    form_key: String,
    focus_form: bool,
    /// Frames left in which the window keeps asking to come to the front. A request made
    /// before the window is on screen is ignored by the system, so it is repeated.
    focus_frames: u8,
    editing: Option<Editing>,
    /// The account whose Remove button was clicked once and waits for the second click.
    confirm_remove: Option<String>,
    message: String,
    message_is_error: bool,
    /// A key is being checked; nothing else is sent until the answer arrives.
    busy: bool,
}

fn send(request: &EditRequest) {
    if let Ok(line) = serde_json::to_string(request) {
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{line}").and_then(|_| out.flush());
    }
}

impl Window {
    fn receive(&mut self, ctx: &egui::Context) {
        while let Ok(message) = self.inbox.try_recv() {
            match message {
                ToWindow::Rows { language, rows } => {
                    i18n::set_language(&language);
                    ctx.send_viewport_cmd(ViewportCommand::Title(t().accounts_title.to_string()));
                    self.rows = rows;
                }
                ToWindow::Result { result } => {
                    self.busy = false;
                    self.message = result.text;
                    self.message_is_error = result.error;
                    if result.clear_form {
                        self.form_name.clear();
                        self.form_key.clear();
                    }
                }
                ToWindow::Focus { add_form } => {
                    ctx.send_viewport_cmd(ViewportCommand::Minimized(false));
                    self.focus_frames = 4;
                    self.focus_form |= add_form;
                }
            }
        }
    }

    /// Sends an edit. The ones that check a key take a moment, so they say so.
    fn request(&mut self, request: EditRequest) {
        let checks_key = matches!(request, EditRequest::Add { .. } | EditRequest::ReplaceKey { .. });
        send(&request);
        self.confirm_remove = None;
        self.message_is_error = false;
        self.message = if checks_key { t().checking.to_string() } else { String::new() };
        self.busy = checks_key;
    }

    fn add_form(&mut self, ui: &mut egui::Ui) {
        // The bundled font has no arrow glyph.
        ui.label(RichText::new(t().add_account_hint.replace('→', ">")).weak());
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            let name = ui.add(TextEdit::singleline(&mut self.form_name).hint_text(t().name_placeholder).desired_width(220.0));
            if std::mem::take(&mut self.focus_form) {
                name.request_focus();
            }
            let key = ui.add(
                TextEdit::singleline(&mut self.form_key).password(true).hint_text(t().key_placeholder).desired_width(360.0),
            );
            let entered = (name.lost_focus() || key.lost_focus()) && ui.input(|i| i.key_pressed(Key::Enter));
            let clicked = ui.add_enabled(!self.busy, egui::Button::new(t().add_button)).clicked();
            if (clicked || entered) && !self.busy {
                self.request(EditRequest::Add { name: self.form_name.clone(), key: self.form_key.clone() });
            }
        });
    }

    /// A cell that turns into a text field on a double click. Return saves, Escape or a
    /// click elsewhere abandons the edit.
    fn editable_cell(&mut self, ui: &mut egui::Ui, row: &AccountRow, field: Field, shown: &str) {
        let is_edited = matches!(&self.editing, Some(e) if e.name == row.name && e.kind == row.kind && e.field == field);
        if !is_edited {
            let label = ui.add(egui::Label::new(shown).sense(Sense::click()).truncate());
            if row.editable() && label.double_clicked() && !self.busy {
                // The key is never shown: its field starts empty.
                let text = if field == Field::Name { row.name.clone() } else { String::new() };
                self.editing = Some(Editing { name: row.name.clone(), kind: row.kind, field, text, focused: false });
            }
            return;
        }
        let Some(editing) = self.editing.as_mut() else { return };
        let edit = TextEdit::singleline(&mut editing.text).password(field == Field::Key).desired_width(f32::INFINITY);
        let response = ui.add(edit);
        if !std::mem::replace(&mut editing.focused, true) {
            response.request_focus();
            return;
        }
        if !response.lost_focus() {
            return;
        }
        let saved = ui.input(|i| i.key_pressed(Key::Enter));
        let Some(done) = self.editing.take().filter(|_| saved) else { return };
        let unchanged = field == Field::Name && done.text.trim() == done.name;
        if unchanged || (field == Field::Key && done.text.trim().is_empty()) {
            return;
        }
        self.request(match field {
            Field::Name => EditRequest::Rename { name: done.name, kind: done.kind, to: done.text },
            Field::Key => EditRequest::ReplaceKey { name: done.name, kind: done.kind, key: done.text },
        });
    }

    /// Remove for an added account, asked for twice; Hide or Show for a Claude Code login.
    fn row_button(&mut self, ui: &mut egui::Ui, row: &AccountRow) {
        if !row.editable() {
            let label = if row.hidden { t().show_login } else { t().hide_login };
            if ui.button(label).clicked() {
                self.request(EditRequest::SetHidden { name: row.name.clone(), hidden: !row.hidden });
            }
            return;
        }
        let confirming = self.confirm_remove.as_deref() == Some(&row.name);
        let label = if confirming { t().confirm_remove } else { t().remove_button };
        if ui.button(label).clicked() {
            if confirming {
                self.request(EditRequest::Remove { name: row.name.clone() });
            } else {
                self.confirm_remove = Some(row.name.clone());
            }
        }
    }

    fn table(&mut self, ui: &mut egui::Ui) {
        let rows = self.rows.clone();
        let width = ui.available_width();
        egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
            egui::Grid::new("accounts").num_columns(5).striped(true).spacing([14.0, 8.0]).show(ui, |ui| {
                let widths = [0.21, 0.18, 0.27, 0.20].map(|share| (width * share).floor());
                let headers = [t().col_account, t().col_type, t().col_key, t().col_status];
                for (header, width) in headers.into_iter().zip(widths) {
                    ui.scope(|ui| {
                        ui.set_width(width);
                        ui.label(RichText::new(header).strong());
                    });
                }
                ui.end_row();
                for row in &rows {
                    let cell = |ui: &mut egui::Ui, width: f32, add: &mut dyn FnMut(&mut egui::Ui)| {
                        ui.scope(|ui| {
                            ui.set_width(width);
                            add(ui);
                        });
                    };
                    cell(ui, widths[0], &mut |ui| self.editable_cell(ui, row, Field::Name, &row.name));
                    cell(ui, widths[1], &mut |ui| {
                        ui.add(egui::Label::new(row.type_text()).truncate());
                    });
                    cell(ui, widths[2], &mut |ui| self.editable_cell(ui, row, Field::Key, row.key_text()));
                    cell(ui, widths[3], &mut |ui| {
                        ui.add(egui::Label::new(&row.status).truncate()).on_hover_text(&row.status);
                    });
                    self.row_button(ui, row);
                    ui.end_row();
                }
            });
        });
    }
}

impl eframe::App for Window {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.receive(&ctx);
        if self.focus_frames > 0 {
            self.focus_frames -= 1;
            ctx.send_viewport_cmd(ViewportCommand::Focus);
            ctx.request_repaint();
        }
        egui::Panel::top("form").show(ui, |ui| {
            ui.add_space(8.0);
            self.add_form(ui);
            ui.add_space(8.0);
        });
        egui::Panel::bottom("message").show(ui, |ui| {
            ui.add_space(6.0);
            if self.message.is_empty() {
                ui.label(RichText::new(t().edit_hint).weak());
            } else if self.message_is_error {
                ui.colored_label(Color32::from_rgb(220, 80, 70), &self.message);
            } else {
                ui.label(&self.message);
            }
            ui.add_space(6.0);
        });
        egui::CentralPanel::default().show(ui, |ui| self.table(ui));
    }
}

/// Runs the window until it is closed, or until the tray that started it goes away.
/// Returns the process exit code.
pub fn run() -> i32 {
    let (to_window, inbox) = channel();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([880.0, 420.0]).with_min_inner_size([640.0, 260.0]),
        ..Default::default()
    };
    let started = eframe::run_native(
        t().accounts_title,
        options,
        Box::new(move |creation| {
            let ctx = creation.egui_ctx.clone();
            std::thread::spawn(move || {
                for line in std::io::stdin().lock().lines().map_while(Result::ok) {
                    let Ok(message) = serde_json::from_str::<ToWindow>(&line) else { continue };
                    if to_window.send(message).is_err() {
                        break;
                    }
                    ctx.request_repaint();
                }
                // The tray is gone; a window that can no longer save anything closes too.
                std::process::exit(0);
            });
            Ok(Box::new(Window {
                inbox,
                rows: Vec::new(),
                form_name: String::new(),
                form_key: String::new(),
                focus_form: false,
                focus_frames: 0,
                editing: None,
                confirm_remove: None,
                message: String::new(),
                message_is_error: false,
                busy: false,
            }))
        }),
    );
    match started {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("could not open the accounts window: {e}");
            1
        }
    }
}
