# AccessiRoom ElevenLabs Voice Backend

This service is the credential boundary between the AccessiRoom iPad application and ElevenLabs. It issues one short-lived WebRTC conversation token per accepted session request. It never receives Assessment Results, map geometry, RoomPlan data, transcripts, or tool results.

## Requirements

- Node.js 20.6 or newer, or Docker
- A private ElevenLabs agent configured with exactly the three client tools in [ADR 0003](../docs/adr/0003-use-backend-issued-elevenlabs-webrtc-tokens.md)
- A restricted ElevenLabs API key

## Local configuration

From this directory:

```sh
cp .env.example .env
```

Edit `.env` and replace only these values:

```text
ELEVENLABS_API_KEY=your_restricted_api_key
ELEVENLABS_AGENT_ID=your_private_agent_id
```

The populated `.env` file is ignored by Git. Do not put either secret in the Xcode project or paste it into application logs.

Start the service:

```sh
npm run start:local
```

Verify it:

```sh
curl http://127.0.0.1:8787/healthz

curl -X POST http://127.0.0.1:8787/v1/voice/sessions \
  -H 'Content-Type: application/json' \
  -d '{
    "protocolVersion": 1,
    "capabilities": ["getRequirementEvidence", "focus", "clearFocus"]
  }'
```

The second response contains a short-lived `conversationToken`. Do not share or persist it.

## Tests

```sh
npm test
```

The tests verify the exact capability allowlist, the rejection of additional geometry or assessment fields, token remapping, provider failures, no-store headers, and rate limiting.

## Deployment

Deploy `backend/` to any Node-compatible HTTPS service, or build the included Dockerfile:

```sh
docker build -t accessiroom-voice-backend .
docker run --rm -p 8787:8787 \
  --env-file .env \
  -e HOST=0.0.0.0 \
  accessiroom-voice-backend
```

`--env-file .env` supplies the ignored local secrets to the running container. The `.env` file is deliberately excluded from the image, so `docker run -e ELEVENLABS_API_KEY` works only when that variable has already been exported in the host shell. `-e HOST=0.0.0.0` overrides the local-only bind address so Docker's published port can reach the process.

Configure the hosting platform's secret manager with:

- `ELEVENLABS_API_KEY`
- `ELEVENLABS_AGENT_ID`

Optional settings:

- `PORT` and `HOST`
- `RATE_LIMIT_PER_MINUTE`, default `30`
- `UPSTREAM_TIMEOUT_MS`, default `10000`
- `TRUST_PROXY=true` only when the service is behind a trusted reverse proxy that sets `X-Forwarded-For`

For a direct Node deployment rather than the Docker image, set `HOST=0.0.0.0` so the hosting platform can reach the process.

Set the iOS target's `ELEVENLABS_BACKEND_BASE_URL` build setting to the deployed HTTPS origin, for example `https://voice.example.com`. The app adds `/v1/voice/sessions` itself.

The current iOS request does not carry application authentication. Before exposing this service as a public production endpoint, add a deployment-appropriate client-authentication mechanism such as App Attest verification in addition to the included rate limiting.

## API contract

`POST /v1/voice/sessions` accepts only:

```json
{
  "protocolVersion": 1,
  "capabilities": [
    "getRequirementEvidence",
    "focus",
    "clearFocus"
  ]
}
```

Any additional property is rejected, deliberately preventing this endpoint from becoming a path for room or assessment data. A successful response is:

```json
{
  "protocolVersion": 1,
  "conversationToken": "short-lived ElevenLabs WebRTC token"
}
```

`GET /healthz` returns process health without exposing configuration.
