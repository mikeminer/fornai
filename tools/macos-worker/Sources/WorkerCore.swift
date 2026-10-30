import AppKit
import Combine
import Foundation
import Security
import ServiceManagement
import Darwin

private final class WorkerKeychain {
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.fornai.worker.configuration.v1", kSecAttrAccount as String: "configuration",
        kSecAttrSynchronizable as String: false]

    func load() throws -> WorkerConfiguration? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data, data.count <= 131072,
              let config = try? JSONDecoder().decode(WorkerConfiguration.self, from: data) else {
            throw WorkerFailure("Impossibile leggere la configurazione dal Portachiavi. Sbloccalo e riapri l’app.")
        }
        return config
    }

    func save(_ config: WorkerConfiguration) throws {
        let data = try JSONEncoder().encode(config)
        guard data.count <= 131072 else { throw WorkerFailure("Configurazione troppo grande.") }
        let changes: [String: Any] = [kSecValueData as String: data]
        var result = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if result == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(entry as CFDictionary, nil)
            if result == errSecDuplicateItem { result = SecItemUpdate(query as CFDictionary, changes as CFDictionary) }
        }
        guard result == errSecSuccess else { throw WorkerFailure("Impossibile salvare le credenziali nel Portachiavi. Il worker resta fermo.") }
    }
}

private final class WorkerHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let remote: URLSession
    private let local: URLSession
    override init() {
        func configuration(local: Bool) -> URLSessionConfiguration {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = local ? 15 : 20
            config.timeoutIntervalForResource = local ? 15 : 20
            config.httpShouldSetCookies = false; config.httpCookieStorage = nil
            config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            if local { config.connectionProxyDictionary = [:] }
            return config
        }
        remote = URLSession(configuration: configuration(local: false))
        local = URLSession(configuration: configuration(local: true))
        super.init()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func remote<T: Decodable>(_ path: String, body: [String: String]? = nil, token: String? = nil) async throws -> T {
        guard ["/api/worker/pair/start", "/api/worker/pair/poll", "/api/worker/account"].contains(path),
              let url = URL(string: WorkerPolicy.origin + path) else { throw WorkerFailure("Endpoint non autorizzato.") }
        var request = URLRequest(url: url)
        request.setValue(WorkerPolicy.origin, forHTTPHeaderField: "Origin")
        if let token = token { request.setValue(token, forHTTPHeaderField: "x-fornai-worker-token") }
        if let body = body { request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body) }
        return try await send(request, using: remote)
    }
    func models(base: String, key: String) async throws -> [String] {
        struct Models: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
        let base = try WorkerPolicy.localAPI(base)
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let result: Models = try await send(request, using: local)
        let names = Array(Set(result.data.prefix(2000).map(\.id).filter { !$0.isEmpty && $0.count <= 200 && !$0.contains(where: { $0.isNewline }) })).sorted()
        guard !names.isEmpty else { throw WorkerFailure("FreeLLMAPI non espone modelli disponibili.") }
        return names
    }
    private func send<T: Decodable>(_ original: URLRequest, using session: URLSession) async throws -> T {
        var request = original
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            defer { bytes.task.cancel() } // Also stop oversized/error bodies immediately.
            guard let response = response as? HTTPURLResponse else { throw WorkerFailure("Risposta del servizio non valida.") }
            guard (200...299).contains(response.statusCode) else {
                if [401,403].contains(response.statusCode) { throw WorkerFailure("Accesso rifiutato. Controlla la chiave API o collega di nuovo il wallet.") }
                if response.statusCode == 429 { throw WorkerFailure("Limite richieste raggiunto. Attendi qualche minuto.") }
                throw WorkerFailure("Servizio temporaneamente non disponibile. Riprova più tardi.")
            }
            if response.expectedContentLength > Int64(WorkerPolicy.maximumResponseBytes) { throw WorkerFailure("Risposta del servizio troppo grande.") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < WorkerPolicy.maximumResponseBytes else { throw WorkerFailure("Risposta del servizio troppo grande.") }
                data.append(byte)
            }
            guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw WorkerFailure("Risposta del servizio non valida.") }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch let error as WorkerFailure { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid].contains(error.code) {
                throw WorkerFailure("Impossibile verificare la connessione sicura a Fornai.")
            }
            throw WorkerFailure("Connessione non riuscita. Controlla Internet e che FreeLLMAPI sia avviata sul Mac.")
        } catch { throw WorkerFailure("Richiesta non riuscita. Riprova più tardi.") }
    }
}

private final class WorkerChild {
    let id = UUID()
    let config: WorkerConfiguration
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let inputLock = NSLock()
    private let outputQueue = DispatchQueue(label: "dev.fornai.worker.stdout")
    private let drained = DispatchGroup()
    var running: Bool { process.isRunning }

    init(config: WorkerConfiguration) { self.config = config }
    func launch(onEvent: @escaping (WorkerEvent) -> Void, onFailure: @escaping () -> Void, onExit: @escaping (Int32) -> Void) throws {
        guard let resources = Bundle.main.resourceURL else { throw WorkerFailure("Pacchetto del worker non valido. Reinstalla l’app.") }
        let runtime = resources.appendingPathComponent("runtime", isDirectory: true)
        let node = runtime.appendingPathComponent("node"), adapter = runtime.appendingPathComponent("tray-worker.mjs")
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: node.path), manager.fileExists(atPath: adapter.path),
              manager.fileExists(atPath: runtime.appendingPathComponent("worker-runtime.mjs").path) else {
            throw WorkerFailure("Runtime FORNAI mancante. Reinstalla il pacchetto completo.")
        }
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var state = support
        for component in ["FornaiWorker", "state", config.wallet, config.workerName] {
            state.appendPathComponent(component, isDirectory: true)
            if manager.fileExists(atPath: state.path) {
                let attributes = try manager.attributesOfItem(atPath: state.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw WorkerFailure("Directory del worker non valida. Conserva i file per il recupero.") }
            } else { try manager.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
        }
        process.executableURL = node; process.arguments = [adapter.path]; process.currentDirectoryURL = state
        process.environment = WorkerPolicy.childEnvironment(config, statePath: state.path, home: NSHomeDirectory(), temporary: NSTemporaryDirectory())
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        drained.enter()
        process.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async { self.drained.wait(); onExit(process.terminationStatus) }
        }
        do { try process.run() } catch { drained.leave(); throw WorkerFailure("Impossibile avviare il runtime incluso nell’app.") }
        outputQueue.async { [self] in
            defer { drained.leave() }
            var decoder = WorkerLineDecoder()
            do {
                while let data = try output.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                    for event in try decoder.append(data) { onEvent(event) }
                }
                try decoder.finish()
            } catch { onFailure() }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            // Always drain, never log or display dependency stderr.
            while let data = try? errors.fileHandleForReading.read(upToCount: 4096), !data.isEmpty { }
        }
    }
    func send(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value) + Data([10])
        inputLock.lock(); defer { inputLock.unlock() }
        guard process.isRunning else { throw WorkerFailure("Il worker non è avviato.") }
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func terminate() { if process.isRunning { process.terminate() } }
    func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
    func closeInput() { inputLock.lock(); defer { inputLock.unlock() }; try? input.fileHandleForWriting.close() }
}

@MainActor final class WorkerController: NSObject, ObservableObject {
    @Published var apiBase = "http://127.0.0.1:31415/v1" { didSet { draftChanged() } }
    @Published var apiKey = "" { didSet { draftChanged() } }
    @Published var wallet = "" { didSet { draftChanged(walletChanged: oldValue != wallet) } }
    @Published var workerName = "fornai-mac" { didSet { draftChanged() } }
    @Published var model = "auto" { didSet { draftChanged() } }
    @Published var autoStart = false { didSet { draftChanged() } }
    @Published var runAtLogin = false { didSet { draftChanged() } }
    @Published private(set) var status = "paused"
    @Published private(set) var message = "Configura FreeLLMAPI e collega il wallet per iniziare."
    @Published private(set) var creditBalance = "—"
    @Published private(set) var earnedCredits = "—"
    @Published private(set) var networkAuthorized = false
    @Published private(set) var models: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var pairCode = ""
    @Published private(set) var paired = false

    private let testMode: Bool
    private let keychain = WorkerKeychain()
    private lazy var http = WorkerHTTP()
    private var saved = WorkerConfiguration()
    private var loading = false, shuttingDown = false, launched = false
    private var generation: UInt64 = 0
    private var operationID: UUID?
    private var operation: Task<Void, Never>?
    private var balanceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var child: WorkerChild?
    private var desiredRunning = false, retryAllowed = false, stopping = false
    private var shutdownCompletion: (() -> Void)?

    init(testMode: Bool = false) {
        self.testMode = testMode
        super.init()
        guard !testMode else { return }
        do {
            if let config = try keychain.load() { saved = config; apply(config) }
            paired = isPaired
            if paired { message = "Wallet collegato. Premi Avvia per ricevere task." }
        } catch { fail(error) }
    }

    func handleLaunch(background: Bool = false) {
        guard !testMode, !launched, !shuttingDown else { return }
        launched = true
        refreshBalance()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                self?.refreshBalance()
            }
        }
        if saved.saved && saved.autoStart && isPaired { start() }
    }

    private var isPaired: Bool { saved.tokenWallet == wallet && WorkerPolicy.token(saved.workerToken, wallet: wallet) != nil }
    private func apply(_ config: WorkerConfiguration) {
        loading = true; defer { loading = false }
        apiBase = config.apiBase; apiKey = config.apiKey; wallet = config.wallet; workerName = config.workerName
        model = config.model; autoStart = config.autoStart; runAtLogin = config.runAtLogin
    }
    private func draft() -> WorkerConfiguration {
        var config = saved
        config.apiBase = apiBase; config.apiKey = apiKey; config.wallet = wallet
        config.workerName = workerName; config.model = model; config.autoStart = autoStart; config.runAtLogin = runAtLogin
        if config.tokenWallet != wallet { config.workerToken = ""; config.tokenWallet = "" }
        return config
    }
    private func draftChanged(walletChanged: Bool = false) {
        guard !loading else { return }
        generation &+= 1; operation?.cancel(); operation = nil; operationID = nil
        balanceTask?.cancel(); balanceTask = nil; pairCode = ""
        retryTask?.cancel(); retryTask = nil; desiredRunning = false
        if walletChanged { saved.workerToken = ""; saved.tokenWallet = ""; creditBalance = "—"; earnedCredits = "—"; networkAuthorized = false }
        paired = isPaired; isBusy = stopping
        if child != nil { pause() }
    }
    private func checkCurrent(_ expected: UInt64) throws {
        try Task.checkCancellation()
        if generation != expected || shuttingDown { throw CancellationError() }
    }
    private func perform(_ action: @escaping @MainActor (UInt64) async throws -> Void) {
        guard !testMode, !isBusy, !isRunning, !shuttingDown else { return }
        let id = UUID(), expected = generation
        operationID = id; isBusy = true
        operation = Task { [weak self] in
            guard let self = self else { return }
            defer { if self.operationID == id { self.operationID = nil; self.operation = nil; self.isBusy = self.stopping; self.pairCode = "" } }
            do { try await action(expected) }
            catch is CancellationError { }
            catch { if self.generation == expected && !self.shuttingDown { self.fail(error) } }
        }
    }

    func save() {
        guard !testMode, !isBusy, !isRunning, !shuttingDown else { return }
        do {
            var config = try WorkerPolicy.configuration(draft(), requirePair: false); config.saved = true
            try keychain.save(config); saved = config; apply(config)
            do {
                let service = SMAppService.mainApp
                if config.runAtLogin && service.status != .enabled { try service.register() }
                if !config.runAtLogin && service.status != .notRegistered { try service.unregister() }
                if config.runAtLogin && service.status == .requiresApproval {
                    message = "Configurazione salvata. Consenti l’avvio al login nelle Impostazioni di Sistema."
                } else { message = "Configurazione salvata nel Portachiavi." }
            } catch {
                saved.runAtLogin = SMAppService.mainApp.status == .enabled
                loading = true; runAtLogin = saved.runAtLogin; loading = false
                try? keychain.save(saved)
                throw WorkerFailure("Configurazione salvata; impossibile aggiornare l’avvio al login nelle Impostazioni di Sistema.")
            }
            paired = isPaired
        } catch { fail(error) }
    }

    func pairWallet() {
        desiredRunning = false; retryTask?.cancel()
        perform { [weak self] expected in
            guard let self = self else { return }
            let owner = self.wallet, name = self.workerName
            guard WorkerPolicy.isWallet(owner), WorkerPolicy.matches(name, "^[A-Za-z0-9._-]{1,80}$"), name != ".", name != ".." else {
                throw WorkerFailure("Inserisci un wallet Solana e un nome worker validi.")
            }
            let request: WorkerPairStart = try await self.http.remote("/api/worker/pair/start", body: ["wallet": owner, "deviceName": name])
            try self.checkCurrent(expected)
            let url = try WorkerPolicy.pairingURL(request)
            self.pairCode = request.displayCode
            self.message = "Approva nel browser il codice " + request.displayCode + " con lo stesso wallet."
            guard NSWorkspace.shared.open(url) else { throw WorkerFailure("Impossibile aprire il browser per collegare il wallet.") }
            guard let deadline = WorkerPolicy.date(request.expiresAt) else { throw WorkerFailure("Scadenza del collegamento non valida.") }
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 3_000_000_000); try self.checkCurrent(expected)
                let result: WorkerPairPoll = try await self.http.remote("/api/worker/pair/poll", body: ["pairId": request.pairId, "deviceSecret": request.deviceSecret])
                try self.checkCurrent(expected)
                if result.status == "expired" { break }
                if result.status == "pending" { continue }
                guard result.status == "approved", result.wallet == owner, self.wallet == owner,
                      let token = result.workerToken, let claims = WorkerPolicy.token(token, wallet: owner),
                      result.expiresAt == claims.expiresAt else { throw WorkerFailure("Il wallet approvato non corrisponde a quello configurato.") }
                var config = self.draft(); config.workerToken = token; config.tokenWallet = owner
                // Pairing can precede API-key setup. Start still validates all fields.
                try self.keychain.save(config); self.saved = config; self.paired = true
                self.message = "Wallet collegato. Salva la configurazione e avvia il worker."
                self.refreshBalance(); return
            }
            throw WorkerFailure("Collegamento scaduto. Premi Collega wallet per riprovare.")
        }
    }

    func verifyAPI() {
        perform { [weak self] expected in
            guard let self = self else { return }
            let base = try WorkerPolicy.localAPI(self.apiBase).absoluteString, key = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.utf8.count <= 8192, !key.contains(where: { $0.isNewline }) else { throw WorkerFailure("Inserisci la chiave API unificata.") }
            let models = try await self.http.models(base: base, key: key)
            try self.checkCurrent(expected)
            if self.model == "auto" {
                let selected = try WorkerPolicy.automaticModel(models)
                self.loading = true; self.model = selected; self.loading = false
            }
            self.models = models; self.message = "API locale collegata: \(models.count) modelli disponibili. Nessuna inferenza eseguita."
        }
    }

    func refreshBalance() {
        guard !testMode, !shuttingDown, balanceTask == nil, isPaired else { paired = isPaired; return }
        let expected = generation, owner = wallet, token = saved.workerToken
        balanceTask = Task { [weak self] in
            guard let self = self else { return }
            defer { if self.generation == expected { self.balanceTask = nil } }
            do {
                let account: WorkerAccount = try await self.http.remote("/api/worker/account", token: token)
                try self.checkCurrent(expected); try WorkerPolicy.validateAccount(account, wallet: owner)
                self.creditBalance = account.creditBalance; self.earnedCredits = account.workerEarnedCredits
                self.networkAuthorized = account.networkAuthorized
            } catch is CancellationError { }
            catch { if self.generation == expected && !self.shuttingDown { self.message = "Saldo non aggiornato. " + self.safe(error) } }
        }
    }

    func start() {
        guard !testMode, !isBusy, child == nil, !shuttingDown else { return }
        do {
            let config = try WorkerPolicy.configuration(draft(), requirePair: true)
            if config.model == "auto" {
                perform { [weak self] expected in
                    guard let self = self else { return }
                    let models = try await self.http.models(base: config.apiBase, key: config.apiKey)
                    try self.checkCurrent(expected)
                    var resolved = config; resolved.model = try WorkerPolicy.automaticModel(models)
                    self.models = models
                    try self.launchWorker(resolved)
                }
            } else { try launchWorker(config) }
        } catch { child = nil; isRunning = false; desiredRunning = false; fail(error) }
    }

    private func launchWorker(_ proposed: WorkerConfiguration) throws {
        do {
            var config = proposed; config.saved = true
            try keychain.save(config); saved = config; apply(config); paired = true
            retryTask?.cancel(); retryTask = nil; desiredRunning = true; retryAllowed = false
            let process = WorkerChild(config: config), id = process.id
            child = process; isRunning = true; status = "starting"; message = "Connessione a Fornai e FreeLLMAPI…"
            // The main dispatch queue is FIFO. Child drains stdout before exit,
            // so the final credential/status event is handled before didExit.
            try process.launch(onEvent: { [weak self] event in DispatchQueue.main.async { self?.receive(event, from: id) } },
                onFailure: { [weak self] in DispatchQueue.main.async {
                    guard let self = self, self.child?.id == id else { return }
                    self.fail(WorkerFailure("Messaggio del runtime non valido. Il worker viene fermato.")); self.pause()
                } }, onExit: { [weak self] code in DispatchQueue.main.async { self?.didExit(id, code: code) } })
            refreshBalance()
        } catch { child = nil; isRunning = false; desiredRunning = false; throw error }
    }

    private func receive(_ event: WorkerEvent, from id: UUID) {
        guard let process = child, process.id == id else { return }
        if event.type == "credential" {
            var acknowledged = false
            do {
                guard let token = event.workerToken, event.wallet == wallet, event.wallet == process.config.wallet,
                      saved.tokenWallet == wallet, let candidate = WorkerPolicy.token(token, wallet: wallet),
                      let current = WorkerPolicy.token(saved.workerToken, wallet: wallet),
                      let expiry = WorkerPolicy.date(candidate.expiresAt), let previous = WorkerPolicy.date(current.expiresAt), expiry > previous else {
                    throw WorkerFailure("Il rinnovo non corrisponde al wallet attivo.")
                }
                var config = saved; config.workerToken = token
                try keychain.save(config) // ACK only after the atomic Keychain update succeeds.
                saved = config; paired = isPaired; acknowledged = true
            } catch { desiredRunning = false; fail(WorkerFailure("Impossibile salvare il rinnovo nel Portachiavi. Il worker verrà fermato.")) }
            try? process.send(["action": "credential-saved", "id": event.id ?? "", "ok": acknowledged])
            return
        }
        if event.type == "status" {
            if event.state == "error" {
                retryAllowed = desiredRunning && event.fatal == false
                if !retryAllowed { desiredRunning = false }
            }
            if !stopping { status = event.state ?? "error"; message = clean(event.message ?? "") }
        } else if event.type == "log" {
            if !stopping { message = clean(event.message ?? "") }
        } else if event.type == "receipt" {
            message = event.status == "completed" ? "Task completato. Crediti assegnati: \(event.rewardCredits ?? "0")." : "Task non completato. Ricevuta salvata."
            refreshBalance()
        }
    }

    func pause() {
        desiredRunning = false; retryAllowed = false; retryTask?.cancel(); retryTask = nil
        guard !testMode else { return }
        guard let process = child else { isRunning = false; status = "paused"; return }
        guard !stopping else { return }
        stopping = true; isBusy = true; message = "Arresto in corso: salvataggio delle ricevute…"
        try? process.send(["action": "stop"])
        let id = process.id
        stopTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self = self, self.child?.id == id else { return }
                process.terminate()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                guard self.child?.id == id else { return }
                process.kill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                guard self.child?.id == id else { return }
                process.closeInput()
                self.message = "Worker arrestato. Le ricevute conservate saranno recuperate al prossimo avvio."
                if self.shuttingDown { self.finishShutdown() }
            } catch { }
        }
    }

    private func didExit(_ id: UUID, code: Int32) {
        guard let current = child, current.id == id else { return }
        current.closeInput(); child = nil; stopTask?.cancel(); stopTask = nil
        isRunning = false; stopping = false; isBusy = operationID != nil
        if shuttingDown { finishShutdown(); return }
        if status != "error" { status = "paused"; message = "Worker in pausa. Le ricevute salvate saranno recuperate al prossimo avvio." }
        if desiredRunning && retryAllowed {
            message = "Connessione temporaneamente non disponibile. Nuovo tentativo tra 20 secondi; Pausa annulla il riavvio."
            retryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                guard let self = self, self.desiredRunning, self.retryAllowed, !self.shuttingDown else { return }
                self.start()
            }
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        guard !shuttingDown else { return }
        shuttingDown = true; generation &+= 1; shutdownCompletion = completion
        operation?.cancel(); operation = nil; operationID = nil; balanceTask?.cancel(); pollTask?.cancel(); retryTask?.cancel()
        if child == nil { finishShutdown() } else { pause() }
    }
    private func finishShutdown() {
        stopTask?.cancel(); stopTask = nil
        let completion = shutdownCompletion; shutdownCompletion = nil; completion?()
    }
    private func clean(_ value: String) -> String {
        var result = value
        for secret in [apiKey, saved.apiKey, saved.workerToken] where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "[protetto]") }
        return String(result.prefix(500))
    }
    private func safe(_ error: Error) -> String { clean((error as? WorkerFailure)?.message ?? "Operazione non riuscita. Controlla la configurazione e riprova.") }
    private func fail(_ error: Error) { status = "error"; message = safe(error) }
}
