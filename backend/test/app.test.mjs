import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { CAPABILITIES, createRequestHandler } from "../src/app.mjs";

const validBody = {
  protocolVersion: 1,
  capabilities: CAPABILITIES,
};

test("startup fails fast when ElevenLabs secrets are absent or still placeholders", () => {
  assert.throws(
    () => createRequestHandler({ agentId: "test-agent" }),
    /ELEVENLABS_API_KEY is required/,
  );
  assert.throws(
    () => createRequestHandler({
      apiKey: "replace_with_your_restricted_api_key",
      agentId: "test-agent",
    }),
    /ELEVENLABS_API_KEY must be replaced/,
  );
});

test("health check exposes no configuration or secrets", async () => {
  await withServer({}, async (baseURL) => {
    const response = await fetch(`${baseURL}/healthz`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { status: "ok", protocolVersion: 1 });
    assert.equal(response.headers.get("cache-control"), "no-store, max-age=0");
  });
});

test("session endpoint requests and remaps an ElevenLabs WebRTC token", async () => {
  let capturedURL;
  let capturedOptions;
  const fetchImpl = async (url, options) => {
    capturedURL = url;
    capturedOptions = options;
    return Response.json({ token: "short-lived-token" });
  };

  await withServer({ fetchImpl }, async (baseURL) => {
    const response = await sessionRequest(baseURL, validBody);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      protocolVersion: 1,
      conversationToken: "short-lived-token",
    });
    assert.equal(response.headers.get("cache-control"), "no-store, max-age=0");
  });

  assert.equal(
    capturedURL.toString(),
    "https://api.elevenlabs.io/v1/convai/conversation/token?agent_id=test-agent",
  );
  assert.equal(capturedOptions.method, "GET");
  assert.equal(capturedOptions.headers["xi-api-key"], "test-api-key");
});

test("session endpoint rejects capabilities outside the exact read-only allowlist", async () => {
  let upstreamCallCount = 0;
  await withServer({
    fetchImpl: async () => {
      upstreamCallCount += 1;
      return Response.json({ token: "must-not-be-issued" });
    },
  }, async (baseURL) => {
    const response = await sessionRequest(baseURL, {
      protocolVersion: 1,
      capabilities: [...CAPABILITIES, "mutateArrangement"],
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), {
      message: "Unsupported voice-session capability set.",
    });
  });
  assert.equal(upstreamCallCount, 0);
});

test("session endpoint rejects additional assessment or geometry fields", async () => {
  let upstreamCallCount = 0;
  await withServer({
    fetchImpl: async () => {
      upstreamCallCount += 1;
      return Response.json({ token: "must-not-be-issued" });
    },
  }, async (baseURL) => {
    const response = await sessionRequest(baseURL, {
      ...validBody,
      roomGeometry: { points: [[0, 0], [1, 1]] },
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), {
      message: "The request may contain only protocolVersion and capabilities.",
    });
  });
  assert.equal(upstreamCallCount, 0);
});

test("session endpoint surfaces a stable provider refusal without leaking its body", async () => {
  await withServer({
    fetchImpl: async () => Response.json(
      { detail: "secret provider diagnostics" },
      { status: 401 },
    ),
  }, async (baseURL) => {
    const response = await sessionRequest(baseURL, validBody);
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), {
      message: "ElevenLabs refused the session request (401).",
    });
  });
});

test("session endpoint rejects malformed provider token responses", async () => {
  await withServer({
    fetchImpl: async () => Response.json({ unexpected: true }),
  }, async (baseURL) => {
    const response = await sessionRequest(baseURL, validBody);
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), {
      message: "ElevenLabs returned an invalid token response.",
    });
  });
});

test("session endpoint rate limits token creation by client address", async () => {
  await withServer({ rateLimitPerMinute: 1 }, async (baseURL) => {
    const first = await sessionRequest(baseURL, validBody);
    const second = await sessionRequest(baseURL, validBody);
    assert.equal(first.status, 200);
    assert.equal(second.status, 429);
    assert.equal(second.headers.get("retry-after"), "60");
  });
});

async function sessionRequest(baseURL, body) {
  return fetch(`${baseURL}/v1/voice/sessions`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function withServer(overrides, operation) {
  const handler = createRequestHandler({
    apiKey: "test-api-key",
    agentId: "test-agent",
    fetchImpl: async () => Response.json({ token: "test-token" }),
    logger: { error() {} },
    ...overrides,
  });
  const server = createServer(handler);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert(address && typeof address === "object");

  try {
    await operation(`http://127.0.0.1:${address.port}`);
  } finally {
    await new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
  }
}
