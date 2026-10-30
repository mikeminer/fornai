import AppKit
import Combine

@MainActor
final class WorkerView: NSView, NSTextFieldDelegate, NSComboBoxDelegate {
    private let controller: WorkerController
    private var observation: AnyCancellable?
    private var updating = false
    private var listedModels: [String] = []
    private(set) var controls: [String: NSControl] = [:]

    private let apiBase = NSTextField()
    private let apiKey = NSSecureTextField()
    private let wallet = NSTextField()
    private let workerName = NSTextField()
    private let model = NSComboBox()
    private let webSearch = NSButton(checkboxWithTitle: "Abilita l’agente Fornai: web e GitHub", target: nil, action: nil)
    private let searchEngine = NSPopUpButton(frame: .zero, pullsDown: false)
    private let agentSteps = NSStepper()
    private let agentSearches = NSStepper()
    private let stepsValue = WorkerView.label("6", size: 14, weight: .medium)
    private let searchesValue = WorkerView.label("2", size: 14, weight: .medium)
    private let searchEngines = ["tavily-search", "exa-search", "firecrawl-search"]
    private let autoStart = NSButton(checkboxWithTitle: "Avvia il worker quando apro l’app", target: nil, action: nil)
    private let runAtLogin = NSButton(checkboxWithTitle: "Apri Fornai quando accedo al Mac", target: nil, action: nil)
    private let statusLabel = WorkerView.label("In pausa", size: 19, weight: .semibold)
    private let messageLabel = WorkerView.label("", size: 12)
    private let networkLabel = WorkerView.label("", size: 12)
    private let balanceLabel = WorkerView.label("—", size: 25, weight: .semibold)
    private let earnedLabel = WorkerView.label("—", size: 25, weight: .semibold)
    private let pairingLabel = WorkerView.label("", size: 12)
    private var startButton: NSButton!
    private var pairButton: NSButton!
    private var saveButton: NSButton!
    private var verifyButton: NSButton!
    private var refreshButton: NSButton!

    private static let cream = NSColor(srgbRed: 0.96, green: 0.95, blue: 0.91, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.13, green: 0.20, blue: 0.15, alpha: 1)
    private static let tomato = NSColor(srgbRed: 0.85, green: 0.25, blue: 0.13, alpha: 1)

    init(controller: WorkerController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 840))
        appearance = NSAppearance(named: .aqua)
        buildInterface()
        refresh()
        // objectWillChange precedes the published value; render on the next
        // main-queue turn so status, balances and models are consistent.
        observation = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { nil }

    private static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight)
        view.textColor = ink
        view.isSelectable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func register(_ control: NSControl, _ identifier: String, label: String) {
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        control.setAccessibilityIdentifier(identifier)
        control.setAccessibilityLabel(label)
        controls[identifier] = control
    }

    private func button(_ title: String, id: String, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded
        result.controlSize = .large
        result.setContentHuggingPriority(.required, for: .horizontal)
        register(result, id, label: title)
        return result
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        return row
    }

    private func section(_ title: String, copy: String? = nil) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(Self.label(title, size: 16, weight: .semibold))
        if let copy {
            let description = Self.label(copy, size: 12)
            description.textColor = .secondaryLabelColor
            stack.addArrangedSubview(description)
            description.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func formRow(_ title: String, control: NSView) -> NSStackView {
        let caption = Self.label(title, size: 12, weight: .medium)
        caption.widthAnchor.constraint(equalToConstant: 106).isActive = true
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = horizontal([caption, control])
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        return row
    }

    private func buildInterface() {
        wantsLayer = true
        layer?.backgroundColor = Self.cream.cgColor
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let document = FlippedWorkerDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 24
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 26),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])

        let mark = NSImageView()
        mark.imageScaling = .scaleProportionallyUpOrDown
        if let url = Bundle.main.url(forResource: "fornai_logo", withExtension: "png") {
            mark.image = NSImage(contentsOf: url)
        }
        if mark.image == nil { mark.image = NSImage(systemSymbolName: "f.circle.fill", accessibilityDescription: "Fornai") }
        mark.setAccessibilityLabel("Fornai")
        mark.widthAnchor.constraint(equalToConstant: 74).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSStackView(views: [Self.label("Fornai Worker", size: 30, weight: .bold), Self.label("Il tuo Mac, nella rete Fornai.", size: 13)])
        title.orientation = .vertical
        title.alignment = .leading
        title.spacing = 4
        add(horizontal([mark, title], spacing: 16), to: content)

        let status = section("Il tuo worker")
        status.addArrangedSubview(statusLabel)
        add(messageLabel, to: status)
        add(networkLabel, to: status)
        startButton = button("Avvia", id: "worker.toggle", action: #selector(toggleWorker))
        startButton.contentTintColor = Self.tomato
        refreshButton = button("Aggiorna saldo", id: "worker.refresh", action: #selector(refreshBalance))
        let actions = horizontal([startButton, refreshButton])
        status.addArrangedSubview(actions)
        let counters = horizontal([
            metric("Crediti disponibili", value: balanceLabel),
            metric("Crediti guadagnati", value: earnedLabel)
        ], spacing: 24)
        counters.distribution = .fillEqually
        add(counters, to: status)
        add(status, to: content)

        let api = section("FreeLLMAPI locale", copy: "Lascia FreeLLMAPI aperta sul Mac. La chiave unificata resta su questo dispositivo e viene usata soltanto per l’API locale.")
        apiBase.placeholderString = "http://127.0.0.1:31415/v1"
        apiKey.placeholderString = "Chiave unificata FreeLLMAPI"
        workerName.placeholderString = "fornai-mac"
        workerName.toolTip = "Usa lettere, numeri, punti, trattini o trattini bassi, senza spazi."
        model.placeholderString = "Scegli un modello o inserisci il suo ID"
        model.isEditable = true
        model.completes = true
        model.usesDataSource = false
        model.numberOfVisibleItems = 8
        for (control, id, title) in [
            (apiBase, "settings.apiBase", "Indirizzo API locale"),
            (apiKey, "settings.apiKey", "Chiave API locale"),
            (workerName, "settings.workerName", "Nome del worker")
        ] {
            register(control, id, label: title)
            control.delegate = self
        }
        register(model, "settings.model", label: "Modello FreeLLMAPI")
        model.delegate = self
        add(formRow("Indirizzo API", control: apiBase), to: api)
        add(formRow("Chiave API", control: apiKey), to: api)
        add(formRow("Nome worker", control: workerName), to: api)
        add(formRow("Modello", control: model), to: api)
        verifyButton = button("Verifica API", id: "worker.verify", action: #selector(verifyAPI))
        api.addArrangedSubview(verifyButton)
        add(api, to: content)

        let research = section("Agente Fornai", copy: "Cerca online prima di rispondere e legge i repository pubblici GitHub indicati nella chat. Configura il motore scelto in FreeLLMAPI: si usa la stessa chiave unificata.")
        register(webSearch, "settings.webSearchEnabled", label: webSearch.title)
        webSearch.target = self
        webSearch.action = #selector(preferencesChanged)
        research.addArrangedSubview(webSearch)
        searchEngine.addItems(withTitles: ["Tavily", "Exa", "Firecrawl"])
        register(searchEngine, "settings.searchEngine", label: "Motore di ricerca web")
        searchEngine.target = self
        searchEngine.action = #selector(preferencesChanged)
        add(formRow("Motore", control: searchEngine), to: research)
        add(formRow("Passaggi massimi", control: numericLimit(agentSteps, value: stepsValue, id: "settings.agentMaxSteps", title: "Passaggi massimi dell’agente", minimum: 2, maximum: 8)), to: research)
        add(formRow("Ricerche massime", control: numericLimit(agentSearches, value: searchesValue, id: "settings.agentMaxSearches", title: "Ricerche web massime", minimum: 1, maximum: 5)), to: research)
        add(research, to: content)

        let account = section("Account Fornai", copy: "Inserisci l’indirizzo pubblico del wallet. Il collegamento si approva su fornai.dev nel browser; l’app non chiede la frase di recupero.")
        wallet.placeholderString = "Indirizzo pubblico Solana"
        wallet.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        wallet.delegate = self
        register(wallet, "settings.wallet", label: "Indirizzo pubblico del wallet Solana")
        add(formRow("Wallet", control: wallet), to: account)
        pairButton = button("Collega wallet", id: "worker.pair", action: #selector(pairWallet))
        account.addArrangedSubview(pairButton)
        pairingLabel.isSelectable = true
        add(pairingLabel, to: account)
        add(account, to: content)

        let preferences = section("Avvio e impostazioni")
        for (control, id) in [(autoStart, "settings.autoStart"), (runAtLogin, "settings.runAtLogin")] {
            register(control, id, label: control.title)
            control.target = self
            control.action = #selector(preferencesChanged)
            preferences.addArrangedSubview(control)
        }
        saveButton = button("Salva impostazioni", id: "worker.save", action: #selector(save))
        preferences.addArrangedSubview(saveButton)
        add(preferences, to: content)

        let note = Self.label("Se abilitato alle richieste della rete, ogni task completato per un altro wallet guadagna 1 credito. I task personali e l’attesa non generano crediti. I crediti si usano su Fornai e non sono denaro o token PASTA.", size: 11)
        note.textColor = .secondaryLabelColor
        add(note, to: content)
        let help = button("Guida al worker", id: "worker.help", action: #selector(openHelp))
        let closeNote = Self.label("Chiudendo questa finestra, Fornai resta nella barra dei menu.", size: 11)
        closeNote.textColor = .secondaryLabelColor
        add(closeNote, to: content)
        content.addArrangedSubview(help)
    }

    private func metric(_ title: String, value: NSTextField) -> NSStackView {
        value.lineBreakMode = .byTruncatingMiddle
        value.maximumNumberOfLines = 1
        let stack = NSStackView(views: [Self.label(title, size: 11), value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        value.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func numericLimit(_ stepper: NSStepper, value: NSTextField, id: String, title: String, minimum: Double, maximum: Double) -> NSStackView {
        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(preferencesChanged)
        register(stepper, id, label: title)
        stepper.toolTip = "Da \(Int(minimum)) a \(Int(maximum)) per task."
        value.widthAnchor.constraint(equalToConstant: 32).isActive = true
        stepper.widthAnchor.constraint(equalToConstant: 19).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return horizontal([value, stepper, spacer], spacing: 8)
    }

    private func refresh() {
        updating = true
        defer { updating = false }
        for (field, value) in [(apiBase, controller.apiBase), (apiKey, controller.apiKey), (wallet, controller.wallet), (workerName, controller.workerName)] {
            if field.currentEditor() == nil { field.stringValue = value }
        }
        if listedModels != controller.models {
            listedModels = controller.models
            let editingValue = model.stringValue
            model.removeAllItems()
            model.addItems(withObjectValues: listedModels)
            model.stringValue = editingValue
        }
        if model.currentEditor() == nil { model.stringValue = controller.model }
        autoStart.state = controller.autoStart ? .on : .off
        runAtLogin.state = controller.runAtLogin ? .on : .off
        webSearch.state = controller.webSearchEnabled ? .on : .off
        searchEngine.selectItem(at: searchEngines.firstIndex(of: controller.searchEngine) ?? 0)
        agentSteps.integerValue = controller.agentMaxSteps
        agentSearches.integerValue = controller.agentMaxSearches
        stepsValue.stringValue = String(controller.agentMaxSteps)
        searchesValue.stringValue = String(controller.agentMaxSearches)
        let editable = !controller.isBusy && !controller.isRunning
        [apiBase, apiKey, wallet, workerName].forEach { $0.isEnabled = editable }
        model.isEnabled = editable
        autoStart.isEnabled = editable
        runAtLogin.isEnabled = editable
        webSearch.isEnabled = editable
        searchEngine.isEnabled = editable && controller.webSearchEnabled
        agentSteps.isEnabled = editable && controller.webSearchEnabled
        agentSearches.isEnabled = editable && controller.webSearchEnabled
        saveButton.isEnabled = editable
        verifyButton.isEnabled = editable
        pairButton.isEnabled = editable && !controller.wallet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        pairButton.title = controller.paired ? "Ricollega wallet" : "Collega wallet"
        startButton.title = controller.isRunning ? "Pausa" : "Avvia"
        startButton.setAccessibilityLabel(startButton.title)
        startButton.isEnabled = !controller.isBusy && (controller.isRunning || controller.paired)
        refreshButton.isEnabled = controller.paired && !controller.isBusy
        switch controller.status {
        case "starting": statusLabel.stringValue = "Avvio in corso"
        case "ready": statusLabel.stringValue = "Pronto"
        case "working": statusLabel.stringValue = "Task in esecuzione"
        case "error": statusLabel.stringValue = "Serve attenzione"
        default: statusLabel.stringValue = "In pausa"
        }
        statusLabel.textColor = controller.status == "error" ? Self.tomato : Self.ink
        messageLabel.stringValue = controller.message
        networkLabel.stringValue = controller.networkAuthorized
            ? "Abilitato alle richieste della rete."
            : "Richieste di rete non abilitate per questo wallet. Collegare l’app non abilita automaticamente i guadagni."
        balanceLabel.stringValue = controller.paired ? controller.creditBalance : "—"
        earnedLabel.stringValue = controller.paired ? controller.earnedCredits : "—"
        balanceLabel.toolTip = balanceLabel.stringValue
        earnedLabel.toolTip = earnedLabel.stringValue
        pairingLabel.stringValue = controller.pairCode.isEmpty
            ? (controller.paired ? "Wallet collegato a Fornai." : "Nessun wallet collegato.")
            : "Codice da confrontare nel browser: \(controller.pairCode)"
    }

    private func updateDraft() {
        guard !updating else { return }
        if controller.apiBase != apiBase.stringValue { controller.apiBase = apiBase.stringValue }
        if controller.apiKey != apiKey.stringValue { controller.apiKey = apiKey.stringValue }
        if controller.wallet != wallet.stringValue { controller.wallet = wallet.stringValue }
        if controller.workerName != workerName.stringValue { controller.workerName = workerName.stringValue }
        if controller.model != model.stringValue { controller.model = model.stringValue }
        if controller.autoStart != (autoStart.state == .on) { controller.autoStart = autoStart.state == .on }
        if controller.runAtLogin != (runAtLogin.state == .on) { controller.runAtLogin = runAtLogin.state == .on }
        if controller.webSearchEnabled != (webSearch.state == .on) { controller.webSearchEnabled = webSearch.state == .on }
        let engine = searchEngines[max(0, searchEngine.indexOfSelectedItem)]
        if controller.searchEngine != engine { controller.searchEngine = engine }
        if controller.agentMaxSteps != agentSteps.integerValue { controller.agentMaxSteps = agentSteps.integerValue }
        if controller.agentMaxSearches != agentSearches.integerValue { controller.agentMaxSearches = agentSearches.integerValue }
    }

    func controlTextDidChange(_ notification: Notification) { updateDraft() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let selection = model.objectValueOfSelectedItem as? String { controller.model = selection }
    }
    @objc private func preferencesChanged() { updateDraft() }
    @objc private func save() { updateDraft(); controller.save() }
    @objc private func pairWallet() { updateDraft(); controller.pairWallet() }
    @objc private func verifyAPI() { updateDraft(); controller.verifyAPI() }
    @objc private func refreshBalance() { controller.refreshBalance() }
    @objc private func toggleWorker() {
        if controller.isRunning { controller.pause() }
        else { updateDraft(); controller.start() }
    }
    @objc private func openHelp() {
        guard let url = URL(string: "https://fornai.dev/#workers") else { return }
        NSWorkspace.shared.open(url)
    }
}

private final class FlippedWorkerDocument: NSView {
    override var isFlipped: Bool { true }
}
