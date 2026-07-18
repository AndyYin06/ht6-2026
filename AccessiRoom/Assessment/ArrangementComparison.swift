import Foundation

struct FindingChange: Identifiable, Equatable, Sendable {
    let requirementID: String
    let requirementTitle: String
    let finding: AssessmentFinding

    var id: String { finding.id }
}

enum ArrangementImprovementBasis: Equatable, Sendable {
    case status
    case unmetEssentialNeeds
    case unresolvedEssentialNeeds
    case layoutScore
    case preferenceOutcomes
    case noDifference
}

struct ArrangementComparison: Equatable, Sendable {
    let observed: AssessmentResult
    let proposed: AssessmentResult
    let changedPlacements: [ProposedObjectChange]
    let proposedRemovals: [ProposedObjectChange]
    let resolvedFindings: [FindingChange]
    let remainingFindings: [FindingChange]
    let newlyIntroducedFindings: [FindingChange]
    let isImproved: Bool
    let improvementBasis: ArrangementImprovementBasis

    var classificationTitle: String {
        isImproved ? "Improved Arrangement" : "Not an Improved Arrangement"
    }
}

struct ArrangementComparisonEngine {
    func compare(
        observed: AssessmentResult,
        proposed: AssessmentResult,
        arrangement: ProposedArrangement
    ) -> ArrangementComparison? {
        guard arrangement.hasChanges,
              proposed.status != .invalidProposal,
              observed.engineVersion == proposed.engineVersion,
              Set(observed.requirements.map(\.id)) == Set(proposed.requirements.map(\.id))
        else { return nil }

        let observedFindings = findings(in: observed)
        let proposedFindings = findings(in: proposed)
        let observedIDs = Set(observedFindings.keys)
        let proposedIDs = Set(proposedFindings.keys)
        let classification = classify(observed: observed, proposed: proposed)

        return ArrangementComparison(
            observed: observed,
            proposed: proposed,
            changedPlacements: arrangement.changes.filter { !$0.isRemoved }.sorted { $0.id < $1.id },
            proposedRemovals: arrangement.changes.filter(\.isRemoved).sorted { $0.id < $1.id },
            resolvedFindings: (observedIDs.subtracting(proposedIDs)).compactMap { observedFindings[$0] }.sorted(by: findingOrder),
            remainingFindings: (observedIDs.intersection(proposedIDs)).compactMap { proposedFindings[$0] }.sorted(by: findingOrder),
            newlyIntroducedFindings: (proposedIDs.subtracting(observedIDs)).compactMap { proposedFindings[$0] }.sorted(by: findingOrder),
            isImproved: classification.isImproved,
            improvementBasis: classification.basis
        )
    }

    private func classify(
        observed: AssessmentResult,
        proposed: AssessmentResult
    ) -> (isImproved: Bool, basis: ArrangementImprovementBasis) {
        let comparisons: [(ComparisonResult, ArrangementImprovementBasis)] = [
            (statusRank(proposed.status).compared(to: statusRank(observed.status)), .status),
            (essentialCount(.doesNotMeetNeed, in: observed).compared(to: essentialCount(.doesNotMeetNeed, in: proposed)), .unmetEssentialNeeds),
            (essentialCount(.needsVerification, in: observed).compared(to: essentialCount(.needsVerification, in: proposed)), .unresolvedEssentialNeeds),
            (scoreLowerBound(proposed).compared(to: scoreLowerBound(observed)), .layoutScore),
            (scoreUpperBound(proposed).compared(to: scoreUpperBound(observed)), .layoutScore),
            (preferenceCount(.meetsNeed, in: proposed).compared(to: preferenceCount(.meetsNeed, in: observed)), .preferenceOutcomes),
            (preferenceCount(.doesNotMeetNeed, in: observed).compared(to: preferenceCount(.doesNotMeetNeed, in: proposed)), .preferenceOutcomes),
            (preferenceCount(.needsVerification, in: observed).compared(to: preferenceCount(.needsVerification, in: proposed)), .preferenceOutcomes),
        ]

        guard let firstDifference = comparisons.first(where: { $0.0 != .orderedSame }) else {
            return (false, .noDifference)
        }
        return (firstDifference.0 == .orderedDescending, firstDifference.1)
    }

    private func statusRank(_ status: ArrangementStatus) -> Int {
        switch status {
        case .invalidProposal: 0
        case .doesNotSupportEssentialNeeds: 1
        case .needsVerification: 2
        case .supportsEssentialNeeds: 3
        }
    }

    private func essentialCount(_ outcome: AnalysisOutcome, in result: AssessmentResult) -> Int {
        result.requirements.filter { $0.priority == .essential && $0.outcome == outcome }.count
    }

    private func preferenceCount(_ outcome: AnalysisOutcome, in result: AssessmentResult) -> Int {
        result.requirements.filter { $0.priority == .preference && $0.outcome == outcome }.count
    }

    private func scoreLowerBound(_ result: AssessmentResult) -> Int {
        result.score?.lowerBound ?? Int.min
    }

    private func scoreUpperBound(_ result: AssessmentResult) -> Int {
        result.score?.upperBound ?? Int.min
    }

    private func findings(in result: AssessmentResult) -> [String: FindingChange] {
        Dictionary(result.requirements.flatMap { requirement in
            requirement.findings.map { finding in
                (finding.id, FindingChange(
                    requirementID: requirement.id,
                    requirementTitle: requirement.title,
                    finding: finding
                ))
            }
        }, uniquingKeysWith: { first, _ in first })
    }

    private func findingOrder(_ lhs: FindingChange, _ rhs: FindingChange) -> Bool {
        [lhs.requirementTitle, lhs.finding.title, lhs.id]
            .lexicographicallyPrecedes([rhs.requirementTitle, rhs.finding.title, rhs.id])
    }
}

private extension Int {
    func compared(to other: Int) -> ComparisonResult {
        if self < other { return .orderedAscending }
        if self > other { return .orderedDescending }
        return .orderedSame
    }
}
