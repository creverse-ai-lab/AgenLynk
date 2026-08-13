// Static check that sidecar/src reaches Gateway private code only through
// gateway/legacy-adapter.js. Covers import/from plus the common static
// bypasses (URL/new URL, createRequire, pathToFileURL).
import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";

export const LEGACY_ADAPTER_RELATIVE_PATH = "gateway/legacy-adapter.js";

export const PRIVATE_IMPORT_PATTERNS = [
  {
    id: "static-import",
    regex: /(?:from\s+|import\s*\()\s*["'`][^"'`\n]*(?:\.\.\/){2,}src\//
  },
  {
    id: "url-constructor",
    regex: /(?:new\s+URL|\bURL)\s*\(\s*["'`][^"'`\n]*(?:\.\.\/){2,}src\//
  },
  {
    id: "createRequire",
    regex: /\bcreateRequire\s*\(/
  },
  {
    id: "pathToFileURL",
    regex: /\bpathToFileURL\s*\(/
  }
];

export function findForbiddenPrivateImportPatterns(source) {
  if (typeof source !== "string" || !source) return [];
  return PRIVATE_IMPORT_PATTERNS
    .filter((pattern) => pattern.regex.test(source))
    .map((pattern) => pattern.id);
}

export async function collectSidecarPrivateImportViolations(sourceRoot) {
  const adapterPath = join(sourceRoot, ...LEGACY_ADAPTER_RELATIVE_PATH.split("/"));
  const violations = [];
  for (const path of await javascriptFiles(sourceRoot)) {
    if (path === adapterPath) continue;
    const patterns = findForbiddenPrivateImportPatterns(await readFile(path, "utf8"));
    if (patterns.length) {
      violations.push({ path: relative(sourceRoot, path), patterns });
    }
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
