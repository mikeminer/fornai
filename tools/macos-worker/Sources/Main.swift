import AppKit
import Combine
import CoreServices

@main
struct FornaiWorkerApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = WorkerAppDelegate(testMode: CommandLine.arguments.contains("--self-test"))
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class WorkerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let testMode: Bool
    private var controller: WorkerController?
    private var window: NSWindow?
    private var workerView: WorkerView?
    private var statusItem: NSStatusItem?
    private var stateMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?
    private var refreshMenuItem: NSMenuItem?
    private var observation: AnyCancellable?
    private var quitting = false
    private var canTerminate = false

    init(testMode: Bool) {
        self.testMode = testMode
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !testMode, activateExistingInstance() {
            NSApplication.shared.terminate(nil)
            return
        }
        let core = WorkerController(testMode: testMode)
        controller = core
        configureWindow(core)
        configureMenus()
        observation = core.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshMenu() }
        }
        refreshMenu()
        if testMode {
            DispatchQueue.main.async { self.runSelfTest() }
        } else {
            let event = NSAppleEventManager.shared().currentAppleEvent
            let background = Self.isBackgroundLaunch(arguments: CommandLine.arguments, eventID: event?.eventID,
                launchReason: event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue)
            core.handleLaunch(background: background)
            if !background { showSettings() }
        }
    }

    private static func isBackgroundLaunch(arguments: [String], eventID: AEEventID?, launchReason: AEKeyword?) -> Bool {
        if arguments.contains("--background") { return true }
        guard eventID == kAEOpenApplication else { return false }
        return launchReason == keyAELaunchedAsLogInItem || launchReason == keyAELaunchedAsServiceItem
    }

    private func activateExistingInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            // The ordinary Launch Services app-open path also delivers reopen
            // to the existing instance. Never start a second worker here.
            return true
        }
        return false
    }

    private func configureWindow(_ core: WorkerController) {
        let content = WorkerView(controller: core)
        let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        result.title = "Fornai Worker"
        result.identifier = NSUserInterfaceItemIdentifier("fornai.worker.window")
        result.contentMinSize = NSSize(width: 540, height: 580)
        result.isReleasedWhenClosed = false
        result.delegate = self
        result.appearance = NSAppearance(named: .aqua)
        result.contentView = content
        result.center()
        window = result
        workerView = content
    }

    private func menuItem(_ title: String, action: Selector?, key: String = "", id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(id)
        return item
    }

    private func configureMenus() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "f.circle", accessibilityDescription: "Fornai Worker") {
            image.isTemplate = true
            status.button?.image = image
        } else { status.button?.title = "F" }
        status.button?.setAccessibilityLabel("Fornai Worker")
        status.button?.setAccessibilityIdentifier("fornai.worker.status")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem("Apri Fornai Worker", action: #selector(showSettings), id: "menu.open"))
        let state = menuItem("In pausa", action: nil, id: "menu.state")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        let toggle = menuItem("Avvia worker", action: #selector(toggleWorker), id: "menu.toggle")
        menu.addItem(toggle)
        let refresh = menuItem("Aggiorna saldo", action: #selector(refreshBalance), id: "menu.refresh")
        menu.addItem(refresh)
        menu.addItem(menuItem("Apri fornai.dev", action: #selector(openWebsite), id: "menu.website"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Esci da Fornai Worker", action: #selector(quit), key: "q", id: "menu.quit"))
        status.menu = menu
        statusItem = status
        stateMenuItem = state
        toggleMenuItem = toggle
        refreshMenuItem = refresh

        // A standard Edit menu supplies Copy/Paste/Select All for the public
        // wallet and secure API-key fields when the settings window is active.
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu(title: "Fornai Worker")
        app.submenu?.addItem(menuItem("Esci da Fornai Worker", action: #selector(quit), key: "q", id: "application.quit"))
        main.addItem(app)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Modifica")
        for (title, action, key) in [("Taglia", "cut:", "x"), ("Copia", "copy:", "c"), ("Incolla", "paste:", "v"), ("Seleziona tutto", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApplication.shared.mainMenu = main
    }

    private func refreshMenu() {
        guard let core = controller else { return }
        let label: String
        switch core.status {
        case "starting": label = "Avvio in corso"
        case "ready": label = "Pronto"
        case "working": label = "Task in esecuzione"
        case "error": label = "Serve attenzione"
        default: label = "In pausa"
        }
        stateMenuItem?.title = label
        statusItem?.button?.toolTip = "Fornai Worker · \(label)"
        if let image = NSImage(systemSymbolName: core.status == "working" ? "f.circle.fill" : "f.circle", accessibilityDescription: "Fornai Worker · \(label)") {
            image.isTemplate = true
            statusItem?.button?.image = image
        }
        toggleMenuItem?.title = core.isRunning ? "Metti in pausa" : "Avvia worker"
        toggleMenuItem?.isEnabled = !core.isBusy && (core.isRunning || core.paired)
        refreshMenuItem?.isEnabled = !core.isBusy && core.paired
    }

    @objc private func showSettings() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc private func toggleWorker() {
        guard let core = controller, !core.isBusy else { return }
        if core.isRunning { core.pause() } else { core.start() }
    }
    @objc private func refreshBalance() { controller?.refreshBalance() }
    @objc private func openWebsite() {
        guard let url = URL(string: "https://fornai.dev") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if canTerminate || controller == nil || testMode { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
        controller?.shutdown { [weak self] in
            DispatchQueue.main.async {
                self?.canTerminate = true
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private func runSelfTest() {
        guard let core = controller, let view = workerView, let window,
              let statusItem, statusItem.button != nil, let menu = statusItem.menu else {
            failSelfTest("UI bootstrap")
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let expected = ["settings.apiBase", "settings.apiKey", "settings.wallet", "settings.workerName", "settings.model", "settings.autoStart", "settings.runAtLogin", "worker.toggle", "worker.refresh", "worker.verify", "worker.pair", "worker.save", "worker.help"]
        guard expected.allSatisfy({ view.controls[$0] != nil }),
              view.controls["settings.apiKey"] is NSSecureTextField,
              view.controls["settings.model"] is NSComboBox,
              view.controls["worker.save"]?.action != nil,
              view.controls["worker.toggle"]?.action != nil,
              !core.isRunning, !core.autoStart, !core.runAtLogin,
              core.apiKey.isEmpty, core.wallet.isEmpty else { failSelfTest("Controls and isolated defaults") }
        guard ["settings.apiBase", "settings.apiKey", "settings.wallet", "settings.model"].allSatisfy({
            guard let field = view.controls[$0] else { return false }
            return field.bounds.width >= 80 && field.bounds.height >= 18
        }) else { failSelfTest("Form layout") }
        guard Self.isBackgroundLaunch(arguments: [], eventID: kAEOpenApplication, launchReason: keyAELaunchedAsLogInItem),
              Self.isBackgroundLaunch(arguments: [], eventID: kAEOpenApplication, launchReason: keyAELaunchedAsServiceItem),
              Self.isBackgroundLaunch(arguments: ["--background"], eventID: nil, launchReason: nil),
              !Self.isBackgroundLaunch(arguments: [], eventID: kAEOpenApplication, launchReason: nil) else {
            failSelfTest("Login and interactive launch")
        }
        let menuIDs = Set(menu.items.compactMap { $0.identifier?.rawValue })
        guard Set(["menu.open", "menu.state", "menu.toggle", "menu.refresh", "menu.website", "menu.quit"]).isSubset(of: menuIDs),
              windowShouldClose(window) == false,
              applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false,
              !window.isVisible, self.statusItem != nil else { failSelfTest("Menu and background lifetime") }
        if let flag = CommandLine.arguments.firstIndex(of: "--screenshot") {
            guard CommandLine.arguments.indices.contains(flag + 1) else { failSelfTest("Missing screenshot path") }
            // Render only our own NSView. This does not capture the desktop,
            // other applications or require Screen Recording permission.
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { failSelfTest("View bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { failSelfTest("PNG encoding") }
            do {
                let target = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try png.write(to: target, options: .atomic)
            } catch { failSelfTest("Writing app preview") }
        }
        print("FORNAI_MACOS_UI_SELF_TEST_OK controls=\(expected.count) menu=6")
        NSStatusBar.system.removeStatusItem(statusItem)
        exit(0)
    }

    private func failSelfTest(_ stage: String) -> Never {
        fputs("FORNAI_MACOS_UI_SELF_TEST_FAILED: \(stage)\n", stderr)
        exit(1)
    }
}
