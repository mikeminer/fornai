// Copyright (c) 2026 mikeminer. All rights reserved.
// SPDX-License-Identifier: LicenseRef-Fornai-Proprietary

import Foundation
import Darwin

@main struct PolicyTests {
    static var passed = 0
    static var failed = 0
    static let wallet = "11111111111111111111111111111111"
    static let otherWallet = "So11111111111111111111111111111111111111112"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func require(_ condition: @autoclosure () throws -> Bool) throws {
        if try condition() == false { throw WorkerFailure("assertion failed") }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw WorkerFailure("expected rejection")
    }
    static func test(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS " + name) }
        catch { failed += 1; print("FAIL " + name) } // Never print payloads or tokens.
    }
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func token(owner: String = wallet, issued: Date = now, expiry: Date = now.addingTimeInterval(7 * 86400), scope: String = "worker", version: Int = 2) throws -> String {
        let claims = WorkerTokenClaims(version: version, id: "12345678-1234-4123-8123-123456789abc", address: owner, scope: scope, createdAt: iso(issued), expiresAt: iso(expiry))
        return encode(try JSONEncoder().encode(claims)) + "." + encode(Data(repeating: 17, count: 32))
    }
    static func pair(url: String? = nil, secret: String = encode(Data(repeating: 2, count: 32)), code: String = "ABCD-EF23", expiry: Date = now.addingTimeInterval(600)) -> WorkerPairStart {
        let id = "12345678-1234-4123-8123-123456789abc"
        return WorkerPairStart(pairId: id, deviceSecret: secret, displayCode: code, expiresAt: iso(expiry), verificationUrl: url ?? WorkerPolicy.origin + "/worker/connect?pair=" + id, pollIntervalSeconds: 3)
    }
    static func main() {
        test("base58 wallets decode to exactly 32 bytes") {
            try require(WorkerPolicy.isWallet(wallet)); try require(WorkerPolicy.isWallet(otherWallet))
            for bad in ["", "0" + String(wallet.dropFirst()), String(repeating: "1", count: 31), String(repeating: "1", count: 33), String(repeating: "z", count: 44), wallet + " ", "../../secret"] {
                try require(!WorkerPolicy.isWallet(bad))
            }
        }
        test("local API accepts only HTTP loopback and literal v1") {
            for good in ["http://127.0.0.1:31415/v1", "http://localhost:31415/v1/", "http://[::1]:31415/v1"] {
                _ = try WorkerPolicy.localAPI(good)
            }
            for bad in ["https://127.0.0.1/v1", "http://example.com/v1", "http://localhost.evil/v1", "http://127.0.0.1@evil/v1", "http://user:password@localhost/v1", "http://localhost/v1?secret=1", "http://localhost/v1#x", "http://localhost/%76%31", "http://localhost/v1/../x", "http://localhost:65536/v1", "file:///v1"] {
                try rejects { _ = try WorkerPolicy.localAPI(bad) }
            }
        }
        test("worker token is owner scoped and time bounded") {
            let current = try token()
            try require(WorkerPolicy.token(current, wallet: wallet, now: now)?.scope == "worker")
            try require(WorkerPolicy.token(current, wallet: otherWallet, now: now) == nil)
            for invalid in [try token(scope: "session"), try token(version: 1), try token(issued: now.addingTimeInterval(60)), try token(expiry: now), try token(expiry: now.addingTimeInterval(7 * 86400 + 1))] {
                try require(WorkerPolicy.token(invalid, wallet: wallet, now: now) == nil)
            }
            try require(WorkerPolicy.token(current + ".extra", wallet: wallet, now: now) == nil)
            try require(WorkerPolicy.token(String(current.dropLast(5)), wallet: wallet, now: now) == nil)
        }
        test("wallet casing is never normalized by token checks") {
            let current = try token(owner: otherWallet)
            try require(WorkerPolicy.token(current, wallet: otherWallet.lowercased(), now: now) == nil)
        }
        test("pair URL is exact origin path UUID and TTL") {
            try require(try WorkerPolicy.pairingURL(pair(), now: now).host == "fornai.dev")
            for url in ["http://fornai.dev/worker/connect?pair=" + pair().pairId, "https://fornai.dev.evil/worker/connect?pair=" + pair().pairId, pair().verificationUrl + "&next=https://evil", pair().verificationUrl + "#x"] {
                try rejects { _ = try WorkerPolicy.pairingURL(pair(url: url), now: now) }
            }
            try rejects { _ = try WorkerPolicy.pairingURL(pair(expiry: now), now: now) }
            try rejects { _ = try WorkerPolicy.pairingURL(pair(expiry: now.addingTimeInterval(631)), now: now) }
            try rejects { _ = try WorkerPolicy.pairingURL(pair(secret: "bad"), now: now) }
            try rejects { _ = try WorkerPolicy.pairingURL(pair(code: "0000-OOOO"), now: now) }
        }
        test("credits remain integer strings without precision loss") {
            let large = "900719925474099312345678901234567890"
            try require(WorkerPolicy.validCredit(large)); try require(WorkerPolicy.validCredit("0"))
            for bad in ["-1", "+1", "1.0", "01", "1e3", " 1", "1\n", String(repeating: "9", count: 61)] { try require(!WorkerPolicy.validCredit(bad)) }
            let policy = WorkerCreditPolicy(unit: "FORNAI_CREDIT", jobCost: "1", workerReward: "1")
            let account = WorkerAccount(protocolVersion: 2, wallet: wallet, creditBalance: large, workerEarnedCredits: large, creditPolicy: policy, networkAuthorized: false)
            try WorkerPolicy.validateAccount(account, wallet: wallet)
            try rejects { try WorkerPolicy.validateAccount(account, wallet: otherWallet) }
            try require(account.creditBalance == large)
        }
        test("PASTA or numeric balances cannot masquerade as internal credits") {
            let wrong = WorkerAccount(protocolVersion: 2, wallet: wallet, creditBalance: "1000000", workerEarnedCredits: "0", creditPolicy: WorkerCreditPolicy(unit: "PASTA", jobCost: "1", workerReward: "1"), networkAuthorized: true)
            try rejects { try WorkerPolicy.validateAccount(wrong, wallet: wallet) }
            let numeric = Data("{\"protocolVersion\":2,\"wallet\":\"\(wallet)\",\"creditBalance\":1,\"workerEarnedCredits\":\"0\",\"creditPolicy\":{\"unit\":\"FORNAI_CREDIT\",\"jobCost\":\"1\",\"workerReward\":\"1\"},\"networkAuthorized\":true}".utf8)
            try rejects { _ = try JSONDecoder().decode(WorkerAccount.self, from: numeric) }
        }
        test("IPC decoder handles fragmented UTF8 and multiple lines") {
            var decoder = WorkerLineDecoder()
            let packet = Data("{\"type\":\"log\",\"message\":\"Pronto è collegato\"}\r\n{\"type\":\"status\",\"state\":\"ready\",\"message\":\"Pronto\"}\n".utf8)
            var messages: [WorkerEvent] = []
            for byte in packet { messages += try decoder.append(Data([byte])) }
            try decoder.finish(); try require(messages.count == 2); try require(messages[0].message == "Pronto è collegato")
        }
        test("IPC bounds apply before newline and truncated messages are rejected") {
            var decoder = WorkerLineDecoder()
            try rejects { _ = try decoder.append(Data(repeating: 65, count: WorkerPolicy.maximumIPCBytes + 1)) }
            var partial = WorkerLineDecoder()
            _ = try partial.append(Data("{\"type\":\"log\"".utf8))
            try rejects { try partial.finish() }
            try rejects { _ = try WorkerPolicy.decodeEvent(Data("{\"type\":\"shell\",\"command\":\"anything\"}".utf8)) }
        }
        test("credential IPC does not require a nonexistent expiresAt field") {
            let body: [String: String] = ["type": "credential", "id": pair().pairId, "workerToken": try token(), "wallet": wallet]
            let event = try WorkerPolicy.decodeEvent(JSONSerialization.data(withJSONObject: body))
            try require(event.type == "credential"); try require(event.wallet == wallet)
            let claims = WorkerPolicy.token(event.workerToken!, wallet: wallet, now: now)
            try require(claims?.expiresAt == iso(now.addingTimeInterval(7 * 86400)))
        }
        test("receipts validate reward unit and amount") {
            let good = Data("{\"type\":\"receipt\",\"jobId\":\"job_fixture\",\"status\":\"completed\",\"currency\":\"FORNAI_CREDIT\",\"rewardCredits\":\"1\"}".utf8)
            try require(try WorkerPolicy.decodeEvent(good).rewardCredits == "1")
            try rejects { _ = try WorkerPolicy.decodeEvent(Data(String(data: good, encoding: .utf8)!.replacingOccurrences(of: "FORNAI_CREDIT", with: "PASTA").utf8)) }
        }
        test("configuration blocks unsafe worker directory names") {
            var config = WorkerConfiguration(); config.wallet = wallet; config.apiKey = "fixture-key"
            _ = try WorkerPolicy.configuration(config, requirePair: false)
            for name in [".", "..", "a/b", "a\\b", "worker\nother", "worker\n"] {
                config.workerName = name; try rejects { _ = try WorkerPolicy.configuration(config, requirePair: false) }
            }
            config.workerName = "mac-book"; config.workerToken = "invalid"
            try rejects { _ = try WorkerPolicy.configuration(config, requirePair: true) }
        }
        test("child environment is explicit and cannot inherit TLS or injection settings") {
            var config = WorkerConfiguration(); config.wallet = wallet; config.apiKey = "fixture-local"; config.workerToken = "fixture-worker"
            let values = WorkerPolicy.childEnvironment(config, statePath: "/private/state", home: "/Users/test", temporary: "/tmp")
            try require(values["FORNAI_API_URL"] == "https://fornai.dev")
            try require(values["NODE_OPTIONS"] == "--use-system-ca")
            for key in ["NODE_TLS_REJECT_UNAUTHORIZED", "NODE_EXTRA_CA_CERTS", "NODE_PATH", "DYLD_INSERT_LIBRARIES", "DATABASE_URL", "HTTPS_PROXY", "FORNAI_SESSION_SECRET"] { try require(values[key] == nil) }
            try require(values["FORNAI_WORKER_ENV_FILE"] == "")
            try require(values["FORNAI_AGENT_WEB_SEARCH"] == "0")
            try require(values["FORNAI_AGENT_SEARCH_ENGINE"] == "tavily-search")
            try require(values["FORNAI_AGENT_MAX_STEPS"] == "6")
            try require(values["FORNAI_AGENT_MAX_SEARCHES"] == "2")
        }
        test("legacy Keychain configuration preserves credentials with research disabled") {
            let old = Data("""
                {"apiBase":"http://127.0.0.1:31415/v1","apiKey":"fixture-local","wallet":"\(wallet)","workerName":"existing-mac","model":"existing-model","workerToken":"fixture-worker","tokenWallet":"\(wallet)","autoStart":true,"runAtLogin":true,"saved":true}
                """.utf8)
            let config = try JSONDecoder().decode(WorkerConfiguration.self, from: old)
            try WorkerPolicy.agentSettings(config)
            try require(config.apiKey == "fixture-local" && config.workerToken == "fixture-worker")
            try require(config.wallet == wallet && config.tokenWallet == wallet)
            try require(config.workerName == "existing-mac" && config.model == "existing-model")
            try require(config.autoStart && config.runAtLogin && config.saved)
            try require(!config.webSearchEnabled && config.searchEngine == "tavily-search")
            try require(config.agentMaxSteps == 6 && config.agentMaxSearches == 2)
        }
        test("research settings survive Codable and map only to fixed environment names") {
            var config = WorkerConfiguration()
            config.webSearchEnabled = true; config.searchEngine = "exa-search"
            config.agentMaxSteps = 8; config.agentMaxSearches = 5
            let restored = try JSONDecoder().decode(WorkerConfiguration.self, from: JSONEncoder().encode(config))
            try WorkerPolicy.agentSettings(restored)
            let values = WorkerPolicy.childEnvironment(restored, statePath: "/private/state", home: "/Users/test", temporary: "/tmp")
            try require(values["FORNAI_AGENT_WEB_SEARCH"] == "1")
            try require(values["FORNAI_AGENT_SEARCH_ENGINE"] == "exa-search")
            try require(values["FORNAI_AGENT_MAX_STEPS"] == "8")
            try require(values["FORNAI_AGENT_MAX_SEARCHES"] == "5")
            try require(Set(values.keys.filter { $0.hasPrefix("FORNAI_AGENT_") }) == Set(["FORNAI_AGENT_WEB_SEARCH", "FORNAI_AGENT_SEARCH_ENGINE", "FORNAI_AGENT_MAX_STEPS", "FORNAI_AGENT_MAX_SEARCHES"]))
        }
        test("research engines cannot select automatic paid fallback or arbitrary endpoints") {
            var config = WorkerConfiguration()
            for engine in ["tavily-search", "exa-search", "firecrawl-search"] {
                config.searchEngine = engine; try WorkerPolicy.agentSettings(config)
            }
            for engine in ["", "auto", "linkup-search", "https://example.com/search", "TAVILY-SEARCH", "tavily-search\n"] {
                config.searchEngine = engine
                try rejects { try WorkerPolicy.agentSettings(config) }
            }
        }
        test("research budgets reject out of range even when research is disabled") {
            var config = WorkerConfiguration()
            config.agentMaxSteps = 2; config.agentMaxSearches = 1
            try WorkerPolicy.agentSettings(config)
            for steps in [Int.min, 0, 1, 9, Int.max] {
                config.agentMaxSteps = steps
                try rejects { try WorkerPolicy.agentSettings(config) }
            }
            config.agentMaxSteps = 4
            for searches in [Int.min, 0, 6, Int.max] {
                config.agentMaxSearches = searches
                try rejects { try WorkerPolicy.agentSettings(config) }
            }
        }
        test("first launch keeps login and work disabled") {
            let config = WorkerConfiguration()
            try require(!config.autoStart && !config.runAtLogin && !config.saved && config.workerToken.isEmpty)
            try require(!config.webSearchEnabled && config.searchEngine == "tavily-search" && config.agentMaxSteps == 6 && config.agentMaxSearches == 2)
        }
        test("auto uses an actual advertised model instead of assuming an alias exists") {
            try require(try WorkerPolicy.automaticModel(["auto", "other"]) == "auto")
            try require(try WorkerPolicy.automaticModel(["first", "openai/gpt-oss-120b"]) == "openai/gpt-oss-120b")
            try require(try WorkerPolicy.automaticModel(["actual-model"]) == "actual-model")
            try rejects { _ = try WorkerPolicy.automaticModel([]) }
        }
        print("\(passed) passed, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
