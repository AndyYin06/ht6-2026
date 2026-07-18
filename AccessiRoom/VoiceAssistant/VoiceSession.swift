import Combine
import Foundation

enum VoiceSupportedSurface: String, Equatable, Sendable {
    case roomSetup
    case assessment
    case proposedArrangement
    case arrangementComparison

    var title: String {
        switch self {
        case .roomSetup: "Room Setup"
        case .assessment: "Assessment"
        case .proposedArrangement: "Proposed Arrangement"
        case .arrangementComparison: "Arrangement Comparison"
        }
    }
}

enum VoiceSessionPhase: Equatable, Sendable {
    case inactive
    case permissionRequired
    case connecting
    case listening
    case thinking
    case speaking
    case awaitingConfirmation
    case executing
    case recoverableError
    case ended

    var title: String {
        switch self {
        case .inactive, .ended: "Voice inactive"
        case .permissionRequired: "Permission required"
        case .connecting: "Connecting"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .awaitingConfirmation: "Awaiting confirmation"
        case .executing: "Applying confirmed action"
        case .recoverableError: "Voice unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .inactive, .ended: "mic"
        case .permissionRequired: "hand.raised.fill"
        case .connecting, .thinking, .executing: "ellipsis.circle"
        case .listening: "mic.fill"
        case .speaking: "speaker.wave.2.fill"
        case .awaitingConfirmation: "checkmark.circle"
        case .recoverableError: "exclamationmark.triangle.fill"
        }
    }

    var isSessionActive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking, .awaitingConfirmation, .executing: true
        case .inactive, .permissionRequired, .recoverableError, .ended: false
        }
    }
}

struct VoiceTranscriptEntry: Identifiable, Equatable, Sendable {
    enum Speaker: Equatable, Sendable {
        case user
        case assistant

        var title: String {
            switch self {
            case .user: "You"
            case .assistant: "AccessiRoom Guide"
            }
        }
    }

    let id: UUID
    let speaker: Speaker
    let text: String

    init(id: UUID = UUID(), speaker: Speaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

struct VoiceToolCall: Sendable {
    let id: String
    let name: String
    let parameters: Data
    let expectsResponse: Bool
}

struct VoiceToolResult: Sendable {
    let data: Data
    let isError: Bool
}

enum VoiceTransportEvent: Sendable {
    case phase(VoiceSessionPhase)
    case userTranscript(String)
    case agentResponse(String)
    case toolCall(VoiceToolCall)
    case disconnected
}

@MainActor
protocol VoiceSessionTransport: AnyObject {
    var eventHandler: ((VoiceTransportEvent) -> Void)? { get set }
    func start() async throws
    func stop() async
    func sendToolResult(_ result: VoiceToolResult, for call: VoiceToolCall) async throws
}

enum VoiceSessionTransportError: LocalizedError, Equatable {
    case backendNotConfigured
    case invalidBackendResponse
    case unsupportedTool(String)
    case invalidToolParameters(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            "The ElevenLabs backend is not configured yet. Your room and assessment remain available."
        case .invalidBackendResponse:
            "The voice backend returned an invalid session response. Your room and assessment remain available."
        case let .unsupportedTool(name):
            "The ElevenLabs agent requested the unsupported tool \(name)."
        case let .invalidToolParameters(message):
            message
        }
    }
}

@MainActor
final class UnavailableVoiceSessionTransport: VoiceSessionTransport {
    var eventHandler: ((VoiceTransportEvent) -> Void)?

    func start() async throws { throw VoiceSessionTransportError.backendNotConfigured }
    func stop() async {}
    func sendToolResult(_ result: VoiceToolResult, for call: VoiceToolCall) async throws {}
}

@MainActor
final class VoiceSession: ObservableObject {
    @Published private(set) var phase: VoiceSessionPhase = .inactive
    @Published private(set) var transcript: [VoiceTranscriptEntry] = []
    @Published private(set) var currentSurface: VoiceSupportedSurface?
    @Published private(set) var errorMessage: String?
    @Published private(set) var clarification: RequirementClarification?
    @Published var isExpanded = false
    @Published var isDisclosurePresented = false

    private let transport: any VoiceSessionTransport
    private var connectionAttemptID: UUID?
    private var inFlightToolTask: Task<Void, Never>?
    private var gateway: (any AgentGateway)?
    private var focusHandler: ((RequirementFocusResponse) -> Void)?

    init(transport: any VoiceSessionTransport = UnavailableVoiceSessionTransport()) {
        self.transport = transport
        transport.eventHandler = { [weak self] event in self?.receive(event) }
    }

    static func live(bundle: Bundle = .main) -> VoiceSession {
        guard let configuration = ElevenLabsBackendConfiguration(bundle: bundle) else {
            return VoiceSession()
        }
        return VoiceSession(transport: ElevenLabsVoiceSessionTransport(configuration: configuration))
    }

    func installGateway(
        _ gateway: any AgentGateway,
        focusHandler: @escaping (RequirementFocusResponse) -> Void
    ) {
        self.gateway = gateway
        self.focusHandler = focusHandler
    }

    func enter(_ surface: VoiceSupportedSurface) { currentSurface = surface }

    func requestStart() {
        guard !phase.isSessionActive else {
            isExpanded = true
            return
        }
        phase = .permissionRequired
        isDisclosurePresented = true
    }

    func cancelDisclosure() {
        isDisclosurePresented = false
        if phase == .permissionRequired { phase = .inactive }
    }

    func startAfterDisclosure() async {
        guard phase == .permissionRequired, isDisclosurePresented else { return }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        isDisclosurePresented = false
        errorMessage = nil
        phase = .connecting
        isExpanded = true

        do {
            try await transport.start()
            guard connectionAttemptID == attemptID else {
                await transport.stop()
                return
            }
            phase = .listening
        } catch {
            guard connectionAttemptID == attemptID else { return }
            errorMessage = error.localizedDescription
            phase = .recoverableError
        }
    }

    func stop() async {
        isDisclosurePresented = false
        connectionAttemptID = nil
        inFlightToolTask?.cancel()
        inFlightToolTask = nil
        await transport.stop()
        transcript.removeAll()
        clarification = nil
        errorMessage = nil
        phase = .ended
        isExpanded = false
    }

    func appendTranscript(speaker: VoiceTranscriptEntry.Speaker, text: String) {
        guard phase.isSessionActive else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(VoiceTranscriptEntry(speaker: speaker, text: trimmed))
    }

    func updatePhase(_ newPhase: VoiceSessionPhase) {
        guard phase.isSessionActive, newPhase.isSessionActive else { return }
        phase = newPhase
    }

    func chooseCandidate(_ candidate: RequirementCandidate) {
        guard let gateway else { return }
        let request = RequirementFocusRequest(reference: .selectedRequirement(id: candidate.id))
        let response = gateway.focusRequirement(request)
        focusHandler?(response)
        clarification = nil
    }

    private func receive(_ event: VoiceTransportEvent) {
        switch event {
        case let .phase(newPhase):
            updatePhase(newPhase)
        case let .userTranscript(text):
            appendTranscript(speaker: .user, text: text)
            updatePhase(.thinking)
        case let .agentResponse(text):
            appendTranscript(speaker: .assistant, text: text)
        case let .toolCall(call):
            execute(call)
        case .disconnected:
            connectionAttemptID = nil
            inFlightToolTask?.cancel()
            inFlightToolTask = nil
            clarification = nil
            errorMessage = "The voice connection ended before that request finished."
            phase = .recoverableError
            isExpanded = true
        }
    }

    private func execute(_ call: VoiceToolCall) {
        inFlightToolTask?.cancel()
        phase = .thinking
        inFlightToolTask = Task { [weak self] in
            guard let self else { return }
            let result = self.route(call)
            guard !Task.isCancelled, call.expectsResponse else { return }
            do {
                try await self.transport.sendToolResult(result, for: call)
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.phase = .recoverableError
            }
        }
    }

    private func route(_ call: VoiceToolCall) -> VoiceToolResult {
        guard let gateway else {
            return encodeError("No current Assessment Result is available. Open an assessment and try again.")
        }

        switch call.name {
        case "getRequirementEvidence":
            return getEvidence(call, gateway: gateway)
        case "focus":
            return focus(call, gateway: gateway)
        case "clearFocus":
            let response = gateway.clearFocus(ClearRequirementFocusRequest())
            focusHandler?(response)
            clarification = nil
            return encode(RemoteToolEnvelope(kind: "cleared"))
        default:
            return encodeError(VoiceSessionTransportError.unsupportedTool(call.name).localizedDescription)
        }
    }

    private func getEvidence(_ call: VoiceToolCall, gateway: any AgentGateway) -> VoiceToolResult {
        do {
            let parameters = try JSONDecoder().decode(ReadOnlyToolParameters.self, from: call.parameters)
            let reference = try parameters.reference()
            let requestedConclusion = try parameters.conclusion()
            let request = RequirementEvidenceRequest(
                reference: reference,
                requestedConclusion: requestedConclusion
            )
            let response = gateway.getRequirementEvidence(request)
            let focusResponse = gateway.focusRequirement(RequirementFocusRequest(
                requestID: request.requestID,
                reference: reference
            ))
            focusHandler?(focusResponse)

            switch response {
            case let .evidence(payload):
                clarification = nil
                return encode(RemoteToolEnvelope(
                    kind: "evidence",
                    requirementID: payload.requirementID,
                    title: payload.title,
                    outcome: payload.authoritativeOutcome.rawValue,
                    authoritativeExplanation: payload.explanation
                ))
            case let .clarification(value):
                clarification = value
                return encode(RemoteToolEnvelope(
                    kind: "clarification",
                    message: value.prompt,
                    candidates: value.candidates.map(RemoteRequirementCandidate.init)
                ))
            case let .refused(refusal):
                clarification = nil
                appendTranscript(speaker: .assistant, text: refusal.message)
                return encode(RemoteToolEnvelope(kind: "refused", message: refusal.message), isError: true)
            }
        } catch {
            return encodeError(error.localizedDescription)
        }
    }

    private func focus(_ call: VoiceToolCall, gateway: any AgentGateway) -> VoiceToolResult {
        do {
            let parameters = try JSONDecoder().decode(ReadOnlyToolParameters.self, from: call.parameters)
            let response = gateway.focusRequirement(RequirementFocusRequest(reference: try parameters.reference()))
            focusHandler?(response)
            switch response {
            case let .focused(value):
                clarification = nil
                return encode(RemoteToolEnvelope(kind: "focused", requirementID: value.requirementID))
            case let .clarification(value, _):
                clarification = value
                return encode(RemoteToolEnvelope(
                    kind: "clarification",
                    message: value.prompt,
                    candidates: value.candidates.map(RemoteRequirementCandidate.init)
                ))
            case .cleared:
                clarification = nil
                return encode(RemoteToolEnvelope(kind: "cleared"))
            case let .refused(refusal):
                appendTranscript(speaker: .assistant, text: refusal.message)
                return encode(RemoteToolEnvelope(kind: "refused", message: refusal.message), isError: true)
            }
        } catch {
            return encodeError(error.localizedDescription)
        }
    }

    private func encode(_ envelope: RemoteToolEnvelope, isError: Bool = false) -> VoiceToolResult {
        do {
            return VoiceToolResult(data: try JSONEncoder().encode(envelope), isError: isError)
        } catch {
            return VoiceToolResult(data: Data("{\"kind\":\"refused\",\"message\":\"Unable to encode the local result.\"}".utf8), isError: true)
        }
    }

    private func encodeError(_ message: String) -> VoiceToolResult {
        appendTranscript(speaker: .assistant, text: message)
        return encode(RemoteToolEnvelope(kind: "refused", message: message), isError: true)
    }
}

private struct ReadOnlyToolParameters: Decodable {
    let requirementID: String?
    let name: String?
    let requestedConclusion: String?

    enum CodingKeys: String, CodingKey {
        case requirementID = "requirement_id"
        case name
        case requestedConclusion = "requested_conclusion"
    }

    func reference() throws -> RequirementReference {
        let id = requirementID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (id?.isEmpty == false ? id : nil, visibleName?.isEmpty == false ? visibleName : nil) {
        case let (.some(id), .none): return .selectedRequirement(id: id)
        case let (.none, .some(name)): return .named(name)
        default:
            throw VoiceSessionTransportError.invalidToolParameters(
                "Provide exactly one requirement_id or visible requirement name."
            )
        }
    }

    func conclusion() throws -> AnalysisOutcome? {
        guard let requestedConclusion else { return nil }
        guard let outcome = AnalysisOutcome(rawValue: requestedConclusion) else {
            throw VoiceSessionTransportError.invalidToolParameters(
                "The requested conclusion is not a supported Analysis Outcome."
            )
        }
        return outcome
    }
}

private struct RemoteRequirementCandidate: Codable {
    let id: String
    let title: String
    let outcome: String

    init(_ candidate: RequirementCandidate) {
        id = candidate.id
        title = candidate.title
        outcome = candidate.outcome.rawValue
    }
}

private struct RemoteToolEnvelope: Codable {
    let kind: String
    var requirementID: String?
    var title: String?
    var outcome: String?
    var authoritativeExplanation: String?
    var message: String?
    var candidates: [RemoteRequirementCandidate]?
}
