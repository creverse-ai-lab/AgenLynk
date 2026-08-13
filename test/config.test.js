import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { controlIdentity } from "../sidecar/src/app/config.js";

test("Control bridge loads its identity from installer state without embedded credentials", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-control-identity-"));
  const statePath = join(directory, "install.json");
  try {
    await writeFile(statePath, JSON.stringify({
      version: 1,
      managedMcp: {},
      identity: {
        token: "stored-control-token-at-least-24-characters",
        rootId: "stored-main"
      }
    }));
    assert.deepEqual(controlIdentity({ env: {}, statePath }), {
      token: "stored-control-token-at-least-24-characters",
      rootId: "stored-main",
      statePath
    });
    assert.deepEqual(controlIdentity({
      env: {
        ACP_GATEWAY_CONTROL_TOKEN: "explicit-control-token-at-least-24-characters",
        ACP_GATEWAY_ROOT_ID: "explicit-main"
      },
      statePath
    }), {
      token: "explicit-control-token-at-least-24-characters",
      rootId: "explicit-main",
      statePath
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
