import AppKit
import UsageCore

/// Fields for a custom HTTPS GET usage API, shared by "Add custom API…" and "Edit…".
/// No external code, OAuth session or MCP tool is ever run from this form.
@MainActor
final class CustomConnectionForm: NSObject {
    enum Mode: Equatable {
        case add
        case edit(name: String)
    }

    let mode: Mode
    let nameField = SettingsUI.textField(placeholder: "e.g. Acme AI · its initials become the icon", accessibility: "Name")
    let endpointField = SettingsUI.textField(placeholder: "https://api.vendor.com/account/balance", accessibility: "GET endpoint")
    let authPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tokenField: NSSecureTextField
    let pointerField = SettingsUI.textField(placeholder: "/data/credits", accessibility: "JSON pointer to the usage value")
    let unitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let scaleField = SettingsUI.textField(placeholder: "1", accessibility: "Scale")
    let serviceGroup = SettingsGroupView()
    let valueGroup = SettingsGroupView()
    let tokenRow: SettingsRowView

    init(mode: Mode) {
        self.mode = mode
        tokenField = SettingsUI.secureField(
            placeholder: mode == .add ? "Paste a restricted, read-only token" : "Leave blank to keep the saved token",
            accessibility: "Token")
        tokenRow = SettingsUI.formRow("Token", control: tokenField)
        super.init()
        for authentication in CustomConnection.Authentication.allCases {
            authPopup.addItem(withTitle: ConnectionCatalog.title(for: authentication))
        }
        authPopup.selectItem(at: 1)
        authPopup.target = self
        authPopup.action = #selector(authenticationChanged)
        authPopup.setAccessibilityLabel("Authentication")
        for metric in CustomConnection.Metric.allCases { unitPopup.addItem(withTitle: ConnectionCatalog.title(for: metric)) }
        unitPopup.setAccessibilityLabel("Unit")
        scaleField.stringValue = "1"

        switch mode {
        case .add:
            serviceGroup.addRow(SettingsUI.formRow("Name", control: nameField))
        case .edit(let name):
            let value = SettingsLabel.make(name, font: SettingsStyle.bodyFont, color: .secondaryLabelColor, wraps: false)
            value.setAccessibilityLabel("Name, \(name), can't be changed")
            let row = SettingsRowView(title: "Name", subtitle: "Can't be changed. Remove and add again to rename.", accessories: [value])
            serviceGroup.addRow(row)
        }
        serviceGroup.addRow(SettingsUI.formRow("GET endpoint", control: endpointField))
        serviceGroup.addRow(SettingsUI.formRow("Authentication", control: authPopup, width: 180))
        serviceGroup.addRow(tokenRow)
        valueGroup.addRow(SettingsUI.formRow("JSON pointer", control: pointerField))
        valueGroup.addRow(SettingsUI.formRow("Unit", control: unitPopup, width: 180))
        valueGroup.addRow(SettingsUI.formRow("Scale", control: scaleField, width: 110))
    }

    var authentication: CustomConnection.Authentication {
        CustomConnection.Authentication.allCases[max(0, authPopup.indexOfSelectedItem)]
    }

    var metric: CustomConnection.Metric {
        CustomConnection.Metric.allCases[max(0, unitPopup.indexOfSelectedItem)]
    }

    var controls: [NSControl] { [nameField, endpointField, authPopup, tokenField, pointerField, unitPopup, scaleField] }

    func setBusy(_ busy: Bool) {
        for control in controls { control.isEnabled = !busy }
    }

    func prefill(_ configuration: CustomConnection) {
        endpointField.stringValue = configuration.endpoint
        pointerField.stringValue = configuration.pointer
        scaleField.stringValue = ConnectionCatalog.scaleText(configuration.multiplier)
        authPopup.selectItem(at: CustomConnection.Authentication.allCases.firstIndex(of: configuration.authentication) ?? 1)
        unitPopup.selectItem(at: CustomConnection.Metric.allCases.firstIndex(of: configuration.metric) ?? 0)
        tokenField.stringValue = ""
        authenticationChanged()
    }

    func apply(_ template: CustomConnectionTemplate) {
        nameField.stringValue = template.name
        endpointField.stringValue = template.endpoint
        pointerField.stringValue = template.pointer
        scaleField.stringValue = ConnectionCatalog.scaleText(template.multiplier)
        authPopup.selectItem(at: CustomConnection.Authentication.allCases.firstIndex(of: template.authentication) ?? 1)
        unitPopup.selectItem(at: CustomConnection.Metric.allCases.firstIndex(of: template.metric) ?? 0)
        authenticationChanged()
    }

    /// The trimmed field values as a validated configuration. Name is fixed when editing.
    func configuration(provider: ProviderID) throws -> CustomConnection {
        guard let multiplier = Double(scaleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ConnectorError.unavailable("Enter a number for Scale, like 1 or 0.01.")
        }
        return try CustomConnection(provider: provider,
                                    endpoint: endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                    pointer: pointerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                    metric: metric, authentication: authentication, multiplier: multiplier)
    }

    var typedToken: String { tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    func clearSecrets() {
        tokenField.abortEditing()
        tokenField.stringValue = ""
    }

    @objc func authenticationChanged() {
        tokenRow.isHidden = authentication == .none
    }
}

// MARK: - Add custom API pane

@MainActor
final class AddCustomAPIPane: SettingsPane {
    let form = CustomConnectionForm(mode: .add)
    let approval = NSButton(checkboxWithTitle: "I checked it's a read-only usage endpoint with a restricted token.", target: nil, action: nil)
    let testButton: NSButton
    let mcpButton: NSButton
    let message = SettingsMessageView()

    init(host: SettingsWindowController, template: CustomConnectionTemplate?) {
        testButton = SettingsUI.button("Test & Add", target: nil, action: #selector(testAndAdd))
        mcpButton = NSButton(title: "Have an MCP server instead?", target: nil, action: #selector(explainMCP))
        super.init(id: .addCustom, host: host)
        testButton.target = self
        testButton.keyEquivalent = "\r"
        mcpButton.target = self
        mcpButton.isBordered = false
        mcpButton.contentTintColor = .linkColor
        mcpButton.font = SettingsStyle.detailFont
        approval.font = SettingsStyle.detailFont
        approval.setAccessibilityLabel("I checked the endpoint is read-only and the token is restricted")

        let header = SettingsPaneHeaderView(icon: SettingsUI.symbol("plus", pointSize: 22, weight: .medium), title: "Add custom API",
                                            status: "Show a balance or quota from any documented HTTPS JSON API.")
        add(header)
        addSection("Service", [form.serviceGroup,
                               SettingsUI.footnote("Find the balance endpoint in the service's API docs. Never put a token in the URL.")])
        addSection("Value", [form.valueGroup,
                             SettingsUI.footnote(#"Example: {"data":{"credits":42}} → /data/credits. Scale 0.01 turns cents into dollars."#)])
        let custom = ProviderID.custom(name: "Refresh policy")
        let pinned = custom.flatMap { RefreshPolicy.interval(for: $0, pinned: [$0], lowPower: false) } ?? 900
        let lowPower = custom.flatMap { RefreshPolicy.interval(for: $0, pinned: [$0], lowPower: true) } ?? 1_800
        addSection(nil, [approval,
                         SettingsUI.buttonBar(leading: [mcpButton], trailing: [testButton]),
                         message,
                         SettingsUI.footnote("Test & Add sends one GET request and saves only if it returns a valid number. Tokens stay in your Keychain. In the menu bar it refreshes every \(Int(pinned / 60)) min (\(Int(lowPower / 60)) in Low Power Mode).")])
        if let template {
            form.apply(template)
            message.show(.info(template.note))
        }
    }

    override var secureFields: [NSSecureTextField] { [form.tokenField] }

    func setBusy(_ busy: Bool) {
        form.setBusy(busy)
        approval.isEnabled = !busy
        testButton.isEnabled = !busy
    }

    @objc func testAndAdd() { host?.testAndAddCustom(from: self) }

    @objc func explainMCP() {
        message.show(.info("MCP import isn't enabled in this build. A server token doesn't prove its tools are read-only, so nothing is installed or run here. Don't paste browser cookies or admin tokens."))
    }
}

// MARK: - Existing custom API

@MainActor
final class CustomSetupSection: NSObject, ProviderSetupSection {
    let provider: ProviderID
    weak var host: SettingsWindowController?
    let endpointRow = SettingsRowView(title: "Endpoint")
    let valueRow = SettingsRowView(title: "Value")
    let authRow = SettingsRowView(title: "Authentication")
    let summaryGroup: SettingsGroupView
    let form: CustomConnectionForm
    let editButton: NSButton
    let removeButton: NSButton
    let saveButton: NSButton
    let cancelButton: NSButton
    let summaryBar: NSStackView
    let editBar: NSStackView
    let view: NSView
    private(set) var isEditing = false
    var secureFields: [NSSecureTextField] { [form.tokenField] }
    var isConfigured: Bool { true }

    init(provider: ProviderID, host: SettingsWindowController) {
        self.provider = provider
        self.host = host
        form = CustomConnectionForm(mode: .edit(name: provider.displayName))
        summaryGroup = SettingsGroupView(rows: [endpointRow, valueRow, authRow])
        editButton = SettingsUI.button("Edit…", target: nil, action: #selector(beginEditing))
        removeButton = SettingsUI.button("Remove…", target: nil, action: #selector(remove))
        saveButton = SettingsUI.button("Test & Save", target: nil, action: #selector(testAndSave))
        cancelButton = SettingsUI.button("Cancel", target: nil, action: #selector(cancelEditing))
        summaryBar = SettingsUI.buttonBar(leading: [removeButton], trailing: [editButton])
        editBar = SettingsUI.buttonBar(leading: [], trailing: [cancelButton, saveButton])
        view = SettingsUI.column([summaryGroup, summaryBar, form.serviceGroup, form.valueGroup, editBar])
        super.init()
        for button in [editButton, removeButton, saveButton, cancelButton] { button.target = self }
        endpointRow.subtitleLabel.lineBreakMode = .byTruncatingMiddle
        applyMode()
        update()
    }

    var configuration: CustomConnection? { host?.customConnection(for: provider) }

    func update() {
        guard !isEditing, let configuration else { return }
        endpointRow.subtitle = "GET \(configuration.endpoint)"
        valueRow.subtitle = "\(configuration.pointer.isEmpty ? "Whole response" : configuration.pointer) · "
            + "\(ConnectionCatalog.title(for: configuration.metric)) · scale \(ConnectionCatalog.scaleText(configuration.multiplier))"
        authRow.subtitle = configuration.authentication == .none ? "None"
            : "\(ConnectionCatalog.title(for: configuration.authentication)) · saved in your Keychain"
    }

    private func applyMode() {
        summaryGroup.isHidden = isEditing
        summaryBar.isHidden = isEditing
        form.serviceGroup.isHidden = !isEditing
        form.valueGroup.isHidden = !isEditing
        editBar.isHidden = !isEditing
        saveButton.keyEquivalent = isEditing ? "\r" : ""
    }

    func setBusy(_ busy: Bool) {
        form.setBusy(busy)
        saveButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
    }

    /// Back to the summary after a successful save; the typed token is dropped.
    func finishEditing() {
        form.clearSecrets()
        isEditing = false
        applyMode()
        update()
    }

    @objc func beginEditing() {
        guard let configuration else { return }
        form.prefill(configuration)
        isEditing = true
        applyMode()
        form.endpointField.window?.makeFirstResponder(form.endpointField)
    }

    @objc func cancelEditing() {
        host?.cancelCustomTask()
        finishEditing()
        host?.post(nil, for: provider)
    }

    @objc func testAndSave() { host?.testAndSaveCustomEdit(self) }
    @objc func remove() { host?.confirmRemoveCustom(provider) }
}
