# ADR 0003: Use Backend-Issued ElevenLabs WebRTC Conversation Tokens

**Status:** Accepted  
**Date:** July 18, 2026

## Context

AccessiRoom needs a real, low-latency ElevenLabs conversation without putting a permanent ElevenLabs credential in the iPad application. The first interaction is read-only: the agent may request authoritative requirement evidence and presentation focus, but it may not mutate assessment or room state.

ElevenLabs supports direct WebSocket conversations and WebRTC through its Swift SDK. The Swift SDK handles microphone capture, playback, echo cancellation, interruption, transcripts, connection state, and client-tool calls. ElevenLabs recommends WebRTC conversation tokens for private agents; the token is created with `GET /v1/convai/conversation/token` by a trusted service holding the ElevenLabs API key.

## Decision

Use the official ElevenLabs Swift SDK over WebRTC. A trusted AccessiRoom backend issues a short-lived conversation token. The iPad never receives an ElevenLabs API key and never sends assessment evidence to the backend.

The app calls this backend endpoint when the Operator starts a disclosed voice session:

```http
POST /v1/voice/sessions
Content-Type: application/json

{
  "protocolVersion": 1,
  "capabilities": [
    "getRequirementEvidence",
    "focus",
    "clearFocus"
  ]
}
```

Successful response:

```json
{
  "protocolVersion": 1,
  "conversationToken": "short-lived ElevenLabs WebRTC token"
}
```

The backend must:

- Authenticate and rate-limit the application request as appropriate for the deployment.
- Keep `xi-api-key` server-side.
- Request the token from ElevenLabs for the configured private AccessiRoom agent.
- Return only the short-lived conversation token; it does not receive RoomPlan data, assessment data, audio, transcripts, or tool results.
- Reject unsupported protocol versions or capability sets instead of silently broadening access.

The private ElevenLabs agent must define exactly these client tools:

1. `getRequirementEvidence`
   - Optional `requirement_id` string.
   - Optional `name` string.
   - Optional `requested_conclusion`: `meetsNeed`, `doesNotMeetNeed`, or `needsVerification`.
   - Exactly one of `requirement_id` or `name` is required.
2. `focus`
   - Optional `requirement_id` string.
   - Optional `name` string.
   - Exactly one is required.
3. `clearFocus`
   - No parameters.

No webhook, MCP, system action, mutation, file, network, or generic automation tool is part of the AccessiRoom agent configuration. The agent prompt must say that an evidence response's `authoritativeExplanation` is the complete text it may narrate about the result; clarification and refusal messages must be repeated without alteration.

Tool calls run on the iPad against the current in-memory `AssessmentResult`. Only a minimized Codable result crosses the WebRTC session: response kind, opaque requirement identifiers, visible titles/outcomes needed for clarification, and the authoritative explanation or gateway message. Route points, limiting-segment coordinates, polygons, captured-object geometry, RoomPlan JSON, USDZ data, local paths, and occupant identity never enter a tool result.

## Lifecycle

- The app requests a new backend token for every Operator-started voice session.
- The ElevenLabs SDK owns WebRTC audio and interruption handling.
- The app observes user transcripts, agent responses, speaking/listening state, disconnects, and unhandled client-tool calls.
- Disconnecting ends microphone/audio transport, cancels the in-flight local turn, clears ephemeral transcript and clarification state when the session is explicitly stopped, and never changes authoritative local state.
- A provider or backend failure leaves all assessment and touch workflows available.

## Consequences

- WebRTC adds the official ElevenLabs Swift SDK and its LiveKit dependency to the app.
- The deployment must provide `ELEVENLABS_BACKEND_BASE_URL`; an absent value produces a recoverable voice-unavailable state.
- The backend is deliberately a credential broker, not an assessment service or RoomPlan store.
- Mutation cards and revision tokens remain a later protocol version and require a separate decision.

## References

- [ElevenLabs Swift SDK](https://elevenlabs.io/docs/eleven-agents/libraries/swift)
- [ElevenLabs conversation token endpoint](https://elevenlabs.io/docs/eleven-agents/api-reference/conversations/get-webrtc-token)
- [ElevenLabs client events and client tool calls](https://elevenlabs.io/docs/eleven-agents/customization/events/client-events)

