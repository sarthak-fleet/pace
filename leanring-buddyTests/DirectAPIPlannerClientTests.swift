//
//  DirectAPIPlannerClientTests.swift
//  leanring-buddyTests
//
//  Integration tests for DirectAPIPlannerClient against the stdlib fixture
//  server at scripts/direct-api-fixture-server.py.
//

import Foundation
import Testing

@testable import Pace

// MARK: - Fixture helpers

private enum DirectAPIFixture {
    static let fixtureScriptPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts")
        .appendingPathComponent("direct-api-fixture-server.py")
        .path

    static let pythonThreeExecutablePath: String? = [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3"
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static var isFixtureRunnable: Bool {
        pythonThreeExecutablePath != nil
            && FileManager.default.fileExists(atPath: fixtureScriptPath)
    }

    static func findAvailablePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return 19877 }
        defer { Darwin.close(socket) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafeMutablePointer(to: &addr) { addrPointer in
            addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 19877 }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { addrPointer in
            addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                _ = Darwin.getsockname(socket, sockaddrPointer, &addrLen)
            }
        }
        return Int(CFSwapInt16BigToHost(boundAddr.sin_port))
    }

    static func startFixtureServer(on port: Int, python: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [fixtureScriptPath, String(port)]

        let readyPipe = Pipe()
        process.standardOutput = readyPipe

        try process.run()

        let fileHandle = readyPipe.fileHandleForReading
        var buffer = Data()
        while !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = fileHandle.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.02) }
            buffer.append(chunk)
        }
        return process
    }

    /// Saves an API key under the given provider before the test and
    /// guarantees it gets wiped after — so DirectAPIPlannerClient can
    /// load a real-looking key from PaceKeychainStore without dirtying
    /// the developer's Pace keychain.
    @MainActor
    static func withStoredTestKey(
        for provider: PaceDirectAPIProvider,
        value: String,
        body: () async throws -> Void
    ) async rethrows {
        _ = PaceKeychainStore.storeAPIKey(value, for: provider)
        do {
            try await body()
            _ = PaceKeychainStore.deleteAPIKey(for: provider)
        } catch {
            _ = PaceKeychainStore.deleteAPIKey(for: provider)
            throw error
        }
    }
}

// MARK: - Integration tests

@MainActor
struct DirectAPIPlannerClientTests {

    @Test(.enabled(if: DirectAPIFixture.isFixtureRunnable))
    func happyPathStreamsAccumulatedContentFromOpenAIShape() async throws {
        guard let python = DirectAPIFixture.pythonThreeExecutablePath else { return }
        let fixturePort = DirectAPIFixture.findAvailablePort()
        let fixtureProcess = try DirectAPIFixture.startFixtureServer(on: fixturePort, python: python)
        defer { fixtureProcess.terminate() }

        try await DirectAPIFixture.withStoredTestKey(for: .openai, value: "sk-test-happy") {
            let endpointURL = URL(string: "http://127.0.0.1:\(fixturePort)/v1/chat/completions")!
            let directAPIClient = DirectAPIPlannerClient(
                provider: .openai,
                endpointURL: endpointURL,
                modelIdentifier: "gpt-4o-mini"
            )

            var receivedChunkSnapshots: [String] = []
            let (finalText, _) = try await directAPIClient.generateResponseStreaming(
                images: [],
                systemPrompt: "You are a test.",
                conversationHistory: [],
                userPrompt: "Hello",
                onTextChunk: { accumulatedSnapshot in
                    receivedChunkSnapshots.append(accumulatedSnapshot)
                }
            )

            #expect(finalText == "Hello world from the fixture")
            #expect(receivedChunkSnapshots.count >= 2)
        }
    }

    @Test(.enabled(if: DirectAPIFixture.isFixtureRunnable))
    func missingAPIKeyThrowsBeforeFiringRequest() async throws {
        guard let python = DirectAPIFixture.pythonThreeExecutablePath else { return }
        let fixturePort = DirectAPIFixture.findAvailablePort()
        let fixtureProcess = try DirectAPIFixture.startFixtureServer(on: fixturePort, python: python)
        defer { fixtureProcess.terminate() }

        // Guarantee no key is stored — the client should refuse to fire.
        _ = PaceKeychainStore.deleteAPIKey(for: .anthropic)
        defer { _ = PaceKeychainStore.deleteAPIKey(for: .anthropic) }

        let endpointURL = URL(string: "http://127.0.0.1:\(fixturePort)/v1/chat/completions")!
        let directAPIClient = DirectAPIPlannerClient(
            provider: .anthropic,
            endpointURL: endpointURL,
            modelIdentifier: "claude-sonnet-4-5"
        )

        do {
            _ = try await directAPIClient.generateResponseStreaming(
                images: [],
                systemPrompt: "x",
                conversationHistory: [],
                userPrompt: "y",
                onTextChunk: { _ in }
            )
            #expect(Bool(false), "expected throw")
        } catch let directAPIError as PaceDirectAPIError {
            switch directAPIError {
            case .missingAPIKey(let provider):
                #expect(provider == .anthropic)
            default:
                #expect(Bool(false), "expected .missingAPIKey, got \(directAPIError)")
            }
        }
    }

    @Test(.enabled(if: DirectAPIFixture.isFixtureRunnable))
    func fixtureServerReturnsHTTP401WhenTriggered() async throws {
        // Direct probe of the fixture's 401 path so the contract stays
        // honest. The DirectAPIPlannerClient itself can't fire this path
        // because the trigger lives in the request body — but we can
        // confirm the fixture matches the upstream 401 shape the
        // client's error-mapping branch is designed against.
        guard let python = DirectAPIFixture.pythonThreeExecutablePath else { return }
        let fixturePort = DirectAPIFixture.findAvailablePort()
        let fixtureProcess = try DirectAPIFixture.startFixtureServer(on: fixturePort, python: python)
        defer { fixtureProcess.terminate() }

        let endpointURL = URL(string: "http://127.0.0.1:\(fixturePort)/v1/chat/completions")!
        var probeRequest = URLRequest(url: endpointURL)
        probeRequest.httpMethod = "POST"
        probeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probeRequest.httpBody = try JSONSerialization.data(
            withJSONObject: ["trigger_error": "invalid_key"]
        )
        let (_, response) = try await URLSession.shared.data(for: probeRequest)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)
    }

    // MARK: - Pure error-mapping tests (no network)

    @Test
    func missingKeyErrorIsLocalizable() {
        let missingKeyError = PaceDirectAPIError.missingAPIKey(provider: .anthropic)
        #expect(missingKeyError.errorDescription != nil)
        #expect(missingKeyError.errorDescription!.contains("Anthropic"))
    }

    @Test
    func invalidAPIKeyErrorIsLocalizableAndIdentifiesProvider() {
        let invalidKeyError = PaceDirectAPIError.invalidAPIKey(provider: .openai)
        #expect(invalidKeyError.errorDescription != nil)
        #expect(invalidKeyError.errorDescription!.contains("OpenAI"))
        #expect(invalidKeyError.errorDescription!.contains("401"))
    }

    @Test
    func httpErrorIncludesVerbatimUpstreamBodyExcerpt() {
        let upstreamBodyExcerpt = "{\"error\":{\"message\":\"model 'foo' does not exist\"}}"
        let httpError = PaceDirectAPIError.httpError(statusCode: 400, bodyExcerpt: upstreamBodyExcerpt)
        #expect(httpError.errorDescription != nil)
        #expect(httpError.errorDescription!.contains("400"))
        #expect(httpError.errorDescription!.contains("model 'foo' does not exist"))
    }
}

// MARK: - Header / request shape tests

struct DirectAPIPlannerClientHeaderTests {

    @Test
    func anthropicRequestUsesXAPIKeyAndAnthropicVersionHeaders() throws {
        let endpointURL = URL(string: "https://api.anthropic.com/v1/chat/completions")!
        let request = try DirectAPIPlannerClient.makeRequest(
            provider: .anthropic,
            endpointURL: endpointURL,
            modelIdentifier: "claude-sonnet-4-5",
            apiKey: "sk-ant-test",
            systemPrompt: "be brief",
            userPrompt: "hi"
        )
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func openaiRequestUsesAuthorizationBearerHeader() throws {
        let endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        let request = try DirectAPIPlannerClient.makeRequest(
            provider: .openai,
            endpointURL: endpointURL,
            modelIdentifier: "gpt-4o-mini",
            apiKey: "sk-test-openai",
            systemPrompt: "be brief",
            userPrompt: "hi"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-openai")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == nil)
    }

    @Test
    func openrouterRequestUsesAuthorizationBearerHeader() throws {
        let endpointURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        let request = try DirectAPIPlannerClient.makeRequest(
            provider: .openrouter,
            endpointURL: endpointURL,
            modelIdentifier: "anthropic/claude-sonnet-4",
            apiKey: "sk-or-test",
            systemPrompt: "be brief",
            userPrompt: "hi"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test
    func customProviderRequestUsesAuthorizationBearerHeader() throws {
        let endpointURL = URL(string: "https://my-proxy.example.com/v1/chat/completions")!
        let request = try DirectAPIPlannerClient.makeRequest(
            provider: .custom,
            endpointURL: endpointURL,
            modelIdentifier: "custom-model",
            apiKey: "sk-custom-test",
            systemPrompt: "be brief",
            userPrompt: "hi"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-custom-test")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test
    func requestBodyIncludesTheSystemAndUserMessages() throws {
        let endpointURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        let request = try DirectAPIPlannerClient.makeRequest(
            provider: .openai,
            endpointURL: endpointURL,
            modelIdentifier: "gpt-4o-mini",
            apiKey: "sk-test",
            systemPrompt: "you are helpful",
            userPrompt: "what time is it?"
        )
        let bodyJSON = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        #expect(bodyJSON?["model"] as? String == "gpt-4o-mini")
        #expect(bodyJSON?["stream"] as? Bool == true)
        let messages = bodyJSON?["messages"] as? [[String: Any]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] as? String == "system")
        #expect(messages?[0]["content"] as? String == "you are helpful")
        #expect(messages?[1]["role"] as? String == "user")
        #expect(messages?[1]["content"] as? String == "what time is it?")
    }
}
