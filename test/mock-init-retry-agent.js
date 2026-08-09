import { existsSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

const marker = process.argv[2];
const failInitialize = !existsSync(marker);
if (failInitialize) writeFileSync(marker, "failed-once");

const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method !== "initialize") return;
  if (failInitialize) {
    process.stdout.write(`${JSON.stringify({
      jsonrpc: "2.0",
      id: message.id,
      error: { code: -32000, message: "initialize failed once" }
    })}\n`);
    return;
  }
  process.stdout.write(`${JSON.stringify({
    jsonrpc: "2.0",
    id: message.id,
    result: { protocolVersion: 1, agentCapabilities: {} }
  })}\n`);
});
