// The "Manage accounts" window: every account on one list, with where its key is kept and
// how its last poll went. Accounts you added can get a new key or be removed from here;
// Claude Code logins are listed for completeness but belong to Claude Code.

import AppKit

/// One row of the accounts window.
struct AccountRow {
    enum Kind { case claudeCode, sessionKey, token }

    let name: String
    let kind: Kind
    let inKeychain: Bool
    let status: String

    /// Only accounts added to the app can be changed here.
    var editable: Bool { kind != .claudeCode }

    var typeText: String {
        switch kind {
        case .claudeCode: return T.typeClaudeCode
        case .sessionKey: return T.typeSessionKey
        case .token: return T.typeToken
        }
    }

    var storageText: String {
        switch kind {
        case .claudeCode: return T.storageClaudeCode
        case .sessionKey, .token: return inKeychain ? T.storageKeychain : T.storageConfig
        }
    }
}

final class AccountsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let rowsProvider: () -> [AccountRow]
    private let onAdd: () -> Void
    private let onReplaceKey: (AccountRow) -> Void
    private let onRemove: (AccountRow) -> Void

    private var rows: [AccountRow] = []
    private let table = NSTableView()
    private var addButton: NSButton!
    private var replaceButton: NSButton!
    private var removeButton: NSButton!

    private enum Column: String, CaseIterable {
        case name, type, storage, status
    }

    init(rows: @escaping () -> [AccountRow], onAdd: @escaping () -> Void,
         onReplaceKey: @escaping (AccountRow) -> Void, onRemove: @escaping (AccountRow) -> Void) {
        rowsProvider = rows
        self.onAdd = onAdd
        self.onReplaceKey = onReplaceKey
        self.onRemove = onRemove

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 340),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 560, height: 220)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() {
        guard let window, let content = window.contentView else { return }
        let widths: [Column: CGFloat] = [.name: 190, .type: 170, .storage: 180, .status: 200]
        for column in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            c.width = widths[column] ?? 120
            c.minWidth = 80
            c.resizingMask = column == .status ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(replaceKey)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 56, width: content.bounds.width - 40,
                                                height: content.bounds.height - 76))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)

        addButton = button(action: #selector(add), x: 20)
        replaceButton = button(action: #selector(replaceKey), x: 140)
        removeButton = button(action: #selector(remove), x: 290)
        for b in [addButton!, replaceButton!, removeButton!] { content.addSubview(b) }
        applyLanguage()
    }

    private func button(action: Selector, x: CGFloat) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .rounded
        b.frame = NSRect(x: x, y: 14, width: 140, height: 30)
        b.autoresizingMask = [.maxXMargin, .maxYMargin]
        return b
    }

    /// Relabels everything — called on open, so a language switch shows up next time.
    func applyLanguage() {
        window?.title = T.accountsTitle
        let titles: [Column: String] = [.name: T.colAccount, .type: T.colType,
                                        .storage: T.colStorage, .status: T.colStatus]
        for c in table.tableColumns {
            c.title = Column(rawValue: c.identifier.rawValue).flatMap { titles[$0] } ?? ""
        }
        addButton.title = T.addAccount
        replaceButton.title = T.replaceKey
        removeButton.title = T.removeButton
        for b in [addButton!, replaceButton!, removeButton!] { b.sizeToFit() }
        // Lay the buttons out left to right after sizing, since titles differ per language.
        var x: CGFloat = 20
        for b in [addButton!, replaceButton!, removeButton!] {
            b.frame.origin.x = x
            b.frame.size.width = max(b.frame.width + 16, 110)
            x += b.frame.width + 8
        }
    }

    func show() {
        applyLanguage()
        reload()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Re-reads the rows, keeping the selection on the same account where it still exists.
    func reload() {
        let selected = selectedRow?.name
        rows = rowsProvider()
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.name == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateButtons()
    }

    private var selectedRow: AccountRow? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private func updateButtons() {
        let editable = selectedRow?.editable == true
        replaceButton.isEnabled = editable
        removeButton.isEnabled = editable
    }

    @objc private func add() { onAdd() }

    @objc private func replaceKey() {
        guard let row = selectedRow, row.editable else { return }
        onReplaceKey(row)
    }

    @objc private func remove() {
        guard let row = selectedRow, row.editable else { return }
        onRemove(row)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        let r = rows[row]
        switch column {
        case .name: field.stringValue = r.name
        case .type: field.stringValue = r.typeText
        case .storage: field.stringValue = r.storageText
        case .status: field.stringValue = r.status
        }
        field.toolTip = field.stringValue
        field.textColor = r.editable || column == .status ? .labelColor : .secondaryLabelColor
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}
