// Starts a domain function: `serve(fn)` as the last line of its index.ts.
import { supabaseDeps, type Tx } from "./supabase.ts";
import type { defineFunction } from "./router.ts";

export function serve(fn: ReturnType<typeof defineFunction<Tx>>) {
  const deps = supabaseDeps();
  Deno.serve((req) => fn.handle(req, deps));
}
