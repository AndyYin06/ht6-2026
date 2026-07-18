import Foundation

/// The local, read-only boundary exposed to a future voice transport. It returns only
/// request-scoped assessment evidence; map geometry remains in the local focus response.
protocol AgentGateway: Sendable {
    func getRequirementEvidence(_ request: RequirementEvidenceRequest) -> RequirementEvidenceResponse
    func focusRequirement(_ request: RequirementFocusRequest) -> RequirementFocusResponse
    func clearFocus(_ request: ClearRequirementFocusRequest) -> RequirementFocusResponse
}

enum RequirementReference: Codable, Equatable, Sendable {
    case selectedRequirement(id: String)
    case named(String)
}

struct RequirementEvidenceRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let reference: RequirementReference
    let requestedConclusion: AnalysisOutcome?

    init(
        requestID: UUID = UUID(),
        reference: RequirementReference,
        requestedConclusion: AnalysisOutcome? = nil
    ) {
        self.requestID = requestID
        self.reference = reference
        self.requestedConclusion = requestedConclusion
    }
}

struct RequirementFocusRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let reference: RequirementReference

    init(requestID: UUID = UUID(), reference: RequirementReference) {
        self.requestID = requestID
        self.reference = reference
    }
}

struct ClearRequirementFocusRequest: Codable, Equatable, Sendable {
    let requestID: UUID

    init(requestID: UUID = UUID()) {
        self.requestID = requestID
    }
}

struct RequirementCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: AssessmentRequirementKind
    let outcome: AnalysisOutcome
    let targetObjectID: String?
}

struct RequirementClarification: Codable, Equatable, Sendable {
    let requestID: UUID
    let prompt: String
    let candidates: [RequirementCandidate]
}

enum RequirementEvidenceRefusalReason: String, Codable, Equatable, Sendable {
    case noMatchingRequirement
    case unsupportedConclusion
}

struct RequirementEvidenceRefusal: Codable, Equatable, Sendable {
    let requestID: UUID
    let reason: RequirementEvidenceRefusalReason
    let message: String
}

struct RequirementEvidencePayload: Codable, Equatable, Sendable {
    struct Measurement: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let label: String
        let measuredMetres: Double?
        let requiredMetres: Double
        let toleranceMetres: Double?
        let outcome: AnalysisOutcome
    }

    struct Route: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let accessPointID: String
        let targetID: String
        let limitingClearanceMetres: Double?
        let requiredClearanceMetres: Double
        let outcome: AnalysisOutcome
    }

    let requestID: UUID
    let engineVersion: String
    let requirementID: String
    let title: String
    let kind: AssessmentRequirementKind
    let priority: MobilityNeedPriority
    let authoritativeOutcome: AnalysisOutcome
    let explanation: String
    let measurements: [Measurement]
    let routes: [Route]
    let findingTitles: [String]
    let limitation: String?
}

enum RequirementEvidenceResponse: Codable, Equatable, Sendable {
    case evidence(RequirementEvidencePayload)
    case clarification(RequirementClarification)
    case refused(RequirementEvidenceRefusal)
}

/// Local-only visual focus. Geometry is intentionally excluded from the evidence payload
/// that can cross the future backend boundary.
struct RequirementVisualFocus: Equatable, Sendable {
    let requestID: UUID
    let requirementID: String
    let targetObjectID: String?
    let routeID: String?
    let limitingSegment: AssessmentRouteSegment?
    let candidateRequirementIDs: [String]
    var candidateObjectIDs: [String] = []

    static func cleared(requestID: UUID) -> RequirementVisualFocus {
        RequirementVisualFocus(
            requestID: requestID,
            requirementID: "",
            targetObjectID: nil,
            routeID: nil,
            limitingSegment: nil,
            candidateRequirementIDs: []
        )
    }
}

enum RequirementFocusResponse: Equatable, Sendable {
    case focused(RequirementVisualFocus)
    case clarification(RequirementClarification, candidateFocus: RequirementVisualFocus)
    case cleared(RequirementVisualFocus)
    case refused(RequirementEvidenceRefusal)
}

struct LocalAgentGateway: AgentGateway {
    let assessment: AssessmentResult

    func getRequirementEvidence(_ request: RequirementEvidenceRequest) -> RequirementEvidenceResponse {
        switch resolve(request.reference, requestID: request.requestID) {
        case let .resolved(requirement):
            if let requestedConclusion = request.requestedConclusion,
               requestedConclusion != requirement.outcome {
                return .refused(RequirementEvidenceRefusal(
                    requestID: request.requestID,
                    reason: .unsupportedConclusion,
                    message: "The requested conclusion conflicts with the current authoritative outcome, \(requirement.outcome.title). The assistant cannot override or reinterpret it."
                ))
            }
            return .evidence(payload(for: requirement, requestID: request.requestID))
        case let .clarification(clarification):
            return .clarification(clarification)
        case let .refused(refusal):
            return .refused(refusal)
        }
    }

    func focusRequirement(_ request: RequirementFocusRequest) -> RequirementFocusResponse {
        switch resolve(request.reference, requestID: request.requestID) {
        case let .resolved(requirement):
            let route = limitingRoute(for: requirement)
            return .focused(RequirementVisualFocus(
                requestID: request.requestID,
                requirementID: requirement.id,
                targetObjectID: requirement.targetObjectID,
                routeID: route?.id,
                limitingSegment: route?.limitingSegment,
                candidateRequirementIDs: []
            ))
        case let .clarification(clarification):
            return .clarification(
                clarification,
                candidateFocus: RequirementVisualFocus(
                    requestID: request.requestID,
                    requirementID: "",
                    targetObjectID: nil,
                    routeID: nil,
                    limitingSegment: nil,
                    candidateRequirementIDs: clarification.candidates.map(\.id),
                    candidateObjectIDs: clarification.candidates.compactMap(\.targetObjectID)
                )
            )
        case let .refused(refusal):
            return .refused(refusal)
        }
    }

    func clearFocus(_ request: ClearRequirementFocusRequest) -> RequirementFocusResponse {
        .cleared(.cleared(requestID: request.requestID))
    }

    private enum Resolution {
        case resolved(AssessmentRequirementResult)
        case clarification(RequirementClarification)
        case refused(RequirementEvidenceRefusal)
    }

    private func resolve(_ reference: RequirementReference, requestID: UUID) -> Resolution {
        let matches: [AssessmentRequirementResult]
        switch reference {
        case let .selectedRequirement(id):
            matches = assessment.requirements.filter { $0.id == id }
        case let .named(name):
            let normalizedName = normalize(name)
            matches = assessment.requirements.filter { normalize($0.title) == normalizedName }
        }

        if matches.count == 1, let requirement = matches.first {
            return .resolved(requirement)
        }
        if matches.count > 1 {
            return .clarification(RequirementClarification(
                requestID: requestID,
                prompt: "More than one assessment requirement is named \(matches[0].title). Choose the highlighted destination or requirement.",
                candidates: matches.map(candidate)
            ))
        }
        return .refused(RequirementEvidenceRefusal(
            requestID: requestID,
            reason: .noMatchingRequirement,
            message: "No current Assessment Requirement matches that reference. Select one or use its exact visible name."
        ))
    }

    private func payload(
        for requirement: AssessmentRequirementResult,
        requestID: UUID
    ) -> RequirementEvidencePayload {
        let route = limitingRoute(for: requirement)
        let measurements = requirement.measurements.map {
            RequirementEvidencePayload.Measurement(
                id: $0.id,
                label: $0.label,
                measuredMetres: $0.measuredMetres,
                requiredMetres: $0.requiredMetres,
                toleranceMetres: $0.toleranceMetres,
                outcome: $0.outcome
            )
        }
        return RequirementEvidencePayload(
            requestID: requestID,
            engineVersion: assessment.engineVersion,
            requirementID: requirement.id,
            title: requirement.title,
            kind: requirement.kind,
            priority: requirement.priority,
            authoritativeOutcome: requirement.outcome,
            explanation: explanation(for: requirement, limitingRoute: route),
            measurements: measurements,
            routes: requirement.routes.map {
                RequirementEvidencePayload.Route(
                    id: $0.id,
                    accessPointID: $0.accessPointID,
                    targetID: $0.targetID,
                    limitingClearanceMetres: $0.limitingClearanceMetres,
                    requiredClearanceMetres: $0.requiredClearanceMetres,
                    outcome: $0.outcome
                )
            },
            findingTitles: requirement.findings.map(\.title),
            limitation: limitation(for: requirement)
        )
    }

    private func explanation(
        for requirement: AssessmentRequirementResult,
        limitingRoute: AssessmentRoute?
    ) -> String {
        let outcome = requirement.outcome.title
        let comparison: String
        if let route = limitingRoute, let measured = route.limitingClearanceMetres {
            comparison = "The highlighted route has a captured limiting clearance of \(metres(measured)); the required passage clearance is \(metres(route.requiredClearanceMetres)), with ±\(metres(AssessmentEngine.measurementToleranceMetres)) Measurement Tolerance."
        } else if let measurement = requirement.measurements.first(where: { $0.measuredMetres != nil }),
                  let measured = measurement.measuredMetres {
            comparison = "The captured value is \(metres(measured)); the required value is \(metres(measurement.requiredMetres))\(tolerancePhrase(measurement.toleranceMetres))."
        } else {
            comparison = requirement.summary
        }

        switch requirement.outcome {
        case .meetsNeed, .doesNotMeetNeed:
            return "\(comparison) The Assessment Engine's authoritative outcome is \(outcome)."
        case .needsVerification:
            return "\(comparison) The authoritative outcome remains Needs Verification. The available evidence does not support concluding Meets Need or Does Not Meet Need."
        }
    }

    private func limitation(for requirement: AssessmentRequirementResult) -> String? {
        guard requirement.outcome == .needsVerification else { return nil }
        if requirement.kind == .customMobilityNeed {
            return "This Custom Mobility Need has no structured measurement rule. Guided or Operator Verification is required; the assistant cannot infer an outcome."
        }
        return "Measurement uncertainty or incomplete captured evidence prevents a supported conclusion."
    }

    private func limitingRoute(for requirement: AssessmentRequirementResult) -> AssessmentRoute? {
        requirement.routes.min { lhs, rhs in
            let lhsRank = outcomeRank(lhs.outcome)
            let rhsRank = outcomeRank(rhs.outcome)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (lhs.limitingClearanceMetres ?? .infinity)
                < (rhs.limitingClearanceMetres ?? .infinity)
        }
    }

    private func outcomeRank(_ outcome: AnalysisOutcome) -> Int {
        switch outcome {
        case .doesNotMeetNeed: 0
        case .needsVerification: 1
        case .meetsNeed: 2
        }
    }

    private func candidate(_ requirement: AssessmentRequirementResult) -> RequirementCandidate {
        RequirementCandidate(
            id: requirement.id,
            title: requirement.title,
            kind: requirement.kind,
            outcome: requirement.outcome,
            targetObjectID: requirement.targetObjectID
        )
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func metres(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3))) + " m"
    }

    private func tolerancePhrase(_ tolerance: Double?) -> String {
        tolerance.map { ", with ±\(metres($0)) Measurement Tolerance" } ?? ""
    }
}
