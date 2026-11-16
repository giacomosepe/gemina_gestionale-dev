import { resolve, sep } from "node:path";

/** True if the folder is inside a git repository (a .git is found from the folder upwards). Real data must never be written there. */
export async function insideRepo(dir: string): Promise<boolean> {
  for (let d = resolve(dir); ; d = resolve(d, "..")) {
    try { await Deno.stat(`${d}${sep}.git`); return true; } catch (e) { if (!(e instanceof Deno.errors.NotFound)) throw e; }
    if (resolve(d, "..") === d) return false;
  }
}
