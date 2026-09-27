// Shared filesystem predicates used by the app-owned sidecar services.
// they had drifted: two rethrew non-ENOENT errors, one swallowed them, so an
// EACCES path read as "absent" and the caller happily created over it.
// Rethrowing is the behaviour kept here — only "not there" answers false.

import { access } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";

export async function pathExists(path) {
  try {
    await access(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

export async function pathIsMissing(path) {
  return !(await pathExists(path));
}

/** `path` is absolute and strictly inside `root` (never `root` itself). */
export function isWithin(root, path) {
  if (typeof root !== "string" || !root || typeof path !== "string" || !isAbsolute(path)) return false;
  const child = relative(resolve(root), resolve(path));
  return child !== "" && child !== ".." && !child.startsWith(`..${sep}`) && !isAbsolute(child);
}
