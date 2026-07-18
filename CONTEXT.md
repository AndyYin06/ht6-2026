# AccessiRoom

AccessiRoom models a captured physical room so an Operator can identify mobility barriers for a Room Occupant and compare room arrangements that may improve movement and access. Room scanning, visualization, and editing support this accessibility-planning purpose rather than general interior design.

## Language

**AccessiRoom**:
The product experience for evaluating how well an indoor space supports a person's movement and access, then testing potential improvements.
_Avoid_: RealRoom Sandbox, RoomScanner, general-purpose room planner

**Captured Room**:
The digital evidence produced by scanning one physical room, including its detected architecture, objects, dimensions, and placements. Undetected obstacles and inaccurate captured dimensions remain limitations of any assessment derived from it.
_Avoid_: Room model, exact digital twin, verified floor plan

**Room Arrangement**:
The positions and orientations of movable objects within a Captured Room, considered for their effect on movement and access.
_Avoid_: Interior design, decor, layout design

**Room Occupant**:
The specific person whose known mobility needs determine whether a room supports adequate movement and access. The Room Occupant may differ from the person operating AccessiRoom.
_Avoid_: User, accessibility persona, generic profile

**Operator**:
The person using AccessiRoom to scan, configure, and assess a room for the Room Occupant, typically the occupant or an informal supporter. The Operator confirms that the Mobility Profile represents the occupant's known needs and is not assumed to have specialist training.
_Avoid_: Room Occupant, account holder, clinician

**Mobility Needs**:
The Room Occupant's known requirements for moving through and using a room, including any space required by their mobility device.
_Avoid_: Disability type, universal accessibility requirements

**Mobility Profile**:
The measurable Essential Needs and Preferences used to evaluate a room for one Room Occupant, such as required passage width, turning space, and clear floor space. Room-specific destinations and zones are configured later during Room Setup Review.
_Avoid_: Accessibility category, disability label, generic user type

**Profile Template**:
An editable starting point for a Mobility Profile based on a common mobility context. Suggested measurements identify their source, applicable jurisdiction, and version, and do not assert the Room Occupant's actual needs or certify compliance.
_Avoid_: Accessibility Profile, preset requirements

**Analysis Finding**:
A concrete mismatch between a Room Arrangement and a requirement in the active Mobility Profile, expressed with the affected location, route, or clearance.
_Avoid_: Violation, compliance failure, generic warning

**Mobility Barrier**:
A spatial condition identified by an Analysis Finding that interferes with a Mobility Need. It is not a general safety hazard or a declaration that the room is unsafe.
_Avoid_: Safety hazard, code violation, inaccessible room

**Layout Score**:
A deterministic, explainable 0–100 summary for comparing the Observed Arrangement and current Proposed Arrangement within one unchanged assessment. Essential Needs receive 80 points and Preferences receive 20, divided evenly within each group; when no Preferences exist, Essential Needs span all 100 points. A score of 100 means every configured need is confirmed as met; a score of 0 means none are confirmed as met. Invalid proposals receive no score, while unresolved needs produce a provisional range bounded by treating them as unmet and met. Neither endpoint means universally accessible, certified, or safe. The score exposes its contributing findings and Analysis Coverage and cannot rank different rooms, occupants, profiles, or assessment setups.
_Avoid_: Accessibility rating, compliance score, certification score

**Analysis Coverage**:
The proportion of needs in a Mobility Profile for which AccessiRoom can report Meets Need or Does Not Meet Need. It accompanies a provisional Layout Score when one or more needs require verification.
_Avoid_: Confidence score, completion percentage, scan quality

**Assessment Report**:
The human-readable export of an assessment, including its Mobility Profile, Arrangement Status, Analysis Coverage, Analysis Findings, limitations, and any Arrangement Comparison.
_Avoid_: Accessibility certificate, inspection report, raw room export

**Essential Need**:
A Mobility Need that must be satisfied for the arrangement to support the Room Occupant. Failure of an Essential Need cannot be offset by improvements elsewhere in the Layout Score.
_Avoid_: High-weight rule, critical warning, mandatory compliance rule

**Preference**:
A Mobility Need whose satisfaction improves the Room Occupant's experience but is not required for the arrangement to support them.
_Avoid_: Optional rule, minor issue, low-weight requirement

**Required Destination**:
A place or object in one Captured Room that the Room Occupant must be able to approach. Required Destinations are chosen explicitly for that room rather than inferred from every detected object or carried in the Mobility Profile.
_Avoid_: Detected object, point of interest, automatic destination

**Access Point**:
An operator-confirmed door or opening that connects the room to circulation outside it. Usable passage at every Access Point and a Suitable Route from each Access Point to every Essential Required Destination are Essential Needs; closet and cabinet doors are not Access Points.
_Avoid_: Route Origin, every detected door, scan opening

**Suitable Route**:
Any continuous path from an Access Point to a Required Destination's Approach Zone that satisfies the applicable Mobility Profile requirements. It need not be the geometrically shortest path, and its limiting clearance remains visible in the result.
_Avoid_: Shortest path, walking line, guaranteed traversal

**Room Setup Review**:
The required confirmation that a Captured Room correctly identifies Access Points, movement-relevant Architectural Features, Movable Objects, Required Destinations, Approach Zones, and Turning Zones. Findings and scores are unavailable until this review is complete.
_Avoid_: Scan Review, room approval, analysis preview

**Scan Review**:
The stage where the Operator decides whether a newly Captured Room is adequate to retain as evidence. It does not configure or approve the room for a Mobility Profile.
_Avoid_: Room Setup Review, analysis setup, results screen

**Approach Zone**:
The usable arrival area associated with a Required Destination. A destination is reachable only when the Room Occupant can follow a Suitable Route from each applicable Access Point into this zone with the space required by their Mobility Profile.
_Avoid_: Object edge, destination point, bounding box

**Turning Zone**:
A room-specific area where the Room Occupant must be able to turn using the turning-space dimensions in their Mobility Profile.
_Avoid_: Universal turning clearance, open floor area, route node

**Observed Arrangement**:
The positions and orientations of objects evidenced by a Captured Room. It is the baseline for analysis and remains unchanged by digital experimentation.
_Avoid_: Original layout, current room, saved arrangement

**Proposed Arrangement**:
A hypothetical change to an Observed Arrangement used to predict how movement and access might improve. It does not assert that the physical room has changed or that the prediction has been verified.
_Avoid_: Revised room, improved room, updated scan

**Arrangement Comparison**:
An evaluation of the Observed Arrangement and the current Proposed Arrangement using the same Mobility Profile and room-specific assessment setup.
_Avoid_: Room comparison, saved alternatives, before-and-after proof

**Arrangement Status**:
The primary summary of an arrangement, determined in order: any Arrangement Conflict makes a proposal Invalid; otherwise any unmet Essential Need means Does Not Support Essential Needs; otherwise any unresolved Essential Need means Needs Verification; otherwise it Supports Essential Needs. Preference uncertainty affects the Layout Score range but not a confirmed Supports Essential Needs status.
_Avoid_: Accessibility status, pass/fail grade, score band

**Improved Arrangement**:
A Proposed Arrangement with a better Arrangement Status, fewer unmet or unresolved Essential Needs, or—when those are equal—a better Layout Score and satisfaction of Preferences. A score increase cannot offset a newly unmet Essential Need.
_Avoid_: Higher-scoring layout, optimized room, accessible arrangement

**Accessibility Map**:
The top-down representation of a Room Arrangement used to understand routes, clearances, Required Destinations, Approach Zones, and Analysis Findings. It is the primary workspace for assessment and rearrangement.
_Avoid_: Floor plan, minimap, 3D room view

**Captured Object**:
An object whose presence and observed placement are evidenced by a Captured Room.
_Avoid_: Catalog Item, Placed Object, furniture asset

**Excluded Detection**:
A detected object that the operator identifies as false during Room Setup Review and excludes from assessment. This corrects the assessment input rather than proposing removal of a real object.
_Avoid_: Proposed Removal, deleted furniture, removed obstacle

**Proposed Placement**:
A hypothetical position and orientation assigned to a movable Captured Object within a Proposed Arrangement. It leaves the object's observed placement intact.
_Avoid_: Updated object, edited scan, actual placement

**Movable Object**:
A Captured Object that the operator confirms may be repositioned in a Proposed Arrangement. Automated recognition may suggest this classification but does not decide it conclusively.
_Avoid_: Furniture category, editable entity, Catalog Item

**Architectural Feature**:
A fixed part of the Captured Room, such as a wall, door, opening, or window, that constrains arrangements but cannot receive a Proposed Placement.
_Avoid_: Immovable object, room object

**Proposed Removal**:
The omission of a Movable Object from a Proposed Arrangement, representing the possibility of removing it from the physical room. The object remains present in the Observed Arrangement.
_Avoid_: Delete object, erase scan, correct detection

**Arrangement Conflict**:
A physically implausible relationship within a Proposed Arrangement, such as overlapping objects or an object crossing an Architectural Feature. An arrangement with unresolved conflicts is not eligible for a Layout Score.
_Avoid_: Accessibility concern, Analysis Finding, collision warning

**Meets Need**:
An analysis outcome indicating that the available spatial evidence supports a requirement in the Mobility Profile with sufficient margin for measurement uncertainty.
_Avoid_: Accessible, compliant, passed

**Does Not Meet Need**:
An analysis outcome indicating that the available spatial evidence conflicts with a requirement in the Mobility Profile with sufficient margin for measurement uncertainty.
_Avoid_: Inaccessible, noncompliant, failed

**Needs Verification**:
An analysis outcome indicating that measurement uncertainty prevents AccessiRoom from determining whether a requirement in the Mobility Profile is met.
_Avoid_: Probably accessible, borderline pass, unknown error
