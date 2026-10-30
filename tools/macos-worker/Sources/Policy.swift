import Foundation

struct WorkerFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct WorkerConfiguration: Codable {
    var apiBase = "http://127.0.0.1:31415/v1"
    var apiKey = ""
    var wallet = ""
    var workerName = "fornai-mac"
    var model = "auto"
    var workerToken = ""
    var tokenWallet = ""
    var autoStart = false
    var runAtLogin = false
    var saved = false
}

struct WorkerTokenClaims: Codable {
    let version: Int
    let id: String
    let address: String
    let scope: String
    let createdAt: String
    let expiresAt: String
}

struct WorkerPairStart: Decodable {
    let pairId: String
    let deviceSecret: String
    let displayCode: String
    let expiresAt: String
    let verificationUrl: String
    let pollIntervalSeconds: Int?
}

struct WorkerPairPoll: Decodable {
    let status: String
    let workerToken: String?
    let wallet: String?
    let expiresAt: String
}

struct WorkerCreditPolicy: Decodable {
    let unit: String
    let jobCost: String
    let workerReward: String
}

struct WorkerAccount: Decodable {
    let protocolVersion: Int
    let wallet: String
    let creditBalance: String
    let workerEarnedCredits: String
    let creditPolicy: WorkerCreditPolicy
    let networkAuthorized: Bool
}

struct WorkerEvent: Decodable {
    let type: String
    var state: String?
    var message: String?
    var fatal: Bool?
    var id: String?
    var workerToken: String?
    var wallet: String?
    var jobId: String?
    var status: String?
    var currency: String?
    var rewardCredits: String?
}

enum WorkerPolicy {
    static let origin = "https://fornai.dev"
    static let maximumResponseBytes = 262_144
    static let maximumIPCBytes = 32_768
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    static func isWallet(_ value: String) -> Bool {
        guard (32...44).contains(value.utf8.count) else { return false }
        var bytes: [Int] = [] // little-endian base-256, without redundant zeros
        for character in value.utf8 {
            guard let index = alphabet.firstIndex(of: character) else { return false }
            var carry = index
            for i in bytes.indices { carry += bytes[i] * 58; bytes[i] = carry & 255; carry >>= 8 }
            while carry > 0 { bytes.append(carry & 255); carry >>= 8 }
            if bytes.count > 32 { return false }
        }
        return bytes.count + value.utf8.prefix(while: { $0 == 49 }).count == 32
    }

    static func localAPI(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "http",
              let host = parts.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["/v1", "/v1/"].contains(parts.percentEncodedPath),
              parts.port == nil || (1...65535).contains(parts.port!), let url = parts.url else {
            throw WorkerFailure("L’API deve essere HTTP locale: 127.0.0.1, localhost o ::1, con percorso /v1.")
        }
        return url.absoluteString.hasSuffix("/") ? URL(string: String(url.absoluteString.dropLast()))! : url
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty, matches(value, "^[A-Za-z0-9_-]+$") else { return nil }
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
    }

    // Structural and account checks only. The server verifies the HMAC at preflight.
    static func token(_ value: String, wallet: String, now: Date = Date()) -> WorkerTokenClaims? {
        guard isWallet(wallet), value.utf8.count <= 2048 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let body = decodeBase64URL(String(parts[0])),
              decodeBase64URL(String(parts[1]))?.count == 32,
              let claims = try? JSONDecoder().decode(WorkerTokenClaims.self, from: body),
              claims.version == 2, !claims.id.isEmpty, claims.id.count <= 100,
              claims.address == wallet, claims.scope == "worker",
              let issued = date(claims.createdAt), let expiry = date(claims.expiresAt),
              issued <= now.addingTimeInterval(30), expiry > now,
              expiry > issued, expiry.timeIntervalSince(issued) <= 7 * 86400 else { return nil }
        return claims
    }

    static func validPairID(_ value: String) -> Bool {
        matches(value, "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    }

    static func pairingURL(_ request: WorkerPairStart, now: Date = Date()) throws -> URL {
        let exact = origin + "/worker/connect?pair=" + request.pairId
        guard validPairID(request.pairId), request.verificationUrl == exact,
              matches(request.deviceSecret, "^[A-Za-z0-9_-]{43}$"), decodeBase64URL(request.deviceSecret)?.count == 32,
              matches(request.displayCode, "^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$"),
              let expiry = date(request.expiresAt), expiry > now, expiry <= now.addingTimeInterval(630),
              let url = URL(string: exact) else { throw WorkerFailure("Risposta di collegamento non valida.") }
        return url
    }

    static func validCredit(_ value: String) -> Bool { matches(value, "^(0|[1-9][0-9]{0,59})$") }

    static func automaticModel(_ models: [String]) throws -> String {
        if models.contains("auto") { return "auto" }
        if models.contains("openai/gpt-oss-120b") { return "openai/gpt-oss-120b" }
        guard let first = models.first, !first.isEmpty else { throw WorkerFailure("FreeLLMAPI non espone modelli disponibili.") }
        return first
    }

    static func validateAccount(_ value: WorkerAccount, wallet: String) throws {
        guard value.protocolVersion == 2, value.wallet == wallet,
              validCredit(value.creditBalance), validCredit(value.workerEarnedCredits),
              value.creditPolicy.unit == "FORNAI_CREDIT", validCredit(value.creditPolicy.jobCost),
              validCredit(value.creditPolicy.workerReward) else { throw WorkerFailure("Il saldo ricevuto non corrisponde al wallet collegato.") }
    }

    static func configuration(_ value: WorkerConfiguration, requirePair: Bool) throws -> WorkerConfiguration {
        var result = value
        result.apiBase = try localAPI(value.apiBase.trimmingCharacters(in: .whitespacesAndNewlines)).absoluteString
        result.apiKey = value.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.apiKey.isEmpty, result.apiKey.utf8.count <= 8192, !result.apiKey.contains(where: { $0.isNewline }),
              isWallet(value.wallet) else { throw WorkerFailure("Inserisci la chiave API unificata e un indirizzo pubblico Solana valido.") }
        guard matches(value.workerName, "^[A-Za-z0-9._-]{1,80}$"), value.workerName != ".", value.workerName != ".." else {
            throw WorkerFailure("Nome worker: da 1 a 80 lettere, numeri, punti, trattini o underscore.")
        }
        result.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.model.isEmpty { result.model = "auto" }
        guard result.model.count <= 200, !result.model.contains(where: { $0.isNewline }) else { throw WorkerFailure("Nome modello non valido.") }
        if requirePair && (value.tokenWallet != value.wallet || token(value.workerToken, wallet: value.wallet) == nil) {
            throw WorkerFailure("Collega il wallet al sito prima di avviare il worker.")
        }
        return result
    }

    static func decodeEvent(_ data: Data) throws -> WorkerEvent {
        guard data.count <= maximumIPCBytes, let event = try? JSONDecoder().decode(WorkerEvent.self, from: data) else {
            throw WorkerFailure("Messaggio del runtime non valido.")
        }
        switch event.type {
        case "credential":
            guard let id = event.id, validPairID(id), let wallet = event.wallet, isWallet(wallet),
                  let token = event.workerToken, token.utf8.count <= 2048 else { throw WorkerFailure("Credenziale del runtime non valida.") }
        case "status":
            guard let state = event.state, ["starting", "ready", "working", "paused", "error"].contains(state),
                  let message = event.message, message.count <= 4000 else { throw WorkerFailure("Stato del runtime non valido.") }
        case "log":
            guard let message = event.message, message.count <= 4000 else { throw WorkerFailure("Messaggio del runtime non valido.") }
        case "receipt":
            guard let id = event.jobId, !id.isEmpty, id.count <= 200,
                  let status = event.status, ["completed", "failed"].contains(status),
                  event.currency == "FORNAI_CREDIT", let reward = event.rewardCredits, validCredit(reward) else {
                throw WorkerFailure("Ricevuta del runtime non valida.")
            }
        default: throw WorkerFailure("Messaggio del runtime non riconosciuto.")
        }
        return event
    }

    static func childEnvironment(_ config: WorkerConfiguration, statePath: String, home: String, temporary: String) -> [String: String] {
        // A fresh dictionary: no inherited TLS overrides, Node injection options,
        // proxy settings, DYLD variables, server credentials or .env path.
        ["HOME": home, "TMPDIR": temporary, "LANG": "en_US.UTF-8", "NODE_OPTIONS": "--use-system-ca",
         "FORNAI_API_URL": origin, "FORNAI_WORKER_TOKEN": config.workerToken,
         "FORNAI_WORKER_WALLET": config.wallet, "FORNAI_WORKER_NAME": config.workerName,
         "FORNAI_WORKER_STATE_DIR": statePath, "FORNAI_WORKER_ENV_FILE": "",
         "FORNAI_WORKER_INTERVAL_MS": "15000", "FORNAI_LEASE_RENEW_MS": "30000",
         "FORNAI_REQUEST_TIMEOUT_MS": "15000", "FORNAI_INFERENCE_TIMEOUT_MS": "180000",
         "FREELLMAPI_BASE_URL": config.apiBase, "FREELLMAPI_API_KEY": config.apiKey,
         "FREELLMAPI_MODEL": config.model, "FREELLMAPI_MAX_TOKENS": "4096"]
    }
}

struct WorkerLineDecoder {
    private var pending = Data()
    mutating func append(_ data: Data) throws -> [WorkerEvent] {
        var events: [WorkerEvent] = []
        for byte in data {
            if byte == 10 {
                if pending.last == 13 { pending.removeLast() }
                if !pending.isEmpty { events.append(try WorkerPolicy.decodeEvent(pending)) }
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < WorkerPolicy.maximumIPCBytes else { throw WorkerFailure("Messaggio del runtime troppo grande.") }
                pending.append(byte)
            }
        }
        return events
    }
    mutating func finish() throws {
        guard pending.isEmpty else { throw WorkerFailure("Messaggio del runtime interrotto.") }
    }
}
