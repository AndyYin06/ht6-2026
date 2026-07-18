const PROTOCOL_VERSION = 1;
const CAPABILITIES = Object.freeze([
  "getRequirementEvidence",
  "focus",
  "clearFocus",
]);
const REQUEST_KEYS = Object.freeze(["capabilities", "protocolVersion"]);
const MAX_REQUEST_BYTES = 4_096;

class RequestError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function createRequestHandler({
  apiKey,
  agentId,
  fetchImpl = globalThis.fetch,
  rateLimitPerMinute = 30,
  upstreamTimeoutMs = 10_000,
  trustProxy = false,
  now = Date.now,
  logger = console,
} = {}) {
  requireConfiguration("ELEVENLABS_API_KEY", apiKey);
  requireConfiguration("ELEVENLABS_AGENT_ID", agentId);
  if (typeof fetchImpl !== "function") {
    throw new Error("A Fetch implementation is required.");
  }

  const limiter = createFixedWindowRateLimiter({
    limit: positiveInteger(rateLimitPerMinute, "RATE_LIMIT_PER_MINUTE"),
    windowMs: 60_000,
    now,
  });
  const timeoutMs = positiveInteger(upstreamTimeoutMs, "UPSTREAM_TIMEOUT_MS");

  return async function handleRequest(request, response) {
    setSecurityHeaders(response);
    const path = new URL(request.url ?? "/", "http://localhost").pathname;

    if (request.method === "GET" && path === "/healthz") {
      sendJSON(response, 200, { status: "ok", protocolVersion: PROTOCOL_VERSION });
      return;
    }

    if (path !== "/v1/voice/sessions") {
      sendJSON(response, 404, { message: "Not found." });
      return;
    }
    if (request.method !== "POST") {
      response.setHeader("Allow", "POST");
      sendJSON(response, 405, { message: "Method not allowed." });
      return;
    }

    const rateLimit = limiter.check(clientAddress(request, trustProxy));
    response.setHeader("X-RateLimit-Limit", String(rateLimit.limit));
    response.setHeader("X-RateLimit-Remaining", String(rateLimit.remaining));
    if (!rateLimit.allowed) {
      response.setHeader("Retry-After", String(rateLimit.retryAfterSeconds));
      sendJSON(response, 429, { message: "Too many voice-session requests. Try again shortly." });
      return;
    }

    try {
      requireJSONContentType(request);
      const body = await readJSONBody(request, MAX_REQUEST_BYTES);
      validateSessionRequest(body);
    } catch (error) {
      const status = error instanceof RequestError ? error.status : 400;
      sendJSON(response, status, { message: error.message || "Invalid request." });
      return;
    }

    const tokenURL = new URL("https://api.elevenlabs.io/v1/convai/conversation/token");
    tokenURL.searchParams.set("agent_id", agentId);

    let upstream;
    try {
      upstream = await fetchImpl(tokenURL, {
        method: "GET",
        headers: {
          Accept: "application/json",
          "xi-api-key": apiKey,
        },
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (error) {
      logger.error?.("ElevenLabs token request failed before receiving a response.", {
        cause: error instanceof Error ? error.name : "UnknownError",
      });
      sendJSON(response, 502, { message: "The voice provider could not be reached." });
      return;
    }

    if (!upstream.ok) {
      logger.error?.("ElevenLabs refused a conversation-token request.", {
        upstreamStatus: upstream.status,
      });
      sendJSON(response, 502, {
        message: `ElevenLabs refused the session request (${upstream.status}).`,
      });
      return;
    }

    let tokenPayload;
    try {
      tokenPayload = await upstream.json();
    } catch {
      sendJSON(response, 502, { message: "ElevenLabs returned an invalid token response." });
      return;
    }

    if (typeof tokenPayload?.token !== "string" || tokenPayload.token.length === 0) {
      sendJSON(response, 502, { message: "ElevenLabs returned an invalid token response." });
      return;
    }

    sendJSON(response, 200, {
      protocolVersion: PROTOCOL_VERSION,
      conversationToken: tokenPayload.token,
    });
  };
}

export { CAPABILITIES, PROTOCOL_VERSION };

function validateSessionRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new RequestError(400, "The request body must be a JSON object.");
  }

  const keys = Object.keys(body).sort();
  if (keys.length !== REQUEST_KEYS.length || keys.some((key, index) => key !== REQUEST_KEYS[index])) {
    throw new RequestError(
      400,
      "The request may contain only protocolVersion and capabilities.",
    );
  }
  if (body.protocolVersion !== PROTOCOL_VERSION) {
    throw new RequestError(400, "Unsupported voice-session protocol version.");
  }
  if (!Array.isArray(body.capabilities)) {
    throw new RequestError(400, "Capabilities must be an array.");
  }

  const received = [...body.capabilities].sort();
  const expected = [...CAPABILITIES].sort();
  const isExactSet = received.length === expected.length
    && new Set(received).size === expected.length
    && received.every((capability, index) => capability === expected[index]);
  if (!isExactSet) {
    throw new RequestError(400, "Unsupported voice-session capability set.");
  }
}

async function readJSONBody(request, maximumBytes) {
  const chunks = [];
  let byteCount = 0;
  for await (const chunk of request) {
    byteCount += chunk.length;
    if (byteCount > maximumBytes) {
      throw new RequestError(413, "The request body is too large.");
    }
    chunks.push(chunk);
  }

  if (byteCount === 0) {
    throw new RequestError(400, "A JSON request body is required.");
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new RequestError(400, "The request body is not valid JSON.");
  }
}

function requireJSONContentType(request) {
  const contentType = request.headers["content-type"] ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new RequestError(415, "Content-Type must be application/json.");
  }
}

function sendJSON(response, status, payload) {
  const body = JSON.stringify(payload);
  response.statusCode = status;
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Content-Length", Buffer.byteLength(body));
  response.end(body);
}

function setSecurityHeaders(response) {
  response.setHeader("Cache-Control", "no-store, max-age=0");
  response.setHeader("Pragma", "no-cache");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("X-Frame-Options", "DENY");
}

function clientAddress(request, trustProxy) {
  if (trustProxy) {
    const forwarded = request.headers["x-forwarded-for"];
    if (typeof forwarded === "string" && forwarded.length > 0) {
      return forwarded.split(",", 1)[0].trim();
    }
  }
  return request.socket.remoteAddress ?? "unknown";
}

function createFixedWindowRateLimiter({ limit, windowMs, now }) {
  const clients = new Map();
  return {
    check(key) {
      const currentTime = now();
      let entry = clients.get(key);
      if (!entry || currentTime >= entry.resetAt) {
        entry = { count: 0, resetAt: currentTime + windowMs };
        clients.set(key, entry);
      }
      entry.count += 1;
      const allowed = entry.count <= limit;
      return {
        allowed,
        limit,
        remaining: Math.max(0, limit - entry.count),
        retryAfterSeconds: Math.max(1, Math.ceil((entry.resetAt - currentTime) / 1_000)),
      };
    },
  };
}

function requireConfiguration(name, value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${name} is required.`);
  }
  if (value.startsWith("replace_with_")) {
    throw new Error(`${name} must be replaced with a real value.`);
  }
}

function positiveInteger(value, name) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer.`);
  }
  return parsed;
}
