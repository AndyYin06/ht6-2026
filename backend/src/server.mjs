import { createServer } from "node:http";
import { createRequestHandler } from "./app.mjs";

const host = process.env.HOST?.trim() || "127.0.0.1";
const port = portNumber(process.env.PORT ?? "8787");

const handler = createRequestHandler({
  apiKey: process.env.ELEVENLABS_API_KEY,
  agentId: process.env.ELEVENLABS_AGENT_ID,
  rateLimitPerMinute: process.env.RATE_LIMIT_PER_MINUTE ?? 30,
  upstreamTimeoutMs: process.env.UPSTREAM_TIMEOUT_MS ?? 10_000,
  trustProxy: process.env.TRUST_PROXY === "true",
});

const server = createServer((request, response) => {
  handler(request, response).catch((error) => {
    console.error("Unhandled voice-backend request failure.", {
      cause: error instanceof Error ? error.name : "UnknownError",
    });
    if (!response.headersSent) {
      response.writeHead(500, {
        "Cache-Control": "no-store",
        "Content-Type": "application/json; charset=utf-8",
      });
    }
    response.end(JSON.stringify({ message: "Internal server error." }));
  });
});

server.listen(port, host, () => {
  console.log(`AccessiRoom voice backend listening on http://${host}:${port}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close((error) => {
      if (error) {
        console.error("Voice backend shutdown failed.");
        process.exitCode = 1;
      }
    });
  });
}

function portNumber(rawValue) {
  const parsed = Number(rawValue);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > 65_535) {
    throw new Error("PORT must be an integer from 1 through 65535.");
  }
  return parsed;
}
