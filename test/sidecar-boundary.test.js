import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { collectSidecarPrivateImportViolations, findForbiddenPrivateImportPatterns } from "../scripts/sidecar-private-imports.js";

test("private import guard rejects source-tree, legacy-adapter, and private package subpaths", () => {
  assert.deepEqual(findForbiddenPrivateImportPatterns('import { x } from "../../../src/socket-rpc.js";'), ["private-src-import"]);
  assert.deepEqual(findForbiddenPrivateImportPatterns('import x from "../gateway/legacy-adapter.js";'), ["legacy-adapter"]);
  assert.deepEqual(findForbiddenPrivateImportPatterns('import "acp-gateway/src/socket-rpc.js";'), ["package-private-subpath"]);
  assert.deepEqual(findForbiddenPrivateImportPatterns('import { GatewayRpcClient } from "../gateway/client.js";'), []);
});

test("scanner permits pathToFileURL only in the public client loader", async () => {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-sidecar-boundary-"));
  try {
    await mkdir(join(root, "gateway"), { recursive: true });
    await mkdir(join(root, "server"), { recursive: true });
    await writeFile(join(root, "gateway/client.js"), 'pathToFileURL(process.env.ACP_GATEWAY_CLIENT_ENTRYPOINT);\n');
    await writeFile(join(root, "server/monitor.js"), 'pathToFileURL("/tmp/private.js");\n');
    assert.deepEqual(await collectSidecarPrivateImportViolations(root), [{ path: "server/monitor.js", patterns: ["pathToFileURL"] }]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("actual sidecar imports only the Phase 3 public client boundary", async () => {
  const sourceRoot = fileURLToPath(new URL("../sidecar/src/", import.meta.url));
  assert.deepEqual(await collectSidecarPrivateImportViolations(sourceRoot), []);
});
