import XCTest
@testable import AccessiRoom

final class AccessiRoomTests: XCTestCase {
    @MainActor
    func testVoiceSessionStartsOnlyAfterDisclosureConfirmation() async {
        let transport = TestVoiceSessionTransport()
        let session = VoiceSession(transport: transport)

        session.requestStart()

        XCTAssertTrue(session.isDisclosurePresented)
        XCTAssertEqual(session.phase, .permissionRequired)
        XCTAssertEqual(transport.startCount, 0)

        await session.startAfterDisclosure()

        XCTAssertFalse(session.isDisclosurePresented)
        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(transport.startCount, 1)
    }

    @MainActor
    func testVoiceSessionPersistsContextAndClearsTranscriptWhenStopped() async {
        let transport = TestVoiceSessionTransport()
        let session = VoiceSession(transport: transport)
        session.requestStart()
        await session.startAfterDisclosure()
        session.enter(.assessment)
        session.appendTranscript(speaker: .user, text: "Why is this route blocked?")
        session.enter(.arrangementComparison)

        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(session.currentSurface, .arrangementComparison)
        XCTAssertEqual(session.transcript.count, 1)

        await session.stop()

        XCTAssertEqual(session.phase, .ended)
        XCTAssertTrue(session.transcript.isEmpty)
        XCTAssertEqual(transport.stopCount, 1)
    }

    @MainActor
    func testVoiceSessionReportsBackendFailureWithoutBlockingLocalWorkflow() async {
        let transport = TestVoiceSessionTransport(startError: .backendNotConfigured)
        let session = VoiceSession(transport: transport)

        session.requestStart()
        await session.startAfterDisclosure()

        XCTAssertEqual(session.phase, .recoverableError)
        XCTAssertEqual(
            session.errorMessage,
            "The ElevenLabs backend is not configured yet. Your room and assessment remain available."
        )
    }

    func testMeasurementToleranceClassifiesConservatively() {
        XCTAssertEqual(
            AssessmentEngine.classify(measured: 0.95, required: 0.90, tolerance: 0.05),
            .meetsNeed
        )
        XCTAssertEqual(
            AssessmentEngine.classify(measured: 0.90, required: 0.90, tolerance: 0.05),
            .needsVerification
        )
        XCTAssertEqual(
            AssessmentEngine.classify(measured: 0.85, required: 0.90, tolerance: 0.05),
            .needsVerification
        )
        XCTAssertEqual(
            AssessmentEngine.classify(measured: 0.849, required: 0.90, tolerance: 0.05),
            .doesNotMeetNeed
        )
    }

    func testRequirementAggregationUsesFailureThenVerificationPrecedence() {
        XCTAssertEqual(AssessmentEngine.aggregate([.meetsNeed, .needsVerification]), .needsVerification)
        XCTAssertEqual(AssessmentEngine.aggregate([.needsVerification, .doesNotMeetNeed]), .doesNotMeetNeed)
        XCTAssertEqual(AssessmentEngine.aggregate([.meetsNeed, .meetsNeed]), .meetsNeed)
    }

    func testEssentialRequirementControlsArrangementStatus() {
        XCTAssertEqual(
            AssessmentEngine.status(for: [requirement(outcome: .doesNotMeetNeed, priority: .preference)]),
            .supportsEssentialNeeds
        )
        XCTAssertEqual(
            AssessmentEngine.status(for: [requirement(outcome: .needsVerification, priority: .essential)]),
            .needsVerification
        )
        XCTAssertEqual(
            AssessmentEngine.status(for: [requirement(outcome: .doesNotMeetNeed, priority: .essential)]),
            .doesNotSupportEssentialNeeds
        )
    }

    func testScoreReportsBoundsForUnresolvedRequirements() {
        let score = AssessmentEngine.score(for: [
            requirement(id: "essential-pass", outcome: .meetsNeed, priority: .essential),
            requirement(id: "essential-unresolved", outcome: .needsVerification, priority: .essential),
            requirement(id: "preference-fail", outcome: .doesNotMeetNeed, priority: .preference),
        ])

        XCTAssertEqual(score.lowerBound, 40)
        XCTAssertEqual(score.upperBound, 80)
        XCTAssertTrue(score.isProvisional)
    }

    func testArrangementComparisonRequiresChangedValidProposal() {
        let observed = assessmentResult(requirements: [
            requirement(id: "essential", outcome: .meetsNeed, priority: .essential),
        ])
        let invalid = assessmentResult(
            requirements: observed.requirements,
            status: .invalidProposal,
            score: nil
        )
        let unchanged = ProposedArrangement.empty(roomID: UUID())

        XCTAssertNil(ArrangementComparisonEngine().compare(
            observed: observed,
            proposed: observed,
            arrangement: unchanged
        ))

        var changed = unchanged
        changed.update(objectID: "chair") { $0.translationXMetres = 0.1 }
        XCTAssertNil(ArrangementComparisonEngine().compare(
            observed: observed,
            proposed: invalid,
            arrangement: changed
        ))
    }

    func testImprovedArrangementUsesDocumentedPrecedence() throws {
        var arrangement = ProposedArrangement.empty(roomID: UUID())
        arrangement.update(objectID: "chair") { $0.translationXMetres = 0.1 }

        let observed = assessmentResult(
            requirements: [
                requirement(id: "e1", outcome: .doesNotMeetNeed, priority: .essential),
                requirement(id: "e2", outcome: .doesNotMeetNeed, priority: .essential),
            ],
            score: LayoutScore(lowerBound: 80, upperBound: 80)
        )
        let proposed = assessmentResult(
            requirements: [
                requirement(id: "e1", outcome: .doesNotMeetNeed, priority: .essential),
                requirement(id: "e2", outcome: .meetsNeed, priority: .essential),
            ],
            score: LayoutScore(lowerBound: 20, upperBound: 20)
        )

        let fewerUnmet = try XCTUnwrap(ArrangementComparisonEngine().compare(
            observed: observed,
            proposed: proposed,
            arrangement: arrangement
        ))
        XCTAssertTrue(fewerUnmet.isImproved)
        XCTAssertEqual(fewerUnmet.improvementBasis, .unmetEssentialNeeds)

        let verification = assessmentResult(requirements: [
            requirement(id: "e1", outcome: .needsVerification, priority: .essential),
            requirement(id: "e2", outcome: .meetsNeed, priority: .essential),
        ])
        let newlyUnmet = assessmentResult(
            requirements: [
                requirement(id: "e1", outcome: .doesNotMeetNeed, priority: .essential),
                requirement(id: "e2", outcome: .meetsNeed, priority: .essential),
            ],
            score: LayoutScore(lowerBound: 100, upperBound: 100)
        )
        let higherScoreWithWorseStatus = try XCTUnwrap(ArrangementComparisonEngine().compare(
            observed: verification,
            proposed: newlyUnmet,
            arrangement: arrangement
        ))
        XCTAssertFalse(higherScoreWithWorseStatus.isImproved)
        XCTAssertEqual(higherScoreWithWorseStatus.improvementBasis, .status)
    }

    func testImprovedArrangementUsesScoreThenPreferenceOutcomes() throws {
        var arrangement = ProposedArrangement.empty(roomID: UUID())
        arrangement.update(objectID: "chair") { $0.rotationRadians = 0.2 }
        let essential = requirement(id: "essential", outcome: .meetsNeed, priority: .essential)
        let observedPreference = requirement(id: "preference", outcome: .needsVerification, priority: .preference)
        let proposedPreference = requirement(id: "preference", outcome: .meetsNeed, priority: .preference)

        let scoreImprovement = try XCTUnwrap(ArrangementComparisonEngine().compare(
            observed: assessmentResult(
                requirements: [essential, observedPreference],
                score: LayoutScore(lowerBound: 80, upperBound: 100)
            ),
            proposed: assessmentResult(
                requirements: [essential, observedPreference],
                score: LayoutScore(lowerBound: 90, upperBound: 100)
            ),
            arrangement: arrangement
        ))
        XCTAssertTrue(scoreImprovement.isImproved)
        XCTAssertEqual(scoreImprovement.improvementBasis, .layoutScore)

        let preferenceImprovement = try XCTUnwrap(ArrangementComparisonEngine().compare(
            observed: assessmentResult(
                requirements: [essential, observedPreference],
                score: LayoutScore(lowerBound: 100, upperBound: 100)
            ),
            proposed: assessmentResult(
                requirements: [essential, proposedPreference],
                score: LayoutScore(lowerBound: 100, upperBound: 100)
            ),
            arrangement: arrangement
        ))
        XCTAssertTrue(preferenceImprovement.isImproved)
        XCTAssertEqual(preferenceImprovement.improvementBasis, .preferenceOutcomes)
    }

    func testArrangementComparisonClassifiesFindingChangesAndObjectChanges() throws {
        var arrangement = ProposedArrangement.empty(roomID: UUID())
        arrangement.update(objectID: "chair") { $0.translationZMetres = 0.2 }
        arrangement.update(objectID: "table") { $0.isRemoved = true }
        let observed = assessmentResult(requirements: [
            requirement(
                id: "essential",
                outcome: .doesNotMeetNeed,
                priority: .essential,
                findings: [finding(id: "resolved"), finding(id: "remaining")]
            ),
        ])
        let proposed = assessmentResult(requirements: [
            requirement(
                id: "essential",
                outcome: .doesNotMeetNeed,
                priority: .essential,
                findings: [finding(id: "remaining"), finding(id: "new")]
            ),
        ])

        let comparison = try XCTUnwrap(ArrangementComparisonEngine().compare(
            observed: observed,
            proposed: proposed,
            arrangement: arrangement
        ))
        XCTAssertEqual(comparison.changedPlacements.map(\.id), ["chair"])
        XCTAssertEqual(comparison.proposedRemovals.map(\.id), ["table"])
        XCTAssertEqual(comparison.resolvedFindings.map(\.id), ["resolved"])
        XCTAssertEqual(comparison.remainingFindings.map(\.id), ["remaining"])
        XCTAssertEqual(comparison.newlyIntroducedFindings.map(\.id), ["new"])
    }

    @MainActor
    func testConfirmedMobilityProfilePersistsAcrossStoreInstances() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = MobilityProfileStore(rootDirectory: fixture.storeDirectory)
        var profile = MobilityProfile.customDraft()
        profile.occupantName = "Sam"
        profile.customNeeds = [
            CustomMobilityNeed(
                title: "Keep extra space beside seating",
                details: "For comfortable positioning",
                priority: .preference
            )
        ]
        try store.save(profile)
        try store.confirm()

        let reloaded = MobilityProfileStore(rootDirectory: fixture.storeDirectory)
        XCTAssertEqual(reloaded.profile?.occupantName, "Sam")
        XCTAssertEqual(reloaded.profile?.customNeeds.first?.priority, .preference)
        XCTAssertTrue(reloaded.isConfirmed)
    }

    @MainActor
    func testEditingMobilityProfileInvalidatesConfirmation() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = MobilityProfileStore(rootDirectory: fixture.storeDirectory)
        var profile = MobilityProfile.customDraft()
        profile.occupantName = "Sam"
        try store.save(profile)
        try store.confirm()
        XCTAssertTrue(store.isConfirmed)

        var edited = try XCTUnwrap(store.profile)
        edited.measurements.minimumPassageWidthCentimetres = 100
        try store.save(edited)

        XCTAssertFalse(store.isConfirmed)
        XCTAssertNil(store.confirmation)
    }

    @MainActor
    func testReplacingAcceptedRoomKeepsConfirmedMobilityProfile() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let profileStore = MobilityProfileStore(rootDirectory: fixture.storeDirectory)
        var profile = MobilityProfile.customDraft()
        profile.occupantName = "Sam"
        try profileStore.save(profile)
        try profileStore.confirm()

        let roomStore = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try roomStore.accept(fixture.makeCandidate(source: .demo, contents: "first"))
        try roomStore.accept(fixture.makeCandidate(source: .liveScan, contents: "second"))

        let reloadedProfileStore = MobilityProfileStore(rootDirectory: fixture.storeDirectory)
        XCTAssertTrue(reloadedProfileStore.isConfirmed)
        XCTAssertEqual(reloadedProfileStore.profile?.occupantName, "Sam")
    }

    @MainActor
    func testAcceptPersistsRoomAcrossStoreInstances() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try store.accept(fixture.makeCandidate(source: .demo, contents: "first"))

        let reloadedStore = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        let acceptedRoom = try XCTUnwrap(reloadedStore.acceptedRoom)
        XCTAssertEqual(acceptedRoom.source, .demo)
        XCTAssertEqual(try String(contentsOf: acceptedRoom.jsonURL), "first-json")
        XCTAssertEqual(try String(contentsOf: acceptedRoom.usdzURL), "first-usdz")
    }

    @MainActor
    func testAcceptReplacesTheOnlyAcceptedRoom() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try store.accept(fixture.makeCandidate(source: .demo, contents: "first"))
        let firstID = try XCTUnwrap(store.acceptedRoom?.id)

        try store.accept(fixture.makeCandidate(source: .liveScan, contents: "second"))
        let secondRoom = try XCTUnwrap(store.acceptedRoom)
        XCTAssertNotEqual(secondRoom.id, firstID)
        XCTAssertEqual(secondRoom.source, .liveScan)
        XCTAssertEqual(try String(contentsOf: secondRoom.jsonURL), "second-json")

        let roomDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.storeDirectory.appending(path: "Rooms"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(roomDirectories.count, 1)
    }

    @MainActor
    func testIncompletePersistedRoomIsNotLoaded() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try store.accept(fixture.makeCandidate(source: .demo, contents: "first"))
        let acceptedRoom = try XCTUnwrap(store.acceptedRoom)
        try FileManager.default.removeItem(at: acceptedRoom.usdzURL)

        let reloadedStore = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        XCTAssertNil(reloadedStore.acceptedRoom)
    }

    @MainActor
    func testConfirmedRoomSetupPersistsWithAcceptedRoom() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try store.accept(fixture.makeRoomPlanCandidate(contents: "first"))
        let room = try XCTUnwrap(store.acceptedRoom)
        let inventory = try CapturedRoomInventory.load(from: room.jsonURL)
        var setup = RoomSetup.draft(roomID: room.id, inventory: inventory, measurements: nil)
        setup.accessPointIDs.insert(try XCTUnwrap(inventory.accessPointCandidates.first?.id))
        setup.objects[0].isRequiredDestination = true

        try store.confirm(setup, inventory: inventory)

        let reloaded = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        XCTAssertTrue(reloaded.roomSetup?.isConfirmed == true)
        XCTAssertEqual(reloaded.roomSetup?.roomID, room.id)
        XCTAssertEqual(reloaded.roomSetup?.objects.first?.isRequiredDestination, true)
    }

    @MainActor
    func testReplacingAcceptedRoomInvalidatesRoomSetup() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try store.accept(fixture.makeRoomPlanCandidate(contents: "first"))
        let room = try XCTUnwrap(store.acceptedRoom)
        let inventory = try CapturedRoomInventory.load(from: room.jsonURL)
        var setup = RoomSetup.draft(roomID: room.id, inventory: inventory, measurements: nil)
        setup.accessPointIDs.insert(try XCTUnwrap(inventory.accessPointCandidates.first?.id))
        setup.objects[0].isRequiredDestination = true
        try store.confirm(setup, inventory: inventory)

        try store.accept(fixture.makeRoomPlanCandidate(contents: "second"))

        XCTAssertNil(store.roomSetup)
        XCTAssertNil(AcceptedRoomStore(rootDirectory: fixture.storeDirectory).roomSetup)
    }

    @MainActor
    func testProposedArrangementPersistsAndIsClearedWithAcceptedRoom() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try store.accept(fixture.makeRoomPlanCandidate(contents: "first"))
        let room = try XCTUnwrap(store.acceptedRoom)
        let inventory = try CapturedRoomInventory.load(from: room.jsonURL)
        var setup = RoomSetup.draft(roomID: room.id, inventory: inventory, measurements: nil)
        setup.accessPointIDs.insert(try XCTUnwrap(inventory.accessPointCandidates.first?.id))
        setup.objects[0].isMovable = true
        setup.objects[0].isRequiredDestination = true
        try store.confirm(setup, inventory: inventory)

        var arrangement = ProposedArrangement.empty(roomID: room.id)
        arrangement.update(objectID: "chair-1") {
            $0.translationXMetres = 0.25
            $0.rotationRadians = .pi / 4
        }
        try store.save(arrangement)

        let reloaded = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        XCTAssertEqual(reloaded.proposedArrangement, arrangement)

        try store.accept(fixture.makeRoomPlanCandidate(contents: "second"))
        XCTAssertNil(store.proposedArrangement)
        XCTAssertNil(AcceptedRoomStore(rootDirectory: fixture.storeDirectory).proposedArrangement)
    }

    @MainActor
    func testResettingProposalRemovesPersistedArrangement() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try store.accept(fixture.makeRoomPlanCandidate(contents: "room"))
        let room = try XCTUnwrap(store.acceptedRoom)
        let inventory = try CapturedRoomInventory.load(from: room.jsonURL)
        var setup = RoomSetup.draft(roomID: room.id, inventory: inventory, measurements: nil)
        setup.accessPointIDs.insert("door-1")
        setup.objects[0].isMovable = true
        setup.objects[0].isRequiredDestination = true
        try store.confirm(setup, inventory: inventory)

        var arrangement = ProposedArrangement.empty(roomID: room.id)
        arrangement.update(objectID: "chair-1") { $0.isRemoved = true }
        try store.save(arrangement)
        try store.save(.empty(roomID: room.id))

        XCTAssertNil(store.proposedArrangement)
        XCTAssertNil(AcceptedRoomStore(rootDirectory: fixture.storeDirectory).proposedArrangement)
    }

    @MainActor
    func testOverlappingProposedPlacementIsInvalidAndHasNoScore() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try store.accept(fixture.makeArrangementCandidate())
        let room = try XCTUnwrap(store.acceptedRoom)
        let inventory = try CapturedRoomInventory.load(from: room.jsonURL)
        var setup = RoomSetup.draft(roomID: room.id, inventory: inventory, measurements: nil)
        setup.accessPointIDs.insert("door-1")
        setup.objects[0].isMovable = true
        setup.objects[1].isRequiredDestination = true
        try store.confirm(setup, inventory: inventory)

        var arrangement = ProposedArrangement.empty(roomID: room.id)
        arrangement.update(objectID: "chair-1") { $0.translationXMetres = 2 }
        let result = try AssessmentEngine().assess(
            room: room,
            profile: .customDraft(),
            setup: try XCTUnwrap(store.roomSetup),
            arrangement: arrangement
        )

        XCTAssertEqual(result.status, .invalidProposal)
        XCTAssertNil(result.score)
        XCTAssertTrue(result.conflicts.contains { $0.title == "Objects overlap" })
    }

    func testAgentGatewayReturnsRequestScopedExactRequirementEvidence() throws {
        let requestID = UUID()
        let route = AssessmentRoute(
            id: "route-door-chair",
            accessPointID: "door-1",
            targetID: "destination-chair-1",
            points: [FloorPoint(x: 0, z: 0), FloorPoint(x: 1, z: 0)],
            limitingClearanceMetres: 0.849,
            requiredClearanceMetres: 0.9,
            limitingSegment: AssessmentRouteSegment(
                start: FloorPoint(x: 0.4, z: 0),
                end: FloorPoint(x: 0.6, z: 0)
            ),
            outcome: .doesNotMeetNeed
        )
        let result = assessmentResult(requirements: [requirement(
            id: "destination-chair-1",
            outcome: .doesNotMeetNeed,
            priority: .essential,
            title: "Chair",
            targetObjectID: "chair-1",
            routes: [route],
            measurements: [AssessmentMeasurementEvidence(
                id: route.id,
                label: "Route limiting clearance",
                measuredMetres: 0.849,
                requiredMetres: 0.9,
                toleranceMetres: 0.05,
                outcome: .doesNotMeetNeed
            )]
        )])

        let response = LocalAgentGateway(assessment: result).getRequirementEvidence(
            RequirementEvidenceRequest(requestID: requestID, reference: .named(" chair "))
        )
        guard case let .evidence(payload) = response else {
            return XCTFail("Expected typed evidence")
        }

        XCTAssertEqual(payload.requestID, requestID)
        XCTAssertEqual(payload.authoritativeOutcome, .doesNotMeetNeed)
        XCTAssertEqual(payload.measurements.first?.measuredMetres, 0.849)
        XCTAssertEqual(payload.measurements.first?.requiredMetres, 0.9)
        XCTAssertTrue(payload.explanation.contains("0.849 m"))
        XCTAssertTrue(payload.explanation.contains("0.9 m"))
    }

    func testAgentGatewayAsksForClarificationWhenNamesAreAmbiguous() {
        let result = assessmentResult(requirements: [
            requirement(
                id: "destination-chair-1",
                outcome: .meetsNeed,
                priority: .essential,
                title: "Chair",
                targetObjectID: "chair-1"
            ),
            requirement(
                id: "destination-chair-2",
                outcome: .doesNotMeetNeed,
                priority: .essential,
                title: "Chair",
                targetObjectID: "chair-2"
            ),
        ])

        let gateway = LocalAgentGateway(assessment: result)
        let evidence = gateway.getRequirementEvidence(
            RequirementEvidenceRequest(reference: .named("Chair"))
        )
        guard case let .clarification(clarification) = evidence else {
            return XCTFail("Expected clarification")
        }
        XCTAssertEqual(clarification.candidates.map(\.targetObjectID), ["chair-1", "chair-2"])

        let focus = gateway.focusRequirement(RequirementFocusRequest(reference: .named("Chair")))
        guard case let .clarification(_, candidateFocus) = focus else {
            return XCTFail("Expected candidate focus")
        }
        XCTAssertEqual(candidateFocus.candidateRequirementIDs, ["destination-chair-1", "destination-chair-2"])
    }

    func testAgentGatewayPreservesNeedsVerificationAndRefusesUnsupportedConclusion() throws {
        let result = assessmentResult(requirements: [requirement(
            id: "custom-transfer-space",
            outcome: .needsVerification,
            priority: .essential,
            title: "Transfer space",
            kind: .customMobilityNeed
        )])

        let response = LocalAgentGateway(assessment: result).getRequirementEvidence(
            RequirementEvidenceRequest(reference: .selectedRequirement(id: "custom-transfer-space"))
        )
        guard case let .evidence(payload) = response else {
            return XCTFail("Expected unresolved evidence")
        }

        XCTAssertEqual(payload.authoritativeOutcome, .needsVerification)
        XCTAssertTrue(payload.explanation.contains("does not support concluding"))
        XCTAssertTrue(try XCTUnwrap(payload.limitation).contains("cannot infer an outcome"))

        let overrideAttempt = LocalAgentGateway(assessment: result).getRequirementEvidence(
            RequirementEvidenceRequest(
                reference: .selectedRequirement(id: "custom-transfer-space"),
                requestedConclusion: .meetsNeed
            )
        )
        guard case let .refused(refusal) = overrideAttempt else {
            return XCTFail("Expected unsupported conclusion refusal")
        }
        XCTAssertEqual(refusal.reason, .unsupportedConclusion)
        XCTAssertTrue(refusal.message.contains("cannot override"))
    }

    func testAgentGatewayFocusesDestinationRouteAndLimitingSegment() {
        let segment = AssessmentRouteSegment(
            start: FloorPoint(x: 1, z: 1),
            end: FloorPoint(x: 1.1, z: 1)
        )
        let route = AssessmentRoute(
            id: "route-door-table",
            accessPointID: "door-1",
            targetID: "destination-table-1",
            points: [segment.start, segment.end],
            limitingClearanceMetres: 0.82,
            requiredClearanceMetres: 0.9,
            limitingSegment: segment,
            outcome: .doesNotMeetNeed
        )
        let result = assessmentResult(requirements: [requirement(
            id: "destination-table-1",
            outcome: .doesNotMeetNeed,
            priority: .essential,
            title: "Table",
            targetObjectID: "table-1",
            routes: [route]
        )])

        let response = LocalAgentGateway(assessment: result).focusRequirement(
            RequirementFocusRequest(reference: .selectedRequirement(id: "destination-table-1"))
        )
        guard case let .focused(focus) = response else {
            return XCTFail("Expected visual focus")
        }

        XCTAssertEqual(focus.targetObjectID, "table-1")
        XCTAssertEqual(focus.routeID, route.id)
        XCTAssertEqual(focus.limitingSegment, segment)
    }

    @MainActor
    func testVoiceEvidenceToolReturnsOnlyMinimizedAuthoritativePayload() async throws {
        let segment = AssessmentRouteSegment(
            start: FloorPoint(x: 0.4, z: 0),
            end: FloorPoint(x: 0.6, z: 0)
        )
        let route = AssessmentRoute(
            id: "route-door-chair",
            accessPointID: "door-1",
            targetID: "destination-chair-1",
            points: [FloorPoint(x: 0, z: 0), FloorPoint(x: 1, z: 0)],
            limitingClearanceMetres: 0.849,
            requiredClearanceMetres: 0.9,
            limitingSegment: segment,
            outcome: .doesNotMeetNeed
        )
        let result = assessmentResult(requirements: [requirement(
            id: "destination-chair-1",
            outcome: .doesNotMeetNeed,
            priority: .essential,
            title: "Chair",
            targetObjectID: "chair-1",
            routes: [route]
        )])
        let transport = TestVoiceSessionTransport()
        let session = VoiceSession(transport: transport)
        var localFocus: RequirementFocusResponse?
        session.installGateway(LocalAgentGateway(assessment: result)) { localFocus = $0 }

        transport.emit(.toolCall(VoiceToolCall(
            id: "tool-1",
            name: "getRequirementEvidence",
            parameters: Data(#"{"name":"Chair"}"#.utf8),
            expectsResponse: true
        )))
        await waitForToolResult(on: transport)

        let toolResult = try XCTUnwrap(transport.toolResults.first?.0)
        XCTAssertFalse(toolResult.isError)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: toolResult.data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(json.keys),
            ["kind", "requirementID", "title", "outcome", "authoritativeExplanation"]
        )
        XCTAssertEqual(json["kind"] as? String, "evidence")
        XCTAssertEqual(json["outcome"] as? String, AnalysisOutcome.doesNotMeetNeed.rawValue)
        XCTAssertTrue((json["authoritativeExplanation"] as? String)?.contains("0.849 m") == true)

        let encoded = String(decoding: toolResult.data, as: UTF8.self)
        for forbiddenField in ["points", "limitingSegment", "focusPolygons", "map", "RoomPlan", "measurements", "routes"] {
            XCTAssertFalse(encoded.contains(forbiddenField), "Leaked forbidden field: \(forbiddenField)")
        }

        guard case let .focused(focus) = localFocus else {
            return XCTFail("Expected local object, route, and segment focus")
        }
        XCTAssertEqual(focus.targetObjectID, "chair-1")
        XCTAssertEqual(focus.routeID, route.id)
        XCTAssertEqual(focus.limitingSegment, segment)
    }

    @MainActor
    func testVoiceToolAmbiguityHighlightsCandidatesAndReturnsClarification() async throws {
        let result = assessmentResult(requirements: [
            requirement(
                id: "destination-chair-1",
                outcome: .meetsNeed,
                priority: .essential,
                title: "Chair",
                targetObjectID: "chair-1"
            ),
            requirement(
                id: "destination-chair-2",
                outcome: .doesNotMeetNeed,
                priority: .essential,
                title: "Chair",
                targetObjectID: "chair-2"
            ),
        ])
        let transport = TestVoiceSessionTransport()
        let session = VoiceSession(transport: transport)
        var localFocus: RequirementFocusResponse?
        session.installGateway(LocalAgentGateway(assessment: result)) { localFocus = $0 }

        transport.emit(.toolCall(VoiceToolCall(
            id: "tool-ambiguity",
            name: "getRequirementEvidence",
            parameters: Data(#"{"name":"Chair"}"#.utf8),
            expectsResponse: true
        )))
        await waitForToolResult(on: transport)

        XCTAssertEqual(session.clarification?.candidates.count, 2)
        guard case let .clarification(_, candidateFocus) = localFocus else {
            return XCTFail("Expected ambiguous candidates to receive local focus")
        }
        XCTAssertEqual(candidateFocus.candidateObjectIDs, ["chair-1", "chair-2"])

        let data = try XCTUnwrap(transport.toolResults.first?.0.data)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("clarification"))
        XCTAssertFalse(encoded.contains("targetObjectID"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let candidates = try XCTUnwrap(json["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.compactMap { $0["id"] as? String }, [
            "destination-chair-1",
            "destination-chair-2",
        ])
    }

    @MainActor
    func testVoiceToolPreservesNeedsVerificationAndGatewayRefusalVerbatim() async throws {
        let result = assessmentResult(requirements: [requirement(
            id: "custom-transfer-space",
            outcome: .needsVerification,
            priority: .essential,
            title: "Transfer space",
            kind: .customMobilityNeed
        )])
        let gateway = LocalAgentGateway(assessment: result)
        let directResponse = gateway.getRequirementEvidence(RequirementEvidenceRequest(
            reference: .selectedRequirement(id: "custom-transfer-space"),
            requestedConclusion: .meetsNeed
        ))
        guard case let .refused(expectedRefusal) = directResponse else {
            return XCTFail("Expected the gateway to refuse an override")
        }

        let transport = TestVoiceSessionTransport()
        let session = VoiceSession(transport: transport)
        session.installGateway(gateway) { _ in }
        session.requestStart()
        await session.startAfterDisclosure()
        transport.emit(.toolCall(VoiceToolCall(
            id: "tool-refusal",
            name: "getRequirementEvidence",
            parameters: Data(#"{"requirement_id":"custom-transfer-space","requested_conclusion":"meetsNeed"}"#.utf8),
            expectsResponse: true
        )))
        await waitForToolResult(on: transport)

        let toolResult = try XCTUnwrap(transport.toolResults.first?.0)
        XCTAssertTrue(toolResult.isError)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: toolResult.data) as? [String: Any]
        )
        XCTAssertEqual(json["message"] as? String, expectedRefusal.message)
        XCTAssertEqual(session.transcript.last?.text, expectedRefusal.message)

        transport.toolResults.removeAll()
        transport.emit(.toolCall(VoiceToolCall(
            id: "tool-verification",
            name: "getRequirementEvidence",
            parameters: Data(#"{"requirement_id":"custom-transfer-space"}"#.utf8),
            expectsResponse: true
        )))
        await waitForToolResult(on: transport)
        let verificationData = try XCTUnwrap(transport.toolResults.first?.0.data)
        let verificationJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: verificationData) as? [String: Any]
        )
        XCTAssertEqual(
            verificationJSON["outcome"] as? String,
            AnalysisOutcome.needsVerification.rawValue
        )
    }

    @MainActor
    func testVoiceSessionRejectsUnexposedTools() async throws {
        let result = assessmentResult(requirements: [requirement(
            id: "destination-chair-1",
            outcome: .doesNotMeetNeed,
            priority: .essential,
            title: "Chair"
        )])
        let transport = TestVoiceSessionTransport()
        let session = VoiceSession(transport: transport)
        session.installGateway(LocalAgentGateway(assessment: result)) { _ in }

        transport.emit(.toolCall(VoiceToolCall(
            id: "tool-unsupported",
            name: "mutateArrangement",
            parameters: Data("{}".utf8),
            expectsResponse: true
        )))
        await waitForToolResult(on: transport)

        let response = try XCTUnwrap(transport.toolResults.first?.0)
        XCTAssertTrue(response.isError)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        )
        XCTAssertEqual(json["kind"] as? String, "refused")
        XCTAssertEqual(
            json["message"] as? String,
            "The ElevenLabs agent requested the unsupported tool mutateArrangement."
        )
    }

    @MainActor
    func testVoiceSessionCancelsPendingResultOnDisconnect() async {
        let result = assessmentResult(requirements: [requirement(
            id: "destination-chair-1",
            outcome: .doesNotMeetNeed,
            priority: .essential,
            title: "Chair"
        )])
        let transport = TestVoiceSessionTransport(blockToolResults: true)
        let session = VoiceSession(transport: transport)
        session.installGateway(LocalAgentGateway(assessment: result)) { _ in }
        session.requestStart()
        await session.startAfterDisclosure()

        transport.emit(.toolCall(VoiceToolCall(
            id: "tool-pending",
            name: "getRequirementEvidence",
            parameters: Data(#"{"name":"Chair"}"#.utf8),
            expectsResponse: true
        )))
        await waitForToolSendToStart(on: transport)
        transport.emit(.disconnected)
        await waitForToolCancellation(on: transport)

        XCTAssertTrue(transport.toolSendWasCancelled)
        XCTAssertEqual(session.phase, .recoverableError)
        XCTAssertEqual(
            session.errorMessage,
            "The voice connection ended before that request finished."
        )
        XCTAssertTrue(transport.toolResults.isEmpty)
    }

    @MainActor
    private func waitForToolResult(on transport: TestVoiceSessionTransport) async {
        for _ in 0..<100 where transport.toolResults.isEmpty {
            await Task.yield()
        }
    }

    @MainActor
    private func waitForToolSendToStart(on transport: TestVoiceSessionTransport) async {
        for _ in 0..<100 where !transport.toolSendStarted {
            await Task.yield()
        }
    }

    @MainActor
    private func waitForToolCancellation(on transport: TestVoiceSessionTransport) async {
        for _ in 0..<100 where !transport.toolSendWasCancelled {
            await Task.yield()
        }
    }

    private func requirement(
        id: String = UUID().uuidString,
        outcome: AnalysisOutcome,
        priority: MobilityNeedPriority,
        findings: [AssessmentFinding] = [],
        title: String? = nil,
        targetObjectID: String? = nil,
        kind: AssessmentRequirementKind = .requiredDestination,
        routes: [AssessmentRoute] = [],
        measurements: [AssessmentMeasurementEvidence] = []
    ) -> AssessmentRequirementResult {
        AssessmentRequirementResult(
            id: id,
            kind: kind,
            title: title ?? id,
            targetObjectID: targetObjectID,
            priority: priority,
            outcome: outcome,
            summary: "",
            routes: routes,
            findings: findings,
            focusPolygons: [],
            measurements: measurements
        )
    }

    private func finding(id: String) -> AssessmentFinding {
        AssessmentFinding(
            id: id,
            title: id,
            details: "",
            outcome: .doesNotMeetNeed,
            location: nil
        )
    }

    private func assessmentResult(
        requirements: [AssessmentRequirementResult],
        status: ArrangementStatus? = nil,
        score: LayoutScore? = nil
    ) -> AssessmentResult {
        AssessmentResult(
            engineVersion: AssessmentEngine.engineVersion,
            status: status ?? AssessmentEngine.status(for: requirements),
            score: score ?? AssessmentEngine.score(for: requirements),
            conflicts: [],
            determinedRequirementCount: requirements.filter { $0.outcome != .needsVerification }.count,
            totalRequirementCount: requirements.count,
            requirements: requirements,
            map: AssessmentMapModel(
                floor: FloorPolygon(points: []),
                obstacles: [],
                accessPoints: [],
                zones: []
            )
        )
    }
}

@MainActor
private final class TestVoiceSessionTransport: VoiceSessionTransport {
    var eventHandler: ((VoiceTransportEvent) -> Void)?
    var startCount = 0
    var stopCount = 0
    var toolResults: [(VoiceToolResult, VoiceToolCall)] = []
    var toolSendStarted = false
    var toolSendWasCancelled = false

    private let startError: VoiceSessionTransportError?
    private let blockToolResults: Bool

    init(
        startError: VoiceSessionTransportError? = nil,
        blockToolResults: Bool = false
    ) {
        self.startError = startError
        self.blockToolResults = blockToolResults
    }

    func start() async throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func stop() async {
        stopCount += 1
    }

    func sendToolResult(_ result: VoiceToolResult, for call: VoiceToolCall) async throws {
        toolSendStarted = true
        if blockToolResults {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                toolSendWasCancelled = true
                throw error
            }
        }
        toolResults.append((result, call))
    }

    func emit(_ event: VoiceTransportEvent) {
        eventHandler?(event)
    }
}

private struct RoomStoreFixture {
    let rootDirectory: URL
    let storeDirectory: URL

    init() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "AccessiRoomTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        storeDirectory = rootDirectory.appending(path: "Store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    func makeCandidate(
        source: CapturedRoomSource,
        contents: String
    ) throws -> CapturedRoomArtifact {
        let candidateDirectory = rootDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: candidateDirectory,
            withIntermediateDirectories: true
        )
        let jsonURL = candidateDirectory.appending(path: "CapturedRoom.json")
        let usdzURL = candidateDirectory.appending(path: "CapturedRoom.usdz")
        try Data("\(contents)-json".utf8).write(to: jsonURL)
        try Data("\(contents)-usdz".utf8).write(to: usdzURL)

        return CapturedRoomArtifact(
            id: UUID(),
            jsonURL: jsonURL,
            usdzURL: usdzURL,
            source: source,
            capturedAt: Date(),
            disposableDirectory: candidateDirectory
        )
    }

    func makeRoomPlanCandidate(contents: String) throws -> CapturedRoomArtifact {
        let candidate = try makeCandidate(source: .demo, contents: contents)
        let json = """
        {
          "doors": [{
            "identifier": "door-1",
            "category": {"door": {}},
            "dimensions": [0.9, 2.0, 0]
          }],
          "walls": [{
            "identifier": "wall-1",
            "category": {"wall": {}},
            "dimensions": [4.0, 2.4, 0]
          }],
          "objects": [{
            "identifier": "chair-1",
            "category": {"chair": {}},
            "confidence": {"high": {}},
            "dimensions": [0.6, 1.0, 0.6]
          }]
        }
        """
        try Data(json.utf8).write(to: candidate.jsonURL, options: .atomic)
        return candidate
    }

    func makeArrangementCandidate() throws -> CapturedRoomArtifact {
        let candidate = try makeCandidate(source: .demo, contents: "arrangement")
        let identity = "[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]"
        let json = """
        {
          "floors": [{
            "identifier": "floor-1",
            "category": {"floor": {}},
            "polygonCorners": [[-3,0,-3],[3,0,-3],[3,0,3],[-3,0,3]],
            "transform": \(identity)
          }],
          "doors": [{
            "identifier": "door-1",
            "category": {"door": {}},
            "dimensions": [1.2,2.0,0],
            "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,-3,1]
          }],
          "walls": [{
            "identifier": "wall-1",
            "category": {"wall": {}},
            "dimensions": [6.0,2.4,0],
            "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,-3,1]
          }],
          "objects": [{
            "identifier": "chair-1",
            "category": {"chair": {}},
            "dimensions": [0.8,1.0,0.8],
            "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, -1,0,0,1]
          },{
            "identifier": "table-1",
            "category": {"table": {}},
            "dimensions": [0.8,1.0,0.8],
            "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 1,0,0,1]
          }]
        }
        """
        try Data(json.utf8).write(to: candidate.jsonURL, options: .atomic)
        return candidate
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
