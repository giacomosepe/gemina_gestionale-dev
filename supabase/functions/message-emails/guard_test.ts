import assert from "node:assert/strict";
import { parseAllowlist, recipientAllowed } from "./guard.ts";

const list = parseAllowlist(" Giacomo@GiacomoSepe.com, giacomo.sepe@icloud.com ,,");

Deno.test("allowlist is parsed, trimmed and lower-cased", () => {
  assert.deepEqual([...list].sort(), ["giacomo.sepe@icloud.com", "giacomo@giacomosepe.com"]);
  assert.equal(parseAllowlist(undefined).size, 0);
});

Deno.test("not live: only allowlisted addresses, any letter case", () => {
  assert.equal(recipientAllowed("GIACOMO.SEPE@icloud.com", false, list), true);
  assert.equal(recipientAllowed("client@example.com", false, list), false);
  assert.equal(recipientAllowed("giacomo.sepe@icloud.com.evil.io", false, list), false);
});

Deno.test("not live and empty allowlist: nobody", () => {
  assert.equal(recipientAllowed("giacomo.sepe@icloud.com", false, parseAllowlist("")), false);
});

Deno.test("live: everyone", () => {
  assert.equal(recipientAllowed("client@example.com", true, new Set()), true);
});
