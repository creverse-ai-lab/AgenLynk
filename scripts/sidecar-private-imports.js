// Sidecar boundary guard: no import may reach an AgenLynk-owned Gateway
// implementation. gateway/client.js may dynamically load only the verified
// public entrypoint supplied by Swift.
import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";

export const PUBLIC_CLIENT_RELATIVE_PATH = "gateway/client.js";

export const PRIVATE_IMPORT_PATTERNS = [
  { id: "private-src-import", regex: /(?:from\s+|import\s*\(|new\s+URL)\s*\(?\s*["'`][^"'`\n]*(?:\.\.\/){2,}src\// },
  { id: "legacy-adapter", regex: /legacy-adapter\.js/ },
  { id: "package-private-subpath", regex: /acp-gateway\/src\// },
  { id: "createRequire", regex: /\bcreateRequire\s*\(/ }
];

export function findForbiddenPrivateImportPatterns(source) {
  if (typeof source !== "string" || !source) return [];
  return PRIVATE_IMPORT_PATTERNS.filter((pattern) => pattern.regex.test(source)).map((pattern) => pattern.id);
}

export async function collectSidecarPrivateImportViolations(sourceRoot) {
  const violations = [];
  for (const path of await javascriptFiles(sourceRoot)) {
    const source = await readFile(path, "utf8");
    const patterns = findForbiddenPrivateImportPatterns(source);
    const rel = relative(sourceRoot, path);
    if (rel !== PUBLIC_CLIENT_RELATIVE_PATH && /\bpathToFileURL\s*\(/.test(source)) patterns.push("pathToFileURL");
    if (patterns.length) violations.push({ path: rel, patterns: [...new Set(patterns)] });
  }
  return violations;
}

async function javascriptFiles(root) {
  const files = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) files.push(...await javascriptFiles(path));
    else if (entry.isFile() && entry.name.endsWith(".js")) files.push(path);
  }
  return files;
}
