# AccessiRoom

**Scan a room. Identify mobility barriers. Test a better arrangement.**

## Development Setup

AccessiRoom is a native, iPad-only SwiftUI application. The project targets iPadOS 17 or later and uses RoomPlan, ARKit, and RealityKit. Assessment data is intended to remain on device, consistent with [ADR 0001](docs/adr/0001-keep-core-assessment-data-on-device.md).

Requirements:

- macOS with Xcode 26 or later
- An iPad supported by RoomPlan for live room capture
- An Apple development team selected in Xcode for device deployment

Open `AccessiRoom.xcodeproj`, select the `AccessiRoom` scheme, and choose an iPad destination. The app can compile in the iPad simulator, but RoomPlan capture requires supported physical hardware.

From the command line, verify the project without signing:

```sh
xcodebuild -project AccessiRoom.xcodeproj \
  -scheme AccessiRoom \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The checked-in shared scheme includes the `AccessiRoomTests` unit-test target. Before running on a device, set a unique bundle identifier and development team under the app target's Signing & Capabilities settings.

### Room Capture Flow

The initial room-capture slice includes:

- Live RoomPlan capture on supported LiDAR-equipped iPads
- Processing and on-device JSON/USDZ storage
- Scan Review with rescan, cancel, share, and explicit acceptance
- A bundled Demo Room that follows the same review and acceptance path
- One persisted Accepted Room with a Continue Room action
- Interactive system 3D previews for candidate and accepted rooms
- One on-device Mobility Profile that remains when the Accepted Room is replaced
- Explicit, revision-bound Operator confirmation; editing invalidates confirmation
- An optional editable demonstration template sourced to the 2010 ADA Standards
- A deterministic Observed Arrangement assessment with requirement outcomes, score bounds, evidence coverage, representative routes, and a top-down Accessibility Map

Live scanning is disabled when RoomPlan reports that the current device is unsupported. The Demo Room remains available in the simulator.

AccessiRoom is an iPad application that uses Apple RoomPlan, ARKit, and RealityKit to evaluate how well one indoor room supports a specific Room Occupant's known mobility needs.

The product is not a general interior-design tool. Room scanning, visualization, and editing exist to answer a narrower question:

> Does this room arrangement support this person's movement and access needs?

AccessiRoom preserves what the scan observed, lets an Operator test a hypothetical arrangement, and explains whether that proposal improves the room against a confirmed Mobility Profile.

## Product Loop

```text
Create/Confirm Mobility Profile → Continue or Scan Room → Scan Review → Room Setup Review → Assess → Propose Change → Compare
```

Analysis updates automatically after each completed edit. There is no separate recalculation step.

## Who It Is For

The Room Occupant is the person whose mobility needs define the assessment. The Operator is the person holding the iPad and may be:

- The Room Occupant
- A family member
- A caregiver or other informal supporter
- An occupational therapist or accessibility professional

The MVP is designed first for occupants and informal supporters. It uses plain language and does not assume specialist training.

## Mobility Profiles

A Mobility Profile contains measurable requirements for one Room Occupant, such as:

- Minimum passage width
- Required turning space
- Required clearances
- Custom Essential Needs and Preferences

Each need is either:

- **Essential** — it must be met for the arrangement to support the occupant.
- **Preferred** — meeting it improves the experience but is not required.

The Operator explicitly confirms that the profile reflects the occupant's known needs. AccessiRoom does not infer medical requirements from a diagnosis, age, or mobility-device label.

The MVP prioritizes custom profile configuration and may include at most one demonstration template. Any suggested template measurement must identify its source, jurisdiction where applicable, and version. Templates remain editable starting points and do not certify compliance or clinical appropriateness.

One confirmed Mobility Profile belongs to the Room Occupant and may be reused when the accepted room is replaced. Room-specific destinations and zones do not belong to the profile.

## Capturing and Configuring a Room

### Scan Review

RoomPlan captures architectural features, detected objects, approximate dimensions, and placements. Scan Review asks only:

> Is this capture adequate to keep as evidence?

The Operator may accept the capture, rescan, or cancel. Accepting a scan does not make it ready for analysis.

### Room Setup Review

Before AccessiRoom can show findings or a score, the Operator must confirm the room-specific assessment setup:

- Every Access Point
- Movement-relevant Architectural Features
- Which detected objects are real
- Which Captured Objects are movable
- Required Destinations
- Approach Zones beside those destinations
- Turning Zones where turning is necessary

An Access Point is a confirmed door or opening that connects the room to circulation outside it. Closet and cabinet doors are not Access Points merely because they were detected as doors.

Every Access Point must provide usable passage. Every Required Destination, whether Essential or a Preference, must have a suitable route from every Access Point to its Approach Zone; priority determines the consequence of an unsuitable route.

RoomPlan can miss objects or estimate dimensions incorrectly. During setup, the Operator may exclude a false detection. The MVP does not support adding a missed obstacle, correcting captured footprints, or entering manual measurements. These limitations remain visible in the assessment and report.

RoomPlan detection confidence remains visible as evidence provenance but does not change geometry, Measurement Tolerance, outcomes, or scoring. Once the Operator includes a detection during Room Setup Review, the deterministic engine evaluates its captured footprint without inventing a numeric adjustment from the confidence category.

## Assessment

AccessiRoom evaluates floor-plane movement and access using deterministic spatial rules.

The MVP evaluates:

- Passage and doorway clearance
- Continuous routes from Access Points to Required Destinations
- The narrowest clearance along each suitable route
- Approach Zones
- Explicit Turning Zones
- Object-to-object and object-to-architecture conflicts

A suitable route is any continuous route that satisfies the active Mobility Profile. It need not be the geometrically shortest route.

The MVP uses static spatial clearance. It does not simulate the full movement dynamics of a person, wheelchair, or walker. It also does not assess vertical reach, transfers, bed height, desk knee clearance, door-hardware operation, surface conditions, lighting, or furniture stability.

### Analysis Outcomes

Each evaluated need has one of three outcomes:

- **Meets Need** — the spatial evidence supports the requirement with sufficient margin for measurement uncertainty.
- **Does Not Meet Need** — the evidence conflicts with the requirement with sufficient margin.
- **Needs Verification** — uncertainty crosses the requirement threshold, so the app cannot determine the outcome.

Measurement tolerance is conservative, system-defined, non-editable, and disclosed. Borderline measurements are never forced into a pass or failure. The MVP does not allow manual measurements to override captured evidence.

An Analysis Finding explains a concrete mismatch using the affected location, route, or clearance. Findings describe Mobility Barriers; they do not declare that a room is unsafe, inaccessible for everyone, or noncompliant.

## Arrangement Status and Layout Score

Arrangement Status is the primary summary. Its precedence is:

1. **Invalid Proposal** — an Arrangement Conflict exists.
2. **Does Not Support Essential Needs** — at least one Essential Need is confirmed unmet.
3. **Needs Verification** — no Essential Need is confirmed unmet, but at least one remains unresolved.
4. **Supports Essential Needs** — every Essential Need is confirmed met.

Unresolved Preferences do not change a confirmed Supports Essential Needs status, but they make the Layout Score provisional.

The Layout Score is a secondary, deterministic, explainable 0–100 comparison measure. One scored Assessment Requirement is created for each Access Point, Required Destination, Turning Zone, and Custom Mobility Need; individual routes and clearance locations are supporting evidence rather than separately weighted requirements:

- Essential Needs receive 80 points, divided evenly within that group.
- Preferences receive 20 points, divided evenly within that group.
- If no Preferences exist, Essential Needs span all 100 points.
- A score of 100 means every configured need is confirmed met.
- A score of 0 means no configured need is confirmed met.
- An invalid proposal receives no score.
- Needs Verification produces a provisional score range by treating unresolved needs as unmet for the lower bound and met for the upper bound.
- Analysis Coverage states how many needs have determined outcomes.

The score breakdown exposes every contribution. Generative AI does not produce findings, status, or scores.

Scores are meaningful only within one unchanged assessment of one room. They cannot rank different rooms, occupants, profiles, or assessment setups, and they do not represent safety, certification, or code compliance.

## Observed and Proposed Arrangements

The Observed Arrangement preserves the positions and orientations evidenced by the accepted scan.

The Operator creates one current Proposed Arrangement by:

- Moving a confirmed Movable Object
- Rotating a confirmed Movable Object
- Proposing removal of a confirmed Movable Object
- Undoing or redoing edits
- Resetting the proposal to the Observed Arrangement

A Proposed Placement never changes the observed evidence. A Proposed Removal means “consider removing this real object from the physical room”; it does not delete the object from the scan.

Architectural Features such as walls, doors, openings, and windows remain fixed.

The proposal persists across app restarts. The MVP does not retain multiple proposed alternatives or a history of assessments.

### Arrangement Conflicts

Object overlap, crossing a wall, or another physically implausible placement is an Arrangement Conflict. A proposal with unresolved conflicts is invalid and receives no Layout Score.

AccessiRoom does not automatically rearrange furniture. It identifies the affected need and evaluates changes made by the Operator.

## Accessibility Map and 3D View

The primary assessment and editing workspace is a top-down Accessibility Map showing:

- Object footprints
- Access Points
- Suitable routes and limiting clearances
- Required Destinations and Approach Zones
- Turning Zones
- Analysis Findings
- Proposed changes

The interactive 3D room is a supporting view for recognizing objects and understanding spatial context.

The interface itself is part of the accessibility commitment. MVP acceptance includes VoiceOver-labelled controls and findings, Dynamic Type, non-color-only status indicators, comfortable touch targets, and non-gesture alternatives for precise movement and rotation.

## Arrangement Comparison

AccessiRoom compares only the Observed Arrangement with the current Proposed Arrangement under the same assessment setup.

The comparison uses aligned top-down Accessibility Maps and shows:

- Changed placements and Proposed Removals
- Resolved, remaining, and newly introduced findings
- Arrangement Status changes
- Analysis Coverage
- Layout Score or provisional score-range changes

A proposal is an Improved Arrangement only when comparison follows this priority:

1. Better Arrangement Status
2. Fewer unmet Essential Needs
3. Fewer unresolved Essential Needs
4. Better Layout Score and satisfaction of Preferences

A higher score cannot offset a newly unmet Essential Need.

## Assessment Report

The primary user-facing export is a human-readable Assessment Report containing:

- The room and assessment identity
- The confirmed Mobility Profile
- Arrangement Status
- Analysis Coverage
- Analysis Findings
- Observed-versus-proposed maps and comparison
- Measurement and scan limitations
- The non-certification disclaimer

Raw RoomPlan, JSON, and USDZ export is not part of the normal product flow. It may exist only as a development diagnostic capability.

The app retains no history after the accepted room is replaced. An explicitly exported Assessment Report is the durable record.

## Data and Analysis Boundaries

Captured Rooms, Mobility Profiles, confirmed Room Setups, and arrangements are stored and processed on-device. Assessment results are derived on demand from those persisted inputs, and data leaves the device only through an explicit Operator-initiated export.

Authoritative analysis is deterministic and reproducible. A future assistant may explain established results in plain language, but it cannot create, override, or independently score them.

See:

- [ADR 0001: Keep Core Assessment Data On-Device](docs/adr/0001-keep-core-assessment-data-on-device.md)
- [ADR 0002: Keep Generative AI Out of Authoritative Analysis](docs/adr/0002-keep-generative-ai-out-of-authoritative-analysis.md)

## MVP Boundary

The iPad MVP retains:

- One Room Occupant
- One active, confirmed Mobility Profile
- One accepted Captured Room
- One persistent Proposed Arrangement
- Observed-versus-proposed comparison
- No in-app assessment history

Replacing the accepted room preserves the Room Occupant and Mobility Profile but discards the old room setup, arrangements, and live comparison. The replacement requires a new Scan Review and Room Setup Review.

The bundled Demo Room follows the same workflow as a live scan. It may provide a prefilled demonstration profile and suggested setup, but both remain unconfirmed until the Operator reviews them.

Deferred capabilities include:

- Multiple occupants, profiles, or retained rooms
- Multiple saved proposals
- Object Catalog and custom object capture
- Automatic rearrangement suggestions
- Manual obstacle creation or measurement correction
- Dynamic maneuver simulation
- Vertical reach and transfer assessment
- Door-hardware operability analysis
- Multi-room routes
- Cloud synchronization or hosted analysis
- Generative explanations or voice assistance
- Guided Verification and Operator Verification for free-text Custom Mobility Needs
- Professional certification and building-code verification

## Product Limitations

AccessiRoom is a spatial-planning aid. It does not provide:

- Professional accessibility certification
- Building-code compliance verification
- Medical or clinical advice
- Architectural approval
- A guarantee that RoomPlan detected every obstacle
- A guarantee that captured dimensions are exact
- A guarantee that a person can execute a modeled route
- An assessment of door-leaf swing, opening force, thresholds, hardware operation, or effective clear width beyond the nominal captured opening
- Recognition of usable space beneath or within a detected object; every included Captured Object conservatively blocks its full floor-plane footprint
- A claim that a room is safe or unsafe
- Photorealistic reconstruction

The product reports only what its captured spatial evidence supports against the confirmed Mobility Profile.

## Technology

- **RoomPlan** captures room architecture, openings, objects, dimensions, and transforms.
- **ARKit** provides device tracking, alignment, and spatial interaction.
- **RealityKit** renders room geometry, editable proposals, and analysis overlays.
- **Swift and SwiftUI** implement the iPad application, deterministic analysis, setup, findings, comparison, and reports.

## Development Setup

Requirements:

- Xcode
- A RoomPlan-supported physical iPad
- A compatible iPadOS deployment target
- Camera permission configured for the app target

Open the current Xcode project:

```bash
open RoomScanner.xcodeproj
```

RoomPlan capture must be tested on supported physical hardware rather than the iOS Simulator. The repository and target still contain legacy `RoomScanner` and `RealRoom Sandbox` naming while the implementation is migrated to the AccessiRoom domain.

## Domain Documentation

- [CONTEXT.md](CONTEXT.md) defines canonical domain language.
- [docs/adr/](docs/adr/) records durable architectural decisions.
