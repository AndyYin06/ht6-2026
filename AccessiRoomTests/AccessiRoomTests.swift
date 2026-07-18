import XCTest
@testable import AccessiRoom

final class AccessiRoomTests: XCTestCase {
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

    private func requirement(
        id: String = UUID().uuidString,
        outcome: AnalysisOutcome,
        priority: MobilityNeedPriority
    ) -> AssessmentRequirementResult {
        AssessmentRequirementResult(
            id: id,
            kind: .requiredDestination,
            title: id,
            priority: priority,
            outcome: outcome,
            summary: "",
            routes: [],
            findings: [],
            focusPolygons: []
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

    func remove() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
