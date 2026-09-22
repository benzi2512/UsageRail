import AppKit
import UsageCore

/// Everything the Settings window can show on the right.
enum SettingsPaneID: Hashable {
    case general
    case entry(ConnectionCatalogEntry.ID)
    case addCustom

    static func provider(_ provider: ProviderID) -> Self { .entry(.provider(provider)) }

    var provider: ProviderID? {
        if case .entry(.provider(let provider)) = self { return provider }
        return nil
    }
}

struct SettingsSidebarItem: Equatable {
    enum Icon: Equatable {
        case symbol(String)
        case provider(ProviderID)
        case research(String)
    }

    enum Accessory: Equatable {
        case none
        case value(String, attention: Bool)
        case dot(SettingsDotView.Tone)
        case tag(String)
    }

    let pane: SettingsPaneID
    let title: String
    let icon: Icon
    let accessory: Accessory
    let accessibilityLabel: String
}

/// Source-list sidebar. Reloads keep the selected pane and never rebuild it.
@MainActor
final class SettingsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Row: Equatable {
        case header(String)
        case spacer
        case item(SettingsSidebarItem)
    }

    let tableView = NSTableView()
    var onSelect: ((SettingsPaneID) -> Void)?
    private(set) var rows: [Row] = []
    private var isApplyingSelection = false

    var items: [SettingsSidebarItem] {
        rows.compactMap { if case .item(let item) = $0 { return item } else { return nil } }
    }

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 540))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        column.width = 200
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .custom
        tableView.floatsGroupRows = false
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Settings sections")
        scroll.documentView = tableView
        view = scroll
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The single column always spans the sidebar, so names never truncate early.
        tableView.sizeLastColumnToFit()
    }

    /// Replaces the rows and reselects `selected` without reporting a selection change.
    func setRows(_ newRows: [Row], selected: SettingsPaneID) {
        loadViewIfNeeded()
        if newRows != rows {
            rows = newRows
            isApplyingSelection = true
            tableView.reloadData()
            isApplyingSelection = false
        }
        select(selected)
    }

    func select(_ pane: SettingsPaneID) {
        guard let index = row(for: pane) else { return }
        guard tableView.selectedRow != index else { return }
        isApplyingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        isApplyingSelection = false
    }

    func row(for pane: SettingsPaneID) -> Int? {
        rows.firstIndex { if case .item(let item) = $0 { return item.pane == pane } else { return false } }
    }

    var selectedPane: SettingsPaneID? {
        guard rows.indices.contains(tableView.selectedRow), case .item(let item) = rows[tableView.selectedRow] else { return nil }
        return item.pane
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        switch rows[row] {
        case .header, .spacer: return true
        case .item: return false
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 34 }
        switch rows[row] {
        case .header: return 28
        case .spacer: return 10
        case .item: return 34
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row), case .item = rows[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard rows.indices.contains(row), case .item = rows[row] else { return nil }
        return SettingsSidebarRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title):
            let identifier = NSUserInterfaceItemIdentifier("header")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SettingsSidebarHeaderCell
                ?? SettingsSidebarHeaderCell(identifier: identifier)
            cell.label.stringValue = title
            return cell
        case .spacer:
            return NSView()
        case .item(let item):
            let identifier = NSUserInterfaceItemIdentifier("item")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SettingsSidebarCell
                ?? SettingsSidebarCell(identifier: identifier)
            cell.configure(item)
            return cell
        }
    }

    /// Type-to-select jumps between panes by name; headers are skipped.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
        return item.title
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let pane = selectedPane else { return }
        onSelect?(pane)
    }
}

final class SettingsSidebarHeaderCell: NSTableCellView {
    /// Deliberately not the `textField` outlet, so group-row styling can't dim it below legibility.
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityRole(.staticText)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// Tells its cell about selection so the icon and value match the system-styled title.
final class SettingsSidebarRowView: NSTableRowView {
    override var isSelected: Bool { didSet { updateCell() } }
    override var isEmphasized: Bool { didSet { updateCell() } }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateCell()
    }

    private func updateCell() {
        for case let cell as SettingsSidebarCell in subviews { cell.setSelection(isSelected, emphasized: isEmphasized) }
    }
}

final class SettingsSidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let dot = SettingsDotView()
    private var accessory: SettingsSidebarItem.Accessory = .none
    private var isSelectedRow = false
    private var isEmphasizedRow = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.alignment = .right
        value.lineBreakMode = .byClipping
        value.translatesAutoresizingMaskIntoConstraints = false
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        value.setContentHuggingPriority(.required, for: .horizontal)
        for view in [icon, title, value, dot] as [NSView] { addSubview(view) }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ item: SettingsSidebarItem) {
        title.stringValue = item.title
        switch item.icon {
        case .symbol(let name): icon.image = SettingsUI.symbol(name, pointSize: 14, weight: .medium)
        case .provider(let provider): icon.image = ProviderIconArtwork.image(for: provider)
        case .research(let name):
            icon.image = ConnectionResearch.entries.first { $0.name == name }.map(ProviderIconArtwork.image(for:))
        }
        accessory = item.accessory
        switch item.accessory {
        case .none:
            value.stringValue = ""; value.isHidden = true; dot.tone = nil
        case .value(let text, _):
            value.stringValue = text; value.isHidden = false; dot.tone = nil
        case .dot(let tone):
            value.stringValue = ""; value.isHidden = true; dot.tone = tone
        case .tag(let text):
            value.stringValue = text; value.isHidden = false; dot.tone = nil
        }
        setAccessibilityLabel(item.accessibilityLabel)
        toolTip = nil
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    func setSelection(_ selected: Bool, emphasized: Bool) {
        isSelectedRow = selected
        isEmphasizedRow = selected && emphasized
        updateColors()
    }

    /// The title is styled by the source list itself; the icon and value follow the same state:
    /// white on an emphasized (accent) selection, accent on a quiet selection, neutral otherwise.
    private func updateColors() {
        let emphasized = backgroundStyle == .emphasized || isEmphasizedRow
        let isTemplate = icon.image?.isTemplate ?? true
        let selectedTint: NSColor = emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
        icon.contentTintColor = isTemplate ? (isSelectedRow || emphasized ? selectedTint : .labelColor) : nil
        if emphasized { title.textColor = .alternateSelectedControlTextColor } else { title.textColor = .labelColor }
        switch accessory {
        case .value(_, let attention):
            value.textColor = emphasized ? .alternateSelectedControlTextColor : (attention ? .systemOrange : .secondaryLabelColor)
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case .tag:
            value.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            value.font = .systemFont(ofSize: 11)
        default:
            break
        }
    }
}
