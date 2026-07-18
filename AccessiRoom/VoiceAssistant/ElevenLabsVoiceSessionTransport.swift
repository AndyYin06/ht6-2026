import Combine
import ElevenLabs
import Foundation

struct ElevenLabsBackendConfiguration: Sendable {
    static let protocolVersion = 1
    static let capabilities = ["getRequirementEvidence", "focus", "clearFocus"]

    let baseURL: URL

    init?(bundle: Bundle) {
        guard let rawValue = bundle.object(forInfoDictionaryKey: "ELEVENLABS_BACKEND_BASE_URL") as? String,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rawValue.contains("$("),
              let url = URL(string: rawValue) else {
            return nil
        }
        baseURL = url
    }

    init(baseURL: URL) {
        self.baseURL = baseURL
    }
}

private struct BackendSessionRequest: Codable {
    let protocolVersion: Int
    let capabilities: [String]
}

private struct BackendSessionResponse: Codable {
    let protocolVersion: Int
    let conversationToken: String
}

private struct BackendErrorResponse: Decodable {
    let message: String
}

private struct ElevenLabsBackendClient: Sendable {
    let configuration: ElevenLabsBackendConfiguration
    let session: URLSession

    init(
        configuration: ElevenLabsBackendConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    func createSession() async throws -> String {
        let endpoint = configuration.baseURL
            .appending(path: "v1", directoryHint: .isDirectory)
            .appending(path: "voice", directoryHint: .isDirectory)
            .appending(path: "sessions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(BackendSessionRequest(
            protocolVersion: ElevenLabsBackendConfiguration.protocolVersion,
            capabilities: ElevenLabsBackendConfiguration.capabilities
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionTransportError.invalidBackendResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let backendError = try? JSONDecoder().decode(BackendErrorResponse.self, from: data) {
                throw VoiceSessionTransportError.invalidToolParameters(backendError.message)
            }
            throw VoiceSessionTransportError.invalidBackendResponse
        }

        let payload = try JSONDecoder().decode(BackendSessionResponse.self, from: data)
        guard payload.protocolVersion == ElevenLabsBackendConfiguration.protocolVersion,
              !payload.conversationToken.isEmpty else {
            throw VoiceSessionTransportError.invalidBackendResponse
        }
        return payload.conversationToken
    }
}

@MainActor
final class ElevenLabsVoiceSessionTransport: VoiceSessionTransport {
    var eventHandler: ((VoiceTransportEvent) -> Void)?

    private let backend: ElevenLabsBackendClient
    private var conversation: Conversation?
    private var cancellables: Set<AnyCancellable> = []
    private var isStopping = false

    init(configuration: ElevenLabsBackendConfiguration, session: URLSession = .shared) {
        backend = ElevenLabsBackendClient(configuration: configuration, session: session)
    }

    func start() async throws {
        isStopping = false
        let token = try await backend.createSession()
        let config = ConversationConfig(
            conversationOverrides: ConversationOverrides(
                textOnly: false,
                clientEvents: ["user_transcript", "agent_response"]
            ),
            onDisconnect: { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isStopping else { return }
                    self.eventHandler?(.disconnected)
                }
            },
            onAgentResponse: { [weak self] text, _ in
                Task { @MainActor in self?.eventHandler?(.agentResponse(text)) }
            },
            onUserTranscript: { [weak self] text, _ in
                Task { @MainActor in self?.eventHandler?(.userTranscript(text)) }
            },
            onUnhandledClientToolCall: { [weak self] toolCall in
                Task { @MainActor in self?.receive(toolCall) }
            }
        )

        let conversation = try await ElevenLabs.startConversation(
            conversationToken: token,
            config: config
        )
        self.conversation = conversation
        observe(conversation)
    }

    func stop() async {
        isStopping = true
        cancellables.removeAll()
        await conversation?.endConversation()
        conversation = nil
    }

    func sendToolResult(_ result: VoiceToolResult, for call: VoiceToolCall) async throws {
        guard let conversation else { throw VoiceSessionTransportError.invalidBackendResponse }
        let object = try JSONSerialization.jsonObject(with: result.data)
        try await conversation.sendToolResult(for: call.id, result: object, isError: result.isError)
    }

    private func observe(_ conversation: Conversation) {
        conversation.$agentState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .listening: eventHandler?(.phase(.listening))
                case .thinking: eventHandler?(.phase(.thinking))
                case .speaking: eventHandler?(.phase(.speaking))
                }
            }
            .store(in: &cancellables)
    }

    private func receive(_ toolCall: ClientToolCallEvent) {
        do {
            let parameters = try toolCall.getParameters()
            let data = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
            eventHandler?(.toolCall(VoiceToolCall(
                id: toolCall.toolCallId,
                name: toolCall.toolName,
                parameters: data,
                expectsResponse: true
            )))
        } catch {
            let result = VoiceToolResult(
                data: Data("{\"kind\":\"refused\",\"message\":\"Malformed client-tool parameters were rejected.\"}".utf8),
                isError: true
            )
            let call = VoiceToolCall(
                id: toolCall.toolCallId,
                name: toolCall.toolName,
                parameters: Data("{}".utf8),
                expectsResponse: true
            )
            Task { try? await sendToolResult(result, for: call) }
        }
    }
}
