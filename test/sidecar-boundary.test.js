import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  collectSidecarPrivateImportViolations,
  findForbiddenPrivateImportPatterns
} from "../scripts/sidecar-private-imports.js";

test("legacy-adapter.js remains the only allowed Gateway private-import exception", async () => {
  const root = await mkdtemp(join(tmpdir(), "acp-sidecar-boundary-"));
  try {
    await mkdir(join(root, "gateway"), { recursive: true });
    await mkdir(join(root, "server"), { recursive: true });
    await writeFile(
      join(root, "gateway/legacy-adapter.js"),
      [
        'import { GatewayRpcClient } from "../../../src/socket-rpc.js";',
        'export const url = new URL("../../../src/gateway-daemon.js", import.meta.url);',
        'import { createRequire } from "node:module";',
        "createRequire(import.meta.url);",
        "pathToFileURL(\"/tmp/x.js\");",
        ""
      ].join("\n")
    );
    await writeFile(join(root, "server/monitor.js"), 'export const ok = true;\n');
    assert.deepEqual(await collectSidecarPrivateImportViolations(root), []);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("private import guard rejects static import, URL, createRequire, and pathToFileURL bypasses", () => {
  assert.deepEqual(
    findForbiddenPrivateImportPatterns('import { x } from "../../../src/socket-rpc.js";'),
    ["static-import"]
  );
  assert.deepEqual(
    findForbiddenPrivateImportPatterns('const mod = await import("../../../src/config.js");'),
    ["static-import"]
  );
  assert.deepEqual(
    findForbiddenPrivateImportPatterns('export const url = new URL("../../../src/gateway-daemon.js", import.meta.url);'),
    ["url-constructor"]
  );
  assert.deepEqual(
    findForbiddenPrivateImportPatterns('const url = URL("../../../src/installer.js");'),
    ["url-constructor"]
  );
  assert.deepEqual(
    findForbiddenPrivateImportPatterns("const require = createRequire(import.meta.url);"),
    ["createRequire"]
  );
  assert.deepEqual(
    findForbiddenPrivateImportPatterns("await import(pathToFileURL(join(root, \"src/version.js\")));"),
    ["pathToFileURL"]
  );
  assert.deepEqual(
    findForbiddenPrivateImportPatterns('import { GatewayRpcClient } from "../gateway/legacy-adapter.js";'),
    []
  );
});

test("scanner reports forbidden patterns outside the adapter", async () => {
  const root = await mkdtemp(join(tmpdir(), "acp-sidecar-boundary-"));
  try {
    await mkdir(join(root, "gateway"), { recursive: true });
    await mkdir(join(root, "server"), { recursive: true });
    await writeFile(join(root, "gateway/legacy-adapter.js"), 'import { x } from "../../../src/foo.js";\n');
    await writeFile(join(root, "server/monitor.js"), 'import { x } from "../../../src/foo.js";\n');
    const violations = await collectSidecarPrivateImportViolations(root);
    assert.deepEqual(violations, [{ path: "server/monitor.js", patterns: ["static-import"] }]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("actual sidecar/src has no private Gateway access outside legacy-adapter.js", async () => {
  const sourceRoot = fileURLToPath(new URL("../sidecar/src/", import.meta.url));
  assert.deepEqual(await collectSidecarPrivateImportViolations(sourceRoot), []);
});
