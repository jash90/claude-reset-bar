// The "Manage accounts" window: every account on one list, edited in place without a
// single dialog. A name or a key is changed by double-clicking it, a new account is added
// with the form under the list, removing takes a second click instead of a confirmation
// box, and every outcome is reported on the line at the bottom.

import AppKit

/// Why an account edit did not go through, in words the window can show as they are.
struct EditFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The outcome of an account edit; success carries the account's (possibly new) name.
typealias EditResult = Result<String, EditFailure>

/// One row of the accounts window.
struct AccountRow {
    enum Kind { case claudeCode, sessionKey, token }

    let name: String
    let kind: Kind
    let inKeychain: Bool
    /// A Claude Code login hidden from the menu.
    let hidden: Bool
    let status: String

    /// Only accounts added to the app have a name and a key of their own to change.
    /// Claude Code logins belong to Claude Code; they can only be hidden.
    var editable: Bool { kind != .claudeCode }

    var typeText: String {
        switch kind {
        case .claudeCode: return T.typeClaudeCode
        case .sessionKey: return T.typeSessionKey
        case .token: return T.typeToken
        }
    }

    var keyText: String {
        switch kind {
        case .claudeCode: return T.keyClaudeCode
        case .sessionKey, .token: return inKeychain ? T.keyInKeychain : T.keyInConfig
        }
    }
}

final class AccountsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                      NSTextFieldDelegate {
    typealias Done = (EditResult) -> Void

    private let rowsProvider: () -> [AccountRow]
    private let onAdd: (String, String, @escaping Done) -> Void
    private let onRename: (AccountRow, String, @escaping Done) -> Void
    private let onReplaceKey: (AccountRow, String, @escaping Done) -> Void
    private let onRemove: (AccountRow, @escaping Done) -> Void
    private let onSetHidden: (AccountRow, Bool, @escaping Done) -> Void

    private var rows: [AccountRow] = []
    private let table = NSTableView()
    private let nameField = NSTextField()
    private let keyField = NSSecureTextField()
    private var addButton: NSButton!
    private var rowButton: NSButton!
    private let messageLabel = NSTextField(labelWithString: "")

    /// The account whose Remove button was clicked once; a second click removes it.
    private var armedRemoval: String?
    /// A reload that arrived while a cell was being edited — rebuilding the table then
    /// would throw away what is being typed.
    private var reloadPending = false

    private enum Column: String, CaseIterable {
        case name, type, key, status
    }

    init(rows: @escaping () -> [AccountRow],
         onAdd: @escaping (String, String, @escaping Done) -> Void,
         onRename: @escaping (AccountRow, String, @escaping Done) -> Void,
         onReplaceKey: @escaping (AccountRow, String, @escaping Done) -> Void,
         onRemove: @escaping (AccountRow, @escaping Done) -> Void,
         onSetHidden: @escaping (AccountRow, Bool, @escaping Done) -> Void) {
        rowsProvider = rows
        self.onAdd = onAdd
        self.onRename = onRename
        self.onReplaceKey = onReplaceKey
        self.onRemove = onRemove
        self.onSetHidden = onSetHidden

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 280)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let widths: [Column: CGFloat] = [.name: 200, .type: 160, .key: 300, .status: 160]
        for column in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            c.width = widths[column] ?? 120
            c.minWidth = 80
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 22

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 100, width: content.bounds.width - 40,
                                                height: content.bounds.height - 120))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)

        // The add form: name, key, button. Return in the key field adds too.
        nameField.frame = NSRect(x: 20, y: 58, width: 200, height: 24)
        nameField.autoresizingMask = [.maxXMargin, .maxYMargin]
        keyField.frame = NSRect(x: 228, y: 58, width: content.bounds.width - 228 - 150, height: 24)
        keyField.autoresizingMask = [.width, .maxYMargin]
        keyField.target = self
        keyField.action = #selector(add)
        addButton = NSButton(title: "", target: self, action: #selector(add))
        addButton.bezelStyle = .rounded
        addButton.frame = NSRect(x: content.bounds.width - 140, y: 55, width: 120, height: 30)
        addButton.autoresizingMask = [.minXMargin, .maxYMargin]

        rowButton = NSButton(title: "", target: self, action: #selector(rowAction))
        rowButton.bezelStyle = .rounded
        rowButton.frame = NSRect(x: 20, y: 14, width: 220, height: 30)
        rowButton.autoresizingMask = [.maxXMargin, .maxYMargin]

        messageLabel.frame = NSRect(x: 250, y: 20, width: content.bounds.width - 270, height: 18)
        messageLabel.autoresizingMask = [.width, .maxYMargin]
        messageLabel.lineBreakMode = .byTruncatingTail

        for v in [nameField, keyField, addButton!, rowButton!, messageLabel] as [NSView] {
            content.addSubview(v)
        }
        applyLanguage()
    }

    /// Relabels everything — called on open, so a language switch shows up next time.
    private func applyLanguage() {
        window?.title = T.accountsTitle
        let titles: [Column: String] = [.name: T.colAccount, .type: T.colType,
                                        .key: T.colKey, .status: T.colStatus]
        for c in table.tableColumns {
            c.title = Column(rawValue: c.identifier.rawValue).flatMap { titles[$0] } ?? ""
        }
        nameField.placeholderString = T.namePlaceholder
        keyField.placeholderString = T.keyPlaceholder
        keyField.toolTip = T.addAccountHint
        addButton.title = T.addButton
        say(T.editHint)
        updateRowButton()
    }

    func show() {
        applyLanguage()
        reload()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func focusAddForm() {
        window?.makeFirstResponder(nameField)
    }

    // MARK: Data

    /// Re-reads the rows, keeping the selection on the same account where it still exists.
    func reload() {
        if isEditingCell {
            reloadPending = true
            return
        }
        reloadPending = false
        let selected = selectedRow?.name
        rows = rowsProvider()
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.name == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateRowButton()
    }

    /// A cell is being edited when the field editor — a text view — sits inside the table.
    /// The table itself is first responder whenever a row was clicked, which is not editing.
    private var isEditingCell: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.isDescendant(of: table)
    }

    private var selectedRow: AccountRow? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    // MARK: Messages

    private func say(_ text: String, error: Bool = false) {
        messageLabel.stringValue = text
        messageLabel.textColor = error ? .systemRed : .secondaryLabelColor
        messageLabel.toolTip = text
    }

    private func report(_ success: String) -> Done {
        { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let name): self.say(String(format: success, name))
            case .failure(let f): self.say(f.message, error: true)
            }
            self.reload()
        }
    }

    // MARK: Actions

    @objc private func add() {
        let name = nameField.stringValue
        let key = keyField.stringValue
        say(T.checking)
        addButton.isEnabled = false
        onAdd(name, key) { [weak self] result in
            guard let self else { return }
            self.addButton.isEnabled = true
            if case .success = result {
                self.nameField.stringValue = ""
                self.keyField.stringValue = ""
            }
            self.report(T.msgAdded)(result)
        }
    }

    /// Remove for an added account (second click confirms), Hide / Show for a Claude Code
    /// login.
    @objc private func rowAction() {
        guard let row = selectedRow else { return }
        if row.kind == .claudeCode {
            onSetHidden(row, !row.hidden, report(row.hidden ? T.msgShown : T.msgHidden))
            return
        }
        guard armedRemoval == row.name else {
            armedRemoval = row.name
            updateRowButton()
            return
        }
        armedRemoval = nil
        onRemove(row, report(T.msgRemoved))
    }

    private func updateRowButton() {
        guard let rowButton else { return }
        guard let row = selectedRow else {
            rowButton.title = T.removeButton
            rowButton.isEnabled = false
            return
        }
        rowButton.isEnabled = true
        if row.kind == .claudeCode {
            rowButton.title = row.hidden ? T.showLogin : T.hideLogin
        } else {
            rowButton.title = armedRemoval == row.name ? T.confirmRemove : T.removeButton
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let r = rows[row]
        let editable = r.editable && (column == .name || column == .key)
        let field: NSTextField = column == .key && r.editable ? NSSecureTextField() : NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = editable
        field.isSelectable = editable
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.identifier = id

        switch column {
        case .name:
            field.stringValue = r.name
        case .type:
            field.stringValue = r.typeText
        case .key:
            // The key itself is never shown. The empty field edits into a new key; the
            // placeholder says where the current one is kept.
            field.stringValue = ""
            field.placeholderString = r.keyText
        case .status:
            field.stringValue = r.status
        }
        if editable {
            field.target = self
            field.action = column == .name ? #selector(nameEdited(_:)) : #selector(keyEdited(_:))
            field.delegate = self
        }
        field.toolTip = column == .key ? r.keyText : field.stringValue
        field.textColor = r.editable || column == .status ? .labelColor : .secondaryLabelColor
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        armedRemoval = nil
        updateRowButton()
    }

    @objc private func nameEdited(_ sender: NSTextField) {
        let index = table.row(for: sender)
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        let name = sender.stringValue
        guard name.trimmingCharacters(in: .whitespaces) != row.name else { return }
        onRename(row, name, report(T.msgRenamed))
    }

    @objc private func keyEdited(_ sender: NSTextField) {
        let index = table.row(for: sender)
        guard rows.indices.contains(index) else { return }
        let key = sender.stringValue
        // Leaving the field without typing anything is not an edit.
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sender.stringValue = ""
        say(T.checking)
        onReplaceKey(rows[index], key, report(T.msgKeyReplaced))
    }

    /// Escape abandons an edit: the cell goes back to what it showed.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        window?.makeFirstResponder(table)
        reload()
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if reloadPending {
            DispatchQueue.main.async { [weak self] in self?.reload() }
        }
    }
}
