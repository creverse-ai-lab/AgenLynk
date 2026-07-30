import { createInterface } from "node:readline";

const rl = createInterface({ input: process.stdin });
let nextId = 100;
const pending = new Map();
const sessionModels = new Map();

function configOptions(sessionId) {
  return [{
    type: "select",
    id: "model",
    name: "Model",
    category: "model",
    currentValue: sessionModels.get(sessionId) ?? "mock-default",
    options: [
      { value: "mock-default", name: "Mock Default" },
      { value: "mock-pro", name: "Mock Pro" }
    ]
  }];
}

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (Object.hasOwn(message, "id") && (Object.hasOwn(message, "result") || message.error)) {
    pending.get(message.id)?.(message.result);
    pending.delete(message.id);
    return;
  }
  if (message.method === "initialize") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: {
        protocolVersion: 1,
        agentCapabilities: { sessionCapabilities: { resume: {}, close: {} } }
      }
    });
    return;
  }
  if (message.method === "session/new") {
    sessionModels.set("mock-session", "mock-default");
    send({ jsonrpc: "2.0", id: message.id, result: { sessionId: "mock-session", configOptions: configOptions("mock-session") } });
    return;
  }
  if (message.method === "session/resume") {
    sessionModels.set(message.params.sessionId, sessionModels.get(message.params.sessionId) ?? "mock-default");
    send({ jsonrpc: "2.0", id: message.id, result: { sessionId: message.params.sessionId, configOptions: configOptions(message.params.sessionId) } });
    return;
  }
  if (message.method === "session/set_config_option") {
    const { sessionId, configId, value } = message.params;
    if (configId !== "model" || !["mock-default", "mock-pro"].includes(value)) {
      send({ jsonrpc: "2.0", id: message.id, error: { code: -32602, message: "invalid model" } });
      return;
    }
    sessionModels.set(sessionId, value);
    send({ jsonrpc: "2.0", id: message.id, result: { configOptions: configOptions(sessionId) } });
    return;
  }
  if (message.method === "session/close") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    return;
  }
  if (message.method === "session/prompt") {
    const prompt = message.params.prompt?.[0]?.text;
    send({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId: message.params.sessionId,
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "READY " } }
      }
    });
    const permissionId = nextId++;
    pending.set(permissionId, (result) => {
      const allowed = ["allow-once", "allow-always"].includes(result?.outcome?.optionId);
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: message.params.sessionId,
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: allowed ? "DONE" : "DENIED" }
          }
        }
      });
      send({ jsonrpc: "2.0", id: message.id, result: { stopReason: "end_turn" } });
    });
    send({
      jsonrpc: "2.0",
      id: permissionId,
      method: "session/request_permission",
      params: {
        sessionId: message.params.sessionId,
        toolCall: { toolCallId: "tool-1", title: "Edit file", kind: "edit" },
        options: prompt === "allow-always-only"
          ? [{ optionId: "allow-always", name: "Always allow", kind: "allow_always" }]
          : [
              { optionId: "allow-once", name: "Allow once", kind: "allow_once" },
              { optionId: "reject-once", name: "Reject", kind: "reject_once" }
            ]
      }
    });
  }
});
