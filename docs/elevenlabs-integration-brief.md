# ElevenLabs Integration Brief and Decision Record

**Status:** Working product and engineering brief  
**Discussion date:** July 18, 2026  
**Primary source:** [AccessiRoom ElevenLabs Integration Specification](../AccessiRoom_ElevenLabs_Integration_Specification.docx)  
**Related decisions:** [ADR 0001](adr/0001-keep-core-assessment-data-on-device.md), [ADR 0002](adr/0002-keep-generative-ai-out-of-authoritative-analysis.md)

## Purpose

This document records the important requirements from the supplied ElevenLabs integration specification and the decisions made during follow-up discussion. It is intended to be the concise implementation handoff for the current project.

When this brief differs from the source specification, the decision recorded here controls the current implementation scope. Deferred topics must not be silently resolved by implementation assumptions.

## Product Position

AccessiRoom Guide is a conversational control and explanation layer for the native iPad application. It helps an Operator configure a Captured Room, understand deterministic findings, test hypothetical furniture changes, and interact with the application while their hands or attention are occupied.

The ElevenLabs agent is not an assessment engine. It may interpret speech, explain approved structured evidence, focus relevant interface elements, and propose allowlisted actions. It must never:

- Create, override, independently score, or predict Analysis Findings, Arrangement Status, Layout Scores, or comparison outcomes.
- Infer mobility requirements from diagnoses, disability labels, images, voice, or observed behaviour.
- Present medical, legal, safety-certification, or building-code conclusions.
- Alter the Observed Arrangement or accepted RoomPlan evidence.
- Upload raw RoomPlan JSON, USDZ, complete floor polygons, or whole-room household scans.
- Automatically optimize or rearrange the room.
- Become the only way to operate AccessiRoom.

The deterministic local Assessment Engine remains the sole authority for results. This preserves the boundary established by ADR 0002.

## Confirmed Decisions from Discussion

### Supported experience

- Voice should be available across all integration-relevant screens: Room Setup, Assessment, Proposed Arrangement editing, Arrangement Comparison, and other supported integration surfaces.
- A voice session should remain active while the user navigates between supported screens.
- Spoken imperial measurements such as “eight inches” are supported. Values must be converted into the metric units used by the domain and spatial systems before validation or application.
- Touch remains available for every voice operation. The underlying AccessiRoom workflow must remain fully usable without voice.

### Connection architecture

- Use a backend integration rather than embedding a permanent ElevenLabs credential in the iPad application.
- The backend may broker credentials and the ElevenLabs conversation, but it does not become an authoritative assessment service or a store for RoomPlan data.
- The exact backend platform, hosting model, and deployment destination are deferred from the current scope.

### Consent, privacy, and retention

- Starting a clearly disclosed voice session counts as explicit authorization to send microphone audio and the permitted minimal structured context to the remote provider.
- This is a deliberate exception to ADR 0001's original “explicit export only” wording. ADR 0001 should eventually be amended to record disclosed, user-initiated assistant sessions as a narrow data-egress exception.
- The agent may receive user-facing object labels, exact assessment measurements, and simplified spatial relations required for the current request.
- Transcripts disappear when the voice session ends.
- Development audit logs are session-only and disappear when the session ends.
- Sensitive audio is not stored in the application audit log.

### Visual grounding and object identity

- “Left,” “right,” “forward,” and “back” are resolved relative to the visible top-down screen orientation.
- The resolved direction must be shown visually before the user confirms a mutation.
- Users may rename detected objects.
- A selected object becomes the conversational focus, allowing references such as “this chair” or “move this one.”
- Previews, maps, comparison views, and reports must explicitly label objects so that spoken references match visible references.
- If multiple objects remain possible, the app highlights the candidates and asks the user to choose. It must not silently select one.

### Mutation validation and confirmation

- Voice-initiated moves that create an Arrangement Conflict are rejected and cannot be confirmed.
- Touch editing may continue to permit conflicting proposals so the existing Invalid Proposal state remains visible through the manual workflow.
- Every mutation requires its own explicit confirmation, including setup changes, proposal edits, removal, reset, undo, and manual verification actions if those actions are later introduced.
- A generic “yes” confirms only when exactly one pending action is visible and the agent has just requested confirmation.
- A pending action is invalidated immediately when a relevant touch edit or other state change makes its state token stale.
- Pending actions expire after 60 seconds.
- Silence, unrelated speech, ambiguous replies, and expired or stale cards never confirm an action.

### Movement precision

- Movement snapping, editing increments, and vague commands such as “move it a little” are outside the current decision scope.
- The implementation must not invent a meaning for vague movement amounts.
- Supported voice movement commands therefore require an explicit numeric value and unit unless a later decision introduces bounded presets.

## Trust and State Model

The integration recognizes three types of state:

1. **Authoritative persisted state:** Mobility Profile, profile confirmation, Accepted Room, confirmed Room Setup, Proposed Arrangement, and any future confirmed manual verification records.
2. **Derived local state:** Assessment Results, route evidence, conflicts, Arrangement Comparison, Arrangement Status, and Layout Score.
3. **Ephemeral integration state:** Voice connection, transcript, conversational focus, reference candidates, pending action, and temporary speech-parsing results.

The agent must not retain a shadow copy capable of overwriting newer local state.

Every context response and staged mutation should carry an opaque state token representing the relevant Accepted Room, profile, setup, proposal, and Assessment Engine revisions. If local state changes, the gateway rejects the stale request, refreshes context, and explains that the room changed before the action could be applied.

The current code has a profile revision but does not yet expose equivalent setup and proposal revisions. The implementation will need a deterministic revision or token strategy before remote mutations are safe.

## Permitted and Prohibited Context

Context must be scoped to the current request.

Permitted context includes:

- Current workflow step and supported screen.
- Opaque room, profile, setup, and proposal identifiers or revisions.
- Current focus and visible entity IDs, labels, categories, and selected state.
- Movable-object and Required Destination flags.
- The current requirement's outcome, priority, values, units, route evidence, and local explanation summary.
- Simplified spatial relations needed to resolve the current instruction.
- A pending action description and its local validation result.

Prohibited context includes:

- Raw RoomPlan JSON or USDZ.
- Complete floor or obstacle geometry.
- Occupant names and unrelated profile notes.
- Unredacted local paths or storage details.
- Whole-room data when a smaller entity-scoped payload is sufficient.
- Historical transcripts unless a future explicit opt-in policy is approved.

Custom needs, object names, transcripts, and provider responses are untrusted text. Labels cannot grant authority or bypass schemas.

## Expected Session and Conversation Behaviour

The voice surface should expose clear states for inactive, permission required, connecting, listening, thinking, speaking, awaiting confirmation, executing, recoverable error, and ended.

During a session:

- Microphone activity is continuously visible and communicated with text or symbols, not colour alone.
- Partial and final transcripts are captioned.
- The user can stop the session and interrupt agent speech.
- Barge-in stops the current response promptly and processes the new request.
- Answers lead with the direct result, then controlling evidence, then one supported next action.
- Exact dimensions and uncertainty language are preferred over general accessibility jargon.
- The agent does not read an entire assessment unless explicitly asked.
- Unsupported questions receive a clear product limitation rather than speculation.
- Instructions to ignore the app, mark something accessible, or override a finding are refused.

The overlay must not obscure the current map focus, primary finding, or pending action card. Voice controls require touch equivalents, VoiceOver labels, Dynamic Type support, logical focus order, Switch Control and keyboard reachability, and Reduce Motion support.

## Tool and Action Boundary

The local Agent Gateway exposes an allowlisted, typed interface. It validates identifiers, state tokens, permissions, numeric ranges, normalized units, target compatibility, and domain constraints before creating a pending action.

Expected read and presentation operations include:

- Get workflow context and supported actions.
- List the visible, redacted entities.
- Get local evidence for one Assessment Requirement.
- Get the local Assessment or Arrangement Comparison summary.
- Focus an entity, finding, route, or comparison section.

Expected staged mutations include:

- Room Setup changes such as selecting an Access Point, including or excluding a detection, marking an object movable, or identifying a Required Destination.
- Proposed Arrangement translation, rotation, removal, reset, and undo.

A pending action card must show the target, original request, normalized domain change, local validation result, expected reassessment, state token/expiry, and Confirm, Cancel, and Inspect controls.

No generic file, shell, network, reflection, outcome-writing, or arbitrary automation tool is available to the agent.

## Core Journeys Retained from the Specification

### Explain a finding

The agent resolves the referenced requirement or destination, requests the latest structured evidence, focuses the relevant object and route limitation, and explains the authoritative result using measured and required values. Ambiguous references require visible candidate selection.

### Configure Room Setup

The agent may stage valid semantic changes against the current draft. The local gateway validates the entity type and setup state. Confirmation commits through the existing Room Setup model. If the mutation invalidates setup confirmation, the interface must require reconfirmation before assessment.

### Edit a Proposed Arrangement

The agent resolves the focused or named movable object, direction, numeric distance or rotation, and unit. The gateway converts units, validates the transformation, and presents the result. Voice rejects conflicts. A confirmed valid edit is persisted locally and triggers deterministic reassessment.

The agent cannot claim that a proposal improved until the local Arrangement Comparison is available.

### Compare arrangements

The agent requests the authoritative local comparison instead of comparing results itself. Explanations prioritize changes to Essential Needs, then unresolved uncertainty, then scores and Preferences. A visually cleaner layout is not described as improved when the deterministic comparison says otherwise.

### Propose removal

Removal is explicitly described as hypothetical. Removing a Required Destination from a proposal does not delete its requirement; it causes that requirement to be unmet. Removal always requires confirmation.

## Failure Handling Retained from the Specification

Failures preserve the previous authoritative state and produce an explicit incomplete or recoverable state. In particular:

- Connection failure leaves the local workflow usable and offers retry.
- A dropped connection cancels an incomplete remote turn.
- Malformed, unsupported, or out-of-range tool calls are rejected locally.
- Stale tokens cause context refresh, not a write.
- Ambiguous objects produce a clarification prompt and visible candidates.
- Non-movable targets are rejected.
- Conflicting voice moves are displayed but cannot be confirmed.
- Uncertain speech values are repeated or shown as alternatives; the system never guesses silently.
- Unsupported assessment questions name the product limitation.
- Old results are never narrated as current after reassessment failure.

The voice provider may require connectivity, but Accepted Rooms, profiles, setup, assessment, proposal editing, comparison, and reports remain local and available without it.

## Deferred and Out-of-Scope Decisions

The following topics were explicitly moved out of the current scope. They are not acceptance criteria and must not be resolved through undocumented implementation choices:

- Movement snapping and increment policy beyond requiring explicit numeric commands.
- Exact Guided Verification authority and its relationship to captured evidence.
- The first supported Guided Verification measurement workflow.
- Manual-measurement precedence, persistence, invalidation, deletion, and re-entry.
- Whether verification may record non-numeric Operator determinations.
- Rollback versus preservation when a proposal saves but reassessment fails.
- Whether a locally validated card remains touch-confirmable after voice disconnects.
- Exact backgrounding and system-interruption lifecycle.
- Backend platform, hosting, and deployment destination.

Because those decisions are deferred, Guided Verification is not implementation-ready in the current scope even though the source specification identifies it as a hackathon must-ship capability. It must either be formally removed from the demo acceptance criteria or revisited before implementation.

Other future extensions retained from the source document include live capture guidance, continuous rapid-edit mode, professional case-history workflows, on-device speech recognition and synthesis, transcript export, localization preferences, and locally generated deterministic layout suggestions.

## Current Documentation Conflicts

The integration creates three deliberate differences from existing project documentation:

1. ADR 0001 currently permits data egress only through explicit export. The confirmed decision adds disclosed, user-initiated voice sessions as a narrow exception for microphone audio and minimized structured context.
2. The README says manual measurements do not override captured evidence. Guided Verification remains deferred until its authority and provenance rules are resolved.
3. The source specification permits explicit voice undo without staging, but the confirmed project decision requires confirmation for every mutation, including undo and reset.

These differences should be reconciled in the ADRs and README when the corresponding implementation work begins.

## Acceptance Baseline for the Current Scope

The current integration is successful when it can demonstrate all of the following without violating the trust boundary:

- A stable, disclosed ElevenLabs voice session that persists across supported-screen navigation.
- Live transcripts/captions and visible microphone and connection state.
- Evidence-grounded explanation of at least one local Assessment Requirement.
- Visual highlighting and explicit labels for every referenced object or route.
- Selection or clarification when object references are ambiguous.
- A numeric voice movement command with imperial-to-metric conversion where needed.
- A validated, time-limited action card and explicit confirmation.
- Rejection of a conflicting voice move while preserving the manual Invalid Proposal workflow.
- Local reassessment after a confirmed valid edit.
- An authoritative Observed-versus-Proposed comparison explanation.
- Refusal of attempts to override or fabricate outcomes.
- Continued operation of the complete local app when voice is unavailable.
- No persistence of transcripts or development audit logs after the session ends.

Guided Verification is excluded from this baseline until the deferred decisions are reopened.

## Decision Trace

| Topic | Decision |
| --- | --- |
| Supported screens | All integration-relevant screens |
| Navigation | Voice session continues across supported screens |
| Units | Spoken imperial values supported and converted to metric domain units |
| Provider architecture | Use a backend; deployment choice deferred |
| Remote authorization | Disclosed, user-started voice session is explicit authorization |
| Remote context | Labels, exact measurements, and request-scoped simplified relations allowed |
| Transcript retention | Delete at session end |
| Development audit retention | Session-only |
| Direction frame | Relative to visible top-down screen orientation |
| Movement increments | Deferred; explicit numeric amount required |
| Object identity | User-renamable, selectable focus, visibly labelled in previews and reports |
| Voice conflicts | Reject confirmation |
| Touch conflicts | Continue to allow Invalid Proposal state |
| State changes while pending | Invalidate the card immediately |
| Pending timeout | 60 seconds |
| Mutation confirmation | Required separately for every mutation, including undo and reset |
| Remaining follow-up questions | Moved out of current scope |
