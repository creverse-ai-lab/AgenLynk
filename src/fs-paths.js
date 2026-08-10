// Shared filesystem predicates. Three modules had their own copy of this and
// they had drifted: two rethrew non-ENOENT errors, one swallowed them, so an
// EACCES path read as "absent" and the caller happily created over it.
// Rethrowing is the behaviour kept here — only "not there" answers false.

import { access } from "node:fs/promises";

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
