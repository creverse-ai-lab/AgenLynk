import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { join } from "node:path";
import { access } from "node:fs/promises";
import { constants } from "node:fs";

const GROK_BIN = process.env.GROK_BIN || join(homedir(), ".grok/bin/grok");

export const PROVIDERS = ["grok", "claude", "codex"];

export const PROVIDER_MANIFESTS = {
  grok: {
    id: "grok",
    displayName: "Grok",
    agentCommand: GROK_BIN,
    adapter: "built-in",
    install: null
  },
  claude: {
    id: "claude",
    displayName: "Claude Code",
    agentCommand: process.env.CLAUDE_CODE_EXECUTABLE || join(homedir(), ".local/bin/claude"),
    adapter: "@agentclientprotocol/claude-agent-acp",
    install: "npm install -g @agentclientprotocol/claude-agent-acp"
  },
  codex: {
    id: "codex",
    displayName: "Codex CLI",
    agentCommand: process.env.CODEX_PATH || "codex",
    adapter: process.env.CODEX_ACP_BIN || "codex-acp",
    install: "npm install -g @agentclientprotocol/codex-acp"
  }
};

export function providerConfig(provider, { model } = {}) {
  if (provider === "grok") {
    const selectedModel = optionalModel(model) ?? "grok-4.5";
    return {
      provider,
      command: GROK_BIN,
      args: [
        "--sandbox",
        "off",
        "--permission-mode",
        "default",
        "agent",
        "--model",
        selectedModel,
        "stdio"
      ],
      permissionPolicy: "ask",
      expectedModel: selectedModel,
      modelScope: "process"
    };
  }

  if (provider === "claude") {
    return {
      provider,
      command: process.execPath,
      args: [
        fileURLToPath(
          import.meta.resolve("@agentclientprotocol/claude-agent-acp/dist/index.js")
        )
      ],
      env: {
        CLAUDE_CODE_EXECUTABLE:
          process.env.CLAUDE_CODE_EXECUTABLE || join(homedir(), ".local/bin/claude")
      },
      permissionPolicy: "ask",
      expectedModel: null,
      modelScope: "session"
    };
  }

  if (provider === "codex") {
    return {
      provider,
      command: process.env.CODEX_ACP_BIN || "codex-acp",
      args: [],
      env: {
        CODEX_PATH: process.env.CODEX_PATH || "codex",
        NO_BROWSER: "1"
      },
      permissionPolicy: "ask",
      expectedModel: null,
      modelScope: "session"
    };
  }

  throw new Error(`provider must be one of: ${PROVIDERS.join(", ")}`);
}

export async function detectProviders() {
  return Promise.all(
    Object.values(PROVIDER_MANIFESTS).map(async (manifest) => ({
      ...manifest,
      agentInstalled: await executableExists(manifest.agentCommand),
      adapterInstalled:
        manifest.adapter === "built-in" || manifest.id === "claude"
          ? true
          : await executableExists(manifest.adapter)
    }))
  );
}

async function executableExists(command) {
  if (!command) return false;
  if (command.includes("/")) {
    try {
      await access(command, constants.X_OK);
      return true;
    } catch {
      return false;
    }
  }
  const paths = (process.env.PATH ?? "").split(":").filter(Boolean);
  for (const directory of paths) {
    try {
      await access(join(directory, command), constants.X_OK);
      return true;
    } catch {
      // Continue searching PATH.
    }
  }
  return false;
}

export function currentModelId(initResult) {
  return initResult?._meta?.modelState?.currentModelId ?? null;
}

function optionalModel(value) {
  if (value == null) return null;
  if (typeof value !== "string" || !value.trim()) throw new Error("model must be a non-empty string");
  return value.trim();
}
