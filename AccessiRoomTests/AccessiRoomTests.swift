import XCTest
@testable import AccessiRoom

final class AccessiRoomTests: XCTestCase {
    func testDraggedPlacementStopsBeforeCrossingWall() {
        let roomID = UUID()
        let map = placementMap(
            object: rectangle(minX: -0.25, maxX: 0.25, minZ: -0.25, maxZ: 0.25),
            wall: rectangle(minX: 0.75, maxX: 0.85, minZ: -2, maxZ: 2)
        )

        let translation = ProposedPlacementGeometry.constrainedTranslation(
            for: "chair",
            requested: FloorPoint(x: 2, z: 0),
            map: map,
            arrangement: .empty(roomID: roomID)
        )

        XCTAssertGreaterThan(translation.x, 0.45)
        XCTAssertLessThan(translation.x, 0.50)
        XCTAssertEqual(translation.z, 0, accuracy: 0.000_001)
    }

    func testDraggedPlacementStaysInsideFloorBoundary() {
        let roomID = UUID()
        let map = placementMap(
            object: rectangle(minX: -0.25, maxX: 0.25, minZ: -0.25, maxZ: 0.25),
            wall: rectangle(minX: 1.8, maxX: 1.9, minZ: -2, maxZ: 2)
        )

        let translation = ProposedPlacementGeometry.constrainedTranslation(
            for: "chair",
            requested: FloorPoint(x: -3, z: 0),
            map: map,
            arrangement: .empty(roomID: roomID)
        )

        XCTAssertGreaterThan(translation.x, -1.76)
        XCTAssertLessThan(translation.x, -1.70)
    }

    func testDuplicateRoomItemDisplayNamesAreNumberedInCaptureOrder() {
        let items = [
            inventoryItem(id: "chair-a", category: "chair"),
            inventoryItem(id: "table", category: "table"),
            inventoryItem(id: "chair-b", category: "chair"),
            inventoryItem(id: "wall-a", category: "wall"),
            inventoryItem(id: "wall-b", category: "wall"),
            inventoryItem(id: "door-a", category: "door"),
            inventoryItem(id: "door-b", category: "door"),
        ]

        let names = CapturedRoomInventory.displayNames(for: items)

        XCTAssertEqual(names["chair-a"], "Chair 1")
        XCTAssertEqual(names["table"], "Table")
        XCTAssertEqual(names["chair-b"], "Chair 2")
        XCTAssertEqual(names["wall-a"], "Wall 1")
        XCTAssertEqual(names["wall-b"], "Wall 2")
        XCTAssertEqual(names["door-a"], "Door 1")
        XCTAssertEqual(names["door-b"], "Door 2")
    }

    private func placementMap(object: FloorPolygon, wall: FloorPolygon) -> AssessmentMapModel {
        AssessmentMapModel(
            floor: rectangle(minX: -2, maxX: 2, minZ: -2, maxZ: 2),
            obstacles: [
                AssessmentMapModel.LabelledPolygon(id: "wall", label: "Wall", polygon: wall),
                AssessmentMapModel.LabelledPolygon(id: "chair", label: "Chair", polygon: object),
            ],
            accessPoints: [],
            zones: []
        )
    }

    private func rectangle(
        minX: Double,
        maxX: Double,
        minZ: Double,
        maxZ: Double
    ) -> FloorPolygon {
        FloorPolygon(points: [
            FloorPoint(x: minX, z: minZ),
            FloorPoint(x: maxX, z: minZ),
            FloorPoint(x: maxX, z: maxZ),
            FloorPoint(x: minX, z: maxZ),
        ])
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

    @MainActor
    func testAssessmentMapUsesNumberedLabelsForDuplicateObjects() throws {
        let fixture = try RoomStoreFixture()
        defer { fixture.remove() }

        let store = AcceptedRoomStore(rootDirectory: fixture.storeDirectory)
        try store.accept(fixture.makeArrangementCandidate(secondObjectCategory: "chair"))
        let room = try XCTUnwrap(store.acceptedRoom)
        let inventory = try CapturedRoomInventory.load(from: room.jsonURL)
        var setup = RoomSetup.draft(roomID: room.id, inventory: inventory, measurements: nil)
        setup.accessPointIDs = ["door-1", "door-2"]
        setup.confirmedAt = Date()

        let result = try AssessmentEngine().assess(
            room: room,
            profile: .customDraft(),
            setup: setup
        )
        let labelsByID = Dictionary(uniqueKeysWithValues: result.map.obstacles.map { ($0.id, $0.label) })

        XCTAssertEqual(labelsByID["chair-1"], "Chair 1")
        XCTAssertEqual(labelsByID["table-1"], "Chair 2")
        XCTAssertEqual(labelsByID["wall-1"], "Wall 1")
        XCTAssertEqual(labelsByID["wall-2"], "Wall 2")
        XCTAssertTrue(result.map.obstacles.first { $0.id == "chair-1" }?.displaysLabel == true)
        XCTAssertTrue(result.map.obstacles.first { $0.id == "wall-1" }?.displaysLabel == true)
        XCTAssertEqual(result.map.accessPoints.map(\.label), ["Door 1", "Door 2"])
        XCTAssertTrue(result.map.accessPoints.allSatisfy(\.displaysLabel))
    }

    private func inventoryItem(id: String, category: String) -> CapturedRoomInventory.Item {
        CapturedRoomInventory.Item(
            id: id,
            category: category,
            widthMetres: 1,
            depthMetres: 1,
            confidence: nil,
            transform: [],
            polygonCorners: []
        )
    }

    private func requirement(
        id: String = UUID().uuidString,
        outcome: AnalysisOutcome,
        priority: MobilityNeedPriority,
        findings: [AssessmentFinding] = []
    ) -> AssessmentRequirementResult {
        AssessmentRequirementResult(
            id: id,
            kind: .requiredDestination,
            title: id,
            priority: priority,
            outcome: outcome,
            summary: "",
            routes: [],
            findings: findings,
            focusPolygons: []
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

    func makeArrangementCandidate(secondObjectCategory: String = "table") throws -> CapturedRoomArtifact {
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
          },{
            "identifier": "door-2",
            "category": {"door": {}},
            "dimensions": [1.2,2.0,0],
            "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 2,0,3,1]
          }],
          "walls": [{
            "identifier": "wall-1",
            "category": {"wall": {}},
            "dimensions": [6.0,2.4,0],
            "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,-3,1]
          },{
            "identifier": "wall-2",
            "category": {"wall": {}},
            "dimensions": [6.0,2.4,0],
            "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,3,1]
          }],
          "objects": [{
            "identifier": "chair-1",
            "category": {"chair": {}},
            "dimensions": [0.8,1.0,0.8],
            "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, -1,0,0,1]
          },{
            "identifier": "table-1",
            "category": {"\(secondObjectCategory)": {}},
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
