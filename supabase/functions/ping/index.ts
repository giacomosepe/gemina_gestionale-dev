// ping: the sample domain function on the new base (PM-146). `whoami` answers who the session is and which organization and role it has.
// It proves the whole chain: session check -> transaction as the user -> organization helper -> typed answer.
import { defineFunction } from "../_shared/router.ts";
import { serve } from "../_shared/serve.ts";
import { noInput } from "../_shared/schemas.ts";
import type { Tx } from "../_shared/supabase.ts";

export const ping = defineFunction<Tx>("ping", {
  whoami: {
    input: noInput,
    audience: "any",
    handler: (ctx) => Promise.resolve({ userId: ctx.userId, organizationId: ctx.organizationId, staffRole: ctx.staffRole }),
  },
});

serve(ping);
