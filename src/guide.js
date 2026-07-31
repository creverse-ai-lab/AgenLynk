#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { GatewayRpcClient } from "./socket-rpc.js";
import { GATEWAY_VERSION } from "./version.js";

const rpc = new GatewayRpcClient({ autoStart: false });
const tool = {
  name: "agent_acp_guide",
  description: "Read ACP worker role, provider availability, and delegation restrictions. This tool cannot control agents.",
  inputSchema: { type: "object", properties: {} }
};
const server = new Server(
  { name: "acp-gateway-guide", version: GATEWAY_VERSION },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [tool] }));
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name !== tool.name) return result({ ok: false, error: "Unknown tool" }, true);
  try {
    return result(await rpc.call("guide"));
  } catch {
    return result({
      ok: true,
      role: "worker",
      controlAvailable: false,
      rule: "Only the interactive Main agent may control ACP worker sessions.",
      gateway: "offline"
    });
  }
});

await server.connect(new StdioServerTransport());

function result(data, isError = false) {
  return {
    content: [{ type: "text", text: JSON.stringify(data) }],
    structuredContent: data,
    isError
  };
}
